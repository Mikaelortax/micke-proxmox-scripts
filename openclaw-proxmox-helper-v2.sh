#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# OpenClaw Helper Script - Version 2
# Syfte:
# - Körs INNE i en redan fungerande Debian 12 LXC
# - Verifierar miljön
# - Installerar Node.js 24 vid behov
# - Installerar OpenClaw
# - Kör OpenClaw onboarding
# - Tvingar OpenAI API key-flöde (inte Codex OAuth) via tydlig guidning
# - Sätter säkra och praktiska default-värden
# - Lägger till controlUi.allowedOrigins
# - Skapar startscript och health-script
# - Startar gateway i bakgrunden
# - Verifierar health och port 18789
# - Skriver ut nästa steg för SSH-tunnel och localhost-access
# ============================================================

# -----------------------------
# Låsta värden för denna miljö
# -----------------------------
EXPECTED_CTID="106"
EXPECTED_HOSTNAME="opentest"
EXPECTED_IP="192.168.0.206"
GATEWAY_PORT="18789"

SCRIPT_NAME="OpenClaw Helper Script - Version 2"
START_SCRIPT="/root/openclaw-start.sh"
HEALTH_SCRIPT="/root/openclaw-health.sh"
LOG_FILE="/root/openclaw-gateway.log"
OPENCLAW_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG="${OPENCLAW_DIR}/openclaw.json"

# -----------------------------
# Färger
# -----------------------------
if [ -t 1 ]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_BLUE="\033[1;34m"
  C_GREEN="\033[1;32m"
  C_YELLOW="\033[1;33m"
  C_RED="\033[1;31m"
else
  C_RESET=""
  C_BOLD=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
fi

# -----------------------------
# Loggfunktioner
# -----------------------------
section() {
  echo
  echo -e "${C_BLUE}${C_BOLD}============================================================${C_RESET}"
  echo -e "${C_BLUE}${C_BOLD}$1${C_RESET}"
  echo -e "${C_BLUE}${C_BOLD}============================================================${C_RESET}"
}

info() {
  echo -e "${C_BLUE}[INFO]${C_RESET} $1"
}

ok() {
  echo -e "${C_GREEN}[OK]${C_RESET} $1"
}

warn() {
  echo -e "${C_YELLOW}[WARN]${C_RESET} $1"
}

fail() {
  echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2
  exit 1
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || fail "Scriptet måste köras som root."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

pause_for_enter() {
  echo
  read -r -p "Tryck Enter för att fortsätta..." _
}

cleanup_hint_on_error() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    echo
    echo -e "${C_RED}[ERROR]${C_RESET} Scriptet avbröts med exit-kod ${exit_code}."
    echo "Kolla utskriften ovan för exakt steg som bröt."
    echo "Vid OpenClaw-problem kan du efteråt köra:"
    echo "  openclaw doctor"
    echo "  openclaw logs --follow"
    echo "  openclaw status"
  fi
}
trap cleanup_hint_on_error EXIT

