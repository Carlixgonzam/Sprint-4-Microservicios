# Sprint 4 — BITE.co Microservicios

> ISIS2503 · Arquitecturas de Software · Universidad de los Andes
> Equipo: Electrochampeta

Plataforma de gestión y optimización de costos en infraestructura cloud, implementada como arquitectura de microservicios con persistencia políglota, cache distribuido y mensajería asíncrona. Valida los ASRs de **latencia**, **seguridad** y **modificabilidad**.

---

## Índice

1. [Arquitectura](#arquitectura)
2. [Stack tecnológico](#stack-tecnológico)
3. [Microservicios](#microservicios)
4. [Endpoints principales](#endpoints-principales)
5. [Almacenamiento y mensajería](#almacenamiento-y-mensajería)
6. [Seguridad](#seguridad)
7. [Patrones implementados](#patrones-implementados)
8. [Infraestructura AWS](#infraestructura-aws)
9. [Despliegue](#despliegue)
10. [Poblar las bases de datos](#poblar-las-bases-de-datos)
11. [Verificación end-to-end](#verificación-end-to-end)
12. [Experimentos](#experimentos)
13. [Estructura del repositorio](#estructura-del-repositorio)
14. [Troubleshooting](#troubleshooting)

---

## Arquitectura

```text
Usuario autenticado (JWT con scopes)
   │
   ▼
[API Gateway :8000]  Node.js + Express
   │   • Autenticación JWT (access + refresh tokens)
   │   • Rate limiting (100 req/min/IP)
   │   • Audit log → MongoDB
   │   • Routing por endpoint
   │
   ├── POST /reports/generate ──┐
   ├── GET  /reports/<uuid>  ───┤
   │                            ▼
   │                     [Orchestrator :8004]  FastAPI
   │                        │  • Cache Redis (TTL: 24h/12h/4h)
   │                        │  • Cola RabbitMQ (report.request + DLQ)
   │                        │  • Worker en background
   │                        │
   │                        ├─► [Inventory :8001]    → PostgreSQL
   │                        ├─► [Collector :8005]    → MongoDB (time_series_metrics)
   │                        ├─► [Analyzer  :8006]    → PostgreSQL (cost_analysis, recommendations)
   │                        └─► [Notification :8003]  Java / Spring Boot
   │
   ├── /inventory/*          ──► Inventory Service
   ├── /reports/costs        ──► Report Service
   ├── /notifications/jobs   ──► Notification Service
   └── /dashboard/summary    ──► Inventory + Report en paralelo (Promise.all)
```

El sistema combina tres estilos de comunicación:

- **Sincrónico HTTP** para lecturas de baja latencia (`/inventory`, `/reports/costs`, `/dashboard/summary`).
- **Asincrónico orquestado** para generación de reportes pesados (`POST /reports/generate`), con cache en Redis y cola en RabbitMQ.
- **Fan-out paralelo** en `/dashboard/summary`, que agrega PostgreSQL y MongoDB con `Promise.all` para minimizar el tiempo de respuesta.

### Flujo de generación de reporte

1. El cliente envía `POST /reports/generate` al gateway con un JWT válido.
2. El gateway verifica el token, valida que tenga el scope `read:own_costs`, escribe el evento al `audit_log` e inyecta el `client_id` desde el JWT antes de pasar la solicitud al orchestrator.
3. El orchestrator construye la clave `report:{client}:{type}:{period}` y consulta Redis.
   - **Cache hit** → retorna el reporte cacheado (< 100 ms).
   - **Cache miss** → publica el job en RabbitMQ y responde `{report_id, status: queued}`.
4. El worker del orchestrator consume el mensaje y llama en secuencia:
   - **Inventory** → lista de recursos del cliente.
   - **Collector** → genera métricas y las almacena en `time_series_metrics`.
   - **Analyzer** → calcula costos optimizados y genera recomendaciones.
5. El reporte compuesto se guarda en Redis (clave compuesta y clave por `report_id`) con TTL según el período.
6. Se notifica al `notification-service` (best-effort) para que envíe el email simulado.
7. El cliente consulta `GET /reports/{report_id}` y obtiene `processing` o el reporte completo.

---

## Stack tecnológico

| Capa | Tecnología | Versión |
|---|---|---|
| API Gateway | Node.js + Express | 18 LTS / 4.18 |
| Microservicios FastAPI | Python | 3.11 |
| Notification Service | Java + Spring Boot | 21 LTS / 3.3 |
| Base de datos relacional | PostgreSQL | 15 |
| Base de datos documental | MongoDB | 7 |
| Cache distribuido | Redis | 7 |
| Message broker | RabbitMQ (management) | 3 |
| Contenedores | Docker | 20.10+ |
| Infraestructura | AWS EC2 t2.micro | — |
| Pruebas de carga | Locust | 2.x |

Se cumple el requisito de **tres tecnologías de implementación distintas**: Node.js, Python y Java.

---

## Microservicios

| Servicio | Puerto | Lenguaje | Persistencia | Responsabilidad |
|---|---|---|---|---|
| `api-gateway` | 8000 | Node.js / Express | — | Autenticación, rate limit, routing, audit log |
| `inventory-service` | 8001 | Python / FastAPI | PostgreSQL | Inventario de recursos cloud por empresa/proyecto |
| `report-service` | 8002 | Python / FastAPI | MongoDB | Reportes de costos agregados por empresa/mes |
| `notification-service` | 8003 | Java / Spring Boot | — (en memoria) | Jobs asíncronos, notificación por email simulada |
| `orchestrator-service` | 8004 | Python / FastAPI | Redis + RabbitMQ | Coordinación del pipeline de generación de reportes |
| `collector-service` | 8005 | Python / FastAPI | MongoDB | Métricas de uso (CPU, memoria, network, disk I/O) |
| `analyzer-service` | 8006 | Python / FastAPI | PostgreSQL | Cálculo de costos optimizados y recomendaciones |

---

## Endpoints principales

### API Gateway (`http://<GW-IP>:8000`)

| Método | Ruta | Auth | Scope | Descripción |
|---|---|---|---|---|
| POST | `/auth/token` | — | — | Emite access + refresh tokens (rol `user` o `admin`) |
| POST | `/auth/refresh` | — | — | Renueva un access token a partir de un refresh |
| GET | `/health` | — | — | Health check del gateway |
| POST | `/reports/generate` | JWT | `read:own_costs` | Genera reporte (cache + cola asíncrona) |
| GET | `/reports/{report_id}` | JWT | `read:own_costs` | Consulta el estado o resultado del reporte |
| GET | `/inventory/*` | JWT | `read:own_resources` | Proxy a inventory-service |
| GET | `/reports/costs*` | JWT | `read:own_costs` | Proxy a report-service |
| POST | `/notifications/jobs` | JWT | `read:own_costs` | Proxy a notification-service |
| GET | `/dashboard/summary` | JWT | `read:own_costs` | Agregación paralela inventory + reports |

### Inventory Service (`http://<INV-IP>:8001`)

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/health` | Health check + estado BD |
| GET | `/resources` | Lista recursos con marca de subutilización |
| GET | `/resources?company=X&project=Y` | Filtrado por empresa/proyecto |
| GET | `/resources/summary` | Agregación SQL por empresa/proyecto/proveedor |

### Report Service (`http://<REPORT-IP>:8002`)

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/health` | Health check + estado BD |
| GET | `/costs` | Lista reportes con porcentaje de desperdicio |
| GET | `/costs?company=X&month=2025-01` | Filtrado por empresa/mes |
| GET | `/costs/monthly/{company}` | Histórico mensual de una empresa |

### Notification Service (`http://<NOTIF-IP>:8003`)

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/health` | Health check |
| POST | `/jobs` | Crea job asíncrono (delay de 3 s) |
| GET | `/jobs/{job_id}` | Consulta estado del job |

### Orchestrator Service (`http://<ORCH-IP>:8004`)

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/health` | Health check + estado Redis/RabbitMQ |
| POST | `/reports/generate` | Encola un job de generación (idempotente por cache) |
| GET | `/reports/{report_id}` | Consulta estado o resultado del reporte |

### Collector Service (`http://<ANALYTICS-IP>:8005`)

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/health` | Health check + estado BD |
| POST | `/collect` | Genera y almacena métricas para una lista de recursos |
| GET | `/metrics?client_id=X` | Consulta las últimas métricas de un cliente |

### Analyzer Service (`http://<ANALYTICS-IP>:8006`)

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/health` | Health check + estado BD |
| POST | `/analyze` | Calcula análisis de costos y genera recomendaciones |
| GET | `/analysis/{analysis_id}` | Recupera un análisis y sus recomendaciones |
| GET | `/recommendations?client_id=X` | Lista todas las recomendaciones de un cliente |

---

## Almacenamiento y mensajería

### PostgreSQL — Datos relacionales

Almacena recursos cloud y resultados de análisis de costos.

| Tabla | Columnas clave | Uso |
|---|---|---|
| `cloud_resources` | id, company, project, provider, resource_type, status, cpu_usage, monthly_cost | Inventario de recursos |
| `clients` | id (UUID), name, email, aws_account_id, gcp_project_id, status | Multi-tenancy |
| `cost_analysis` | id (UUID), client_id, total_cost, savings_potential, analysis_data (JSONB) | Resultados de análisis |
| `recommendations` | id (UUID), cost_analysis_id, resource_id, recommendation_type, estimated_savings, priority, status | Recomendaciones de optimización |
| `jwt_tokens` | id (UUID), client_id, token_hash, permissions (JSONB), expires_at, revoked | Auditoría de tokens emitidos |

**Índices**: `idx_company`, `idx_company_project` sobre `cloud_resources`; `ix_cost_analysis_client_id`; `ix_recommendations_analysis`.

### MongoDB — Datos documentales y telemetría

| Colección | Documento | Uso |
|---|---|---|
| `cost_reports` | `{company, project, month, total_cost, waste_cost, ...}` | Reportes históricos de costos |
| `monthly_summaries` | `{company, month, total_cost, total_waste, top_project}` | Resúmenes mensuales pre-agregados |
| `time_series_metrics` | `{client_id, resource_id, metric_name, timestamp, value, unit, provider, region}` | Series temporales de métricas |
| `audit_log` | `{action, actor, client_id, ip, path, status, timestamp}` | Eventos de seguridad |

**Índices**: `(client_id, resource_id, metric_name, timestamp)` sobre `time_series_metrics`; `(client_id, timestamp)` y `(action, timestamp)` sobre `audit_log`.

### Redis — Cache de reportes

| Clave | TTL | Contenido |
|---|---|---|
| `report:{client}:{type}:{period}` | 24h / 12h / 4h | Reporte completo (cache hit en POST repetido) |
| `report:id:{report_id}` | mismo TTL | Reporte indexado por ID (lookup en GET) |
| `report:status:{report_id}` | 1h | Marca de "processing" mientras corre el worker |

### RabbitMQ — Job queue

| Recurso | Tipo | Función |
|---|---|---|
| Exchange `cost-analysis` | topic, durable | Punto de entrada para mensajes |
| Cola `report.request` | durable, con DLX | Encola jobs de generación |
| Cola `dlq.failed` | durable | Dead Letter Queue para fallos |

---

## Seguridad

### Autenticación

Tokens JWT firmados con HMAC-SHA256.

- **Access token**: 1 hora, contiene `permissions[]`.
- **Refresh token**: 7 días, intercambiable por un nuevo access token sin reenviar credenciales.

Obtener un par de tokens:

```bash
curl -X POST http://<GW-IP>:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"alejo","role":"admin"}'
# → {"access_token":"…","refresh_token":"…","permissions":["…"],"expires_in":3600}
```

Renovar:

```bash
curl -X POST http://<GW-IP>:8000/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"refresh_token":"…"}'
```

### Autorización por scopes

| Scope | Permite |
|---|---|
| `read:own_resources` | Consultar inventario propio |
| `read:own_costs` | Consultar costos y generar reportes |
| `write:settings` | Modificar configuración (reservado) |
| `admin:full` | Bypass de todos los scopes |

Roles por defecto:

- `user` → `[read:own_resources, read:own_costs]`
- `admin` → todos los scopes

### Rate limiting

100 requests por minuto por IP. Las solicitudes excedidas retornan HTTP `429` y se registran en `audit_log` con `action: rate_limit_blocked`.

### Audit log

El gateway escribe cada evento de seguridad a la colección MongoDB `audit_log`. La escritura es fire-and-forget — nunca bloquea la respuesta al cliente.

Eventos registrados:

- `token_issued`, `token_refreshed`, `refresh_failed`
- `invalid_token`, `forbidden` (scope insuficiente)
- `rate_limit_blocked`
- `report_generate` (al iniciar la generación)

---

## Patrones implementados

| Patrón | Implementación |
|---|---|
| API Gateway | `api-gateway` como único punto de entrada con cross-cutting concerns |
| Database per Service | Cada servicio dueño exclusivo de su tabla/colección |
| Polyglot Persistence | PostgreSQL (relacional), MongoDB (documental), Redis (clave-valor) |
| Async Messaging | RabbitMQ como cola desacoplada entre orchestrator y worker |
| Cache-Aside | Orchestrator consulta Redis antes de procesar; populates en miss |
| CQRS ligero | Lectura por `report-service`; escritura/cómputo por `orchestrator` + `analyzer` |
| Circuit-breaker básico | Timeouts HTTP + DLQ para mensajes fallidos en RabbitMQ |
| Health Check API | `/health` en todos los servicios |
| Externalized Configuration | Configuración por variables de entorno (`.env` o `-e` Docker) |

---

## Infraestructura AWS

Se requieren **9 instancias EC2 t2.micro** (Amazon Linux 2, Free Tier).

| Instancia | Servicio | Puerto principal | Inbound permitido |
|---|---|---|---|
| `ec2-gateway` | api-gateway | 8000 | 8000 desde 0.0.0.0/0, 22 desde tu IP |
| `ec2-inventory` | inventory-service | 8001 | 8001 desde ec2-gateway y ec2-orchestrator, 22 desde tu IP |
| `ec2-report` | report-service | 8002 | 8002 desde ec2-gateway, 22 desde tu IP |
| `ec2-notification` | notification-service | 8003 | 8003 desde ec2-gateway y ec2-orchestrator, 22 desde tu IP |
| `ec2-orchestrator` | orchestrator-service | 8004 | 8004 desde ec2-gateway, 22 desde tu IP |
| `ec2-analytics` | collector + analyzer | 8005, 8006 | 8005 y 8006 desde ec2-orchestrator, 22 desde tu IP |
| `ec2-broker` | Redis + RabbitMQ | 6379, 5672, 15672 | 6379+5672 desde ec2-orchestrator, 15672 desde tu IP, 22 desde tu IP |
| `ec2-postgres` | PostgreSQL | 5432 | 5432 desde ec2-inventory y ec2-analytics, 22 desde tu IP |
| `ec2-mongo` | MongoDB | 27017 | 27017 desde ec2-report, ec2-analytics y ec2-gateway, 22 desde tu IP |

Todas usan el key pair `labsuser` de AWS Academy.

> Las IPs públicas cambian al reiniciar la sesión del laboratorio. Solo hay que actualizar las variables de entorno del `api-gateway` y del `orchestrator-service` cuando esto ocurra.

---

## Despliegue

### Paso 1 — Llenar las IPs

Editar [`setup_all_ec2.sh`](setup_all_ec2.sh) con las 9 IPs públicas:

```bash
GW_IP="54.X.X.X"
INV_IP="54.X.X.X"
REPORT_IP="54.X.X.X"
NOTIF_IP="54.X.X.X"
POSTGRES_IP="54.X.X.X"
MONGO_IP="54.X.X.X"
BROKER_IP="54.X.X.X"
ORCH_IP="54.X.X.X"
ANALYTICS_IP="54.X.X.X"

REPO_URL="https://github.com/TU_ORG/sprint4-bite.git"
```

### Paso 2 — Ejecutar el script

```bash
chmod +x setup_all_ec2.sh
./setup_all_ec2.sh
```

El script ejecuta en orden:

1. Instala Docker en las 9 instancias en paralelo.
2. Levanta PostgreSQL, MongoDB, Redis y RabbitMQ.
3. Espera 15 s para que se inicialicen.
4. Construye y levanta los 7 microservicios.
5. Ejecuta health checks contra todos.

Tarda entre 8 y 12 minutos.

### Despliegue manual (alternativa)

Si el script falla, cada componente puede levantarse individualmente. Conectarse por SSH a cada instancia y ejecutar:

```bash
# Bases de datos
docker run -d --name postgres --restart unless-stopped \
  -e POSTGRES_USER=bite -e POSTGRES_PASSWORD=bite123 \
  -e POSTGRES_DB=inventory -p 5432:5432 postgres:15

docker run -d --name mongodb --restart unless-stopped \
  -p 27017:27017 mongo:7

docker run -d --name redis --restart unless-stopped \
  -p 6379:6379 redis:7-alpine

docker run -d --name rabbitmq --restart unless-stopped \
  -e RABBITMQ_DEFAULT_USER=bite -e RABBITMQ_DEFAULT_PASS=bite123 \
  -p 5672:5672 -p 15672:15672 rabbitmq:3-management

# Microservicios (ejemplo orchestrator)
git clone $REPO_URL && cd sprint4-bite/sprint4-bite/orchestrator-service
docker build -t orchestrator-service .
docker run -d --name orchestrator-service --restart unless-stopped \
  -e REDIS_URL="redis://<BROKER-IP>:6379/0" \
  -e RABBITMQ_URL="amqp://bite:bite123@<BROKER-IP>:5672/" \
  -e INVENTORY_URL="http://<INV-IP>:8001" \
  -e COLLECTOR_URL="http://<ANALYTICS-IP>:8005" \
  -e ANALYZER_URL="http://<ANALYTICS-IP>:8006" \
  -e NOTIF_URL="http://<NOTIF-IP>:8003" \
  -p 8004:8004 orchestrator-service
```

El mismo patrón aplica para los demás servicios. Las variables de entorno completas están documentadas en `setup_all_ec2.sh`.

---

## Poblar las bases de datos

Editar la IP de PostgreSQL en `seed/seed_postgres.py` y la de MongoDB en `seed/seed_mongo.py`, luego ejecutar desde la máquina local:

```bash
pip install psycopg2-binary pymongo
python3 seed/seed_postgres.py    # 5 000 cloud_resources + índices
python3 seed/seed_mongo.py       # 3 000 cost_reports + 30 monthly_summaries
```

Las tablas y colecciones adicionales (`clients`, `cost_analysis`, `recommendations`, `time_series_metrics`, `audit_log`) las crea el script `deploy/setup-databases.sh` o, en su defecto, los propios microservicios al arrancar (SQLAlchemy `create_all`).

> Solo poblar **una vez**. Cargar el seed dos veces duplica datos.

---

## Verificación end-to-end

```bash
GW_IP="54.X.X.X"

# 1. Health del gateway
curl http://$GW_IP:8000/health
# → {"status":"ok","service":"api-gateway"}

# 2. Sin token debe dar 401
curl http://$GW_IP:8000/inventory/resources
# → {"error":"Missing token"}

# 3. Obtener access token
TOKEN=$(curl -s -X POST http://$GW_IP:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"alejo","role":"admin"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 4. Inventario filtrado
curl -H "Authorization: Bearer $TOKEN" \
  "http://$GW_IP:8000/inventory/resources?company=Bancolombia"

# 5. Dashboard agregado (ASR Latencia)
curl -H "Authorization: Bearer $TOKEN" \
  "http://$GW_IP:8000/dashboard/summary"
# Validar que elapsed_ms < 2000

# 6. Generar un reporte completo (pipeline async)
REPORT_ID=$(curl -sX POST http://$GW_IP:8000/reports/generate \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"report_type":"monthly_analysis","period":"monthly","company":"Bancolombia"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['report_id'])")

# 7. Polling del resultado
sleep 5
curl -H "Authorization: Bearer $TOKEN" \
  http://$GW_IP:8000/reports/$REPORT_ID
# Primera respuesta: status=processing; tras unos segundos, el reporte completo

# 8. Mismo POST otra vez → cache hit (respuesta inmediata con cached:true)
```

### Verificar el audit log

```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@$MONGO_IP \
  "docker exec mongodb mongosh bite_reports --quiet \
   --eval 'db.audit_log.find().sort({timestamp:-1}).limit(5).pretty()'"
```

### Verificar RabbitMQ

Abrir en el navegador: `http://<BROKER-IP>:15672`
Usuario: `bite` · Contraseña: `bite123`
Ver las colas `report.request` y `dlq.failed` en la pestaña Queues.

---

## Experimentos

### EXP 02 — ASR Seguridad: detección de ráfaga maliciosa

Verifica que el rate limiter del gateway detecta y bloquea automáticamente un atacante que excede 100 req/min.

```bash
# Terminal 1 — monitorear el audit log
ssh -i ~/.ssh/labsuser.pem ec2-user@$MONGO_IP \
  "docker exec mongodb mongosh bite_reports --quiet \
   --eval 'db.audit_log.watch([{\$match:{\"fullDocument.action\":\"rate_limit_blocked\"}}])'"

# Terminal 2 — lanzar el ataque
cd load-test
locust -f locustfile.py AttackUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 50 \
  --run-time 60s --headless \
  --csv=results_attack
```

**Evidencia esperada**:

- Respuestas HTTP `429` en el output de Locust.
- Documentos `action: rate_limit_blocked` apareciendo en `audit_log`.
- Los microservicios internos **no** reciben tráfico excedente.

### EXP 03 — ASR Latencia: agregación con y sin índices

Compara `/dashboard/summary` con y sin índices en las BDs.

```bash
cd load-test

# Escenario A: CON índices (estado por defecto)
locust -f locustfile.py LatencyUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 120s --headless \
  --csv=results_con_indices

# Dropear índices
ssh -i ~/.ssh/labsuser.pem ec2-user@$POSTGRES_IP \
  "docker exec postgres psql -U bite -d inventory -c \
   'DROP INDEX IF EXISTS idx_company; DROP INDEX IF EXISTS idx_company_project;'"

# Escenario B: SIN índices
locust -f locustfile.py LatencyUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 120s --headless \
  --csv=results_sin_indices

# Recrear índices al terminar
ssh -i ~/.ssh/labsuser.pem ec2-user@$POSTGRES_IP \
  "docker exec postgres psql -U bite -d inventory -c \
   'CREATE INDEX idx_company ON cloud_resources(company);
    CREATE INDEX idx_company_project ON cloud_resources(company, project);'"
```

Comparar la columna `95%` (p95) entre `results_con_indices_stats.csv` y `results_sin_indices_stats.csv`.

### Trade-off — Seguridad vs Latencia

Mide el overhead del rate limiter sobre la latencia normal.

```bash
# Prueba 1: CON rate limiter (estado por defecto)
locust -f locustfile.py TradeoffUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 90s --headless \
  --csv=results_tradeoff_con_seguridad

# Prueba 2: SIN rate limiter
# Conectarse al gateway, comentar `app.use(limiter)` en index.js y reconstruir
ssh -i ~/.ssh/labsuser.pem ec2-user@$GW_IP
# ...editar y rebuild...

locust -f locustfile.py TradeoffUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 90s --headless \
  --csv=results_tradeoff_sin_seguridad
```

Documentar la diferencia de p95. Típicamente el overhead del rate limiter es 1–5 ms — ese es el costo de la seguridad.

---

## Estructura del repositorio

```text
sprint4-bite/
│
├── api-gateway/                 Node.js + Express
│   ├── index.js                 Auth, rate limit, routing, audit log
│   ├── package.json
│   └── Dockerfile
│
├── inventory-service/           Python / FastAPI + PostgreSQL
│   ├── main.py
│   ├── models.py
│   ├── database.py
│   ├── requirements.txt
│   └── Dockerfile
│
├── report-service/              Python / FastAPI + MongoDB
│   ├── main.py
│   ├── database.py
│   ├── requirements.txt
│   └── Dockerfile
│
├── notification-service/        Java / Spring Boot
│   ├── src/main/java/com/bite/notification/
│   │   ├── NotificationServiceApplication.java
│   │   ├── JobController.java
│   │   ├── JobRequest.java
│   │   ├── JobStore.java
│   │   └── JobProcessor.java
│   ├── src/main/resources/application.properties
│   ├── pom.xml
│   └── Dockerfile
│
├── orchestrator-service/        Python / FastAPI + Redis + RabbitMQ
│   ├── main.py
│   ├── cache.py                 Cliente Redis
│   ├── broker.py                Cliente RabbitMQ
│   ├── worker.py                Worker en background
│   ├── requirements.txt
│   └── Dockerfile
│
├── collector-service/           Python / FastAPI + MongoDB
│   ├── main.py
│   ├── database.py
│   ├── requirements.txt
│   └── Dockerfile
│
├── analyzer-service/            Python / FastAPI + PostgreSQL
│   ├── main.py
│   ├── models.py
│   ├── database.py
│   ├── requirements.txt
│   └── Dockerfile
│
├── deploy/                      Scripts de despliegue nativo (Ubuntu + systemd)
│   ├── common.sh
│   ├── setup-databases.sh       PostgreSQL + MongoDB + schema completo
│   ├── setup-broker.sh          Redis + RabbitMQ
│   ├── deploy-all.sh            Orquestador interactivo
│   ├── deploy-api-gateway.sh
│   ├── deploy-inventory-service.sh
│   ├── deploy-report-service.sh
│   ├── deploy-notification-service.sh
│   ├── deploy-orchestrator-service.sh
│   ├── deploy-collector-service.sh
│   └── deploy-analyzer-service.sh
│
├── seed/
│   ├── seed_postgres.py         5 000 cloud_resources + índices
│   └── seed_mongo.py            3 000 cost_reports + 30 monthly_summaries
│
├── load-test/
│   └── locustfile.py            LatencyUser · AttackUser · TradeoffUser
│
└── setup_all_ec2.sh             Despliegue completo Docker en AWS Academy
```

---

## Troubleshooting

**El gateway no responde en puerto 8000**

```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@$GW_IP "docker ps && docker logs api-gateway"
# Verificar también que el SG de ec2-gateway tiene 8000 abierto desde 0.0.0.0/0
```

**`/reports/generate` responde 502 (orchestrator unavailable)**

```bash
# Verificar que el orchestrator está corriendo y alcanza al broker
ssh -i ~/.ssh/labsuser.pem ec2-user@$ORCH_IP "docker logs orchestrator-service"
curl http://$ORCH_IP:8004/health
# Si redis o rabbitmq dan false, revisar SG del ec2-broker y los contenedores
```

**El worker del orchestrator no procesa mensajes**

```bash
# Ver la cola en la UI de RabbitMQ
open http://$BROKER_IP:15672  # user: bite, pass: bite123
# Si hay mensajes acumulados en report.request, revisar logs del orchestrator
ssh -i ~/.ssh/labsuser.pem ec2-user@$ORCH_IP "docker logs -f orchestrator-service"
```

**El cache hit no funciona**

```bash
# Verificar que Redis tiene la clave
ssh -i ~/.ssh/labsuser.pem ec2-user@$BROKER_IP \
  "docker exec redis redis-cli KEYS 'report:*'"
```

**Las IPs cambiaron al reiniciar el laboratorio**

```bash
# Actualizar setup_all_ec2.sh con las nuevas IPs y reconstruir solo:
# - ec2-gateway (usa IPs de inventory, report, notification, orchestrator y mongo)
# - ec2-orchestrator (usa IPs de inventory, collector, analyzer, notification y broker)
# Los demás servicios tienen puertos fijos y no necesitan cambios.
```

**El seed falla con "connection refused"**

```bash
# Verificar que PostgreSQL/MongoDB están arriba
ssh -i ~/.ssh/labsuser.pem ec2-user@$POSTGRES_IP "docker ps | grep postgres"
ssh -i ~/.ssh/labsuser.pem ec2-user@$MONGO_IP    "docker ps | grep mongodb"
# Verificar que el SG permite 5432/27017 desde tu IP de desarrollo
```

**Locust da 401 en todas las peticiones**

```bash
# El token se genera automáticamente; si falla, probar manualmente:
curl -X POST http://$GW_IP:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"test"}'
```
