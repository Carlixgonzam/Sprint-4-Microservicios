#!/usr/bin/env bash
# deploy/deploy-notification-service.sh
# Deploy BITE Notification Service (Python / FastAPI, stateless) on Ubuntu 24.04
#
# Run as root: sudo bash deploy-notification-service.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — Notification Service Deployment Wizard"
printf "  Service  : %bnotification-service%b (Python / FastAPI)\n" "$BOLD" "$NC"
printf "  Database : none  (stateless — job state is in-process memory)\n"
printf "  Default port : 8003\n"
echo
print_warning "Job state is lost on service restart. This is by design for this sprint."

# ── Wizard ────────────────────────────────────────────────────────────────────
print_section "Source Code"
read_var \
  "Path to notification-service source on this server" \
  "$(dirname "$SCRIPT_DIR")/notification-service" \
  SOURCE_DIR

print_section "Deploy Location"
read_var "Install directory" "/opt/bite/notification-service" APP_DIR

print_section "Service Settings"
read_var "Port to listen on" "8003" PORT
read_var "Number of uvicorn workers" "1" WORKERS
print_info "Workers > 1 will cause each process to have a separate job store (in-memory)."
print_info "Keep at 1 unless you add a shared backend later."

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary \
  "SOURCE_DIR=${SOURCE_DIR}" \
  "APP_DIR=${APP_DIR}" \
  "PORT=${PORT}" \
  "WORKERS=${WORKERS}"

confirm "Deploy notification-service with these settings?" || { echo "Aborted."; exit 0; }

# ── Python 3 ─────────────────────────────────────────────────────────────────
ensure_python3
print_step "Ensuring python3-venv is available"
apt-get install -y python3-venv --no-install-recommends -qq
print_success "python3-venv ready"

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
  printf 'PORT=%s\n' "$PORT"
} > "${APP_DIR}/.env"
chmod 640 "${APP_DIR}/.env"
chown bite:bite "${APP_DIR}/.env"
print_success ".env written (mode 640, owner bite)"

# ── Systemd unit ──────────────────────────────────────────────────────────────
print_step "Installing systemd unit: bite-notification.service"
cat > /etc/systemd/system/bite-notification.service <<UNIT
[Unit]
Description=BITE Notification Service
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
SyslogIdentifier=bite-notification

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
UNIT
print_success "Unit file written to /etc/systemd/system/bite-notification.service"

# ── Enable & start ────────────────────────────────────────────────────────────
print_step "Enabling and starting service"
reload_and_start bite-notification

# ── Done ──────────────────────────────────────────────────────────────────────
echo
printf "${GREEN}${BOLD}  ✓ Notification Service deployed successfully!${NC}\n\n"
printf "  %-18s %b%s%b\n" "Listening on:" "$CYAN" "http://0.0.0.0:${PORT}"                          "$NC"
printf "  %-18s %b%s%b\n" "Health check:" "$CYAN" "curl http://localhost:${PORT}/health"             "$NC"
printf "  %-18s %b%s%b\n" "Create job:"   "$CYAN" 'curl -X POST http://localhost:'"${PORT}"'/jobs -H "Content-Type: application/json" -d "{\"job_id\":\"j1\",\"email\":\"a@b.com\",\"company\":\"Acme\",\"project\":\"X\"}"' "$NC"
printf "  %-18s %b%s%b\n" "Logs:"         "$CYAN" "journalctl -u bite-notification -f"               "$NC"
printf "  %-18s %b%s%b\n" "Stop/start:"   "$CYAN" "systemctl stop|start bite-notification"           "$NC"
echo
