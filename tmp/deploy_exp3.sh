#!/usr/bin/env bash
# deploy_exp3.sh — Prepara el servidor EC2 para el Experimento 3 (Latency ASR)
#
# Uso:
#   bash deploy_exp3.sh <EC2_IP> [RUTA_PEM]
#
# Ejemplos:
#   bash deploy_exp3.sh 54.210.30.5
#   bash deploy_exp3.sh 54.210.30.5 ~/.ssh/labsuser.pem
#
# Qué instala y arranca en la EC2:
#   Node.js 20 LTS + dependencias npm
#   gateway_cached.js  → :8000  (cache-aside en memoria + JWT)
#   stub_inventory.js  → :8001  (latencia Normal 90ms σ=15)
#   stub_report.js     → :8002  (latencia Normal 110ms σ=18)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

EC2_IP="${1:-}"
KEY_FILE="${2:-$HOME/.ssh/labsuser.pem}"
REMOTE_USER="ubuntu"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC}  $*"; }
fail() { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }
log()  { echo -e "${BOLD}───${NC} $*"; }

# ── Validaciones ──────────────────────────────────────────────────────────────
[ -n "$EC2_IP" ]           || fail "Falta la IP.  Uso: bash deploy_exp3.sh <EC2_IP> [PEM]"
[ -d "$SCRIPT_DIR/exp3" ]  || fail "No se encontró exp3/ junto al script."
[ -f "$KEY_FILE" ]         || fail "No se encontró la clave PEM: $KEY_FILE"
chmod 400 "$KEY_FILE"

SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $KEY_FILE"
SCP="scp -o StrictHostKeyChecking=no -i $KEY_FILE"
TARGET="$REMOTE_USER@$EC2_IP"

echo
echo -e "${BOLD}Experimento 3 — Deploy servidor${NC}  →  $EC2_IP"
echo

# ── 1. Verificar SSH ──────────────────────────────────────────────────────────
log "Verificando conexión SSH..."
$SSH "$TARGET" 'echo ok' &>/dev/null || fail "No se puede conectar a $EC2_IP (puerto 22 abierto? key correcta?)"
ok "SSH OK"

# ── 2. Transferir archivos ────────────────────────────────────────────────────
log "Transfiriendo archivos..."
$SSH "$TARGET" 'mkdir -p ~/exp3'
$SCP -r "$SCRIPT_DIR/exp3/"* "$TARGET:~/exp3/"
ok "Archivos copiados a ~/exp3/"

# ── 3. Instalar dependencias en la EC2 ───────────────────────────────────────
log "Instalando dependencias (Node.js 20 + npm)..."
$SSH "$TARGET" << 'REMOTE'
set -e
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -qq 2>&1 | tail -1
sudo apt-get install -y -q curl ca-certificates lsof 2>&1 | tail -1

# Node.js 20 LTS (si no está instalado)
if ! node --version 2>/dev/null | grep -q "^v2"; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
  sudo apt-get install -y -q nodejs 2>&1 | tail -1
fi

cd ~/exp3
npm install --silent --no-fund
REMOTE
ok "Node.js 20 + dependencias npm instalados"

# ── 4. Arrancar los 3 servidores ──────────────────────────────────────────────
log "Arrancando servidores..."
$SSH "$TARGET" << 'REMOTE'
set -e

# Limpiar puertos por si ya hay algo corriendo
for PORT in 8000 8001 8002; do
  PID=$(lsof -ti:"$PORT" 2>/dev/null || true)
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
done
sleep 1

cd ~/exp3
nohup node gateway_cached.js  > ~/exp3/gateway.log   2>&1 & echo $! > ~/exp3/gateway.pid;   disown
nohup node stub_inventory.js  > ~/exp3/inventory.log 2>&1 & echo $! > ~/exp3/inventory.pid; disown
nohup node stub_report.js     > ~/exp3/report.log    2>&1 & echo $! > ~/exp3/report.pid;    disown

sleep 4

# Verificar los tres servicios
curl -sf http://localhost:8000/health | grep -q '"ok"' \
  && echo "gateway_cached OK" \
  || { echo "ERROR: gateway no responde"; tail -20 ~/exp3/gateway.log; exit 1; }

curl -sf http://localhost:8001/resources | grep -q '"count"' \
  && echo "stub_inventory OK" \
  || { echo "ERROR: stub_inventory no responde"; tail -10 ~/exp3/inventory.log; exit 1; }

curl -sf http://localhost:8002/costs | grep -q '"count"' \
  && echo "stub_report OK" \
  || { echo "ERROR: stub_report no responde"; tail -10 ~/exp3/report.log; exit 1; }
REMOTE
ok "gateway_cached.js corriendo en :8000"
ok "stub_inventory.js corriendo en :8001"
ok "stub_report.js    corriendo en :8002"

# ── Resumen ───────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}Servidor listo.${NC}  Corre los escenarios desde tu máquina:"
echo
echo -e "  ${DIM}cd tmp/exp3${NC}"
echo
echo -e "  ${DIM}# Escenario A — sin caché${NC}"
echo -e "  locust -f locustfile.py NoCacheUser \\"
echo -e "    --host http://$EC2_IP:8000 \\"
echo -e "    --users 50 --spawn-rate 10 --run-time 90s --headless"
echo
echo -e "  ${DIM}# Escenario B — con caché${NC}"
echo -e "  locust -f locustfile.py CacheUser \\"
echo -e "    --host http://$EC2_IP:8000 \\"
echo -e "    --users 50 --spawn-rate 10 --run-time 90s --headless"
echo
echo -e "  ${DIM}# Gráficas (después de ambos escenarios)${NC}"
echo -e "  python charts_latency.py"
echo
