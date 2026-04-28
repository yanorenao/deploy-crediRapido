# ---------------------------------------------------------
# Módulo de Observabilidad (Application Insights & Azure Monitor)
# ---------------------------------------------------------

# Application Insights: telemetría distribuida de la API y Functions
resource "azurerm_application_insights" "appins" {
  name                = "appi-credirapido-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
}

# ---------------------------------------------------------
# Canal de Notificaciones (Action Group)
# ---------------------------------------------------------

# Action Group: agrupa los canales de notificación del equipo de operaciones
resource "azurerm_monitor_action_group" "ops_team" {
  name                = "ag-credirapido-ops-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "crediops"

  email_receiver {
    name          = "ops-email"
    email_address = var.ops_email
  }

  # Webhook a Slack para notificaciones de rollback automático
  webhook_receiver {
    name        = "slack-webhook"
    service_uri = var.slack_webhook_url
  }
}

# ---------------------------------------------------------
# Alertas de Métricas (Azure Monitor Metric Alerts)
# ---------------------------------------------------------

# Alerta crítica: Error Rate > 5% — dispara rollback del canary deployment
resource "azurerm_monitor_metric_alert" "error_rate_critical" {
  name                = "alert-credirapido-error-rate-critical-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_container_app.app.id]
  description         = "Tasa de error HTTP supera el 5%. Evaluar rollback del canary."
  severity            = 0 # Critical
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 5
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops_team.id
  }
}

# Alerta de advertencia: Error Rate > 0.5% — alerta temprana antes de umbral crítico
resource "azurerm_monitor_metric_alert" "error_rate_warning" {
  name                = "alert-credirapido-error-rate-warning-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_container_app.app.id]
  description         = "Tasa de error HTTP supera el 0.5%. Monitorear tendencia."
  severity            = 1 # Warning
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0.5
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops_team.id
  }
}

# Alerta: CPU > 80% — indica necesidad de escalar o investigar
resource "azurerm_monitor_metric_alert" "cpu_high" {
  name                = "alert-credirapido-cpu-high-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_container_app.app.id]
  description         = "Utilización de CPU supera el 80%. Verificar autoescalado."
  severity            = 1 # Warning
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "CpuPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops_team.id
  }
}

# Alerta: Profundidad de cola de Service Bus > 500 mensajes
# Indica backlog creciente: Functions no están procesando a la velocidad esperada
resource "azurerm_monitor_metric_alert" "servicebus_queue_depth" {
  name                = "alert-credirapido-queue-depth-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_servicebus_namespace.sb.id]
  description         = "Backlog de la cola supera los 500 mensajes. Riesgo de SLA."
  severity            = 1 # Warning
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "ActiveMessages"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 500
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops_team.id
  }
}

# ---------------------------------------------------------
# Alertas Log-Based (Azure Monitor Scheduled Query Rules)
# ---------------------------------------------------------

# Alerta: Latencia p95 > 500ms — degradación de experiencia del usuario
# Consulta KQL sobre Application Insights para calcular percentiles reales
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "latency_p95" {
  name                = "alert-credirapido-latency-p95-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  description         = "Latencia p95 supera los 500ms. Evaluar degradación del servicio."
  scopes              = [azurerm_application_insights.appins.id]
  severity            = 1 # Warning
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | where cloud_RoleName == 'credirapido-api'
      | summarize p95 = percentile(duration, 95)
      | where p95 > 500
    QUERY

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops_team.id]
  }
}

# Alerta: Latencia p99 > 1000ms — degradación severa para usuarios de cola
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "latency_p99" {
  name                = "alert-credirapido-latency-p99-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  description         = "Latencia p99 supera el segundo. Degradación severa detectada."
  scopes              = [azurerm_application_insights.appins.id]
  severity            = 0 # Critical
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | where cloud_RoleName == 'credirapido-api'
      | summarize p99 = percentile(duration, 99)
      | where p99 > 1000
    QUERY

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops_team.id]
  }
}
