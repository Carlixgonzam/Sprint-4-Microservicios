#!/usr/bin/env bash
# deploy/deploy-notification-service.sh
# Deploy BITE Notification Service (Java 21 / Spring Boot, stateless) on Ubuntu 24.04
#
# Run as root: sudo bash deploy-notification-service.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — Notification Service Deployment Wizard"
printf "  Service  : %bnotification-service%b (Java 21 / Spring Boot 3.3)\n" "$BOLD" "$NC"
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

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary \
  "SOURCE_DIR=${SOURCE_DIR}" \
  "APP_DIR=${APP_DIR}" \
  "PORT=${PORT}"

confirm "Deploy notification-service with these settings?" || { echo "Aborted."; exit 0; }

# ── Java 21 (Temurin) + Maven ────────────────────────────────────────────────
print_step "Ensuring Java 21 (Temurin) and Maven are installed"
JAVA_OK=false
if command -v java &>/dev/null; then
  JAVA_VER=$(java -version 2>&1 | head -1 | awk -F '"' '{print $2}' | cut -d. -f1)
  [ "$JAVA_VER" -ge 21 ] && JAVA_OK=true
fi
if [ "$JAVA_OK" = "false" ]; then
  apt-get update -qq
  apt-get install -y wget apt-transport-https gnupg lsb-release ca-certificates --no-install-recommends -qq
  install -d -m 0755 /etc/apt/keyrings
  wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] \
https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/adoptium.list
  apt-get update -qq
  apt-get install -y temurin-21-jdk --no-install-recommends -qq
fi
JAVA_BIN="$(command -v java)"
print_success "Java $(java -version 2>&1 | head -1 | awk -F '"' '{print $2}') ready (${JAVA_BIN})"

if ! command -v mvn &>/dev/null; then
  apt-get install -y maven --no-install-recommends -qq
fi
print_success "Maven $(mvn -version | head -1 | awk '{print $3}') ready"

# ── System user ───────────────────────────────────────────────────────────────
ensure_bite_user

# ── Build ─────────────────────────────────────────────────────────────────────
print_step "Building Spring Boot jar with Maven (this may take a few minutes the first time)"
(cd "$SOURCE_DIR" && mvn -B -q -DskipTests package)
JAR_PATH="${SOURCE_DIR}/target/notification-service.jar"
if [ ! -f "$JAR_PATH" ]; then
  JAR_PATH="$(ls "${SOURCE_DIR}"/target/*.jar 2>/dev/null | head -1 || true)"
fi
[ -n "${JAR_PATH:-}" ] && [ -f "$JAR_PATH" ] || { print_error "Build did not produce a jar"; exit 1; }
print_success "Built: ${JAR_PATH}"

# ── Deploy jar ────────────────────────────────────────────────────────────────
print_step "Deploying jar → ${APP_DIR}/app.jar"
mkdir -p "$APP_DIR"
cp "$JAR_PATH" "${APP_DIR}/app.jar"
chown -R bite:bite "$APP_DIR"
print_success "Jar deployed (mode 644, owner bite)"

# ── Environment file ──────────────────────────────────────────────────────────
print_step "Writing ${APP_DIR}/.env"
{
  printf 'SERVER_PORT=%s\n' "$PORT"
} > "${APP_DIR}/.env"
chmod 640 "${APP_DIR}/.env"
chown bite:bite "${APP_DIR}/.env"
print_success ".env written (mode 640, owner bite)"

# ── Systemd unit ──────────────────────────────────────────────────────────────
print_step "Installing systemd unit: bite-notification.service"
cat > /etc/systemd/system/bite-notification.service <<UNIT
[Unit]
Description=BITE Notification Service (Spring Boot)
Documentation=https://github.com/Carlixgonzam/Sprint-4-Microservicios
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=bite
Group=bite
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${JAVA_BIN} -jar ${APP_DIR}/app.jar
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
