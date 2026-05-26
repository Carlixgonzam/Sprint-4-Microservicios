# Guía de despliegue — Sprint 4 BITE.co
> Sigue este documento de arriba a abajo. No te saltes pasos.

---

## Antes de empezar

Necesitas tener en tu máquina:
- **Python 3** con pip
- **Git**
- El archivo **`labsuser.pem`** descargado desde AWS Academy (está en la página del laboratorio)

```bash
# Instalar dependencias locales necesarias
pip install psycopg2-binary pymongo locust
```

---

## Paso 1 — Crear las 6 instancias EC2 en AWS Academy

1. Entrar a [AWS Academy](https://awsacademy.instructure.com) → iniciar el laboratorio
2. Ir a **EC2 → Launch Instance**
3. Crear **6 instancias** con esta configuración exacta:

| Nombre | AMI | Tipo | Puerto a abrir |
|---|---|---|---|
| `ec2-gateway` | Amazon Linux 2 | t2.micro | **8000** desde `0.0.0.0/0` |
| `ec2-inventory` | Amazon Linux 2 | t2.micro | **8001** desde IP de ec2-gateway |
| `ec2-report` | Amazon Linux 2 | t2.micro | **8002** desde IP de ec2-gateway |
| `ec2-notification` | Amazon Linux 2 | t2.micro | **8003** desde IP de ec2-gateway |
| `ec2-postgres` | Amazon Linux 2 | t2.micro | **5432** desde IP de ec2-inventory |
| `ec2-mongo` | Amazon Linux 2 | t2.micro | **27017** desde IP de ec2-report |

> En todas: agregar también el puerto **22** desde tu IP para poder conectarte por SSH.  
> Usar el key pair **`labsuser`** en todas.

---

## Paso 2 — Anotar las IPs

Una vez creadas, ir a EC2 → Instances y anotar la **IP pública** de cada una:

```
ec2-gateway      → 
ec2-inventory    → 
ec2-report       → 
ec2-notification → 
ec2-postgres     → 
ec2-mongo        → 
```

> ⚠️ Estas IPs cambian cada vez que reinicias la sesión del laboratorio.  
> Si eso pasa, ve directo al [Paso 6b](#paso-6b--si-las-ips-cambiaron).

---

## Paso 3 — Poner las IPs en el repo

Editar **3 archivos** con las IPs que anotaste:

### `setup_all_ec2.sh`
```bash
GW_IP="IP_DE_EC2_GATEWAY"
INV_IP="IP_DE_EC2_INVENTORY"
REPORT_IP="IP_DE_EC2_REPORT"
NOTIF_IP="IP_DE_EC2_NOTIFICATION"
POSTGRES_IP="IP_DE_EC2_POSTGRES"
MONGO_IP="IP_DE_EC2_MONGO"

REPO_URL="https://github.com/TU_ORG/sprint4-bite.git"  # URL del repo del equipo
```

### `seed/seed_postgres.py` — línea 4
```python
EC2_POSTGRES_IP = "IP_DE_EC2_POSTGRES"
```

### `seed/seed_mongo.py` — línea 4
```python
EC2_MONGO_IP = "IP_DE_EC2_MONGO"
```

Guardar los cambios y hacer push al repo.

---

## Paso 4 — Correr el script de despliegue

```bash
chmod +x setup_all_ec2.sh
./setup_all_ec2.sh
```

Este script hace todo automáticamente:
- Instala Docker en las 6 instancias
- Levanta PostgreSQL y MongoDB
- Construye y levanta los 4 microservicios
- Hace health checks al final

**Tarda entre 5 y 10 minutos.** Al terminar deberías ver algo así:

```
[api-gateway]      ✅ OK (http://54.X.X.X:8000/health)
[inventory-service] ✅ OK (http://54.X.X.X:8001/health)
[report-service]   ✅ OK (http://54.X.X.X:8002/health)
[notification-service] ✅ OK (http://54.X.X.X:8003/health)
```

Si alguno sale con ❌, ver la sección de [Troubleshooting](#troubleshooting).

---

## Paso 5 — Poblar las bases de datos

```bash
python3 seed/seed_postgres.py
# ✅ PostgreSQL: 5000 registros + índices creados

python3 seed/seed_mongo.py
# ✅ MongoDB: 3000 cost_reports + 30 monthly_summaries + índices creados
```

> Solo hay que hacer esto **una vez**. Si ya lo corriste, no lo vuelvas a correr o duplicarás los datos.

---

## Paso 6 — Verificar que todo funciona

```bash
GW_IP="IP_DE_EC2_GATEWAY"

# 1. Health check del gateway (sin token)
curl http://$GW_IP:8000/health
# Esperado: {"status":"ok","service":"api-gateway"}

# 2. Sin token debe dar 401
curl http://$GW_IP:8000/inventory/resources
# Esperado: {"error":"Missing token"}

# 3. Obtener token
TOKEN=$(curl -s -X POST http://$GW_IP:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"test"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo $TOKEN  # debe imprimir el JWT completo

# 4. Consultar el dashboard (endpoint del ASR de latencia)
curl -H "Authorization: Bearer $TOKEN" \
  "http://$GW_IP:8000/dashboard/summary"
# Esperado: JSON con inventory, reports y elapsed_ms < 2000
```

Si todo responde correctamente, el sistema está listo para los experimentos.

---

## Experimento 1 — ASR Seguridad (EXP 02)

Simula un atacante enviando más de 100 req/s desde un mismo origen.  
El gateway debe detectarlo y bloquearlo automáticamente.

```bash
# Terminal 1 — monitorear logs del gateway (abrir antes del ataque)
ssh -i ~/.ssh/labsuser.pem ec2-user@$GW_IP \
  "docker logs -f api-gateway" | grep AUDIT

# Terminal 2 — lanzar el ataque
cd load-test
locust -f locustfile.py AttackUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 50 \
  --run-time 60s --headless \
  --csv=results_attack
```

**Qué guardar como evidencia:**
- Captura del output de Locust mostrando respuestas `429`
- Captura de la Terminal 1 mostrando líneas `[AUDIT] BLOCKED`
- El archivo `results_attack_stats.csv` generado

---

## Experimento 2 — ASR Latencia (EXP 03)

Compara la latencia del dashboard agregado con y sin índices en las BDs.

```bash
cd load-test

# --- Escenario A: CON índices (ya están creados por el seed) ---
locust -f locustfile.py LatencyUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 120s --headless \
  --csv=results_con_indices

# --- Dropear índices para el escenario B ---
ssh -i ~/.ssh/labsuser.pem ec2-user@$POSTGRES_IP \
  "docker exec postgres psql -U bite -d inventory -c \
  'DROP INDEX IF EXISTS idx_company; DROP INDEX IF EXISTS idx_company_project;'"

# --- Escenario B: SIN índices ---
locust -f locustfile.py LatencyUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 120s --headless \
  --csv=results_sin_indices

# --- Volver a crear los índices al terminar ---
ssh -i ~/.ssh/labsuser.pem ec2-user@$POSTGRES_IP \
  "docker exec postgres psql -U bite -d inventory -c \
  'CREATE INDEX idx_company ON cloud_resources(company);
   CREATE INDEX idx_company_project ON cloud_resources(company, project);'"
```

**Qué guardar como evidencia:**
- `results_con_indices_stats.csv`
- `results_sin_indices_stats.csv`
- Comparar columna `95%` (p95) entre ambos archivos

---

## Experimento 3 — Trade-off Seguridad vs Latencia

Mide el overhead que agrega el rate limiter sobre la latencia normal.

```bash
# --- Prueba CON seguridad (estado normal) ---
locust -f locustfile.py TradeoffUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 90s --headless \
  --csv=results_tradeoff_con_seguridad

# --- Deshabilitar rate limiter temporalmente ---
# En ec2-gateway, editar index.js y comentar la línea: app.use(limiter);
ssh -i ~/.ssh/labsuser.pem ec2-user@$GW_IP
# Editar el archivo y hacer rebuild:
cd sprint4-bite/sprint4-bite/api-gateway
# Comentar app.use(limiter); en index.js
docker stop api-gateway && docker rm api-gateway
docker build -t api-gateway .
docker run -d --name api-gateway \
  -e INVENTORY_URL="http://<INV-IP>:8001" \
  -e REPORT_URL="http://<REPORT-IP>:8002" \
  -e NOTIF_URL="http://<NOTIF-IP>:8003" \
  -e JWT_SECRET="bite-secret-2025" \
  -p 8000:8000 api-gateway

# --- Prueba SIN seguridad ---
locust -f locustfile.py TradeoffUser \
  --host http://$GW_IP:8000 \
  --users 50 --spawn-rate 5 \
  --run-time 90s --headless \
  --csv=results_tradeoff_sin_seguridad
```

**Qué documentar:** diferencia de p95 entre `_con_seguridad` y `_sin_seguridad`.  
Típicamente el overhead del rate limiter es 1–5 ms — ese es el costo de la seguridad.

---

## Paso 6b — Si las IPs cambiaron

Cuando AWS Academy reinicia la sesión, solo hay que actualizar el **api-gateway** porque es el único que tiene las IPs de los demás como variables de entorno.

```bash
# 1. Anotar las nuevas IPs desde la consola de EC2

# 2. Reemplazar en setup_all_ec2.sh y hacer push

# 3. Reconectar al gateway y relanzar el contenedor con las nuevas IPs
ssh -i ~/.ssh/labsuser.pem ec2-user@<NUEVA-GW-IP>

docker stop api-gateway && docker rm api-gateway
docker run -d --name api-gateway \
  -e INVENTORY_URL="http://<NUEVA-INV-IP>:8001" \
  -e REPORT_URL="http://<NUEVA-REPORT-IP>:8002" \
  -e NOTIF_URL="http://<NUEVA-NOTIF-IP>:8003" \
  -e JWT_SECRET="bite-secret-2025" \
  -p 8000:8000 api-gateway

# 4. Los demás servicios (inventory, report, notification, BDs)
#    NO necesitan cambios porque sus puertos son fijos.
```

---

## Troubleshooting

**El script `setup_all_ec2.sh` falla en una instancia**
```bash
# Conectarse manualmente y revisar qué pasó
ssh -i ~/.ssh/labsuser.pem ec2-user@<IP>
docker ps          # ver qué contenedores están corriendo
docker logs <nombre-contenedor>   # ver errores
```

**Un health check sale con ❌**
```bash
# Verificar que el contenedor está corriendo
docker ps | grep <nombre-servicio>

# Si no está, intentar levantarlo manualmente
# (ver sección "Despliegue manual" en el README principal)
```

**`dashboard/summary` da error 500**
```bash
# Significa que el gateway no pudo conectar a inventory o report
# Verificar que inventory-service y report-service están corriendo
curl http://<INV-IP>:8001/health
curl http://<REPORT-IP>:8002/health
```

**El seed falla con "connection refused"**
```bash
# Verificar que PostgreSQL/MongoDB están corriendo
ssh -i ~/.ssh/labsuser.pem ec2-user@<POSTGRES-IP> "docker ps | grep postgres"
ssh -i ~/.ssh/labsuser.pem ec2-user@<MONGO-IP> "docker ps | grep mongodb"

# Verificar que el Security Group permite el puerto desde tu IP
# (EC2 → Security Groups → Inbound rules)
```

**Locust da 401 en todas las peticiones**
```bash
# El token se genera automáticamente pero si falla:
curl -X POST http://<GW-IP>:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"test"}'
# Si este curl falla, el gateway no está corriendo
```

---

## Checklist completo

```
[ ] 1. Crear 6 instancias EC2 t2.micro en AWS Academy
[ ] 2. Anotar las 6 IPs públicas
[ ] 3. Editar IPs en setup_all_ec2.sh (+ REPO_URL)
[ ] 4. Editar IP en seed/seed_postgres.py
[ ] 5. Editar IP en seed/seed_mongo.py
[ ] 6. Push de los cambios al repo
[ ] 7. Correr ./setup_all_ec2.sh (esperar 5-10 min)
[ ] 8. Correr seed_postgres.py
[ ] 9. Correr seed_mongo.py
[ ] 10. Verificar health checks con curl
[ ] 11. pip install locust (si no lo tienes)
[ ] 12. EXP 02: Locust AttackUser + captura de logs AUDIT
[ ] 13. EXP 03: Locust LatencyUser con/sin índices
[ ] 14. Trade-off: Locust TradeoffUser con/sin rate limiter
```