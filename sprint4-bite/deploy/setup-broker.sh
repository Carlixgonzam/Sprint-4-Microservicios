#!/usr/bin/env bash
# deploy/setup-broker.sh
# ─────────────────────────────────────────────────────────────────────────────
# Installs and configures Redis 7 + RabbitMQ 3 on a single Ubuntu 24.04 EC2
# instance (ec2-broker). Both run as native systemd services. Redis is used
# by the orchestrator as the report cache; RabbitMQ is the job queue for
# report generation.
#
# Run as root:  sudo bash setup-broker.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — Broker Setup Wizard"
printf "  Installs : Redis 7  +  RabbitMQ 3\n"
printf "  Target   : Ubuntu 24.04 LTS (EC2)\n"
echo
print_warning "Run this on the dedicated ec2-broker instance."

# ── Wizard ────────────────────────────────────────────────────────────────────
print_section "Redis Configuration"
print_info "Redis caches generated reports. No password by default; rely on AWS SG."
read_var "Redis 'requirepass' password (leave empty for none)" "" REDIS_PASSWORD

print_section "RabbitMQ Configuration"
print_info "RabbitMQ is the job queue for the orchestrator → workers."
read_var "RabbitMQ admin username" "bite" RABBIT_USER
read_var "RabbitMQ admin password" "" RABBIT_PASSWORD secret

print_section "Network / Remote Access"
print_info "AWS Security Groups are the primary firewall — restrict by SG."
if confirm "Allow remote connections (bind to 0.0.0.0)?" "y"; then
  BIND_REMOTE="yes"
else
  BIND_REMOTE="no"
fi

print_summary \
  "REDIS_PASSWORD=${REDIS_PASSWORD:-<none>}" \
  "RABBIT_USER=${RABBIT_USER}" \
  "RABBIT_PASSWORD=${RABBIT_PASSWORD}" \
  "BIND_REMOTE=${BIND_REMOTE}"

