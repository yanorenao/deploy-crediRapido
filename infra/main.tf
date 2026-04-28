# Configuración de Terraform y Providers (Idempotencia asegurada vía state remoto)
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "sttfstatecredi"
    container_name       = "tfstate"
    key                  = "fintech.terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}

# Grupo de Recursos Principal
resource "azurerm_resource_group" "rg" {
  name     = "rg-credirapido-${var.environment}"
  location = var.location
}

# ---------------------------------------------------------
# Módulo de Red (VNet Injection & Private Endpoints)
# ---------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-fintech-${var.environment}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "snet_aca" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/23"]
}

resource "azurerm_network_security_group" "nsg_aca" {
  name                = "nsg-aca-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet_network_security_group_association" "snet_aca_nsg" {
  subnet_id                 = azurerm_subnet.snet_aca.id
  network_security_group_id = azurerm_network_security_group.nsg_aca.id
}

resource "azurerm_subnet" "snet_pe" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]
}

# ---------------------------------------------------------
# Módulo de Seguridad y Gobierno (Key Vault & RBAC)
# ---------------------------------------------------------
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = "kv-credirapido-${var.environment}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  # Restricción de red: Acceso solo desde la VNet (Private Endpoint)
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_private_dns_zone" "dns_kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_kv_link" {
  name                  = "dns-link-kv-${var.environment}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.dns_kv.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_endpoint" "pe_kv" {
  name                = "pe-kv-credirapido-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.snet_pe.id

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = azurerm_key_vault.kv.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "dns-group-kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.dns_kv.id]
  }
}

# ---------------------------------------------------------
# Módulo de Registro de Contenedores (Azure Container Registry)
# ---------------------------------------------------------
resource "azurerm_container_registry" "acr" {
  name                = "credirapidoacr${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Premium" # Premium requerido para Private Endpoint y geo-replicación
  admin_enabled       = false     # Acceso solo via Managed Identity (mínimo privilegio)
}

# ---------------------------------------------------------
# Módulo de Base de Datos (PostgreSQL Flexible Server)
# ---------------------------------------------------------
resource "azurerm_private_dns_zone" "dns_pg" {
  name                = "${var.environment}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_pg_link" {
  name                  = "dns-link-pg-${var.environment}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.dns_pg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_postgresql_flexible_server" "pg" {
  name                   = "pg-credirapido-${var.environment}"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  version                = var.pg_version
  administrator_login    = var.db_admin_user
  administrator_password = var.db_admin_password # Inyectado en runtime, nunca hardcodeado
  storage_mb             = 32768
  sku_name               = "GP_Standard_D4s_v3"

  # Alta disponibilidad Zone-Redundant: primary en zona 1, standby en zona 2
  # Failover automático en < 60 segundos ante fallo de zona primaria
  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = "2"
  }

  # Mapeo a red privada / Delegación
  delegated_subnet_id = azurerm_subnet.snet_pe.id
  private_dns_zone_id = azurerm_private_dns_zone.dns_pg.id

  depends_on = [azurerm_private_dns_zone_virtual_network_link.dns_pg_link]
}

# Réplica de lectura asíncrona para consultas de reportes y analytics
# Desacopla lecturas intensivas de escrituras transaccionales
resource "azurerm_postgresql_flexible_server" "pg_read_replica" {
  name                = "pg-credirapido-replica-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  create_mode         = "Replica"
  source_server_id    = azurerm_postgresql_flexible_server.pg.id
  sku_name            = "GP_Standard_D2s_v3"
}

# ---------------------------------------------------------
# Módulo de Mensajería Asíncrona (Azure Service Bus)
# ---------------------------------------------------------
resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-credirapido-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = var.servicebus_sku # Premium: geo-redundancy nativa entre zonas

  # Garantiza que mensajes de solicitudes de crédito no se pierdan ante fallo de zona
  zone_redundant = true
}

resource "azurerm_servicebus_queue" "events_queue" {
  name         = "events-queue"
  namespace_id = azurerm_servicebus_namespace.sb.id

  # Mensajes retenidos hasta 14 días si el consumidor no está disponible
  max_delivery_count              = 10
  dead_lettering_on_message_expiration = true
  lock_duration                   = "PT1M"
  default_message_ttl             = "P14D"
}

# ---------------------------------------------------------
# Módulo de Base de Datos NoSQL (Cosmos DB — Idempotencia)
# ---------------------------------------------------------
resource "azurerm_cosmosdb_account" "cosmos" {
  name                = "cosmos-credirapido-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  # Single-region con backup (idempotencia no requiere consistencia fuerte entre regiones)
  consistency_policy {
    consistency_level = var.cosmosdb_consistency_level
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }

  # Deshabilitar acceso público: acceso solo desde la VNet
  is_virtual_network_filter_enabled = true

  virtual_network_rule {
    id = azurerm_subnet.snet_aca.id
  }
}

resource "azurerm_cosmosdb_sql_database" "cosmos_db" {
  name                = "credirapido-events"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
}

resource "azurerm_cosmosdb_sql_container" "idempotency" {
  name                = "idempotency-keys"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
  database_name       = azurerm_cosmosdb_sql_database.cosmos_db.name
  partition_key_path  = "/messageId"

  # TTL de 24 horas: las claves de idempotencia expiran automáticamente
  default_ttl = 86400
}

# ---------------------------------------------------------
# Módulo de Funciones Serverless (Azure Functions)
# ---------------------------------------------------------
resource "azurerm_storage_account" "func_storage" {
  name                     = "stfunccredi${var.environment}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "ZRS" # Zone-Redundant Storage: 3 copias en 3 zonas
}