# -----------------------------
# Preflight-kontroller
# -----------------------------
check_container() {
  info "Kontrollerar att vi kör i container ..."
  if [ -f /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ | grep -qi '^container='; then
    ok "Container-miljö detekterad via /proc/1/environ."
    return
  fi

  if grep -qaE '(lxc|container)' /proc/1/cgroup 2>/dev/null; then
    ok "Container-miljö detekterad via cgroup."
    return
  fi

  warn "Kunde inte säkert verifiera container via standardkontroller."
  warn "Fortsätter ändå, men detta script är avsett att köras inne i Debian LXC."
}

check_hostname() {
  local current_host
  current_host="$(hostname)"
  info "Kontrollerar hostname ..."
  if [ "$current_host" = "$EXPECTED_HOSTNAME" ]; then
    ok "Hostname matchar förväntat värde: ${EXPECTED_HOSTNAME}"
  else
    warn "Hostname är '${current_host}', förväntat '${EXPECTED_HOSTNAME}'."
    warn "Detta behöver inte vara fel, men kontrollera att du är i rätt container."
  fi
}

check_ip() {
  info "Kontrollerar container-IP ..."
  if ip -4 addr show scope global | grep -q "${EXPECTED_IP}/"; then
    ok "Förväntad IP hittad: ${EXPECTED_IP}"
  else
    warn "Förväntad IP ${EXPECTED_IP} hittades inte på interfacen."
    warn "Fortsätter ändå, men kontrollera att du verkligen är i rätt container."
  fi
}

check_debian() {
  info "Kontrollerar Debian-version ..."
  [ -f /etc/os-release ] || fail "/etc/os-release saknas. Kan inte verifiera OS."

  # shellcheck disable=SC1091
  . /etc/os-release

  [ "${ID:-}" = "debian" ] || fail "Detta script kräver Debian. Hittade: ${ID:-okänt}"
  [ "${VERSION_ID:-}" = "12" ] || fail "Detta script kräver Debian 12. Hittade: ${VERSION_ID:-okänt}"

  ok "Debian 12 verifierat."
}

check_internet() {
  info "Kontrollerar internetåtkomst ..."
  if curl -fsS --max-time 10 https://openclaw.ai >/dev/null; then
    ok "Internetåtkomst OK (openclaw.ai svarar)."
    return
  fi

  if curl -fsS --max-time 10 https://github.com >/dev/null; then
    ok "Internetåtkomst OK (github.com svarar)."
    return
  fi

  fail "Ingen fungerande internetåtkomst upptäcktes."
}

install_base_packages() {
  info "Installerar/verifierar nödvändiga baspaket ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    procps \
    iproute2 \
    net-tools \
    python3 \
    git

  ok "Baspaket installerade/verifierade."
}

ensure_node_24() {
  section "Node.js-kontroll"

  if command_exists node; then
    local node_version node_major
    node_version="$(node --version | sed 's/^v//')"
    node_major="$(printf '%s' "$node_version" | cut -d. -f1 || true)"

    info "Hittade Node.js version: v${node_version}"

    if [ -n "${node_major:-}" ] && [ "$node_major" -ge 24 ]; then
      ok "Node.js är redan kompatibel och rekommenderad (24+)."
      return
    fi

    if [ -n "${node_major:-}" ] && [ "$node_major" -ge 22 ]; then
      warn "Node.js ${node_version} fungerar troligen, men Node 24 rekommenderas."
      info "Uppgraderar till Node.js 24 för att följa OpenClaws rekommenderade runtime."
    else
      warn "Node.js-versionen är för gammal eller ogiltig."
    fi
  else
    warn "Node.js saknas. Installerar Node.js 24."
  fi

  info "Lägger till NodeSource repo för Node.js 24 ..."
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs

  command_exists node || fail "Node.js installerades inte korrekt."
  command_exists npm || fail "npm installerades inte korrekt."

  ok "Node.js installerad/verifierad: $(node --version)"
  ok "npm installerad/verifierad: $(npm --version)"
}

install_openclaw() {
  section "Installera OpenClaw"

  info "Installerar OpenClaw globalt via npm ..."
  npm install -g openclaw@latest

  command_exists openclaw || fail "openclaw-kommandot hittades inte efter installation."

  ok "OpenClaw installerad."
  info "Verifierar OpenClaw-version ..."
  openclaw --version || fail "Kunde inte läsa OpenClaw-version."
  ok "OpenClaw-kommandot fungerar."
}

show_onboarding_instructions() {
  section "OpenClaw onboarding"

  echo "Nu kommer OpenClaws egen onboarding."
  echo
  echo "VIKTIGA VAL NÄR GUIDEN FRÅGAR:"
  echo "1. Välj OpenAI som provider om du får frågan."
  echo "2. Välj OpenAI API key."
  echo "3. Välj INTE Codex OAuth."
  echo "4. Om du får välja modell rekommenderas:"
  echo "   - Primär modell: openai/gpt-5.4"
  echo "   - En lättare modell om du får välja extra/fallback: openai/gpt-5-mini"
  echo "5. Låt OpenClaw skapa/hantera gateway-grunden."
  echo
  echo "Scriptet kör onboarding interaktivt nu."
  echo "När du är klar fortsätter scriptet automatiskt."
  echo
  pause_for_enter
}

run_onboarding() {
  info "Startar: openclaw onboard --install-daemon"
  echo

  set +e
  openclaw onboard --install-daemon
  local rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    ok "OpenClaw onboarding slutförd."
    return
  fi

  warn "Onboarding avslutades inte helt korrekt (exit-kod ${rc})."
  warn "Detta kan bero på daemon-/miljödetaljer i LXC eller att onboarding avbröts."
  warn "Vi fortsätter med verifiering och manuellt startscript ändå."
}

verify_config_presence() {
  section "Verifiera OpenClaw-konfiguration"

  if [ -f "$OPENCLAW_CONFIG" ]; then
    ok "Konfigurationsfil hittad: $OPENCLAW_CONFIG"
  else
    warn "Konfigurationsfilen hittades inte direkt efter onboarding."
    warn "Försöker skapa en minimal bas genom att köra config-läsning ..."

    mkdir -p "$OPENCLAW_DIR"

    if ! [ -f "$OPENCLAW_CONFIG" ]; then
      fail "Konfigurationsfil saknas fortfarande. Kör 'openclaw onboard' manuellt och kör sedan scriptet igen."
    fi
  fi

  cp -a "$OPENCLAW_CONFIG" "${OPENCLAW_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  ok "Backup skapad av konfigurationsfilen."
}

set_allowed_origins() {
  section "Sätt allowedOrigins"

  info "Lägger till praktiska och säkra origins för Control UI ..."
  info "Detta behövs särskilt för icke-loopback-scenarier och framtida direktåtkomst."

  openclaw config set gateway.controlUi.allowedOrigins \
    "[\"http://127.0.0.1:${GATEWAY_PORT}\",\"http://localhost:${GATEWAY_PORT}\",\"http://${EXPECTED_IP}:${GATEWAY_PORT}\"]" \
    --strict-json

  ok "allowedOrigins satt."
}

set_gateway_defaults() {
  section "Sätt gateway-defaults"

  info "Sätter säker loopback-bind på gatewayn ..."
  openclaw config set gateway.bind "\"loopback\"" --strict-json

  info "Sätter gateway-port ..."
  openclaw config set gateway.port "${GATEWAY_PORT}" --strict-json

  ok "Gateway-defaults satta."
}

show_model_recommendation() {
  section "Modellrekommendation"

  echo "Detta script tvingar inte modellval hårt i config, eftersom onboardingflödet kan variera mellan versioner."
  echo "Men rekommenderad OpenAI-strategi för denna installation är:"
  echo
  echo "  Primär:  openai/gpt-5.4"
  echo "  Lättare: openai/gpt-5-mini"
  echo
  echo "Om du senare vill ändra modell kan du använda:"
  echo "  openclaw configure"
  echo "eller"
  echo "  openclaw config get agents.defaults.model"
  echo
}

create_start_script() {
  section "Skapa startscript"

  cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${GATEWAY_PORT}"
LOG_FILE="${LOG_FILE}"

echo "[INFO] Startar OpenClaw gateway på port \${PORT} ..."
nohup openclaw gateway --port "\${PORT}" --bind loopback --verbose > "\${LOG_FILE}" 2>&1 &
sleep 5

if ss -ltn 2>/dev/null | grep -q ":\\\${PORT} "; then
  echo "[OK] Gateway verkar lyssna på port \${PORT}."
  echo "[INFO] Loggfil: \${LOG_FILE}"
else
  echo "[WARN] Gateway verkar inte lyssna på port \${PORT} ännu."
  echo "[INFO] Kontrollera loggen: \${LOG_FILE}"
  exit 1
fi
EOF

  chmod +x "$START_SCRIPT"
  ok "Startscript skapat: $START_SCRIPT"
}

create_health_script() {
  section "Skapa health-script"

  cat > "$HEALTH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${GATEWAY_PORT}"

echo "=== OpenClaw Health Check ==="
echo

echo "[1/3] Portkontroll"
if ss -ltn 2>/dev/null | grep -q ":\\\${PORT} "; then
  echo "[OK] Port \${PORT} lyssnar."
else
  echo "[WARN] Port \${PORT} lyssnar inte."
fi

echo
echo "[2/3] OpenClaw status"
if command -v openclaw >/dev/null 2>&1; then
  openclaw status || true
else
  echo "[WARN] openclaw-kommandot hittades inte."
fi

echo
echo "[3/3] OpenClaw health"
if command -v openclaw >/dev/null 2>&1; then
  openclaw health --json || true
else
  echo "[WARN] openclaw-kommandot hittades inte."
fi
EOF

  chmod +x "$HEALTH_SCRIPT"
  ok "Health-script skapat: $HEALTH_SCRIPT"
}

start_gateway() {
  section "Starta gateway"

  info "Startar OpenClaw gateway i bakgrunden via startscript ..."
  "$START_SCRIPT" || warn "Startscriptet rapporterade varning. Vi gör fler kontroller direkt."
}

verify_gateway() {
  section "Verifiera gateway"

  info "Kontrollerar att port ${GATEWAY_PORT} lyssnar ..."
  if ss -ltn 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
    ok "Port ${GATEWAY_PORT} lyssnar."
  else
    warn "Port ${GATEWAY_PORT} lyssnar inte ännu."
  fi

  info "Kör openclaw health --json ..."
  set +e
  openclaw health --json
  local health_rc=$?
  set -e

  if [ "$health_rc" -eq 0 ]; then
    ok "openclaw health rapporterar OK."
  else
    warn "openclaw health rapporterade problem eller nådde inte gatewayn ännu."
    warn "Kontrollera loggen: ${LOG_FILE}"
  fi
}

print_final_summary() {
  section "Klart - nästa steg"

  echo "OpenClaw Version 2-scriptet har kört klart."
  echo
  echo "Viktiga filer:"
  echo "  Huvudconfig : ${OPENCLAW_CONFIG}"
  echo "  Startscript : ${START_SCRIPT}"
  echo "  Health      : ${HEALTH_SCRIPT}"
  echo "  Loggfil     : ${LOG_FILE}"
  echo
  echo "Snabba kommandon inne i containern:"
  echo "  ${START_SCRIPT}"
  echo "  ${HEALTH_SCRIPT}"
  echo "  openclaw doctor"
  echo "  openclaw logs --follow"
  echo
  echo "SSH-tunnel från din dator till containern:"
  echo "  ssh -N -L ${GATEWAY_PORT}:127.0.0.1:${GATEWAY_PORT} root@${EXPECTED_IP}"
  echo
  echo "Öppna sedan i din webbläsare på din egen dator:"
  echo "  http://127.0.0.1:${GATEWAY_PORT}/"
  echo
  echo "Om UI visar auth/token-relaterat problem kan du kontrollera gatewaytoken med:"
  echo "  openclaw config get gateway.auth.token"
  echo
  echo "Om något inte fungerar:"
  echo "  1. ${HEALTH_SCRIPT}"
  echo "  2. openclaw doctor"
  echo "  3. openclaw logs --follow"
}

main() {
  section "${SCRIPT_NAME}"

  require_root
  ok "Kör som root."

  check_container
  check_hostname
  check_ip
  check_debian
  check_internet
  install_base_packages
  ensure_node_24
  install_openclaw
  show_onboarding_instructions
  run_onboarding
  verify_config_presence
  set_gateway_defaults
  set_allowed_origins
  show_model_recommendation
  create_start_script
  create_health_script
  start_gateway
  verify_gateway
  print_final_summary
}

main "$@"