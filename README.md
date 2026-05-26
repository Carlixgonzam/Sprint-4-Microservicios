# Sprint 4 — BITE.co Microservicios

> ISIS2503 · Arquitecturas de Software · Universidad de los Andes  
> Equipo: Electrochampeta

Plataforma de gestión y optimización de costos cloud, migrada a arquitectura de microservicios con persistencia políglota para validar los ASRs de **latencia**, **seguridad** y **modificabilidad**.

---

## Índice

1. [Arquitectura general](#arquitectura-general)
2. [Microservicios](#microservicios)
3. [Bases de datos](#bases-de-datos)
4. [Patrones de microservicios implementados](#patrones-de-microservicios-implementados)
5. [Infraestructura AWS Academy](#infraestructura-aws-academy)
6. [Configuración y despliegue](#configuración-y-despliegue)
7. [Poblar las bases de datos](#poblar-las-bases-de-datos)
8. [Verificar que todo funciona](#verificar-que-todo-funciona)
9. [Experimentos](#experimentos)
10. [Estructura de carpetas](#estructura-de-carpetas)

---

## Arquitectura general

```
Usuario
  │
  ▼
[API Gateway :8000]  ← Node.js + Express
  │   Rate Limiter (ASR Seguridad)
  │   JWT Auth (ASR Seguridad)
  │
  ├──── /inventory  ──────► [Inventory Service :8001]  ← FastAPI + PostgreSQL
  ├──── /reports    ──────► [Report Service    :8002]  ← FastAPI + MongoDB
  ├──── /notifications ──► [Notification Svc  :8003]  ← FastAPI (async jobs)
  └──── /dashboard/summary ─► consulta paralela a inventory + report
```

El endpoint `/dashboard/summary` es el núcleo del **ASR de latencia**: consulta en paralelo (`Promise.all`) al Inventory Service (PostgreSQL) y al Report Service (MongoDB), consolida la respuesta y la retorna al usuario. Si el análisis supera 2000 ms, se encola en el Notification Service como job asíncrono.

---

## Microservicios

| Servicio | Puerto | Tecnología | BD | Responsabilidad |
|---|---|---|---|---|
| `api-gateway` | 8000 | Node.js 18 + Express | — | Punto de entrada único, JWT, rate limiting, proxy |
| `inventory-service` | 8001 | Python 3.11 + FastAPI | PostgreSQL | Inventario de recursos cloud por empresa/proyecto |
| `report-service` | 8002 | Python 3.11 + FastAPI | MongoDB | Reportes de costos y patrones de desperdicio |
| `notification-service` | 8003 | Python 3.11 + FastAPI | — (en memoria) | Jobs asíncronos, notificación por email simulada |

### Endpoints principales

**API Gateway** (`http://<GW-IP>:8000`)

| Método | Ruta | Auth | Descripción |
|---|---|---|---|
| `POST` | `/auth/token` | No | Genera JWT para pruebas |
| `GET` | `/health` | No | Health check del gateway |
| `GET` | `/dashboard/summary` | JWT | **ASR Latencia**: agrega ambas BDs en paralelo |
| `GET` | `/inventory/*` | JWT | Proxy a inventory-service |
| `GET` | `/reports/*` | JWT | Proxy a report-service |
| `POST` | `/notifications/jobs` | JWT | Proxy a notification-service |

**Inventory Service** (`http://<INV-IP>:8001`)

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/health` | Health check + BD |
| `GET` | `/resources` | Lista recursos con identificación de infrautilizados |
| `GET` | `/resources?company=X&project=Y` | Filtrado por empresa/proyecto |
| `GET` | `/resources/summary` | Agregación SQL por empresa/proyecto/proveedor |

**Report Service** (`http://<REPORT-IP>:8002`)

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/health` | Health check + BD |
| `GET` | `/costs` | Lista reportes de costos con % de desperdicio |
| `GET` | `/costs?company=X&month=2025-01` | Filtrado por empresa/mes |
| `GET` | `/costs/monthly/{company}` | Histórico mensual de una empresa |

**Notification Service** (`http://<NOTIF-IP>:8003`)

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/health` | Health check |
| `POST` | `/jobs` | Crea job asíncrono (análisis > 2s) |
| `GET` | `/jobs/{job_id}` | Consulta estado del job |

---

## Bases de datos

### PostgreSQL — Inventario de recursos cloud

Almacena recursos cloud estructurados (EC2, RDS, S3, etc.) por empresa y proyecto. Relacional porque los recursos tienen esquema fijo y se necesitan JOINs y agregaciones SQL.

**Tabla `cloud_resources`**

| Campo | Tipo | Descripción |
|---|---|---|
| `id` | SERIAL PK | Identificador |
| `company` | VARCHAR(100) | Empresa cliente |
| `project` | VARCHAR(100) | Proyecto dentro de la empresa |
| `provider` | VARCHAR(50) | AWS / GCP / Azure |
| `resource_type` | VARCHAR(100) | EC2, RDS, S3, Lambda… |
| `region` | VARCHAR(50) | Región del proveedor |
| `status` | VARCHAR(20) | running / stopped / idle |
| `cpu_usage` | FLOAT | % uso de CPU |
| `memory_gb` | FLOAT | Memoria asignada |
| `monthly_cost` | FLOAT | Costo mensual en USD |
| `created_at` | TIMESTAMP | Fecha de registro |

**Índices** (creados automáticamente por `seed_postgres.py`):
- `idx_company` sobre `company`
- `idx_company_project` sobre `(company, project)`

### MongoDB — Reportes de costos

Almacena reportes de costos agregados por empresa/proyecto/mes. Documental porque cada reporte puede tener estructura variable y se prioriza velocidad de lectura sobre normalización.

**Colección `cost_reports`** — 3 000 documentos

```json
{
  "company": "Bancolombia",
  "project": "DataLake",
  "month": "2025-01",
  "total_cost": 42500.50,
  "waste_cost": 12750.15,
  "currency": "USD",
  "resources_analyzed": 320,
  "created_at": "2025-01-31T00:00:00Z"
}
```

**Colección `monthly_summaries`** — 30 documentos (5 empresas × 6 meses)

```json
{
  "company": "Bancolombia",
  "month": "2025-01",
  "total_cost": 185000.00,
  "total_waste": 37000.00,
  "top_project": "DataLake"
}
```

**Índices** (creados automáticamente por `seed_mongo.py`):
- `company` desc
- `(company, project)` compuesto
- `month` desc
- `(company, month)` en `monthly_summaries`

---

## Patrones de microservicios implementados

### 1. API Gateway
El `api-gateway` es el único punto de entrada al sistema. Centraliza autenticación JWT, rate limiting y enrutamiento. Los microservicios internos no están expuestos directamente a internet.

### 2. Database per Service
Cada servicio tiene su propia base de datos completamente aislada:
- `inventory-service` → PostgreSQL (solo él tiene acceso)
- `report-service` → MongoDB (solo él tiene acceso)

Ningún servicio accede a la BD de otro. La composición de datos se hace en el API Gateway a nivel de respuesta HTTP.

### 3. Async Messaging
Cuando un análisis supera el umbral de 2 s, el `notification-service` recibe el job y lo procesa en background (FastAPI `BackgroundTasks`). El usuario recibe inmediatamente una respuesta con el `job_id` y puede consultar el estado más tarde.

---

## Infraestructura AWS Academy

Se necesitan **6 instancias EC2 t2.micro** (cubiertas por el Free Tier de AWS Academy):

| Nombre | Uso | Puerto abierto |
|---|---|---|
| `ec2-gateway` | API Gateway (Node.js) | 8000 desde internet, 22 desde tu IP |
| `ec2-inventory` | Inventory Service (Python) | 8001 solo desde IP del gateway, 22 |
| `ec2-report` | Report Service (Python) | 8002 solo desde IP del gateway, 22 |
| `ec2-notification` | Notification Service (Python) | 8003 solo desde IP del gateway, 22 |
| `ec2-postgres` | PostgreSQL | 5432 solo desde IP de ec2-inventory, 22 |
| `ec2-mongo` | MongoDB | 27017 solo desde IP de ec2-report, 22 |

### Crear las instancias en AWS Academy

1. Ir a **EC2 → Launch Instance**
2. Seleccionar **Amazon Linux 2 AMI**
3. Tipo: **t2.micro**
4. En **Security Groups**, configurar los puertos según la tabla anterior
5. Usar el key pair `labsuser` (el que ya tienen del laboratorio)
6. Repetir 6 veces con los nombres indicados

> **Importante:** Las IPs públicas de AWS Academy cambian cada vez que se reinicia la sesión del laboratorio. Hay que actualizarlas en los archivos de configuración cada vez.

---

## Configuración y despliegue

### Paso 1 — Llenar las IPs

Editar `setup_all_ec2.sh` con las IPs públicas de cada instancia:

```bash
GW_IP="54.XXX.XXX.XXX"
INV_IP="54.XXX.XXX.XXX"
REPORT_IP="54.XXX.XXX.XXX"
NOTIF_IP="54.XXX.XXX.XXX"
POSTGRES_IP="54.XXX.XXX.XXX"
MONGO_IP="54.XXX.XXX.XXX"
```

También editar la URL del repositorio:

```bash
REPO_URL="https://github.com/TU_ORG/sprint4-bite.git"
```

### Paso 2 — Correr el script de setup

```bash
chmod +x setup_all_ec2.sh
./setup_all_ec2.sh
```

El script hace en orden:
1. Instala Docker en las 6 instancias en paralelo
2. Levanta PostgreSQL y MongoDB con Docker
3. Espera 10 s para que las BDs inicialicen
4. Construye y levanta los 4 microservicios
5. Hace health checks automáticos al final

### Paso 3 — Despliegue manual (alternativa si el script falla)

Si el script falla en algún paso, cada servicio se puede levantar manualmente:

```bash
# PostgreSQL
ssh -i ~/.ssh/labsuser.pem ec2-user@<POSTGRES-IP>
docker run -d --name postgres --restart unless-stopped \
  -e POSTGRES_USER=bite -e POSTGRES_PASSWORD=bite123 \
  -e POSTGRES_DB=inventory -p 5432:5432 postgres:15

# MongoDB
ssh -i ~/.ssh/labsuser.pem ec2-user@<MONGO-IP>
docker run -d --name mongodb --restart unless-stopped \
  -p 27017:27017 mongo:7

# Inventory Service
ssh -i ~/.ssh/labsuser.pem ec2-user@<INV-IP>
git clone https://github.com/TU_ORG/sprint4-bite.git
cd sprint4-bite/sprint4-bite/inventory-service
docker build -t inventory-service .
docker run -d --name inventory-service --restart unless-stopped \
  -e DATABASE_URL="postgresql://bite:bite123@<POSTGRES-IP>:5432/inventory" \
  -p 8001:8001 inventory-service

# Report Service
ssh -i ~/.ssh/labsuser.pem ec2-user@<REPORT-IP>
git clone https://github.com/TU_ORG/sprint4-bite.git
cd sprint4-bite/sprint4-bite/report-service
docker build -t report-service .
docker run -d --name report-service --restart unless-stopped \
  -e MONGO_URL="mongodb://<MONGO-IP>:27017" \
  -p 8002:8002 report-service

# Notification Service
ssh -i ~/.ssh/labsuser.pem ec2-user@<NOTIF-IP>
git clone https://github.com/TU_ORG/sprint4-bite.git
cd sprint4-bite/sprint4-bite/notification-service
docker build -t notification-service .
docker run -d --name notification-service --restart unless-stopped \
  -p 8003:8003 notification-service

# API Gateway (va último porque necesita las IPs de los demás)
ssh -i ~/.ssh/labsuser.pem ec2-user@<GW-IP>
git clone https://github.com/TU_ORG/sprint4-bite.git
cd sprint4-bite/sprint4-bite/api-gateway
docker build -t api-gateway .
docker run -d --name api-gateway --restart unless-stopped \
  -e INVENTORY_URL="http://<INV-IP>:8001" \
  -e REPORT_URL="http://<REPORT-IP>:8002" \
  -e NOTIF_URL="http://<NOTIF-IP>:8003" \
  -e JWT_SECRET="bite-secret-2025" \
  -p 8000:8000 api-gateway
```

---

## Poblar las bases de datos

Primero editar las IPs en los scripts de seed:

**`seed/seed_postgres.py`** — línea 4:
```python
EC2_POSTGRES_IP = "54.XXX.XXX.XXX"  # IP pública de ec2-postgres
```

**`seed/seed_mongo.py`** — línea 4:
```python
EC2_MONGO_IP = "54.XXX.XXX.XXX"  # IP pública de ec2-mongo
```

Luego correr desde la máquina local (necesita Python 3 con `psycopg2` y `pymongo`):

```bash
pip install psycopg2-binary pymongo

python3 seed/seed_postgres.py
# ✅ PostgreSQL: 5000 registros + índices creados

python3 seed/seed_mongo.py
# ✅ MongoDB: 3000 cost_reports + 30 monthly_summaries + índices creados
```

> Los scripts crean los índices automáticamente. Estos índices son los que permiten comparar latencia con/sin optimización en el experimento.

---

## Verificar que todo funciona

### Health checks

```bash
GW_IP="54.XXX.XXX.XXX"   # reemplazar

curl http://$GW_IP:8000/health
# {"status":"ok","service":"api-gateway"}

# Sin token debe dar 401
curl http://$GW_IP:8000/inventory/resources
# {"error":"Missing token"}
```

### Obtener token

```bash
TOKEN=$(curl -s -X POST http://$GW_IP:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"test"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo $TOKEN   # debe imprimir el JWT
```

### Consultas con token

```bash
# Inventario de recursos
curl -H "Authorization: Bearer $TOKEN" \
  "http://$GW_IP:8000/inventory/resources?company=Bancolombia"

# Reportes de costos
curl -H "Authorization: Bearer $TOKEN" \
  "http://$GW_IP:8000/reports/costs?company=Bancolombia"

# Dashboard agregado (endpoint del ASR de latencia)
curl -H "Authorization: Bearer $TOKEN" \
  "http://$GW_IP:8000/dashboard/summary"
# Respuesta incluye elapsed_ms — verificar que esté bajo 2000
```

### Ver logs del gateway (para verificar rate limiting)

```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@$GW_IP \
  "docker logs -f api-gateway 2>&1 | grep -E 'AUDIT|BLOCKED'"
```

---

## Experimentos

### EXP 02 — ASR Seguridad: detección de ráfaga maliciosa

```bash
cd load-test

# Terminal 1: monitorear logs del gateway
ssh -i ~/.ssh/labsuser.pem ec2-user@<GW-IP> \
  "docker logs -f api-gateway" | grep AUDIT

# Terminal 2: lanzar ataque
locust -f locustfile.py AttackUser \
  --host http://<GW-IP>:8000 \
  --users 50 --spawn-rate 50 \
  --run-time 60s --headless \
  --csv=results_attack
```

**Evidencia esperada:**
- Respuestas HTTP `429` en el output de Locust
- Líneas `[AUDIT] BLOCKED <IP>` en los logs del gateway
- El microservicio interno **no** recibe el tráfico excedente

### EXP 03 — ASR Latencia: consulta agregada con y sin índices

```bash
cd load-test

# El token se genera automáticamente — solo pasar el host

# Escenario 1: con índices (ya creados por el seed)
locust -f locustfile.py LatencyUser \
  --host http://<GW-IP>:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 120s --headless \
  --csv=results_con_indices

# Escenario 2: sin índices (drop manual en la BD para comparar)
# Conectarse a ec2-postgres y dropear índices:
ssh -i ~/.ssh/labsuser.pem ec2-user@<POSTGRES-IP>
docker exec -it postgres psql -U bite -d inventory -c \
  "DROP INDEX IF EXISTS idx_company; DROP INDEX IF EXISTS idx_company_project;"

locust -f locustfile.py LatencyUser \
  --host http://<GW-IP>:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 120s --headless \
  --csv=results_sin_indices

# Comparar p95 entre results_con_indices_stats.csv y results_sin_indices_stats.csv
```

### Trade-off Seguridad vs Latencia

```bash
# Prueba 1: con rate limiter activo (normal)
locust -f locustfile.py TradeoffUser \
  --host http://<GW-IP>:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 90s --headless \
  --csv=results_tradeoff_con_seguridad

# Prueba 2: sin rate limiter
# En ec2-gateway, comentar `app.use(limiter);` en index.js, rebuild y restart:
ssh -i ~/.ssh/labsuser.pem ec2-user@<GW-IP>
cd sprint4-bite/sprint4-bite/api-gateway
# Editar index.js: comentar la línea app.use(limiter);
docker stop api-gateway && docker rm api-gateway
docker build -t api-gateway . && docker run -d --name api-gateway \
  -e INVENTORY_URL="http://<INV-IP>:8001" \
  -e REPORT_URL="http://<REPORT-IP>:8002" \
  -e NOTIF_URL="http://<NOTIF-IP>:8003" \
  -e JWT_SECRET="bite-secret-2025" \
  -p 8000:8000 api-gateway

locust -f locustfile.py TradeoffUser \
  --host http://<GW-IP>:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 90s --headless \
  --csv=results_tradeoff_sin_seguridad

# Comparar p95 → documentar overhead del rate limiter en milisegundos
```

---

## Estructura de carpetas

```
sprint4-bite/
│
├── api-gateway/                 ← Node.js + Express (patrón API Gateway)
│   ├── index.js                 ← Rate limiter, JWT, proxy, /dashboard/summary
│   ├── package.json
│   └── Dockerfile
│
├── inventory-service/           ← FastAPI + PostgreSQL (patrón DB per Service)
│   ├── main.py                  ← /resources, /resources/summary
│   ├── models.py                ← SQLAlchemy ORM
│   ├── database.py              ← Conexión PostgreSQL
│   ├── requirements.txt
│   └── Dockerfile
│
├── report-service/              ← FastAPI + MongoDB (patrón DB per Service)
│   ├── main.py                  ← /costs, /costs/monthly/{company}
│   ├── database.py              ← Conexión MongoDB
│   ├── requirements.txt
│   └── Dockerfile
│
├── notification-service/        ← FastAPI async (patrón Async Messaging)
│   ├── main.py                  ← /jobs (BackgroundTasks)
│   ├── requirements.txt
│   └── Dockerfile
│
├── seed/
│   ├── seed_postgres.py         ← 5000 registros + índices en PostgreSQL
│   └── seed_mongo.py            ← 3000 docs + índices en MongoDB
│
├── load-test/
│   └── locustfile.py            ← LatencyUser, AttackUser, TradeoffUser
│
└── setup_all_ec2.sh             ← Script completo de despliegue en AWS Academy
```

---

## Troubleshooting

**El gateway no responde en puerto 8000**
```bash
# Verificar que el Security Group de ec2-gateway tiene el puerto 8000 abierto
# Verificar que el contenedor está corriendo:
ssh -i ~/.ssh/labsuser.pem ec2-user@<GW-IP> "docker ps"
# Si no aparece api-gateway, revisar logs:
ssh -i ~/.ssh/labsuser.pem ec2-user@<GW-IP> "docker logs api-gateway"
```

**inventory-service no conecta a PostgreSQL**
```bash
# Verificar que el Security Group de ec2-postgres permite 5432 desde IP de ec2-inventory
# Verificar que PostgreSQL está corriendo:
ssh -i ~/.ssh/labsuser.pem ec2-user@<POSTGRES-IP> "docker ps | grep postgres"
```

**Las IPs cambiaron (sesión de laboratorio reiniciada)**
```bash
# Las IPs públicas de AWS Academy cambian al reiniciar la sesión.
# Hay que:
# 1. Actualizar GW_IP, INV_IP, etc. en setup_all_ec2.sh
# 2. Reconstruir y relanzar el contenedor del api-gateway con las nuevas IPs:
docker stop api-gateway && docker rm api-gateway
docker run -d --name api-gateway \
  -e INVENTORY_URL="http://<NUEVA-INV-IP>:8001" \
  -e REPORT_URL="http://<NUEVA-REPORT-IP>:8002" \
  -e NOTIF_URL="http://<NUEVA-NOTIF-IP>:8003" \
  -e JWT_SECRET="bite-secret-2025" \
  -p 8000:8000 api-gateway
```

**Locust da 401 en todas las peticiones**
```bash
# El token se genera automáticamente, pero si /auth/token falla:
curl -X POST http://<GW-IP>:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"test"}'
# Si da error, verificar que el gateway está corriendo
```