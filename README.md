# 🚀 CrediRápido — CI/CD Pipeline & Deployment Infrastructure

> **Proyecto:** Plataforma fintech CrediRápido  
> **Asignatura:** Metodologías para el Desarrollo del Software  
> **Institución:** Politécnico Grancolombiano — Maestría en Arquitectura de Software  
> **Unidad:** 4 — Automatización, Despliegue Continuo y Estrategia de Escalabilidad

---

## 📋 Descripción

Este repositorio contiene la infraestructura de automatización del ciclo de vida de la plataforma **CrediRápido**, implementando un pipeline CI/CD completo bajo el principio de **Pipeline as Code**. Todo el proceso de integración, validación y despliegue está versionado junto al código fuente, garantizando trazabilidad, reproducibilidad y auditoría histórica.

La estrategia de despliegue implementada es **Canary Deployment** sobre **Azure Container Apps**, con rollback automático basado en métricas en tiempo real de Azure Monitor.

---

## 🗂️ Estructura del Repositorio

```
deploy-crediRapido/
├── .github/
│   └── workflows/
│       └── cicd.yml              # Pipeline principal CI/CD (GitHub Actions)
├── scripts/
│   ├── validate-canary.sh        # Monitoreo de métricas y rollback automático
│   └── smoke-tests.sh            # Pruebas de humo sobre Staging
├── infra/                        # Configuración Terraform (IaC)
│   └── ...                       # Recursos Azure: Container Apps, PostgreSQL, etc.
└── README.md
```

---

## ⚙️ Pipeline CI/CD — Etapas

El pipeline se define en `.github/workflows/cicd.yml` y se activa en cada push o pull request a `main`. Está compuesto por **5 etapas secuenciales**:

```
Push/PR a main
     │
     ▼
┌─────────────┐
│  1. BUILD   │  Construye imagen Docker inmutable (tag: SHA del commit)
│  & PUSH     │  y la sube a Azure Container Registry
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  2. VALIDATE│  Pruebas unitarias · SAST · Escaneo dependencias
│             │  Trivy (imagen) · Validación Terraform
└──────┬──────┘
       │  (falla → pipeline se detiene)
       ▼
┌─────────────┐
│  3. DEPLOY  │  Despliega imagen inmutable en QA
│     QA      │  Ejecuta tests de integración automáticamente
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  4. DEPLOY  │  ⚠️ Requiere aprobación manual (GitHub Environment reviewer)
│   STAGING   │  Despliega la misma imagen · Smoke tests
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  5. CANARY  │  5% → 25% → 100% del tráfico
│  PRODUCTION │  Métricas monitoreadas entre cada paso
└─────────────┘  Rollback automático si se superan umbrales
```

### Principio Build Once, Deploy Everywhere

La imagen Docker se construye **una sola vez** en la Etapa 1, tageada con el SHA del commit. La misma imagen (referenciada por digest SHA256) es la que se despliega en QA, Staging y Producción. **Nunca se reconstruye**.

---

## 🔍 Gates de Validación Automática

| Capa de Validación | Herramienta | Criterio de Bloqueo |
|---|---|---|
| Pruebas Unitarias | `dotnet test` + XPlat Coverage | Cobertura < 80% o cualquier prueba fallida |
| Análisis Estático (SAST) | .NET Analyzers | Issues críticos o de alta severidad |
| Escaneo de Dependencias | `dotnet list --vulnerable` | Vulnerabilidades Critical o High |
| Escaneo de Contenedor | Trivy Image Scan | CVE Critical/High en imagen final |
| Validación IaC | `terraform validate` + `fmt -check` | Terraform inválido o sin formatear |
| Pruebas de Integración | `dotnet test Integration/` | Cualquier fallo en ambiente QA |
| Smoke Tests | Script bash sobre endpoint real | HTTP 2xx no retornado en Staging |
| Canary Metrics Gate | Script Azure Monitor API | Error rate > 5% o latencia p95 > 800ms |

---

## 🐦 Canary Deployment — Estrategia de Progresión

El despliegue a producción sigue una progresión gradual con ventanas de observación entre cada paso:

| Fase | Tráfico Canary | Tiempo de Observación |
|---|---|---|
| Inicial | 5% | 5 minutos (300s) |
| Expansión | 25% | 10 minutos (600s) |
| Rollout completo | 100% | — |

### Métricas de Validación del Canary

| Métrica (SLI) | Umbral OK | Umbral Rollback |
|---|---|---|
| HTTP Error Rate (4xx+5xx) | < 2% | > 5% |
| Latencia p95 (API Gateway) | < 500ms | > 800ms |
| Latencia p99 (API Gateway) | < 1000ms | > 1500ms |
| CPU utilization | < 70% | > 85% |
| Memory utilization | < 75% | > 90% |
| Service Bus Queue depth | < 100 mensajes | > 500 mensajes |
| Azure Function failures | < 1% | > 3% |
| PostgreSQL connection pool | < 80% saturación | > 95% |