confirm "Proceed with installation?" || { echo "Aborted."; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM PREP
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Updating package index"
apt-get update -qq
apt-get install -y curl ca-certificates gnupg lsb-release --no-install-recommends -qq
print_success "Base packages ready"

# ═══════════════════════════════════════════════════════════════════════════════
# REDIS 7
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Installing Redis"
apt-get install -y redis-server --no-install-recommends -qq
print_success "Redis $(redis-server --version | awk '{print $3}' | sed 's/v=//') installed"

REDIS_CONF="/etc/redis/redis.conf"

print_step "Configuring Redis"
# Bind address
if [ "$BIND_REMOTE" = "yes" ]; then
  sed -i 's/^bind .*/bind 0.0.0.0 ::/' "$REDIS_CONF"
  sed -i 's/^protected-mode .*/protected-mode no/' "$REDIS_CONF"
  print_success "Redis bind=0.0.0.0, protected-mode=no"
else
  sed -i 's/^bind .*/bind 127.0.0.1 ::1/' "$REDIS_CONF"
  print_success "Redis bind=127.0.0.1 (local only)"
fi

# Optional password
if [ -n "$REDIS_PASSWORD" ]; then
  sed -i "/^# *requirepass /d" "$REDIS_CONF"
  sed -i "/^requirepass /d"   "$REDIS_CONF"
  echo "requirepass ${REDIS_PASSWORD}" >> "$REDIS_CONF"
  print_success "Redis requirepass set"
fi

systemctl enable redis-server
systemctl restart redis-server
sleep 2
if systemctl is-active --quiet redis-server; then
  print_success "redis-server is active"
else
  print_error "redis-server failed to start. Check: journalctl -u redis-server -n 30"
  exit 1
fi

# Verify connectivity
if [ -n "$REDIS_PASSWORD" ]; then
  REDIS_CLI_PING="redis-cli -a ${REDIS_PASSWORD} --no-auth-warning ping"
else
  REDIS_CLI_PING="redis-cli ping"
fi
if [ "$(eval "$REDIS_CLI_PING" 2>/dev/null)" = "PONG" ]; then
  print_success "Redis ping → PONG"
else
  print_error "Redis ping failed."
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RABBITMQ 3
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Installing RabbitMQ (Ubuntu repo)"
apt-get install -y rabbitmq-server --no-install-recommends -qq
systemctl enable rabbitmq-server
systemctl start rabbitmq-server
sleep 5
print_success "RabbitMQ installed and started"

# ── Enable management UI ──────────────────────────────────────────────────────
print_step "Enabling rabbitmq_management plugin"
rabbitmq-plugins enable rabbitmq_management
sleep 2
print_success "Management UI on port 15672"

# ── Create app user, remove default guest ─────────────────────────────────────
print_step "Bootstrapping users and permissions"
if rabbitmqctl list_users | awk '{print $1}' | grep -q "^${RABBIT_USER}$"; then
  rabbitmqctl change_password "${RABBIT_USER}" "${RABBIT_PASSWORD}"
  print_success "User '${RABBIT_USER}' password updated"
else
  rabbitmqctl add_user "${RABBIT_USER}" "${RABBIT_PASSWORD}"
  print_success "User '${RABBIT_USER}' created"
fi
rabbitmqctl set_user_tags        "${RABBIT_USER}" administrator
rabbitmqctl set_permissions -p / "${RABBIT_USER}" ".*" ".*" ".*"
print_success "Permissions granted on vhost '/'"

# Remove the default 'guest' user (only valid for localhost — kill it for safety)
if rabbitmqctl list_users | awk '{print $1}' | grep -q "^guest$"; then
  rabbitmqctl delete_user guest || true
  print_success "Default 'guest' user removed"
fi

# ── Network binding ──────────────────────────────────────────────────────────
RABBIT_ENV="/etc/rabbitmq/rabbitmq-env.conf"
print_step "Configuring RabbitMQ bind address"
if [ "$BIND_REMOTE" = "yes" ]; then
  cat > "$RABBIT_ENV" <<RABBITENV
NODE_IP_ADDRESS=0.0.0.0
RABBITENV
  print_success "RabbitMQ bind=0.0.0.0 (all interfaces)"
else
  cat > "$RABBIT_ENV" <<RABBITENV
NODE_IP_ADDRESS=127.0.0.1
RABBITENV
  print_success "RabbitMQ bind=127.0.0.1 (local only)"
fi

systemctl restart rabbitmq-server
sleep 4
if systemctl is-active --quiet rabbitmq-server; then
  print_success "rabbitmq-server is active"
else
  print_error "rabbitmq-server failed to start. Check: journalctl -u rabbitmq-server -n 50"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# DETECT PRIVATE IP
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Detecting instance private IP"
PRIVATE_IP=""
TOKEN=$(curl -sf --connect-timeout 2 \
  -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [ -n "${TOKEN:-}" ]; then
  PRIVATE_IP=$(curl -sf --connect-timeout 2 \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null) || true
fi
[ -z "${PRIVATE_IP:-}" ] && PRIVATE_IP=$(hostname -I | awk '{print $1}')
print_success "Private IP: ${PRIVATE_IP}"

# ═══════════════════════════════════════════════════════════════════════════════
# SAVE CREDENTIALS
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Saving connection strings to /opt/bite/broker-credentials.env"
mkdir -p /opt/bite
{
  printf '# BITE Broker Credentials — generated %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
  printf '# Mode 600 — do not commit this file.\n\n'
  printf '# Redis (orchestrator cache)\n'
  if [ -n "$REDIS_PASSWORD" ]; then
    printf 'REDIS_URL=redis://:%s@%s:6379/0\n' "$REDIS_PASSWORD" "$PRIVATE_IP"
  else
    printf 'REDIS_URL=redis://%s:6379/0\n' "$PRIVATE_IP"
  fi
  printf '\n# RabbitMQ (orchestrator job queue)\n'
  printf 'RABBITMQ_URL=amqp://%s:%s@%s:5672/\n' \
    "$RABBIT_USER" "$RABBIT_PASSWORD" "$PRIVATE_IP"
  printf '\n# RabbitMQ Management UI: http://%s:15672 (user: %s)\n' \
    "$PRIVATE_IP" "$RABBIT_USER"
} > /opt/bite/broker-credentials.env
chmod 600 /opt/bite/broker-credentials.env
print_success "Credentials saved (mode 600)"

# ═══════════════════════════════════════════════════════════════════════════════
# FINAL OUTPUT
# ═══════════════════════════════════════════════════════════════════════════════
if [ -n "$REDIS_PASSWORD" ]; then
  REDIS_URL_OUT="redis://:${REDIS_PASSWORD}@${PRIVATE_IP}:6379/0"
else
  REDIS_URL_OUT="redis://${PRIVATE_IP}:6379/0"
fi
RABBIT_URL_OUT="amqp://${RABBIT_USER}:${RABBIT_PASSWORD}@${PRIVATE_IP}:5672/"

echo
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}${BOLD}✓ Broker setup complete!${NC}\n"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

printf "  ${BOLD}Service status:${NC}\n"
systemctl is-active --quiet redis-server     && \
  printf "  ${GREEN}●${NC} redis-server     running  (port 6379)\n"  || \
  printf "  ${RED}○${NC} redis-server     STOPPED\n"
systemctl is-active --quiet rabbitmq-server  && \
  printf "  ${GREEN}●${NC} rabbitmq-server  running  (ports 5672 / 15672)\n" || \
  printf "  ${RED}○${NC} rabbitmq-server  STOPPED\n"

echo
printf "  ${BOLD}Connection strings (copy into orchestrator .env):${NC}\n\n"
printf "  ${CYAN}# orchestrator-service${NC}\n"
printf "  REDIS_URL=%s\n"    "$REDIS_URL_OUT"
printf "  RABBITMQ_URL=%s\n\n" "$RABBIT_URL_OUT"

printf "  ${BOLD}Saved to:${NC} /opt/bite/broker-credentials.env  (mode 600)\n"
echo
printf "  ${BOLD}Quick health checks:${NC}\n"
if [ -n "$REDIS_PASSWORD" ]; then
  printf "  ${CYAN}redis-cli -h %s -a '%s' ping${NC}\n" "$PRIVATE_IP" "$REDIS_PASSWORD"
else
  printf "  ${CYAN}redis-cli -h %s ping${NC}\n" "$PRIVATE_IP"
fi
printf "  ${CYAN}curl -u %s:%s http://%s:15672/api/overview${NC}\n" \
  "$RABBIT_USER" "$RABBIT_PASSWORD" "$PRIVATE_IP"
echo
printf "  ${BOLD}Next steps:${NC}\n"
printf "   1. Open EC2 Security Group inbound rules:\n"
printf "        port 6379  (Redis)    ← from ec2-orchestrator SG\n"
printf "        port 5672  (RabbitMQ) ← from ec2-orchestrator SG\n"
printf "        port 15672 (Mgmt UI)  ← from your dev IP (optional)\n"
printf "   2. Deploy orchestrator with these URLs in its .env\n"
echo
