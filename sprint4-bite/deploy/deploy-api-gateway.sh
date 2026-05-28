#!/usr/bin/env bash
# deploy/deploy-api-gateway.sh
# Deploy BITE API Gateway (Node.js/Express) as a systemd service on Ubuntu 24.04
#
# Run as root: sudo bash deploy-api-gateway.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — API Gateway Deployment Wizard"
printf "  Service  : %bapi-gateway%b (Node.js / Express)\n" "$BOLD" "$NC"
printf "  Port     : 8000  (hardcoded in source)\n"
printf "  Manages  : JWT auth · rate limiting · reverse proxy to downstream services\n"

# ── Wizard ────────────────────────────────────────────────────────────────────
print_section "Source Code"
read_var \
  "Path to api-gateway source on this server" \
  "$(dirname "$SCRIPT_DIR")/api-gateway" \
  SOURCE_DIR

print_section "Deploy Location"
read_var "Install directory" "/opt/bite/api-gateway" APP_DIR

print_section "Upstream Service URLs"
print_info "These are the private IPs / hostnames of the other EC2 instances."
read_var "Inventory Service URL" "http://localhost:8001" INVENTORY_URL
read_var "Report Service URL"    "http://localhost:8002" REPORT_URL
read_var "Notification Service URL" "http://localhost:8003" NOTIF_URL

print_section "Security"
read_var "JWT Secret (min 32 chars recommended)" "" JWT_SECRET secret

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary \
  "SOURCE_DIR=${SOURCE_DIR}" \
  "APP_DIR=${APP_DIR}" \
  "INVENTORY_URL=${INVENTORY_URL}" \
  "REPORT_URL=${REPORT_URL}" \
  "NOTIF_URL=${NOTIF_URL}" \
  "JWT_SECRET=${JWT_SECRET}"

confirm "Deploy api-gateway with these settings?" || { echo "Aborted."; exit 0; }

# ── Node.js 18 LTS ────────────────────────────────────────────────────────────
print_step "Ensuring Node.js 18 LTS is installed"
NODE_OK=false
if command -v node &>/dev/null; then
  NODE_VER="$(node -e 'process.stdout.write(process.version.split(".")[0].slice(1))')"
  [ "$NODE_VER" -ge 18 ] && NODE_OK=true
fi
if [ "$NODE_OK" = "false" ]; then
  apt-get update -qq
  apt-get install -y curl ca-certificates
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs
fi
print_success "Node $(node --version)  /  npm $(npm --version)"

# ── System user ───────────────────────────────────────────────────────────────
ensure_bite_user

# ── Deploy files ──────────────────────────────────────────────────────────────
print_step "Deploying application files → ${APP_DIR}"
mkdir -p "$APP_DIR"
rsync -a --delete "${SOURCE_DIR%/}/" "${APP_DIR}/"

print_step "Installing npm production dependencies"
cd "$APP_DIR"
npm install --omit=dev --prefer-offline --silent
chown -R bite:bite "$APP_DIR"

# ── Environment file ──────────────────────────────────────────────────────────
print_step "Writing ${APP_DIR}/.env"
{
  printf 'JWT_SECRET=%s\n'      "$JWT_SECRET"
  printf 'INVENTORY_URL=%s\n'   "$INVENTORY_URL"
  printf 'REPORT_URL=%s\n'      "$REPORT_URL"
  printf 'NOTIF_URL=%s\n'       "$NOTIF_URL"
} > "${APP_DIR}/.env"
chmod 640 "${APP_DIR}/.env"
chown bite:bite "${APP_DIR}/.env"
print_success ".env written (mode 640, owner bite)"

# ── Systemd unit ──────────────────────────────────────────────────────────────
print_step "Installing systemd unit: bite-api-gateway.service"
cat > /etc/systemd/system/bite-api-gateway.service <<UNIT
[Unit]
Description=BITE API Gateway
Documentation=https://github.com/your-org/sprint4-bite
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=bite
Group=bite
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=/usr/bin/node index.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bite-api-gateway

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
UNIT
print_success "Unit file written to /etc/systemd/system/bite-api-gateway.service"

# ── Enable & start ────────────────────────────────────────────────────────────
print_step "Enabling and starting service"
reload_and_start bite-api-gateway

# ── Done ──────────────────────────────────────────────────────────────────────
echo
printf "${GREEN}${BOLD}  ✓ API Gateway deployed successfully!${NC}\n\n"
printf "  %-18s %b%s%b\n" "Listening on:"    "$CYAN" "http://0.0.0.0:8000"           "$NC"
printf "  %-18s %b%s%b\n" "Health check:"    "$CYAN" "curl http://localhost:8000/health" "$NC"
printf "  %-18s %b%s%b\n" "Get token:"       "$CYAN" 'curl -X POST http://localhost:8000/auth/token -H "Content-Type: application/json" -d "{\"username\":\"test\"}"' "$NC"
printf "  %-18s %b%s%b\n" "Logs:"            "$CYAN" "journalctl -u bite-api-gateway -f" "$NC"
printf "  %-18s %b%s%b\n" "Stop/start:"      "$CYAN" "systemctl stop|start bite-api-gateway" "$NC"
echo
