# ---------------------------------------------------------
# Módulo de Políticas como Código (Azure Policy — Compliance)
# ---------------------------------------------------------

# Política: Denegar creación de recursos con IP pública
# Garantiza que toda comunicación pase por Private Endpoints
resource "azurerm_resource_group_policy_assignment" "no_public_ip" {
  name               = "deny-public-ip-credirapido"
  resource_group_id  = azurerm_resource_group.rg.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114"
  description        = "Deniega la creación de recursos con IP pública. Todo acceso debe ser via Private Endpoint."
}

# Política: Requerir cifrado en reposo con Customer-Managed Key
resource "azurerm_resource_group_policy_assignment" "require_encryption" {
  name               = "require-encryption-at-rest"
  resource_group_id  = azurerm_resource_group.rg.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/b5ec538c-daa0-4006-8596-35468b9148e8"
  description        = "Requiere cifrado en reposo para todas las cuentas de almacenamiento."
}

# Política: Requerir TLS 1.2 o superior en todas las aplicaciones web
resource "azurerm_resource_group_policy_assignment" "require_tls" {
  name               = "require-tls-12"
  resource_group_id  = azurerm_resource_group.rg.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/f0e6e85b-9b9f-4a4b-b67b-f730d42f1b0b"
  description        = "Las aplicaciones web solo deben ser accesibles sobre HTTPS con TLS 1.2+."
}

# ---------------------------------------------------------
# Módulo de Gestión de Secretos (Key Vault — Rotación Automática)
# ---------------------------------------------------------

# Contraseña generada aleatoriamente para PostgreSQL (inyectada por Terraform, nunca hardcodeada)
resource "random_password" "db_pass" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Secreto de la contraseña de PostgreSQL con expiración a 90 días
# La expiración fuerza la rotación periódica antes de que el secreto comprometa la seguridad
resource "azurerm_key_vault_secret" "db_password" {
  name            = "credirapido-db-password"
  value           = random_password.db_pass.result
  key_vault_id    = azurerm_key_vault.kv.id
  expiration_date = timeadd(timestamp(), "2160h") # Expira en 90 días (2160h)

  tags = {
    rotation-policy = "auto-90d"
    service         = "postgresql"
    environment     = var.environment
  }

  lifecycle {
    ignore_changes = [expiration_date] # Evita regeneración en cada plan de Terraform
  }
}

# Secreto: Service Bus connection string para las Function Apps
resource "azurerm_key_vault_secret" "sb_connection" {
  name         = "credirapido-servicebus-connection"
  value        = azurerm_servicebus_namespace.sb.default_primary_connection_string
  key_vault_id = azurerm_key_vault.kv.id

  tags = {
    service     = "servicebus"
    environment = var.environment
  }
}

# Secreto: Application Insights connection string
resource "azurerm_key_vault_secret" "appins_connection" {
  name         = "credirapido-appinsights-connection"
  value        = azurerm_application_insights.appins.connection_string
  key_vault_id = azurerm_key_vault.kv.id

  tags = {
    service     = "application-insights"
    environment = var.environment
  }
}

# ---------------------------------------------------------
# Rotación Automática de Secretos (Event Grid + Azure Function)
# ---------------------------------------------------------

# Suscripción a Event Grid: activa la rotación 30 días antes de que el secreto venza
# La función de rotación actualiza la contraseña de PostgreSQL y publica el nuevo secreto.
# Las apps lo leen via Managed Identity sin necesidad de reinicio ni redeployment.
resource "azurerm_eventgrid_event_subscription" "secret_rotation" {
  name  = "credirapido-secret-rotation-${var.environment}"
  scope = azurerm_key_vault.kv.id

  included_event_types = [
    "Microsoft.KeyVault.SecretNearExpiry" # Disparado 30 días antes de vencer
  ]

  azure_function_endpoint {
    function_id = "${azurerm_linux_function_app.producer_app.id}/functions/RotateSecret"
  }
}

# ---------------------------------------------------------
# RBAC Adicional — Acceso a Key Vault para Functions y Pipeline
# ---------------------------------------------------------

# Function Producer: leer secretos de Key Vault (Service Bus connection)
resource "azurerm_role_assignment" "func_producer_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.producer_app.identity[0].principal_id
}

# Function Consumer: leer secretos de Key Vault (DB connection, etc.)
resource "azurerm_role_assignment" "func_consumer_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.consumer_app.identity[0].principal_id
}

# Pipeline CI/CD (Service Principal de GitHub Actions): PUSH de imágenes al ACR
# Permisos mínimos: solo AcrPush, no Owner ni Contributor
resource "azurerm_role_assignment" "pipeline_acr_push" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}
