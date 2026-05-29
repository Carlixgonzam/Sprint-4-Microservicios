#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# deploy_exp3.sh — Wizard de despliegue: Experimento 3 (ASR de Latencia)
# BITE.co · Sprint 4 · AWS Academy
#
# Despliega en una instancia EC2 Ubuntu 24.04 virgen:
#   gateway_cached.js   :8000  (cache-aside en memoria + JWT)
#   stub_inventory.js   :8001  (latencia Normal 90ms σ=15)
#   stub_report.js      :8002  (latencia Normal 110ms σ=18)
#   locustfile.py       Escenario A (sin caché) + B (con caché)
#   charts_latency.py   panel de 6 gráficas
#
# Uso:
#   bash deploy_exp3.sh
#   bash deploy_exp3.sh --ip 1.2.3.4 --key ~/.ssh/labsuser.pem
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
EXP_DIR="$SCRIPT_DIR/exp3"
RESULTS_DIR="$SCRIPT_DIR/results_exp3"
TOTAL_STEPS=8

# ── Banner ─────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  BITE.co · Sprint 4 · AWS Academy                           ║${NC}"
echo -e "${BOLD}${CYAN}║  Experimento 3 — ASR de Latencia · Redis Cache-Aside        ║${NC}"
echo -e "${BOLD}${CYAN}║  Wizard de despliegue · EC2 Ubuntu 24.04                    ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# ── Prerequisitos locales ──────────────────────────────────────────────────────
for cmd in ssh scp curl; do
  command -v "$cmd" &>/dev/null || { fail "Comando '$cmd' no encontrado."; exit 1; }
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

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=60 -i $KEY_FILE"
SSH_TARGET="${REMOTE_USER}@${EC2_IP}"

info "IP         : $EC2_IP"
info "Clave PEM  : $KEY_FILE"
info "Usuario    : $REMOTE_USER"
info "Destino    : $SSH_TARGET"
echo
echo -e "  ${YELLOW}Nota:${NC} Los escenarios de Locust corren ~90 s cada uno."
echo -e "  ${DIM}El wizard permanece conectado durante toda la prueba.${NC}"

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
  echo -e "  • Puerto 22 no abierto en el Security Group"
  echo -e "  • Key PEM incorrecta (chmod 400 requerido)"
  echo -e "  • Instancia aún iniciando (espera 30-60 s)"
  exit 1
fi

# ── Menú de acciones ───────────────────────────────────────────────────────────
echo
echo -e "${BOLD}  ¿Qué deseas hacer?${NC}"
echo "   [1] Despliegue completo  (transferir + instalar + servidores + locust A+B + descargar)"
echo "   [2] Solo transferir archivos e instalar dependencias"
echo "   [3] Solo arrancar los 3 servidores  (requiere paso 2 previo)"
echo "   [4] Solo ejecutar Escenario A  (sin caché, requiere servidores)"
echo "   [5] Solo ejecutar Escenario B  (con caché, requiere servidores)"
echo "   [6] Ejecutar Escenarios A y B  (sin desplegar de nuevo)"
echo "   [7] Solo descargar resultados y generar gráficas"
echo "   [8] Detener todos los servidores en EC2"
echo
ask "Opción [1-8, default: 1]:"
read -r OPTION
OPTION="${OPTION:-1}"

RUN_TRANSFER=false; RUN_INSTALL=false; RUN_SERVERS=false
RUN_A=false;        RUN_B=false;       RUN_RESULTS=false; RUN_STOP=false

case "$OPTION" in
  1) RUN_TRANSFER=true; RUN_INSTALL=true; RUN_SERVERS=true; RUN_A=true; RUN_B=true; RUN_RESULTS=true ;;
  2) RUN_TRANSFER=true; RUN_INSTALL=true ;;
  3) RUN_SERVERS=true ;;
  4) RUN_A=true ;;
  5) RUN_B=true ;;
  6) RUN_A=true; RUN_B=true ;;
  7) RUN_RESULTS=true ;;
  8) RUN_STOP=true ;;
  *) fail "Opción inválida"; exit 1 ;;
esac

