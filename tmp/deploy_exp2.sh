#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# deploy_exp2.sh — Wizard de despliegue: Experimento 2 (ASR de Seguridad)
# BITE.co · Sprint 4 · AWS Academy
#
# Despliega en una instancia EC2 Ubuntu 24.04 virgen:
#   gateway.js   :8000   (rate limiting + JWT)
#   stub.js      :8001   :8002   (microservicios dummy)
#   attack.py    ejecutor del bombardeo de 105 requests
#   charts_security.py   generador del panel de gráficas
#
# Uso:
#   bash deploy_exp2.sh
#   bash deploy_exp2.sh --ip 1.2.3.4 --key ~/.ssh/labsuser.pem
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
trap 'echo -e "\n${RED}[!] Interrumpido.${NC}" >&2' INT TERM

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';  MAGENTA='\033[0;35m'
BOLD='\033[1m';      DIM='\033[2m';      NC='\033[0m'

step() { echo -e "\n${BOLD}${BLUE}▶ PASO $1/${TOTAL_STEPS}${NC}  ${BOLD}$2${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*" >&2; }
info() { echo -e "  ${DIM}→  $*${NC}"; }
ask()  { echo -en "\n  ${CYAN}?${NC}  $* "; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP_DIR="$SCRIPT_DIR/exp2"
RESULTS_DIR="$SCRIPT_DIR/results_exp2"
TOTAL_STEPS=7

# ── Banner ─────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${MAGENTA}║  BITE.co · Sprint 4 · AWS Academy                           ║${NC}"
echo -e "${BOLD}${MAGENTA}║  Experimento 2 — ASR de Seguridad · Rate Limiting           ║${NC}"
echo -e "${BOLD}${MAGENTA}║  Wizard de despliegue · EC2 Ubuntu 24.04                    ║${NC}"
echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# ── Prerequisitos locales ──────────────────────────────────────────────────────
for cmd in ssh scp curl; do
  command -v "$cmd" &>/dev/null || { fail "Comando '$cmd' no encontrado. Instálalo primero."; exit 1; }
done
[ -d "$EXP_DIR" ] || { fail "No se encontró $EXP_DIR — ejecuta el wizard desde la carpeta tmp/"; exit 1; }
ok "Prerequisitos locales OK"

# ── Leer parámetros CLI ────────────────────────────────────────────────────────
EC2_IP="${EC2_IP:-}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/labsuser.pem}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)    EC2_IP="$2";      shift 2 ;;
    --key)   KEY_FILE="$2";    shift 2 ;;
    --user)  REMOTE_USER="$2"; shift 2 ;;
    *)       shift ;;
  esac
done

# ── PASO 1 · Datos de conexión ─────────────────────────────────────────────────
step 1 "Datos de conexión EC2"

if [ -z "$EC2_IP" ]; then
  ask "IP pública de la instancia EC2 (Ubuntu 24.04):"
  read -r EC2_IP
fi

if [ ! -f "$KEY_FILE" ]; then
  warn "No se encontró $KEY_FILE"
  ask "Ruta completa al archivo .pem [Enter = ~/.ssh/labsuser.pem]:"
  read -r KEY_INPUT
  KEY_FILE="${KEY_INPUT:-$HOME/.ssh/labsuser.pem}"
fi

chmod 400 "$KEY_FILE" 2>/dev/null || true

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30 -i $KEY_FILE"
SSH_TARGET="${REMOTE_USER}@${EC2_IP}"

info "IP         : $EC2_IP"
info "Clave PEM  : $KEY_FILE"
info "Usuario    : $REMOTE_USER"
info "Destino    : $SSH_TARGET"

# ── PASO 2 · Verificar conectividad ────────────────────────────────────────────
step 2 "Verificando conectividad SSH"

echo -e "  ${DIM}Intentando conectar a $EC2_IP ...${NC}"
if ssh $SSH_OPTS "$SSH_TARGET" 'echo connected' &>/dev/null; then
  ok "Conexión SSH establecida"
else
  fail "No se pudo conectar a $EC2_IP"
  echo
  echo -e "  ${YELLOW}Posibles causas:${NC}"
  echo -e "  • IP incorrecta o instancia apagada"
  echo -e "  • Puerto 22 no abierto en el Security Group de la instancia"
  echo -e "  • Key PEM incorrecta o sin permisos (chmod 400)"
  echo -e "  • La instancia aún está iniciando (espera 30-60s y reintenta)"
  exit 1
fi

