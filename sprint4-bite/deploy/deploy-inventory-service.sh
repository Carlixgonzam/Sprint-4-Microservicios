#!/usr/bin/env bash
# deploy/deploy-inventory-service.sh
# Deploy BITE Inventory Service (Python/FastAPI + PostgreSQL) on Ubuntu 24.04
#
# Run as root: sudo bash deploy-inventory-service.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — Inventory Service Deployment Wizard"
printf "  Service  : %binventory-service%b (Python / FastAPI)\n" "$BOLD" "$NC"
printf "  Database : PostgreSQL  (external — provide connection string below)\n"
printf "  Default port : 8001\n"

# ── Wizard ────────────────────────────────────────────────────────────────────
print_section "Source Code"
read_var \
  "Path to inventory-service source on this server" \
  "$(dirname "$SCRIPT_DIR")/inventory-service" \
  SOURCE_DIR

print_section "Deploy Location"
read_var "Install directory" "/opt/bite/inventory-service" APP_DIR

print_section "Service Settings"
read_var "Port to listen on" "8001" PORT
read_var "Number of uvicorn workers" "2" WORKERS

print_section "PostgreSQL Connection"
print_info "The DB will NOT be created by this script — point to your central PostgreSQL."
print_info "Format: postgresql://USER:PASSWORD@HOST:5432/DBNAME"
read_var "DATABASE_URL" "postgresql://bite:bite123@<pg-host>:5432/inventory" DATABASE_URL

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary \
  "SOURCE_DIR=${SOURCE_DIR}" \
  "APP_DIR=${APP_DIR}" \
  "PORT=${PORT}" \
  "WORKERS=${WORKERS}" \
  "DATABASE_URL=${DATABASE_URL}"

confirm "Deploy inventory-service with these settings?" || { echo "Aborted."; exit 0; }

# ── Python 3 ─────────────────────────────────────────────────────────────────
ensure_python3
print_step "Ensuring python3-venv is available"
apt-get install -y python3-venv python3-dev libpq-dev gcc --no-install-recommends -qq
print_success "python3-venv and psycopg2 build deps ready"

# ── System user ───────────────────────────────────────────────────────────────
ensure_bite_user

# ── Deploy files ──────────────────────────────────────────────────────────────
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

# ── Environment file ──────────────────────────────────────────────────────────
print_step "Writing ${APP_DIR}/.env"
{
  printf 'DATABASE_URL=%s\n' "$DATABASE_URL"
  printf 'PORT=%s\n'         "$PORT"
} > "${APP_DIR}/.env"
chmod 640 "${APP_DIR}/.env"
chown bite:bite "${APP_DIR}/.env"
print_success ".env written (mode 640, owner bite)"

# ── Systemd unit ──────────────────────────────────────────────────────────────
print_step "Installing systemd unit: bite-inventory.service"
cat > /etc/systemd/system/bite-inventory.service <<UNIT
[Unit]
Description=BITE Inventory Service
Documentation=https://github.com/your-org/sprint4-bite
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
SyslogIdentifier=bite-inventory

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
UNIT
print_success "Unit file written to /etc/systemd/system/bite-inventory.service"

# ── Enable & start ────────────────────────────────────────────────────────────
print_step "Enabling and starting service"
reload_and_start bite-inventory

# ── Done ──────────────────────────────────────────────────────────────────────
echo
printf "${GREEN}${BOLD}  ✓ Inventory Service deployed successfully!${NC}\n\n"
printf "  %-18s %b%s%b\n" "Listening on:"  "$CYAN" "http://0.0.0.0:${PORT}"                  "$NC"
printf "  %-18s %b%s%b\n" "Health check:"  "$CYAN" "curl http://localhost:${PORT}/health"      "$NC"
printf "  %-18s %b%s%b\n" "Resources API:" "$CYAN" "curl http://localhost:${PORT}/resources"   "$NC"
printf "  %-18s %b%s%b\n" "Logs:"          "$CYAN" "journalctl -u bite-inventory -f"           "$NC"
printf "  %-18s %b%s%b\n" "Stop/start:"    "$CYAN" "systemctl stop|start bite-inventory"       "$NC"
echo
printf "  ${YELLOW}⚠  Remember to seed the PostgreSQL database before use.${NC}\n"
printf "     The schema (cloud_resources table) is created automatically on first start.\n"
echo