### Rollback Automático

Si cualquier métrica supera el umbral durante la ventana de observación, `validate-canary.sh` ejecuta automáticamente:
1. Redirige el 100% del tráfico a la revisión anterior
2. Notifica al equipo vía webhook de Slack
3. El pipeline retorna exit code 1 (marca el step como fallido en GitHub Actions)

---

## 🔐 Secretos y Variables Requeridas

Configurar los siguientes secretos en **Settings → Secrets and variables → Actions** del repositorio:

| Secreto | Descripción |
|---|---|
| `ACR_USERNAME` | Usuario de Azure Container Registry |
| `ACR_PASSWORD` | Contraseña de Azure Container Registry |
| `STAGING_URL` | URL base del ambiente Staging para smoke tests |
| `SLACK_WEBHOOK` | URL del webhook de Slack para notificaciones de rollback |

Variables de entorno globales (configuradas en el pipeline):

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `REGISTRY` | `credirapidoacr.azurecr.io` | Servidor del Azure Container Registry |
| `IMAGE_NAME` | `credirapido-api` | Nombre de la imagen Docker |
| `DOTNET_VERSION` | `8.0.x` | Versión del runtime .NET |

---

## 🌍 GitHub Environments Requeridos

Crear los siguientes entornos en **Settings → Environments**:

| Environment | Tipo | Descripción |
|---|---|---|
| `qa` | Automático | Despliega sin aprobación tras validaciones |
| `staging` | **Requiere aprobación manual** | Configurar reviewer(s) designados |
| `production` | **Requiere aprobación manual** | Configurar reviewer(s) designados |

---

## 🏗️ Infraestructura Azure

El pipeline despliega sobre los siguientes recursos Azure (definidos en `infra/` con Terraform):

| Recurso | Propósito |
|---|---|
| Azure Container Apps | Cómputo principal de la API (KEDA autoscaling, zone-redundant) |
| Azure Container Registry | Registro de imágenes Docker |
| Azure PostgreSQL Flexible Server | Base de datos transaccional (Zone-Redundant HA) |
| Azure Service Bus | Cola de mensajes asíncrona (buffer de solicitudes) |
| Azure Functions | Procesamiento crediticio bajo demanda |
| Azure Key Vault | Gestión de secretos con rotación automática |
| Azure Monitor + App Insights | Observabilidad, métricas SLI/SLO y alertas |

### SLOs del Sistema

| SLI | SLO | Error Budget / mes |
|---|---|---|
| Disponibilidad (uptime) | >= 99.9% | 43.8 min/mes |
| Latencia API p95 | < 500ms | Cualquier p95 > 500ms cuenta |
| Latencia API p99 | < 1000ms | Cualquier p99 > 1s cuenta |
| Error rate HTTP (5xx) | < 1% | 1% de solicitudes/mes |
| Tiempo proceso crédito | < 10s end-to-end | SLA de negocio |

---

## 🛡️ DevSecOps

La seguridad está integrada en el pipeline en múltiples niveles:

- **Nivel 1 — Dependencias NuGet:** `dotnet list package --vulnerable --include-transitive`
- **Nivel 2 — Imagen Docker:** Trivy scan (CVE Critical/High → pipeline falla)
- **Nivel 3 — IaC:** Checkov sobre Terraform (`CKV_AZURE_*`)
- **Nivel 4 — SAST:** .NET Analyzers sobre el código fuente
- **Secretos:** Azure Key Vault + Managed Identity (cero credenciales en código)
- **RBAC:** Mínimo privilegio por componente (role assignments granulares)

---

## 🚀 Uso Local

Para ejecutar las validaciones de forma local antes de un push:

```bash
# Restaurar dependencias
dotnet restore --locked-mode

# Tests unitarios con cobertura
dotnet test --collect:'XPlat Code Coverage' --results-directory ./coverage

# Análisis estático
dotnet build /p:EnableNETAnalyzers=true /p:AnalysisMode=All

# Escaneo de dependencias vulnerables
dotnet list package --vulnerable --include-transitive

# Validación Terraform
cd infra && terraform validate && terraform fmt -check -recursive

# Escaneo de imagen (requiere Docker y Trivy instalados)
trivy image --severity CRITICAL,HIGH credirapidoacr.azurecr.io/credirapido-api:<tag>
```

---

## 👥 Autores

- Yeison Noreña Osorio
- Kevin Alexander Rodriguez Rodriguez
- July Alejandra Pabon Rodriguez
- Johnatan David Rincon Callejas

**Docente:** Yamid Ramirez Sanchez  
**Institución:** Politécnico Grancolombiano — Maestría en Arquitectura de Software  
**Fecha:** Abril 2026
