variable "environment" {
  description = "El ambiente de despliegue (ej. dev, qa, staging, prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "La región de Azure para hospedar los recursos"
  type        = string
  default     = "East US 2"
}

variable "db_admin_user" {
  description = "Nombre de usuario administrador para PostgreSQL"
  type        = string
  default     = "pgadmin"
}

variable "db_admin_password" {
  description = "Contraseña para PostgreSQL (Debe ser inyectada vía pipeline, no hardcodeada)"
  type        = string
  sensitive   = true
}

variable "pg_version" {
  description = "Versión de PostgreSQL"
  type        = string
  default     = "15"
}

variable "api_image_tag" {
  description = "Etiqueta (tag) de la imagen del contenedor de API (formato: sha-<commit>)"
  type        = string
  default     = "latest"
}

variable "ops_email" {
  description = "Correo electrónico del equipo de operaciones para recibir alertas"
  type        = string
}

variable "slack_webhook_url" {
  description = "URL del webhook de Slack para notificaciones de alertas y rollback"
  type        = string
  sensitive   = true
}

variable "subscription_id" {
  description = "ID de la suscripción de Azure"
  type        = string
}

variable "servicebus_sku" {
  description = "SKU del Service Bus (Standard o Premium). Premium requerido para geo-redundancy"
  type        = string
  default     = "Premium"
}

variable "cosmosdb_consistency_level" {
  description = "Nivel de consistencia de Cosmos DB"
  type        = string
  default     = "Session"
}

variable "min_replicas" {
  description = "Número mínimo de réplicas de la Container App en producción"
  type        = number
  default     = 2
}

variable "max_replicas" {
  description = "Número máximo de réplicas de la Container App"
  type        = number
  default     = 20
}
