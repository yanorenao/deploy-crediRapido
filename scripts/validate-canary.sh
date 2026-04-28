#!/bin/bash
# validate-canary.sh <traffic_pct> <wait_seconds>
# Monitorea las métricas del canary deployment durante el período indicado.
# Si alguna métrica supera el umbral, ejecuta rollback automático y notifica.

TRAFFIC_PCT=$1
WAIT_SECS=$2

APP_NAME='credirapido-app-prod'
RG='rg-credirapido-prod'
ERROR_THRESHOLD=5    # % máximo de error rate permitido
LATENCY_THRESHOLD=800 # ms p95 máximo permitido

echo "[Canary] Monitoring ${TRAFFIC_PCT}% traffic slice for ${WAIT_SECS}s..."
sleep $WAIT_SECS

# ── Consultar métricas via Azure Monitor API ──────────────────────────
ERROR_RATE=$(az monitor metrics list \
  --resource /subscriptions/.../containerApps/$APP_NAME \
  --metric 'Http5xx' --interval PT5M \
  --query 'value[0].timeseries[0].data[-1].average' -o tsv)

LATENCY=$(az monitor metrics list \
  --resource /subscriptions/.../containerApps/$APP_NAME \
  --metric 'RequestDuration' --interval PT5M \
  --query 'value[0].timeseries[0].data[-1].percentile95' -o tsv)

# ── Gate: Error Rate ──────────────────────────────────────────────────
if (( $(echo "$ERROR_RATE > $ERROR_THRESHOLD" | bc -l) )); then
  echo '::error::Canary error rate exceeded threshold. Rolling back.'
  az containerapp ingress traffic set \
    --name $APP_NAME \
    --resource-group $RG \
    --revision-weight latest=0 previous=100
  curl -X POST $SLACK_WEBHOOK -d '{"text":"🚨 Canary rollback triggered on CrediRapido"}'
  exit 1
fi

# ── Gate: Latencia p95 ────────────────────────────────────────────────
if (( $(echo "$LATENCY > $LATENCY_THRESHOLD" | bc -l) )); then
  echo '::error::Canary p95 latency exceeded threshold. Rolling back.'
  az containerapp ingress traffic set \
    --name $APP_NAME \
    --resource-group $RG \
    --revision-weight latest=0 previous=100
  curl -X POST $SLACK_WEBHOOK -d '{"text":"🚨 Canary rollback triggered on CrediRapido (latency)"}'
  exit 1
fi

echo "[Canary] Metrics OK. Error rate: ${ERROR_RATE}%, Latency p95: ${LATENCY}ms"
