#!/usr/bin/env bash
# deploy/deploy-all.sh
# Orchestrate deployment of all four BITE microservices on one or more EC2 instances.
#
# Run as root: sudo bash deploy-all.sh
#
# Each service can also be deployed independently with its own script.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE Microservices — Full Deployment Wizard"
printf "  Target OS : Ubuntu 24.04 LTS (EC2)\n"
printf "  Services  : api-gateway · inventory · report · notification\n"
printf "  Databases : External PostgreSQL + MongoDB (configured per-service)\n"
echo

# ── Service selection ─────────────────────────────────────────────────────────
print_section "Select Services to Deploy"
echo
printf "  Available services:\n\n"
printf "    ${CYAN}1${NC}) api-gateway          — Node.js, port 8000, JWT proxy\n"
printf "    ${CYAN}2${NC}) inventory-service     — Python/FastAPI, port 8001, PostgreSQL\n"
printf "    ${CYAN}3${NC}) report-service        — Python/FastAPI, port 8002, MongoDB\n"
printf "    ${CYAN}4${NC}) notification-service  — Python/FastAPI, port 8003, stateless\n"
echo
printf "  ${CYAN}[?]${NC} Enter numbers to deploy (space-separated) or ${YELLOW}all${NC}: "
read -r SELECTION

DEPLOY_GW=false
DEPLOY_INV=false
DEPLOY_REP=false
DEPLOY_NOT=false

if [[ "$SELECTION" == "all" ]]; then
  DEPLOY_GW=true; DEPLOY_INV=true; DEPLOY_REP=true; DEPLOY_NOT=true
else
  for num in $SELECTION; do
    case "$num" in
      1) DEPLOY_GW=true  ;;
      2) DEPLOY_INV=true ;;
      3) DEPLOY_REP=true ;;
      4) DEPLOY_NOT=true ;;
      *) print_warning "Unknown selection '${num}', skipping." ;;
    esac
  done
fi

echo
printf "  Services selected:\n"
[ "$DEPLOY_GW"  = "true" ] && printf "    ${GREEN}✓${NC} api-gateway\n"
[ "$DEPLOY_INV" = "true" ] && printf "    ${GREEN}✓${NC} inventory-service\n"
[ "$DEPLOY_REP" = "true" ] && printf "    ${GREEN}✓${NC} report-service\n"
[ "$DEPLOY_NOT" = "true" ] && printf "    ${GREEN}✓${NC} notification-service\n"
echo

if [ "$DEPLOY_GW" = "false" ] && [ "$DEPLOY_INV" = "false" ] && \
   [ "$DEPLOY_REP" = "false" ] && [ "$DEPLOY_NOT" = "false" ]; then
  print_error "No services selected. Exiting."
  exit 1
fi

confirm "Proceed to configure and deploy the selected services?" || { echo "Aborted."; exit 0; }

# ── Run each wizard ───────────────────────────────────────────────────────────
FAILED=()

run_deploy() {
  local script="$1"
  local name="$2"
  echo
  printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "  Launching wizard for: ${BOLD}%s${NC}\n" "$name"
  printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  if bash "${SCRIPT_DIR}/${script}"; then
    print_success "${name} deployment complete"
  else
    print_error "${name} deployment FAILED (exit $?)"
    FAILED+=("$name")
  fi
}

[ "$DEPLOY_GW"  = "true" ] && run_deploy "deploy-api-gateway.sh"          "api-gateway"
[ "$DEPLOY_INV" = "true" ] && run_deploy "deploy-inventory-service.sh"    "inventory-service"
[ "$DEPLOY_REP" = "true" ] && run_deploy "deploy-report-service.sh"       "report-service"
[ "$DEPLOY_NOT" = "true" ] && run_deploy "deploy-notification-service.sh" "notification-service"

# ── Final status ──────────────────────────────────────────────────────────────
echo
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${BOLD}Deployment Summary${NC}\n"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

check_service() {
  local unit="$1" label="$2"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    printf "  ${GREEN}●${NC} %-28s ${GREEN}running${NC}\n" "$label"
  else
    printf "  ${RED}○${NC} %-28s ${RED}stopped / not deployed${NC}\n" "$label"
  fi
}

check_service "bite-api-gateway"   "api-gateway       :8000"
check_service "bite-inventory"     "inventory-service :8001"
check_service "bite-report"        "report-service    :8002"
check_service "bite-notification"  "notification-service :8003"

echo
if [ ${#FAILED[@]} -gt 0 ]; then
  printf "  ${RED}${BOLD}✗ Some services failed to deploy:${NC}\n"
  for svc in "${FAILED[@]}"; do
    printf "    - %s\n" "$svc"
  done
  echo
  printf "  Check logs with: ${CYAN}journalctl -u bite-<service> -n 50 --no-pager${NC}\n"
  exit 1
else
  printf "  ${GREEN}${BOLD}✓ All selected services deployed successfully.${NC}\n\n"
  printf "  Next steps:\n"
  printf "    1. Configure Security Groups to allow inbound on ports 8000-8003\n"
  printf "    2. Seed PostgreSQL (inventory DB) and MongoDB (bite_reports DB)\n"
  printf "    3. Point api-gateway env vars to the correct service private IPs\n"
  printf "    4. Get a token:  curl -X POST http://<gw-ip>:8000/auth/token \\\\\n"
  printf "                          -H 'Content-Type: application/json' \\\\\n"
  printf "                          -d '{\"username\":\"admin\"}'\n"
fi
echo
