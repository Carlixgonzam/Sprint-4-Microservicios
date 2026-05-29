#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# setup_all_ec2.sh
# Instala Docker en todas las instancias y despliega cada servicio.
#
# ANTES DE CORRER:
# 1. Poner las IPs públicas de cada EC2 (las ves en la consola de AWS Academy)
# 2. Ajustar la ruta de tu .pem si es diferente
# 3. chmod +x setup_all_ec2.sh
# 4. ./setup_all_ec2.sh
# ─────────────────────────────────────────────────────────────────────────────

KEY="~/.ssh/labsuser.pem"
SSH_OPTS="-o StrictHostKeyChecking=no -i $KEY"
REPO_URL="https://github.com/Carlixgonzam/Sprint-4-Microservicios.git"   # <-- cambiar por su repo

# ─── IPs de cada EC2 (llenar con las IPs de AWS Academy) ─────────────────────
GW_IP="REEMPLAZAR_IP_GATEWAY"
INV_IP="REEMPLAZAR_IP_INVENTORY"
REPORT_IP="REEMPLAZAR_IP_REPORT"
NOTIF_IP="REEMPLAZAR_IP_NOTIFICATION"
POSTGRES_IP="REEMPLAZAR_IP_POSTGRES"
MONGO_IP="REEMPLAZAR_IP_MONGO"
# ─── EC2s nuevas para el diagrama completo (context.md) ──────────────────────
BROKER_IP="REEMPLAZAR_IP_BROKER"          # Redis + RabbitMQ
ORCH_IP="REEMPLAZAR_IP_ORCHESTRATOR"      # orchestrator-service
ANALYTICS_IP="REEMPLAZAR_IP_ANALYTICS"    # collector-service + analyzer-service
# ─── Credenciales del broker (cambiar si quieres) ────────────────────────────
RABBIT_USER="bite"
RABBIT_PASS="bite123"
# ─────────────────────────────────────────────────────────────────────────────

install_docker() {
    local ip=$1
    local name=$2
    echo "[$name] Instalando Docker en $ip..."
    ssh $SSH_OPTS ec2-user@$ip << 'ENDSSH'
sudo yum update -y
sudo yum install -y git docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user
ENDSSH
    if [ $? -eq 0 ]; then
        echo "[$name] ✅ Docker instalado"
    else
        echo "[$name] ❌ ERROR instalando Docker"
    fi
}

# ── Paso 1: instalar Docker en paralelo en todas las instancias ───────────────
echo "=== PASO 1: Instalando Docker en todas las instancias ==="
install_docker "$GW_IP"        "ec2-gateway"       &
install_docker "$INV_IP"       "ec2-inventory"     &
install_docker "$REPORT_IP"    "ec2-report"        &
install_docker "$NOTIF_IP"     "ec2-notification"  &
install_docker "$POSTGRES_IP"  "ec2-postgres"      &
install_docker "$MONGO_IP"     "ec2-mongo"         &
install_docker "$BROKER_IP"    "ec2-broker"        &
install_docker "$ORCH_IP"      "ec2-orchestrator"  &
install_docker "$ANALYTICS_IP" "ec2-analytics"     &
wait
echo "=== Docker instalado en todas las instancias ==="

# ── Paso 2: levantar bases de datos ──────────────────────────────────────────
echo ""
echo "=== PASO 2: Levantando bases de datos ==="

echo "[ec2-postgres] Levantando PostgreSQL..."
ssh $SSH_OPTS ec2-user@$POSTGRES_IP << 'ENDSSH'
docker run -d \
  --name postgres \
  --restart unless-stopped \
  -e POSTGRES_USER=bite \
  -e POSTGRES_PASSWORD=bite123 \
  -e POSTGRES_DB=inventory \
  -p 5432:5432 \
  postgres:15
echo "PostgreSQL levantado"
ENDSSH

echo "[ec2-mongo] Levantando MongoDB..."
ssh $SSH_OPTS ec2-user@$MONGO_IP << 'ENDSSH'
docker run -d \
  --name mongodb \
  --restart unless-stopped \
  -p 27017:27017 \
  mongo:7
echo "MongoDB levantado"
ENDSSH

echo "[ec2-broker] Levantando Redis + RabbitMQ..."
ssh $SSH_OPTS ec2-user@$BROKER_IP << ENDSSH
docker run -d \
  --name redis \
  --restart unless-stopped \
  -p 6379:6379 \
  redis:7-alpine

docker run -d \
  --name rabbitmq \
  --restart unless-stopped \
  -e RABBITMQ_DEFAULT_USER=${RABBIT_USER} \
  -e RABBITMQ_DEFAULT_PASS=${RABBIT_PASS} \
  -p 5672:5672 \
  -p 15672:15672 \
  rabbitmq:3-management
echo "Redis + RabbitMQ levantados"
ENDSSH

echo "Esperando 15s para que las BDs y el broker inicialicen..."
sleep 15

# ── Paso 3: levantar microservicios ──────────────────────────────────────────
echo ""
echo "=== PASO 3: Levantando microservicios ==="

echo "[ec2-inventory] Levantando inventory-service..."
ssh $SSH_OPTS ec2-user@$INV_IP << ENDSSH
git clone $REPO_URL sprint4-bite || (cd sprint4-bite && git pull)
cd sprint4-bite/sprint4-bite/inventory-service
docker build -t inventory-service . && \
docker run -d \
  --name inventory-service \
  --restart unless-stopped \
  -e DATABASE_URL="postgresql://bite:bite123@${POSTGRES_IP}:5432/inventory" \
  -p 8001:8001 \
  inventory-service