# ── PASO 3 · Transferir archivos ───────────────────────────────────────────────
if $RUN_TRANSFER; then
  step 3 "Transfiriendo archivos a EC2"
  ssh $SSH_OPTS "$SSH_TARGET" 'mkdir -p ~/exp3'
  scp $SSH_OPTS -r "$EXP_DIR/"* "$SSH_TARGET:~/exp3/"
  ok "$(ls "$EXP_DIR" | wc -l) archivos transferidos a ~/exp3/"
fi

# ── PASO 4 · Instalar dependencias ────────────────────────────────────────────
if $RUN_INSTALL; then
  step 4 "Instalando dependencias en EC2  (Node.js 20 + npm + Python venv + Locust)"
  echo -e "  ${DIM}Esto puede tardar 3–5 minutos en una instancia virgen (Locust trae muchas deps)...${NC}"

  ssh $SSH_OPTS "$SSH_TARGET" << 'ENDSSH'
set -e
export DEBIAN_FRONTEND=noninteractive

echo "  [1/5] Actualizando índice de paquetes..."
sudo apt-get update -qq 2>&1 | tail -1

echo "  [2/5] Instalando herramientas base (curl, python3, lsof, gcc)..."
# gcc es necesario para algunas dependencias de Locust (gevent)
sudo apt-get install -y -q curl ca-certificates python3 python3-venv \
  python3-dev lsof gcc build-essential 2>&1 | tail -1

echo "  [3/5] Instalando Node.js 20 LTS..."
if ! node --version 2>/dev/null | grep -q "^v2"; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
  sudo apt-get install -y -q nodejs 2>&1 | tail -1
fi
echo "       node $(node -v)   npm $(npm -v)"

echo "  [4/5] Instalando dependencias npm en ~/exp3/..."
cd ~/exp3
npm install --silent --no-fund 2>&1 | tail -3

echo "  [5/5] Creando entorno virtual Python e instalando Locust..."
python3 -m venv ~/venv
~/venv/bin/pip install --quiet --upgrade pip setuptools wheel
# Locust puede tardar ~60s en compilar gevent
~/venv/bin/pip install --quiet requests numpy matplotlib locust

echo ""
~/venv/bin/locust --version | sed 's/^/       /'
echo ""
echo "✓ Todas las dependencias instaladas"
ENDSSH
  ok "Dependencias listas (incluyendo Locust)"
fi

# ── PASO 5 · Arrancar los 3 servidores ────────────────────────────────────────
if $RUN_SERVERS; then
  step 5 "Arrancando los 3 servidores"

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

echo "  → Arrancando gateway_cached.js (:8000)..."
cd ~/exp3
nohup node gateway_cached.js > ~/exp3/gateway.log 2>&1 &
echo $! > ~/exp3/gateway.pid
disown

echo "  → Arrancando stub_inventory.js (:8001)..."
nohup node stub_inventory.js > ~/exp3/inventory.log 2>&1 &
echo $! > ~/exp3/inventory.pid
disown

echo "  → Arrancando stub_report.js (:8002)..."
nohup node stub_report.js > ~/exp3/report.log 2>&1 &
echo $! > ~/exp3/report.pid
disown

echo "  → Esperando inicialización (4 s)..."
sleep 4

