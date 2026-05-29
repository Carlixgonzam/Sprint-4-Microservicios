#!/usr/bin/env bash
# deploy/deploy-analyzer-service.sh
# Deploy BITE Cost Analyzer Service (Python/FastAPI + PostgreSQL)
# on Ubuntu 24.04
#
# Run as root: sudo bash deploy-analyzer-service.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — Analyzer Service Deployment Wizard"
printf "  Service  : %banalyzer-service%b (Python / FastAPI)\n" "$BOLD" "$NC"
printf "  Database : PostgreSQL (cost_analysis + recommendations tables)\n"
printf "  Default port : 8006\n"

# ── Wizard ────────────────────────────────────────────────────────────────────
print_section "Source Code"
read_var \
  "Path to analyzer-service source on this server" \
  "$(dirname "$SCRIPT_DIR")/analyzer-service" \
  SOURCE_DIR

print_section "Deploy Location"
read_var "Install directory" "/opt/bite/analyzer-service" APP_DIR

print_section "Service Settings"
read_var "Port to listen on" "8006" PORT
read_var "Number of uvicorn workers" "2" WORKERS

print_section "PostgreSQL Connection"
print_info "Use the SAME database as inventory-service (shared 'inventory' DB)."
print_info "Format: postgresql://USER:PASSWORD@HOST:5432/DBNAME"
read_var "DATABASE_URL" "postgresql://bite:bite123@<pg-host>:5432/inventory" DATABASE_URL

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary \
  "SOURCE_DIR=${SOURCE_DIR}" \
  "APP_DIR=${APP_DIR}" \
  "PORT=${PORT}" \
  "WORKERS=${WORKERS}" \
  "DATABASE_URL=${DATABASE_URL}"

confirm "Deploy analyzer-service with these settings?" || { echo "Aborted."; exit 0; }

ensure_python3
print_step "Ensuring python3-venv + psycopg2 build deps"
apt-get install -y python3-venv python3-dev libpq-dev gcc --no-install-recommends -qq
print_success "Build dependencies ready"

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
  printf 'PORT=%s\n'         "$PORT"
  printf 'DATABASE_URL=%s\n' "$DATABASE_URL"
} > "${APP_DIR}/.env"
chmod 640 "${APP_DIR}/.env"
chown bite:bite "${APP_DIR}/.env"
print_success ".env written (mode 640, owner bite)"

print_step "Installing systemd unit: bite-analyzer.service"
cat > /etc/systemd/system/bite-analyzer.service <<UNIT
[Unit]
Description=BITE Cost Analyzer Service
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
SyslogIdentifier=bite-analyzer

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
reload_and_start bite-analyzer

echo
printf "${GREEN}${BOLD}  ✓ Analyzer Service deployed successfully!${NC}\n\n"
printf "  %-18s %b%s%b\n" "Listening on:" "$CYAN" "http://0.0.0.0:${PORT}"                  "$NC"
printf "  %-18s %b%s%b\n" "Health check:" "$CYAN" "curl http://localhost:${PORT}/health"     "$NC"
printf "  %-18s %b%s%b\n" "Logs:"         "$CYAN" "journalctl -u bite-analyzer -f"           "$NC"
echo
