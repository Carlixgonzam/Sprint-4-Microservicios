#!/usr/bin/env bash
# deploy_exp2.sh — Prepara el servidor EC2 para el Experimento 2 (Security ASR)
#
# Uso:
#   bash deploy_exp2.sh <EC2_IP> [RUTA_PEM]
#
# Ejemplos:
#   bash deploy_exp2.sh 54.210.30.5
#   bash deploy_exp2.sh 54.210.30.5 ~/.ssh/labsuser.pem
#
# Qué instala y arranca en la EC2:
#   Node.js 20 LTS + dependencias npm
#   gateway.js   → :8000  (rate limiting + JWT)
#   stub.js      → :8001 :8002  (microservicios dummy)
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
[ -n "$EC2_IP" ]           || fail "Falta la IP.  Uso: bash deploy_exp2.sh <EC2_IP> [PEM]"
[ -d "$SCRIPT_DIR/exp2" ]  || fail "No se encontró exp2/ junto al script."
[ -f "$KEY_FILE" ]         || fail "No se encontró la clave PEM: $KEY_FILE"
chmod 400 "$KEY_FILE"

SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $KEY_FILE"
SCP="scp -o StrictHostKeyChecking=no -i $KEY_FILE"
TARGET="$REMOTE_USER@$EC2_IP"

echo
echo -e "${BOLD}Experimento 2 — Deploy servidor${NC}  →  $EC2_IP"
echo

# ── 1. Verificar SSH ──────────────────────────────────────────────────────────
log "Verificando conexión SSH..."
$SSH "$TARGET" 'echo ok' &>/dev/null || fail "No se puede conectar a $EC2_IP (puerto 22 abierto? key correcta?)"
ok "SSH OK"

# ── 2. Transferir archivos ────────────────────────────────────────────────────
log "Transfiriendo archivos..."
$SSH "$TARGET" 'mkdir -p ~/exp2'
$SCP -r "$SCRIPT_DIR/exp2/"* "$TARGET:~/exp2/"
ok "Archivos copiados a ~/exp2/"

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

cd ~/exp2
npm install --silent --no-fund
REMOTE
ok "Node $(ssh $SSH_EXTRA "$TARGET" 'node -v' 2>/dev/null) + dependencias npm instalados"

# ── 4. Arrancar servidores ────────────────────────────────────────────────────
log "Arrancando servidores..."
$SSH "$TARGET" << 'REMOTE'
set -e

# Limpiar puertos por si ya hay algo corriendo
for PORT in 8000 8001 8002; do
  PID=$(lsof -ti:"$PORT" 2>/dev/null || true)
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
done
sleep 1

cd ~/exp2
nohup node gateway.js > ~/exp2/gateway.log 2>&1 & echo $! > ~/exp2/gateway.pid; disown
nohup node stub.js    > ~/exp2/stub.log    2>&1 & echo $! > ~/exp2/stub.pid;    disown

sleep 3
curl -sf http://localhost:8000/health | grep -q '"ok"' \
  && echo "gateway OK" \
  || { echo "ERROR: gateway no responde"; tail -20 ~/exp2/gateway.log; exit 1; }
REMOTE
ok "gateway.js corriendo en :8000"
ok "stub.js corriendo en :8001 y :8002"

# ── Resumen ───────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}Servidor listo.${NC}  Corre el ataque desde tu máquina:"
echo
echo -e "  ${DIM}cd tmp/exp2${NC}"
echo -e "  python attack.py --host http://$EC2_IP:8000"
echo -e "  python charts_security.py"
echo
echo -e "  ${DIM}# Logs del gateway:${NC}"
echo -e "  $SSH $TARGET 'tail -f ~/exp2/gateway.log | grep AUDIT'"
echo
