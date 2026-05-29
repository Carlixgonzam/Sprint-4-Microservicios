#!/usr/bin/env bash
# deploy/deploy-orchestrator-service.sh
# Deploy BITE Orchestrator Service (Python/FastAPI + Redis cache + RabbitMQ)
# on Ubuntu 24.04
#
# Run as root: sudo bash deploy-orchestrator-service.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — Orchestrator Service Deployment Wizard"
printf "  Service  : %borchestrator-service%b (Python / FastAPI)\n" "$BOLD" "$NC"
printf "  Broker   : Redis (cache) + RabbitMQ (job queue)\n"
printf "  Default port : 8004\n"
echo

# ── Wizard ────────────────────────────────────────────────────────────────────
print_section "Source Code"
read_var \
  "Path to orchestrator-service source on this server" \
  "$(dirname "$SCRIPT_DIR")/orchestrator-service" \
  SOURCE_DIR

print_section "Deploy Location"
read_var "Install directory" "/opt/bite/orchestrator-service" APP_DIR

print_section "Service Settings"
read_var "Port to listen on" "8004" PORT
read_var "Number of uvicorn workers" "1" WORKERS
print_info "Keep WORKERS=1 — the worker thread holds RabbitMQ connection in-process."

print_section "Broker Connections"
print_info "Format: redis://[:password@]HOST:6379/0   amqp://USER:PASSWORD@HOST:5672/"
read_var "REDIS_URL"    "redis://<broker-host>:6379/0"           REDIS_URL
read_var "RABBITMQ_URL" "amqp://bite:<pass>@<broker-host>:5672/" RABBITMQ_URL

print_section "Downstream Service URLs"
read_var "INVENTORY_URL" "http://<inv-host>:8001"        INVENTORY_URL
read_var "COLLECTOR_URL" "http://<analytics-host>:8005"  COLLECTOR_URL
read_var "ANALYZER_URL"  "http://<analytics-host>:8006"  ANALYZER_URL
read_var "NOTIF_URL"     "http://<notif-host>:8003"      NOTIF_URL

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary \
  "SOURCE_DIR=${SOURCE_DIR}" \
  "APP_DIR=${APP_DIR}" \
  "PORT=${PORT}" \
  "WORKERS=${WORKERS}" \
  "REDIS_URL=${REDIS_URL}" \
  "RABBITMQ_URL=${RABBITMQ_URL}" \
  "INVENTORY_URL=${INVENTORY_URL}" \
  "COLLECTOR_URL=${COLLECTOR_URL}" \
  "ANALYZER_URL=${ANALYZER_URL}" \
  "NOTIF_URL=${NOTIF_URL}"

confirm "Deploy orchestrator-service with these settings?" || { echo "Aborted."; exit 0; }

# ── Python 3 ─────────────────────────────────────────────────────────────────
ensure_python3
print_step "Ensuring python3-venv is available"
apt-get install -y python3-venv --no-install-recommends -qq
print_success "python3-venv ready"

# ── System user ───────────────────────────────────────────────────────────────
ensure_bite_user

# ── Deploy files ─────────────────────────────────────────────────────────────
print_step "Deploying application files → ${APP_DIR}"
mkdir -p "$APP_DIR"
rsync -a --delete "${SOURCE_DIR%/}/" "${APP_DIR}/"

# ── Virtual environment ───────────────────────────────────────────────────────
print_step "Creating Python virtual environment"
VENV="${APP_DIR}/venv"
python3 -m venv "$VENV"
print_success "venv at ${VENV}"

print_step "Installing Python dependencies"
"${VENV}/bin/pip" install --upgrade pip --quiet
"${VENV}/bin/pip" install -r "${APP_DIR}/requirements.txt" --quiet
print_success "Dependencies installed"

chown -R bite:bite "$APP_DIR"

# ── Environment file ─────────────────────────────────────────────────────────
print_step "Writing ${APP_DIR}/.env"
{
  printf 'PORT=%s\n'          "$PORT"
  printf 'REDIS_URL=%s\n'     "$REDIS_URL"
  printf 'RABBITMQ_URL=%s\n'  "$RABBITMQ_URL"
  printf 'INVENTORY_URL=%s\n' "$INVENTORY_URL"
  printf 'COLLECTOR_URL=%s\n' "$COLLECTOR_URL"
  printf 'ANALYZER_URL=%s\n'  "$ANALYZER_URL"
  printf 'NOTIF_URL=%s\n'     "$NOTIF_URL"
} > "${APP_DIR}/.env"
chmod 640 "${APP_DIR}/.env"
chown bite:bite "${APP_DIR}/.env"
print_success ".env written (mode 640, owner bite)"

# ── Systemd unit ─────────────────────────────────────────────────────────────
print_step "Installing systemd unit: bite-orchestrator.service"
cat > /etc/systemd/system/bite-orchestrator.service <<UNIT
[Unit]
Description=BITE Orchestrator Service
Documentation=https://github.com/Carlixgonzam/Sprint-4-Microservicios
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=bite
Group=bite
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${VENV}/bin/uvicorn main:app \
  --host 0.0.0.0 \
  --port ${PORT} \
  --workers ${WORKERS} \
  --log-level info
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bite-orchestrator

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
UNIT
print_success "Unit file written to /etc/systemd/system/bite-orchestrator.service"

print_step "Enabling and starting service"
reload_and_start bite-orchestrator

echo
printf "${GREEN}${BOLD}  ✓ Orchestrator Service deployed successfully!${NC}\n\n"
printf "  %-18s %b%s%b\n" "Listening on:" "$CYAN" "http://0.0.0.0:${PORT}"                  "$NC"
printf "  %-18s %b%s%b\n" "Health check:" "$CYAN" "curl http://localhost:${PORT}/health"     "$NC"
printf "  %-18s %b%s%b\n" "Logs:"         "$CYAN" "journalctl -u bite-orchestrator -f"       "$NC"
printf "  %-18s %b%s%b\n" "Stop/start:"   "$CYAN" "systemctl stop|start bite-orchestrator"   "$NC"
echo