# ── Menú de acciones ───────────────────────────────────────────────────────────
echo
echo -e "${BOLD}  ¿Qué deseas hacer?${NC}"
echo "   [1] Despliegue completo  (transferir + instalar + servidores + ataque + descargar)"
echo "   [2] Solo transferir archivos e instalar dependencias"
echo "   [3] Solo arrancar servidores  (requiere paso 2 previo)"
echo "   [4] Solo ejecutar el ataque   (requiere servidores corriendo)"
echo "   [5] Solo descargar resultados"
echo "   [6] Detener todos los servidores en EC2"
echo
ask "Opción [1-6, default: 1]:"
read -r OPTION
OPTION="${OPTION:-1}"

RUN_TRANSFER=false; RUN_INSTALL=false; RUN_SERVERS=false
RUN_ATTACK=false;   RUN_RESULTS=false; RUN_STOP=false

case "$OPTION" in
  1) RUN_TRANSFER=true; RUN_INSTALL=true; RUN_SERVERS=true; RUN_ATTACK=true; RUN_RESULTS=true ;;
  2) RUN_TRANSFER=true; RUN_INSTALL=true ;;
  3) RUN_SERVERS=true ;;
  4) RUN_ATTACK=true ;;
  5) RUN_RESULTS=true ;;
  6) RUN_STOP=true ;;
  *) fail "Opción inválida"; exit 1 ;;
esac

# ── PASO 3 · Transferir archivos ───────────────────────────────────────────────
if $RUN_TRANSFER; then
  step 3 "Transfiriendo archivos a EC2"
  ssh $SSH_OPTS "$SSH_TARGET" 'mkdir -p ~/exp2'
  scp $SSH_OPTS -r "$EXP_DIR/"* "$SSH_TARGET:~/exp2/"
  ok "$(ls "$EXP_DIR" | wc -l) archivos transferidos a ~/exp2/"
fi

# ── PASO 4 · Instalar dependencias ────────────────────────────────────────────
if $RUN_INSTALL; then
  step 4 "Instalando dependencias en EC2  (Node.js 20 + npm + Python venv)"
  echo -e "  ${DIM}Esto puede tardar 2–4 minutos en una instancia virgen...${NC}"

  ssh $SSH_OPTS "$SSH_TARGET" << 'ENDSSH'
set -e
export DEBIAN_FRONTEND=noninteractive

echo "  [1/4] Actualizando índice de paquetes..."
sudo apt-get update -qq 2>&1 | tail -1

echo "  [2/4] Instalando herramientas base (curl, python3, lsof)..."
sudo apt-get install -y -q curl ca-certificates python3 python3-venv lsof 2>&1 | tail -1

echo "  [3/4] Instalando Node.js 20 LTS..."
if ! node --version 2>/dev/null | grep -q "^v2"; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
  sudo apt-get install -y -q nodejs 2>&1 | tail -1
fi
echo "       node $(node -v)   npm $(npm -v)"

echo "  [4/4] Instalando dependencias npm y Python..."
cd ~/exp2
npm install --silent --no-fund 2>&1 | tail -3

python3 -m venv ~/venv
~/venv/bin/pip install --quiet --upgrade pip
~/venv/bin/pip install --quiet requests numpy matplotlib

echo ""
echo "✓ Todas las dependencias instaladas"
ENDSSH
  ok "Dependencias listas"
fi

# ── PASO 5 · Arrancar servidores ───────────────────────────────────────────────
if $RUN_SERVERS; then
  step 5 "Arrancando servidores"

  ssh $SSH_OPTS "$SSH_TARGET" << 'ENDSSH'
set -e

echo "  → Liberando puertos 8000, 8001, 8002..."
for PORT in 8000 8001 8002; do
  PID=$(lsof -ti:"$PORT" 2>/dev/null || true)
  if [ -n "$PID" ]; then
    kill -9 "$PID" 2>/dev/null || true
    echo "    Puerto $PORT liberado (PID $PID)"
  fi
done
sleep 1

echo "  → Arrancando gateway.js (:8000)..."
cd ~/exp2
nohup node gateway.js > ~/exp2/gateway.log 2>&1 &
echo $! > ~/exp2/gateway.pid
disown

echo "  → Arrancando stub.js (:8001 y :8002)..."
nohup node stub.js > ~/exp2/stub.log 2>&1 &
echo $! > ~/exp2/stub.pid
disown

echo "  → Esperando inicialización (3 s)..."
sleep 3

