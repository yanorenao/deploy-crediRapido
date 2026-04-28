#!/bin/bash
# smoke-tests.sh <base_url>
# Verifica que los endpoints críticos del servicio respondan correctamente
# tras el despliegue en Staging.

BASE_URL=$1

if [ -z "$BASE_URL" ]; then
  echo "Usage: ./smoke-tests.sh <base_url>"
  exit 1
fi

FAILED=0

check_endpoint() {
  local path=$1
  local expected_status=$2
  local url="${BASE_URL}${path}"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url")

  if [ "$STATUS" -eq "$expected_status" ]; then
    echo "[OK] $url → HTTP $STATUS"
  else
    echo "[FAIL] $url → esperado HTTP $expected_status, obtenido HTTP $STATUS"
    FAILED=1
  fi
}

echo "=== Smoke Tests — CrediRapido Staging ==="
echo "Base URL: $BASE_URL"
echo ""

check_endpoint "/health"         200
check_endpoint "/health/ready"   200
check_endpoint "/health/live"    200
check_endpoint "/api/v1/credits" 401   # requiere auth → 401 es correcto

echo ""
if [ $FAILED -eq 0 ]; then
  echo "✅ Todos los smoke tests pasaron."
  exit 0
else
  echo "❌ Uno o más smoke tests fallaron."
  exit 1
fi
