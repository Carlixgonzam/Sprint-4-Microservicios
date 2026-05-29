# Guía de despliegue — Sprint 4 BITE.co

> Sigue este documento de arriba a abajo. No te saltes pasos.

---

## Antes de empezar

En tu máquina local necesitas:

- **Python 3** con `pip`
- **Git**
- El archivo **`labsuser.pem`** descargado de AWS Academy

```bash
pip install psycopg2-binary pymongo locust
```

---

## Paso 1 — Crear las 9 instancias EC2

En AWS Academy → EC2 → Launch Instance. Crear las 9 instancias con esta configuración:

| Nombre | AMI | Tipo | Puertos inbound |
|---|---|---|---|
| `ec2-gateway` | Amazon Linux 2 | t2.micro | **8000** desde `0.0.0.0/0` |
| `ec2-inventory` | Amazon Linux 2 | t2.micro | **8001** desde IP de ec2-gateway y ec2-orchestrator |
| `ec2-report` | Amazon Linux 2 | t2.micro | **8002** desde IP de ec2-gateway |
| `ec2-notification` | Amazon Linux 2 | t2.micro | **8003** desde IP de ec2-gateway y ec2-orchestrator |
| `ec2-orchestrator` | Amazon Linux 2 | t2.micro | **8004** desde IP de ec2-gateway |
| `ec2-analytics` | Amazon Linux 2 | t2.micro | **8005** y **8006** desde IP de ec2-orchestrator |
| `ec2-broker` | Amazon Linux 2 | t2.micro | **6379** y **5672** desde IP de ec2-orchestrator, **15672** desde tu IP |
| `ec2-postgres` | Amazon Linux 2 | t2.micro | **5432** desde IP de ec2-inventory y ec2-analytics |
| `ec2-mongo` | Amazon Linux 2 | t2.micro | **27017** desde IP de ec2-report, ec2-analytics y ec2-gateway |

> En todas: agregar el puerto **22** desde tu IP para SSH.
> Usar el key pair **`labsuser`**.

---

## Paso 2 — Anotar las IPs

Una vez creadas, ir a EC2 → Instances y anotar la **IP pública** de cada una:

```text
ec2-gateway       →
ec2-inventory     →
ec2-report        →
ec2-notification  →
ec2-orchestrator  →
ec2-analytics     →
ec2-broker        →
ec2-postgres      →
ec2-mongo         →
```