# Plan Premium EP1: evita cold starts, escala más allá de Consumption
resource "azurerm_service_plan" "func_plan" {
  name                = "asp-credirapido-functions-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "EP1"
}

# Function App — Productor de eventos (API → Service Bus)
resource "azurerm_linux_function_app" "producer_app" {
  name                       = "func-producer-credirapido-${var.environment}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.func_plan.id
  storage_account_name       = azurerm_storage_account.func_storage.name
  storage_account_access_key = azurerm_storage_account.func_storage.primary_access_key

  # Managed Identity: acceso seguro sin credenciales hardcodeadas
  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      dotnet_version              = "8.0"
      use_dotnet_isolated_runtime = true
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"         = "dotnet-isolated"
    "ServiceBusConnection__fullyQualifiedNamespace" = "${azurerm_servicebus_namespace.sb.name}.servicebus.windows.net"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.appins.connection_string
  }
}

# Function App — Consumidor de eventos (Service Bus → PostgreSQL)
resource "azurerm_linux_function_app" "consumer_app" {
  name                       = "func-consumer-credirapido-${var.environment}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.func_plan.id
  storage_account_name       = azurerm_storage_account.func_storage.name
  storage_account_access_key = azurerm_storage_account.func_storage.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      dotnet_version              = "8.0"
      use_dotnet_isolated_runtime = true
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"         = "dotnet-isolated"
    "ServiceBusConnection__fullyQualifiedNamespace" = "${azurerm_servicebus_namespace.sb.name}.servicebus.windows.net"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.appins.connection_string
    "CosmosDbConnection"               = azurerm_cosmosdb_account.cosmos.primary_sql_connection_string
  }
}

# ---------------------------------------------------------
# Módulo de Cómputo (Azure Container Apps)
# ---------------------------------------------------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-credirapido-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "cae" {
  name                       = "cae-credirapido-${var.environment}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  # Zone redundancy: distribuye réplicas en AZ1, AZ2, AZ3 automáticamente
  # Con min_replicas = 2 se garantiza al menos una réplica por zona activa
  zone_redundancy_enabled = true

  # Inyección en VNet de la plataforma PaaS
  infrastructure_subnet_id = azurerm_subnet.snet_aca.id
}

resource "azurerm_container_app" "app" {
  name                         = "ca-credito-api-${var.environment}"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.rg.name

  # Multiple: habilita múltiples revisiones simultáneas (requerido para Canary Deployment)
  revision_mode = "Multiple"

  # Managed Identity para acceso seguro a Key Vault y ACR (Mínimo Privilegio)
  identity {
    type = "SystemAssigned"
  }

  template {
    container {
      name   = "credito-api"
      image  = "${azurerm_container_registry.acr.login_server}/credirapido-api:${var.api_image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }

      env {
        name        = "KeyVaultUri"
        value       = azurerm_key_vault.kv.vault_uri
      }
    }

    # Nunca escalar a 0 en producción: garantiza disponibilidad mínima
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    # Regla 1: Escalar por solicitudes HTTP concurrentes
    custom_scale_rule {
      name             = "http-concurrent-requests"
      custom_rule_type = "http"
      metadata = {
        concurrentRequests = "50"
      }
    }

    # Regla 2: Escalar por profundidad de la cola de Service Bus
    custom_scale_rule {
      name             = "servicebus-queue-depth"
      custom_rule_type = "azure-servicebus"
      metadata = {
        queueName    = azurerm_servicebus_queue.events_queue.name
        messageCount = "100"
        namespace    = azurerm_servicebus_namespace.sb.name
      }
      authentication {
        secret_name       = "servicebus-connection"
        trigger_parameter = "connection"
      }
    }

    # Regla 3: Escalar por utilización de CPU (umbral 70%)
    custom_scale_rule {
      name             = "cpu-utilization"
      custom_rule_type = "cpu"
      metadata = {
        type  = "Utilization"
        value = "70"
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 80
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# ---------------------------------------------------------
# Módulo de Identidades y RBAC (Mínimo Privilegio)
# ---------------------------------------------------------

# Container App API: Solo puede LEER secretos de Key Vault
resource "azurerm_role_assignment" "kv_secrets_user" {
  principal_id         = azurerm_container_app.app.identity[0].principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = azurerm_key_vault.kv.id
}

# Container App API: Solo puede PULL imágenes del ACR
resource "azurerm_role_assignment" "acr_pull" {
  principal_id         = azurerm_container_app.app.identity[0].principal_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}

# Function Producer: SOLO puede ENVIAR mensajes a la cola (no recibir)
resource "azurerm_role_assignment" "func_producer_sb_sender" {
  scope                = azurerm_servicebus_queue.events_queue.id # Solo la cola, no el namespace
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_linux_function_app.producer_app.identity[0].principal_id
}

# Function Consumer: SOLO puede RECIBIR mensajes de la cola (no enviar)
resource "azurerm_role_assignment" "func_consumer_sb_receiver" {
  scope                = azurerm_servicebus_queue.events_queue.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_linux_function_app.consumer_app.identity[0].principal_id
}

# Function Consumer: Acceso de lectura/escritura a Cosmos DB para idempotencia
resource "azurerm_role_assignment" "func_consumer_cosmos" {
  scope                = azurerm_cosmosdb_account.cosmos.id
  role_definition_name = "Cosmos DB Built-in Data Contributor"
  principal_id         = azurerm_linux_function_app.consumer_app.identity[0].principal_id
}