echo "  → Verificando /health..."
HEALTH=$(curl -sf http://localhost:8000/health 2>/dev/null || echo "ERROR")
echo "     /health → $HEALTH"

if echo "$HEALTH" | grep -q '"ok"'; then
  echo ""
  echo "✓ Gateway operativo en :8000"
  echo "✓ Stubs corriendo en :8001 y :8002"
else
  echo ""
  echo "✗ El gateway no responde. Últimas líneas del log:"
  echo "──────────────────────────────────────────────────"
  tail -15 ~/exp2/gateway.log
  echo "──────────────────────────────────────────────────"
  exit 1
fi
ENDSSH
  ok "Servidores corriendo"
  info "Logs disponibles en EC2: ~/exp2/gateway.log  y  ~/exp2/stub.log"
fi

# ── PASO 6 · Ejecutar el ataque ────────────────────────────────────────────────
if $RUN_ATTACK; then
  step 6 "Ejecutando experimento (attack.py → 105 requests)"

  ask "¿Iniciar el ataque ahora? [Y/n]:"
  read -r CONFIRM
  if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    warn "Ataque omitido."
    info "Para ejecutarlo manualmente:"
    info "ssh $SSH_OPTS $SSH_TARGET 'source ~/venv/bin/activate && cd ~/exp2 && python attack.py'"
  else
    echo
    echo -e "  ${DIM}━━━━━━━━━━━━ Salida de attack.py ━━━━━━━━━━━━${NC}"
    # Ejecuta en EC2 con salida en tiempo real
    ssh $SSH_OPTS "$SSH_TARGET" \
      'source ~/venv/bin/activate && cd ~/exp2 && python attack.py'
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo

    echo "  Generando gráficas..."
    ssh $SSH_OPTS "$SSH_TARGET" \
      'source ~/venv/bin/activate && cd ~/exp2 && python charts_security.py'
    ok "Gráficas generadas: ~/exp2/security_charts.png"
  fi
fi

# ── PASO 7 · Descargar resultados ─────────────────────────────────────────────
if $RUN_RESULTS; then
  step 7 "Descargando resultados al directorio local"
  mkdir -p "$RESULTS_DIR"

  ALL_OK=true
  for FILE in security_results.csv security_charts.png gateway.log stub.log; do
    if scp $SSH_OPTS "$SSH_TARGET:~/exp2/$FILE" "$RESULTS_DIR/$FILE" 2>/dev/null; then
      ok "$FILE  →  $RESULTS_DIR/$FILE"
    else
      warn "$FILE no encontrado en EC2  (¿ya corriste el ataque?)"
      ALL_OK=false
    fi
  done

  $ALL_OK && ok "Todos los resultados descargados" || warn "Algunos archivos no estaban disponibles"
fi

# ── Detener servidores ─────────────────────────────────────────────────────────
if $RUN_STOP; then
  step 6 "Deteniendo servidores"
  ssh $SSH_OPTS "$SSH_TARGET" << 'ENDSSH'
STOPPED=0
for PIDFILE in ~/exp2/gateway.pid ~/exp2/stub.pid; do
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    kill "$PID" 2>/dev/null && echo "  Detenido PID $PID" && STOPPED=$((STOPPED+1)) || true
    rm -f "$PIDFILE"
  fi
done
for PORT in 8000 8001 8002; do
  PID=$(lsof -ti:"$PORT" 2>/dev/null || true)
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null && echo "  Puerto $PORT liberado" || true
done
[ $STOPPED -gt 0 ] && echo "✓ $STOPPED proceso(s) detenido(s)" || echo "✓ No había procesos activos"
ENDSSH
fi

# ── Resumen final ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  ✓  Experimento 2 — Wizard completado                       ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}Accesos rápidos:${NC}"
echo
echo -e "  ${DIM}# Ver logs del gateway en tiempo real${NC}"
echo -e "  ssh $SSH_OPTS $SSH_TARGET 'tail -f ~/exp2/gateway.log | grep AUDIT'"
echo
echo -e "  ${DIM}# Re-ejecutar solo el ataque${NC}"
echo -e "  ssh $SSH_OPTS $SSH_TARGET \\"
echo -e "    'source ~/venv/bin/activate && cd ~/exp2 && python attack.py'"
echo
echo -e "  ${DIM}# Ver estado de los servidores${NC}"
echo -e "  ssh $SSH_OPTS $SSH_TARGET 'ps aux | grep node | grep -v grep'"
echo
echo -e "  ${DIM}# Descargar resultados manualmente${NC}"
echo -e "  scp $SSH_OPTS '$SSH_TARGET:~/exp2/security_results.csv' ."
echo -e "  scp $SSH_OPTS '$SSH_TARGET:~/exp2/security_charts.png' ."
echo