> Estas IPs cambian al reiniciar la sesión del laboratorio.
> Si eso ocurre, ir al [Paso 6b](#paso-6b--si-las-ips-cambiaron).

---

## Paso 3 — Configurar el repositorio

Editar **3 archivos** con las IPs:

### `setup_all_ec2.sh`

```bash
GW_IP="IP_DE_EC2_GATEWAY"
INV_IP="IP_DE_EC2_INVENTORY"
REPORT_IP="IP_DE_EC2_REPORT"
NOTIF_IP="IP_DE_EC2_NOTIFICATION"
POSTGRES_IP="IP_DE_EC2_POSTGRES"
MONGO_IP="IP_DE_EC2_MONGO"
BROKER_IP="IP_DE_EC2_BROKER"
ORCH_IP="IP_DE_EC2_ORCHESTRATOR"
ANALYTICS_IP="IP_DE_EC2_ANALYTICS"

REPO_URL="https://github.com/TU_ORG/sprint4-bite.git"
```

### `seed/seed_postgres.py` — línea 4

```python
EC2_POSTGRES_IP = "IP_DE_EC2_POSTGRES"
```

### `seed/seed_mongo.py` — línea 4

```python
EC2_MONGO_IP = "IP_DE_EC2_MONGO"
```

Hacer commit y push.

---

## Paso 4 — Ejecutar el script de despliegue

```bash
chmod +x setup_all_ec2.sh
./setup_all_ec2.sh
```

El script ejecuta automáticamente:

1. Instala Docker en las 9 instancias en paralelo.
2. Levanta PostgreSQL, MongoDB, Redis y RabbitMQ.
3. Construye y levanta los 7 microservicios.
4. Ejecuta health checks contra todos.

**Tarda entre 8 y 12 minutos.** Al terminar debes ver:

```text
[api-gateway]           ✅ OK (http://...:8000/health)
[inventory-service]     ✅ OK (http://...:8001/health)
[report-service]        ✅ OK (http://...:8002/health)
[notification-service]  ✅ OK (http://...:8003/health)
[orchestrator-service]  ✅ OK (http://...:8004/health)
[collector-service]     ✅ OK (http://...:8005/health)
[analyzer-service]      ✅ OK (http://...:8006/health)
```

Si alguno sale con ❌, ir a [Troubleshooting](#troubleshooting).

---

## Paso 5 — Poblar las bases de datos

```bash
python3 seed/seed_postgres.py
# ✅ PostgreSQL: 5 000 registros + índices

python3 seed/seed_mongo.py
# ✅ MongoDB: 3 000 cost_reports + 30 monthly_summaries
```

> Hacer esto **una sola vez**. Si lo corres dos veces, duplicas los datos.

Las tablas adicionales (`clients`, `cost_analysis`, `recommendations`, `time_series_metrics`, `audit_log`) se crean automáticamente al arrancar los servicios (SQLAlchemy `create_all` + MongoDB collection-on-write).

---

## Paso 6 — Verificación end-to-end

```bash
GW_IP="IP_DE_EC2_GATEWAY"

# 1. Health check del gateway
curl http://$GW_IP:8000/health
# → {"status":"ok","service":"api-gateway"}

# 2. Sin token debe dar 401
curl http://$GW_IP:8000/inventory/resources
# → {"error":"Missing token"}

# 3. Obtener access token (rol admin para tener todos los scopes)
TOKEN=$(curl -s -X POST http://$GW_IP:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"test","role":"admin"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo $TOKEN

# 4. Dashboard agregado (ASR Latencia)
curl -H "Authorization: Bearer $TOKEN" \
  "http://$GW_IP:8000/dashboard/summary"
# Validar que elapsed_ms < 2000

# 5. Generar un reporte completo (pipeline async con cache + cola)
REPORT_ID=$(curl -sX POST http://$GW_IP:8000/reports/generate \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"report_type":"monthly_analysis","period":"monthly","company":"Bancolombia"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['report_id'])")

# 6. Polling del resultado (puede demorar unos segundos la primera vez)
sleep 5
curl -H "Authorization: Bearer $TOKEN" http://$GW_IP:8000/reports/$REPORT_ID

# 7. Mismo POST otra vez → cache hit (respuesta inmediata)
curl -X POST http://$GW_IP:8000/reports/generate \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"report_type":"monthly_analysis","period":"monthly","company":"Bancolombia"}'
# → "cached": true
```

Si todo responde correctamente, el sistema está listo para los experimentos.

---

## Experimento 1 — ASR Seguridad (EXP 02)

Simula un atacante que excede el límite de 100 req/min. El gateway debe detectarlo y bloquearlo.

```bash
# Terminal 1 — monitorear el audit log en MongoDB
ssh -i ~/.ssh/labsuser.pem ec2-user@$MONGO_IP \
  "docker exec -it mongodb mongosh bite_reports --quiet \
   --eval 'db.audit_log.find({action:\"rate_limit_blocked\"}).sort({timestamp:-1}).limit(20).pretty()'"

# Terminal 2 — lanzar el ataque
cd load-test
locust -f locustfile.py AttackUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 50 \
  --run-time 60s --headless \
  --csv=results_attack
```

### Evidencia EXP 02

- Captura del output de Locust mostrando respuestas `429`.
- Captura del audit log con documentos `action: rate_limit_blocked`.
- El archivo `results_attack_stats.csv` generado.

---

## Experimento 2 — ASR Latencia (EXP 03)

Compara la latencia del dashboard agregado con y sin índices en las BDs.

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

### Evidencia EXP 03

- `results_con_indices_stats.csv`
- `results_sin_indices_stats.csv`
- Comparar la columna `95%` (p95) entre ambos archivos.

---

## Experimento 3 — Trade-off Seguridad vs Latencia

Mide el overhead que agrega el rate limiter sobre la latencia normal.

```bash
# Prueba 1: CON rate limiter (estado por defecto)
locust -f locustfile.py TradeoffUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 90s --headless \
  --csv=results_tradeoff_con_seguridad

# Deshabilitar rate limiter temporalmente
ssh -i ~/.ssh/labsuser.pem ec2-user@$GW_IP
cd sprint4-bite/sprint4-bite/api-gateway
# Editar index.js y comentar la línea: app.use(limiter);
docker stop api-gateway && docker rm api-gateway
docker build -t api-gateway .
docker run -d --name api-gateway \
  -e INVENTORY_URL="http://<INV-IP>:8001" \
  -e REPORT_URL="http://<REPORT-IP>:8002" \
  -e NOTIF_URL="http://<NOTIF-IP>:8003" \
  -e ORCHESTRATOR_URL="http://<ORCH-IP>:8004" \
  -e MONGO_AUDIT_URL="mongodb://<MONGO-IP>:27017" \
  -e JWT_SECRET="bite-secret-2025" \
  -p 8000:8000 api-gateway

# Prueba 2: SIN rate limiter
locust -f locustfile.py TradeoffUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 90s --headless \
  --csv=results_tradeoff_sin_seguridad
```

### Qué documentar

Diferencia de p95 entre `_con_seguridad` y `_sin_seguridad`.
Típicamente el overhead del rate limiter es 1–5 ms.

---

## Paso 6b — Si las IPs cambiaron

Cuando AWS Academy reinicia la sesión, solo hay que actualizar **dos servicios** porque son los que tienen IPs de otros como variables de entorno:

- `api-gateway` (referencia a inventory, report, notification, orchestrator y mongo)
- `orchestrator-service` (referencia a inventory, collector, analyzer, notification y broker)

```bash
# 1. Anotar las nuevas IPs desde la consola de EC2 y actualizar setup_all_ec2.sh

# 2. Relanzar el orchestrator con las nuevas IPs
ssh -i ~/.ssh/labsuser.pem ec2-user@<NUEVA-ORCH-IP>
docker stop orchestrator-service && docker rm orchestrator-service
docker run -d --name orchestrator-service --restart unless-stopped \
  -e REDIS_URL="redis://<NUEVA-BROKER-IP>:6379/0" \
  -e RABBITMQ_URL="amqp://bite:bite123@<NUEVA-BROKER-IP>:5672/" \
  -e INVENTORY_URL="http://<NUEVA-INV-IP>:8001" \
  -e COLLECTOR_URL="http://<NUEVA-ANALYTICS-IP>:8005" \
  -e ANALYZER_URL="http://<NUEVA-ANALYTICS-IP>:8006" \
  -e NOTIF_URL="http://<NUEVA-NOTIF-IP>:8003" \
  -p 8004:8004 orchestrator-service

# 3. Relanzar el gateway con las nuevas IPs
ssh -i ~/.ssh/labsuser.pem ec2-user@<NUEVA-GW-IP>
docker stop api-gateway && docker rm api-gateway
docker run -d --name api-gateway --restart unless-stopped \
  -e INVENTORY_URL="http://<NUEVA-INV-IP>:8001" \
  -e REPORT_URL="http://<NUEVA-REPORT-IP>:8002" \
  -e NOTIF_URL="http://<NUEVA-NOTIF-IP>:8003" \
  -e ORCHESTRATOR_URL="http://<NUEVA-ORCH-IP>:8004" \
  -e MONGO_AUDIT_URL="mongodb://<NUEVA-MONGO-IP>:27017" \
  -e JWT_SECRET="bite-secret-2025" \
  -p 8000:8000 api-gateway

# Los demás servicios no necesitan cambios — sus puertos son fijos.
```

---

## Troubleshooting

**El script `setup_all_ec2.sh` falla en una instancia**

```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@<IP>
docker ps                       # ver qué contenedores corren
docker logs <nombre>            # ver errores específicos
```

**Un health check sale con ❌**

```bash
# Verificar que el contenedor está corriendo
docker ps | grep <nombre-servicio>

# Si no aparece, levantarlo manualmente (ver "Despliegue manual" en README.md)
```

**`/reports/generate` responde 502 (orchestrator unavailable)**

```bash
# El orchestrator no está alcanzable desde el gateway o el broker está caído
curl http://<ORCH-IP>:8004/health
# → si redis o rabbitmq dan false, revisar SG del ec2-broker
ssh -i ~/.ssh/labsuser.pem ec2-user@<ORCH-IP> "docker logs orchestrator-service"
```

**El worker del orchestrator no procesa mensajes**

```bash
# Abrir la UI de RabbitMQ
open http://<BROKER-IP>:15672  # user: bite, pass: bite123
# Si hay mensajes acumulados en report.request, ver logs del orchestrator
ssh -i ~/.ssh/labsuser.pem ec2-user@<ORCH-IP> "docker logs -f orchestrator-service"
```

**El cache de Redis no se popula**

```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@<BROKER-IP> \
  "docker exec redis redis-cli KEYS 'report:*'"
# Si no hay claves, el worker no está completando el pipeline (ver logs)
```

**`/dashboard/summary` da error 500**

```bash
# El gateway no pudo conectar a inventory o report
curl http://<INV-IP>:8001/health
curl http://<REPORT-IP>:8002/health
```

**El seed falla con "connection refused"**

```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@<POSTGRES-IP> "docker ps | grep postgres"
ssh -i ~/.ssh/labsuser.pem ec2-user@<MONGO-IP>    "docker ps | grep mongodb"
# Verificar que el SG permite 5432/27017 desde tu IP de desarrollo
```

**Locust da 401 en todas las peticiones**

```bash
# El token se genera automáticamente; probar manualmente:
curl -X POST http://<GW-IP>:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"test"}'
```

---

## Checklist completo

```text
[ ]  1. Crear 9 instancias EC2 t2.micro en AWS Academy
[ ]  2. Anotar las 9 IPs públicas
[ ]  3. Editar IPs en setup_all_ec2.sh (+ REPO_URL)
[ ]  4. Editar IP en seed/seed_postgres.py
[ ]  5. Editar IP en seed/seed_mongo.py
[ ]  6. Push de los cambios al repo
[ ]  7. Correr ./setup_all_ec2.sh (esperar 8-12 min)
[ ]  8. Correr seed_postgres.py
[ ]  9. Correr seed_mongo.py
[ ] 10. Verificar health checks con curl
[ ] 11. Verificar /reports/generate (pipeline async)
[ ] 12. Verificar cache hit en segunda llamada
[ ] 13. pip install locust
[ ] 14. EXP 02: AttackUser + captura del audit_log
[ ] 15. EXP 03: LatencyUser con/sin índices
[ ] 16. Trade-off: TradeoffUser con/sin rate limiter
```
