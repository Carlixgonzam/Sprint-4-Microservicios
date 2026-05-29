#!/usr/bin/env bash
# deploy/deploy-collector-service.sh
# Deploy BITE Cloud Collector Service (Python/FastAPI + MongoDB)
# on Ubuntu 24.04
#
# Run as root: sudo bash deploy-collector-service.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — Collector Service Deployment Wizard"
printf "  Service  : %bcollector-service%b (Python / FastAPI)\n" "$BOLD" "$NC"
printf "  Database : MongoDB (time_series_metrics collection)\n"
printf "  Default port : 8005\n"

# ── Wizard ────────────────────────────────────────────────────────────────────
print_section "Source Code"
read_var \
  "Path to collector-service source on this server" \
  "$(dirname "$SCRIPT_DIR")/collector-service" \
  SOURCE_DIR

print_section "Deploy Location"
read_var "Install directory" "/opt/bite/collector-service" APP_DIR

print_section "Service Settings"
read_var "Port to listen on" "8005" PORT
read_var "Number of uvicorn workers" "2" WORKERS

print_section "MongoDB Connection"
print_info "Format: mongodb://USER:PASSWORD@HOST:27017/bite_reports?authSource=bite_reports"
read_var "MONGO_URL" "mongodb://<mongo-host>:27017" MONGO_URL

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary \
  "SOURCE_DIR=${SOURCE_DIR}" \
  "APP_DIR=${APP_DIR}" \
  "PORT=${PORT}" \
  "WORKERS=${WORKERS}" \
  "MONGO_URL=${MONGO_URL}"

confirm "Deploy collector-service with these settings?" || { echo "Aborted."; exit 0; }

ensure_python3
print_step "Ensuring python3-venv is available"
apt-get install -y python3-venv --no-install-recommends -qq
print_success "python3-venv ready"

ensure_bite_user

print_step "Deploying application files → ${APP_DIR}"
mkdir -p "$APP_DIR"
rsync -a --delete "${SOURCE_DIR%/}/" "${APP_DIR}/"

print_step "Creating Python virtual environment"
VENV="${APP_DIR}/venv"
python3 -m venv "$VENV"
print_success "venv at ${VENV}"

print_step "Installing Python dependencies"
"${VENV}/bin/pip" install --upgrade pip --quiet
"${VENV}/bin/pip" install -r "${APP_DIR}/requirements.txt" --quiet
print_success "Dependencies installed"

chown -R bite:bite "$APP_DIR"

print_step "Writing ${APP_DIR}/.env"
{
  printf 'PORT=%s\n'      "$PORT"
  printf 'MONGO_URL=%s\n' "$MONGO_URL"
} > "${APP_DIR}/.env"
chmod 640 "${APP_DIR}/.env"
chown bite:bite "${APP_DIR}/.env"
print_success ".env written (mode 640, owner bite)"

print_step "Installing systemd unit: bite-collector.service"
cat > /etc/systemd/system/bite-collector.service <<UNIT
[Unit]
Description=BITE Cloud Collector Service
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
SyslogIdentifier=bite-collector

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
UNIT
print_success "Unit file written"

print_step "Enabling and starting service"
reload_and_start bite-collector

echo
printf "${GREEN}${BOLD}  ✓ Collector Service deployed successfully!${NC}\n\n"
printf "  %-18s %b%s%b\n" "Listening on:" "$CYAN" "http://0.0.0.0:${PORT}"                  "$NC"
printf "  %-18s %b%s%b\n" "Health check:" "$CYAN" "curl http://localhost:${PORT}/health"     "$NC"
printf "  %-18s %b%s%b\n" "Logs:"         "$CYAN" "journalctl -u bite-collector -f"          "$NC"
echo