echo "inventory-service levantado"
ENDSSH

echo "[ec2-report] Levantando report-service..."
ssh $SSH_OPTS ec2-user@$REPORT_IP << ENDSSH
git clone $REPO_URL sprint4-bite || (cd sprint4-bite && git pull)
cd sprint4-bite/sprint4-bite/report-service
docker build -t report-service . && \
docker run -d \
  --name report-service \
  --restart unless-stopped \
  -e MONGO_URL="mongodb://${MONGO_IP}:27017" \
  -p 8002:8002 \
  report-service
echo "report-service levantado"
ENDSSH

echo "[ec2-notification] Levantando notification-service..."
ssh $SSH_OPTS ec2-user@$NOTIF_IP << ENDSSH
git clone $REPO_URL sprint4-bite || (cd sprint4-bite && git pull)
cd sprint4-bite/sprint4-bite/notification-service
docker build -t notification-service . && \
docker run -d \
  --name notification-service \
  --restart unless-stopped \
  -p 8003:8003 \
  notification-service
echo "notification-service levantado"
ENDSSH

echo "[ec2-analytics] Levantando collector-service + analyzer-service..."
ssh $SSH_OPTS ec2-user@$ANALYTICS_IP << ENDSSH
git clone $REPO_URL sprint4-bite || (cd sprint4-bite && git pull)
cd sprint4-bite/sprint4-bite/collector-service
docker build -t collector-service . && \
docker run -d \
  --name collector-service \
  --restart unless-stopped \
  -e MONGO_URL="mongodb://${MONGO_IP}:27017" \
  -p 8005:8005 \
  collector-service

cd ../analyzer-service
docker build -t analyzer-service . && \
docker run -d \
  --name analyzer-service \
  --restart unless-stopped \
  -e DATABASE_URL="postgresql://bite:bite123@${POSTGRES_IP}:5432/inventory" \
  -p 8006:8006 \
  analyzer-service
echo "collector-service + analyzer-service levantados"
ENDSSH

echo "[ec2-orchestrator] Levantando orchestrator-service..."
ssh $SSH_OPTS ec2-user@$ORCH_IP << ENDSSH
git clone $REPO_URL sprint4-bite || (cd sprint4-bite && git pull)
cd sprint4-bite/sprint4-bite/orchestrator-service
docker build -t orchestrator-service . && \
docker run -d \
  --name orchestrator-service \
  --restart unless-stopped \
  -e REDIS_URL="redis://${BROKER_IP}:6379/0" \
  -e RABBITMQ_URL="amqp://${RABBIT_USER}:${RABBIT_PASS}@${BROKER_IP}:5672/" \
  -e INVENTORY_URL="http://${INV_IP}:8001" \
  -e COLLECTOR_URL="http://${ANALYTICS_IP}:8005" \
  -e ANALYZER_URL="http://${ANALYTICS_IP}:8006" \
  -e NOTIF_URL="http://${NOTIF_IP}:8003" \
  -p 8004:8004 \
  orchestrator-service
echo "orchestrator-service levantado"
ENDSSH

echo "[ec2-gateway] Levantando api-gateway..."
ssh $SSH_OPTS ec2-user@$GW_IP << ENDSSH
git clone $REPO_URL sprint4-bite || (cd sprint4-bite && git pull)
cd sprint4-bite/sprint4-bite/api-gateway
docker build -t api-gateway . && \
docker run -d \
  --name api-gateway \
  --restart unless-stopped \
  -e INVENTORY_URL="http://${INV_IP}:8001" \
  -e REPORT_URL="http://${REPORT_IP}:8002" \
  -e NOTIF_URL="http://${NOTIF_IP}:8003" \
  -e ORCHESTRATOR_URL="http://${ORCH_IP}:8004" \
  -e MONGO_AUDIT_URL="mongodb://${MONGO_IP}:27017" \
  -e JWT_SECRET="bite-secret-2025" \
  -p 8000:8000 \
  api-gateway
echo "api-gateway levantado"
ENDSSH

# ── Paso 4: health checks ─────────────────────────────────────────────────────
echo ""
echo "=== PASO 4: Verificando health checks ==="
sleep 5

check_health() {
    local url=$1
    local name=$2
    status=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    if [ "$status" = "200" ]; then
        echo "[$name] ✅ OK ($url)"
    else
        echo "[$name] ❌ FALLÓ HTTP $status ($url)"
    fi
}

check_health "http://$GW_IP:8000/health"          "api-gateway"
check_health "http://$INV_IP:8001/health"         "inventory-service"
check_health "http://$REPORT_IP:8002/health"      "report-service"
check_health "http://$NOTIF_IP:8003/health"       "notification-service"
check_health "http://$ORCH_IP:8004/health"        "orchestrator-service"
check_health "http://$ANALYTICS_IP:8005/health"   "collector-service"
check_health "http://$ANALYTICS_IP:8006/health"   "analyzer-service"

echo ""
echo "=== DESPLIEGUE COMPLETO ==="
echo ""
echo "Siguiente paso — poblar las BDs:"
echo "  python3 sprint4-bite/seed/seed_postgres.py  (editar IP primero)"
echo "  python3 sprint4-bite/seed/seed_mongo.py     (editar IP primero)"
echo ""
echo "Luego obtener token:"
echo "  curl -X POST http://$GW_IP:8000/auth/token \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"username\":\"test\"}'"