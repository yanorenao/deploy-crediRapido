output "resource_group_name" {
  description = "El nombre del grupo de recursos aprovisionado"
  value       = azurerm_resource_group.rg.name
}

output "api_url" {
  description = "URL externa de la Container App expuesta"
  value       = azurerm_container_app.app.ingress[0].fqdn
}

output "database_fqdn" {
  description = "Nombre de dominio calificado de la base de datos PostgreSQL (primario)"
  value       = azurerm_postgresql_flexible_server.pg.fqdn
}

output "database_replica_fqdn" {
  description = "Nombre de dominio calificado de la réplica de lectura PostgreSQL"
  value       = azurerm_postgresql_flexible_server.pg_read_replica.fqdn
}

output "key_vault_uri" {
  description = "URI del Key Vault"
  value       = azurerm_key_vault.kv.vault_uri
}

output "acr_login_server" {
  description = "Servidor de login del Azure Container Registry"
  value       = azurerm_container_registry.acr.login_server
}

output "servicebus_namespace_fqdn" {
  description = "FQDN del namespace de Service Bus"
  value       = "${azurerm_servicebus_namespace.sb.name}.servicebus.windows.net"
}

output "servicebus_queue_name" {
  description = "Nombre de la cola de eventos de Service Bus"
  value       = azurerm_servicebus_queue.events_queue.name
}

output "cosmosdb_endpoint" {
  description = "Endpoint de Cosmos DB para idempotencia de eventos"
  value       = azurerm_cosmosdb_account.cosmos.endpoint
}

output "application_insights_connection_string" {
  description = "Connection string de Application Insights para instrumentación"
  value       = azurerm_application_insights.appins.connection_string
  sensitive   = true
}

output "application_insights_instrumentation_key" {
  description = "Instrumentation Key de Application Insights"
  value       = azurerm_application_insights.appins.instrumentation_key
  sensitive   = true
}

output "func_producer_principal_id" {
  description = "Principal ID de la Managed Identity de la Function productora"
  value       = azurerm_linux_function_app.producer_app.identity[0].principal_id
}

output "func_consumer_principal_id" {
  description = "Principal ID de la Managed Identity de la Function consumidora"
  value       = azurerm_linux_function_app.consumer_app.identity[0].principal_id
}

output "container_app_principal_id" {
  description = "Principal ID de la Managed Identity de la Container App API"
  value       = azurerm_container_app.app.identity[0].principal_id
}
