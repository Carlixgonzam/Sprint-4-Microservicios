#!/usr/bin/env bash
# deploy/common.sh — Shared utilities for BITE deployment scripts
# Source this file; do not run it directly.

# ── Colors & formatting ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ── Print helpers ─────────────────────────────────────────────────────────────
print_header() {
  local title="$1"
  local w=56
  local pad=$(( (w - ${#title}) / 2 ))
  local rpad=$(( w - pad - ${#title} ))
  echo
  printf "${BLUE}╔"; printf '═%.0s' $(seq 1 $w); printf "╗${NC}\n"
  printf "${BLUE}║${BOLD}"; printf ' %.0s' $(seq 1 $pad)
  printf '%s' "$title"
  printf ' %.0s' $(seq 1 $rpad)
  printf "${BLUE}║${NC}\n"
  printf "${BLUE}╚"; printf '═%.0s' $(seq 1 $w); printf "╝${NC}\n"
  echo
}

print_section() {
  local label="$1"
  local w=44
  local dashes=$(( w - ${#label} - 1 ))
  printf "\n${CYAN}── %s " "$label"
  printf '─%.0s' $(seq 1 $dashes)
  printf "${NC}\n"
}

print_step()    { printf "\n${MAGENTA}▶${NC} ${BOLD}%s${NC}\n" "$1"; }
print_success() { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
print_warning() { printf "  ${YELLOW}⚠${NC} %s\n" "$1"; }
print_error()   { printf "  ${RED}✗${NC} %s\n" "$1" >&2; }
print_info()    { printf "  ${CYAN}i${NC} %s\n" "$1"; }

# ── Configuration summary box ─────────────────────────────────────────────────
# Usage: print_summary "KEY=VALUE" "KEY=VALUE" ...
print_summary() {
  local w=54
  printf "\n${CYAN}┌─ Configuration Summary "
  printf '─%.0s' $(seq 1 $((w - 23)))
  printf "┐${NC}\n"
  for pair in "$@"; do
    local key="${pair%%=*}"
    local val="${pair#*=}"
    if [[ "$key" == *SECRET* || "$key" == *PASSWORD* || "$key" == *PASS* ]]; then
      val="$(printf '%s' "$val" | sed 's/./*/g')"
    fi
    # truncate long values for display
    if [ ${#val} -gt 30 ]; then val="${val:0:27}..."; fi
    printf "${CYAN}│${NC}  %-22s %-28s ${CYAN}│${NC}\n" "${key}:" "$val"
  done
  printf "${CYAN}└"; printf '─%.0s' $(seq 1 $((w + 2))); printf "┘${NC}\n\n"
}

# ── Interactive prompt ────────────────────────────────────────────────────────
# Usage: read_var "Prompt text" "default_value" VARNAME [secret]
read_var() {
  local prompt="$1"
  local default="${2:-}"
  local var_name="$3"
  local is_secret="${4:-false}"
  local value=""

  if [ "$is_secret" = "true" ]; then
    while [ -z "$value" ]; do
      printf "  ${CYAN}[?]${NC} %s: " "$prompt"
      read -rs value
      printf '\n'
      [ -z "$value" ] && print_warning "This field is required."
    done
  elif [ -n "$default" ]; then
    printf "  ${CYAN}[?]${NC} %s ${YELLOW}[%s]${NC}: " "$prompt" "$default"
    read -r value
    value="${value:-$default}"
  else
    while [ -z "$value" ]; do
      printf "  ${CYAN}[?]${NC} %s: " "$prompt"
      read -r value
      [ -z "$value" ] && print_warning "This field is required."
    done
  fi

  printf -v "$var_name" '%s' "$value"
}

# Usage: confirm "Proceed?" [y|n]  — returns 0 for yes, 1 for no
confirm() {
  local prompt="${1:-Proceed?}"
  local default="${2:-y}"
  local hint answer
  [ "$default" = "y" ] && hint="${YELLOW}[Y/n]${NC}" || hint="${YELLOW}[y/N]${NC}"
  printf "  ${CYAN}[?]${NC} %s %b: " "$prompt" "$hint"
  read -r answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root. Try: sudo bash $0"
    exit 1
  fi
}

ensure_bite_user() {
  if ! id -u bite &>/dev/null; then
    print_step "Creating system user 'bite'"
    useradd --system --no-create-home --shell /usr/sbin/nologin bite
    print_success "User 'bite' created"
  else
    print_success "System user 'bite' already exists"
  fi
}

ensure_python3() {
  if ! command -v python3 &>/dev/null; then
    print_step "Installing Python 3"
    apt-get update -qq
    apt-get install -y python3 python3-pip python3-venv
  fi
  print_success "Python $(python3 --version) available"
}

# ── Systemd helpers ───────────────────────────────────────────────────────────
reload_and_start() {
  local svc="$1"
  systemctl daemon-reload
  systemctl enable "$svc"
  systemctl restart "$svc"
  sleep 2
  if systemctl is-active --quiet "$svc"; then
    print_success "Service ${svc} is active"
  else
    print_error "Service ${svc} failed to start."
    printf "  Run: ${CYAN}journalctl -u %s -n 50 --no-pager${NC}\n" "$svc"
    exit 1
  fi
}
