#!/usr/bin/env bash
# deploy_exp2.sh — Bootstrap del servidor para Experimento 2 (Security ASR)
#
# Corre DENTRO de la instancia EC2 (Ubuntu 24.04), en la misma carpeta que exp2/
#
#   scp -i labsuser.pem -r tmp/ ubuntu@<IP>:~/
#   ssh -i labsuser.pem ubuntu@<IP>
#   bash ~/tmp/deploy_exp2.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
ok()  { echo -e "${GREEN}✓${NC}  $*"; }
log() { echo -e "\n${BOLD}───${NC} $*"; }
die() { echo "✗  $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP_DIR="$SCRIPT_DIR/exp2"

[ -d "$EXP_DIR" ] || die "No se encontró exp2/ junto al script."

echo
echo -e "${BOLD}Experimento 2 — Security ASR · Setup del servidor${NC}"
echo

# ── Dependencias del sistema ──────────────────────────────────────────────────
log "Instalando dependencias del sistema..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq 2>&1 | tail -1
sudo apt-get install -y -q curl ca-certificates lsof 2>&1 | tail -1
ok "Paquetes base OK"

# ── Node.js 20 LTS ────────────────────────────────────────────────────────────
log "Instalando Node.js 20 LTS..."
if ! node --version 2>/dev/null | grep -q "^v2"; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
  sudo apt-get install -y -q nodejs 2>&1 | tail -1
fi
ok "$(node -v)  /  npm $(npm -v)"

# ── Dependencias npm ──────────────────────────────────────────────────────────
log "Instalando dependencias npm..."
cd "$EXP_DIR"
npm install --silent --no-fund
ok "node_modules listo"

# ── Arrancar servidores ───────────────────────────────────────────────────────
log "Arrancando servidores..."

for PORT in 8000 8001 8002; do
  PID=$(lsof -ti:"$PORT" 2>/dev/null || true)
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
done
sleep 1

nohup node "$EXP_DIR/gateway.js" > "$EXP_DIR/gateway.log" 2>&1 & echo $! > "$EXP_DIR/gateway.pid"; disown
nohup node "$EXP_DIR/stub.js"    > "$EXP_DIR/stub.log"    2>&1 & echo $! > "$EXP_DIR/stub.pid";    disown

sleep 3
curl -sf http://localhost:8000/health | grep -q '"ok"' \
  || { echo "✗ gateway no responde"; tail -20 "$EXP_DIR/gateway.log"; exit 1; }

ok "gateway.js  →  :8000"
ok "stub.js     →  :8001 y :8002"

# ── Imprimir IP pública para usarla en los scripts locales ───────────────────
PUBLIC_IP=$(curl -sf http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<IP-de-la-instancia>")

echo
echo -e "${BOLD}Servidor listo.${NC}  Corre esto desde tu máquina local:"
echo
echo "  python attack.py --host http://$PUBLIC_IP:8000"
echo "  python charts_security.py"
echo
echo "  # Ver logs del gateway:"
echo "  tail -f $EXP_DIR/gateway.log | grep AUDIT"
echo