echo "  → Verificando health check..."
HEALTH=$(curl -sf http://localhost:8000/health 2>/dev/null || echo "ERROR")
echo "     /health → $HEALTH"

if echo "$HEALTH" | grep -q '"ok"'; then
  echo ""
  echo "  Verificando que los stubs responden..."
  INV=$(curl -sf http://localhost:8001/resources 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'count={d[\"count\"]}')" 2>/dev/null || echo "ERROR")
  REP=$(curl -sf http://localhost:8002/costs 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'count={d[\"count\"]}')" 2>/dev/null || echo "ERROR")
  echo "     :8001/resources → $INV"
  echo "     :8002/costs     → $REP"
  echo ""
  echo "✓ Gateway con caché operativo en :8000"
  echo "✓ Stub Inventory en :8001   (Normal 90ms σ=15)"
  echo "✓ Stub Report     en :8002   (Normal 110ms σ=18)"
else
  echo ""
  echo "✗ Gateway no responde. Últimas líneas del log:"
  echo "──────────────────────────────────────────────"
  tail -15 ~/exp3/gateway.log
  echo "──────────────────────────────────────────────"
  exit 1
fi
ENDSSH
  ok "3 servidores corriendo"
  info "Logs: ~/exp3/gateway.log  ~/exp3/inventory.log  ~/exp3/report.log"
fi

# ── Helper para confirmar ejecución de escenario ───────────────────────────────
confirm_scenario() {
  local label="$1"
  ask "¿Ejecutar $label ahora? [Y/n]:"
  read -r CONF
  [[ ! "$CONF" =~ ^[Nn]$ ]]
}

# ── PASO 6 · Escenario A — sin caché ──────────────────────────────────────────
if $RUN_A; then
  step 6 "Escenario A — Sin caché  (NoCacheUser · 50 usuarios · 90 s)"
  echo -e "  ${DIM}Target: GET /dashboard/summary?nocache=1${NC}"
  echo -e "  ${DIM}Salida: no_cache_results.csv${NC}"
  echo

  if confirm_scenario "Escenario A"; then
    echo -e "  ${DIM}━━━━━━━━ Locust · Escenario A · Sin caché ━━━━━━━━${NC}"
    ssh $SSH_OPTS "$SSH_TARGET" \
      'cd ~/exp3 && source ~/venv/bin/activate && \
       locust -f locustfile.py NoCacheUser \
         --host http://localhost:8000 \
         --users 50 --spawn-rate 10 --run-time 90s --headless \
         --loglevel WARNING 2>&1'
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo

    # Verificar que el CSV fue generado
    CSV_SIZE=$(ssh $SSH_OPTS "$SSH_TARGET" \
      'wc -l ~/exp3/no_cache_results.csv 2>/dev/null | awk "{print \$1}"' 2>/dev/null || echo "0")
    ok "Escenario A completado — no_cache_results.csv ($CSV_SIZE filas)"
  else
    warn "Escenario A omitido"
  fi
fi

# ── PASO 7 · Escenario B — con caché ─────────────────────────────────────────
if $RUN_B; then
  step 7 "Escenario B — Con caché  (CacheUser · 50 usuarios · 90 s)"
  echo -e "  ${DIM}Target: GET /dashboard/summary${NC}"
  echo -e "  ${DIM}Cache-aside activo (TTL 30 s) — ~98 %% HITs en estado estable${NC}"
  echo -e "  ${DIM}Salida: cache_results.csv${NC}"
  echo

  # El Escenario B necesita la caché fría al inicio para medir los MISSes
  # correctamente; resetear la caché reiniciando el gateway tarda < 1s
  if $RUN_A; then
    echo -e "  ${YELLOW}Nota:${NC} Reiniciando gateway para vaciar la caché antes del escenario B..."
    ssh $SSH_OPTS "$SSH_TARGET" << 'ENDSSH'
PID=$(cat ~/exp3/gateway.pid 2>/dev/null || lsof -ti:8000 2>/dev/null || true)
[ -n "$PID" ] && kill "$PID" 2>/dev/null || true
sleep 1
cd ~/exp3
nohup node gateway_cached.js > ~/exp3/gateway.log 2>&1 &
echo $! > ~/exp3/gateway.pid
disown
sleep 2
curl -sf http://localhost:8000/health &>/dev/null && echo "  → Gateway reiniciado (caché vacía)" || echo "  ✗ Error al reiniciar gateway"
ENDSSH
    ok "Gateway reiniciado — caché en frío"
  fi

  if confirm_scenario "Escenario B"; then
    echo -e "  ${DIM}━━━━━━━━ Locust · Escenario B · Con caché ━━━━━━━━${NC}"
    ssh $SSH_OPTS "$SSH_TARGET" \
      'cd ~/exp3 && source ~/venv/bin/activate && \
       locust -f locustfile.py CacheUser \
         --host http://localhost:8000 \
         --users 50 --spawn-rate 10 --run-time 90s --headless \
         --loglevel WARNING 2>&1'
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo

    CSV_SIZE=$(ssh $SSH_OPTS "$SSH_TARGET" \
      'wc -l ~/exp3/cache_results.csv 2>/dev/null | awk "{print \$1}"' 2>/dev/null || echo "0")
    ok "Escenario B completado — cache_results.csv ($CSV_SIZE filas)"
  else
    warn "Escenario B omitido"
  fi

  # Generar gráficas si ambos CSVs existen
  echo
  echo "  Generando panel de gráficas..."
  ssh $SSH_OPTS "$SSH_TARGET" \
    'source ~/venv/bin/activate && cd ~/exp3 && \
     python charts_latency.py' 2>&1 | sed 's/^/    /'
  ok "Gráficas generadas: ~/exp3/latency_charts.png"
fi

# ── PASO 8 · Descargar resultados ─────────────────────────────────────────────
if $RUN_RESULTS; then
  step 8 "Descargando resultados al directorio local"

  # Si todavía no se generaron las gráficas, generarlas ahora
  CHART_EXISTS=$(ssh $SSH_OPTS "$SSH_TARGET" \
    '[ -f ~/exp3/latency_charts.png ] && echo yes || echo no' 2>/dev/null)
  if [ "$CHART_EXISTS" = "no" ]; then
    warn "latency_charts.png no encontrada — generando ahora..."
    ssh $SSH_OPTS "$SSH_TARGET" \
      'source ~/venv/bin/activate && cd ~/exp3 && python charts_latency.py' \
      2>&1 | sed 's/^/    /' || warn "No se pudo generar (¿faltan CSVs?)"
  fi

  mkdir -p "$RESULTS_DIR"
  ALL_OK=true
  for FILE in no_cache_results.csv cache_results.csv latency_charts.png \
              gateway.log inventory.log report.log; do
    if scp $SSH_OPTS "$SSH_TARGET:~/exp3/$FILE" "$RESULTS_DIR/$FILE" 2>/dev/null; then
      ok "$FILE  →  $RESULTS_DIR/$FILE"
    else
      warn "$FILE no encontrado  (¿ya corriste los escenarios?)"
      ALL_OK=false
    fi
  done

  $ALL_OK && ok "Todos los resultados descargados" || warn "Algunos archivos no estaban disponibles"
fi

# ── Detener servidores ─────────────────────────────────────────────────────────
if $RUN_STOP; then
  step 8 "Deteniendo servidores"
  ssh $SSH_OPTS "$SSH_TARGET" << 'ENDSSH'
STOPPED=0
for PIDFILE in ~/exp3/gateway.pid ~/exp3/inventory.pid ~/exp3/report.pid; do
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    kill "$PID" 2>/dev/null && echo "  Detenido PID $PID  ($PIDFILE)" && STOPPED=$((STOPPED+1)) || true
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
echo -e "${BOLD}${GREEN}║  ✓  Experimento 3 — Wizard completado                       ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}Accesos rápidos:${NC}"
echo
echo -e "  ${DIM}# Ver hit rate en tiempo real (mientras corren los servidores)${NC}"
echo -e "  ssh $SSH_OPTS $SSH_TARGET \\"
echo -e "    'tail -f ~/exp3/gateway.log | grep -E \"HIT|MISS\"'"
echo
echo -e "  ${DIM}# Re-ejecutar solo un escenario${NC}"
echo -e "  ssh $SSH_OPTS $SSH_TARGET \\"
echo -e "    'cd ~/exp3 && source ~/venv/bin/activate && \\"
echo -e "     locust -f locustfile.py CacheUser \\"
echo -e "       --host http://localhost:8000 --users 50 --spawn-rate 10 \\"
echo -e "       --run-time 90s --headless'"
echo
echo -e "  ${DIM}# Re-generar gráficas (si ya tienes los CSVs)${NC}"
echo -e "  ssh $SSH_OPTS $SSH_TARGET \\"
echo -e "    'source ~/venv/bin/activate && cd ~/exp3 && python charts_latency.py'"
echo
echo -e "  ${DIM}# Descargar resultados manualmente${NC}"
echo -e "  scp $SSH_OPTS '$SSH_TARGET:~/exp3/no_cache_results.csv' ."
echo -e "  scp $SSH_OPTS '$SSH_TARGET:~/exp3/cache_results.csv' ."
echo -e "  scp $SSH_OPTS '$SSH_TARGET:~/exp3/latency_charts.png' ."
echo
