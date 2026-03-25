#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# OpenClaw Proxmox Helper Script - Version 1
# Syfte:
# - Skapa en Debian 12 LXC på Proxmox
# - Sätta statiskt nätverk
# - Starta containern
# - Installera baspaket
# - Verifiera nätverk och internet
# - Lämna containern redo för OpenClaw (Version 2)
# ============================================================

# -----------------------------
# Standardvärden
# -----------------------------
DEFAULT_CTID="105"
DEFAULT_HOSTNAME="openclaw"
DEFAULT_IP_CIDR="192.168.0.206/24"
DEFAULT_GATEWAY="192.168.0.1"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_DNS="1.1.1.1"
DEFAULT_RAM="4096"
DEFAULT_SWAP="1024"
DEFAULT_CPU="2"
DEFAULT_DISK="16"

# Sätts dynamiskt senare
ROOTFS_STORAGE_DEFAULT=""
TEMPLATE_STORAGE_DEFAULT=""
DEBIAN_TEMPLATE_DEFAULT=""

# Globala variabler
CTID=""
HOSTNAME_CT=""
IP_CIDR=""
GATEWAY=""
BRIDGE=""
DNS_SERVER=""
RAM_MB=""
SWAP_MB=""
CPU_CORES=""
DISK_GB=""
ROOTFS_STORAGE=""
TEMPLATE_STORAGE=""
DEBIAN_TEMPLATE=""
ROOT_PASSWORD=""
ROOT_PASSWORD_CONFIRM=""

# Interna hjälpvärden
CONTAINER_READY_TIMEOUT=60
PING_IP=""
NETMASK_CIDR=""
PCT_CREATE_OUTPUT=""
SUMMARY_STATUS="OK"

# -----------------------------
# UI / logg
# -----------------------------
log() {
  echo "[INFO] $*"
}

warn() {
  echo "[VARNING] $*" >&2
}

error() {
  echo "[FEL] $*" >&2
}

die() {
  error "$*"
  exit 1
}

line() {
  echo "------------------------------------------------------------"
}

# -----------------------------
# Cleanup / felhantering
# -----------------------------
on_error() {
  local exit_code=$?
  SUMMARY_STATUS="FEL"
  error "Scriptet avbröts. Rad: ${BASH_LINENO[0]:-okänd}, exit code: ${exit_code}"
  exit "${exit_code}"
}
trap on_error ERR

# -----------------------------
# Hjälpfunktioner
# -----------------------------
prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local value=""
  read -r -p "${prompt} [${default}]: " value
  if [[ -z "${value}" ]]; then
    echo "${default}"
  else
    echo "${value}"
  fi
}

prompt_password_twice() {
  while true; do
    read -r -s -p "Ange root-lösenord för containern: " ROOT_PASSWORD
    echo
    [[ -n "${ROOT_PASSWORD}" ]] || { warn "Lösenord får inte vara tomt."; continue; }

    read -r -s -p "Bekräfta root-lösenord: " ROOT_PASSWORD_CONFIRM
    echo

    if [[ "${ROOT_PASSWORD}" != "${ROOT_PASSWORD_CONFIRM}" ]]; then
      warn "Lösenorden matchar inte. Försök igen."
      continue
    fi
    break
  done
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

storage_exists() {
  local storage_name="$1"
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${storage_name}"
}

bridge_exists() {
  local bridge_name="$1"
  ip link show "${bridge_name}" >/dev/null 2>&1
}

ctid_exists() {
  local ctid="$1"
  pct status "${ctid}" >/dev/null 2>&1
}

wait_for_container() {
  local ctid="$1"
  local waited=0
  while (( waited < CONTAINER_READY_TIMEOUT )); do
    if pct exec "${ctid}" -- bash -lc "echo ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

detect_first_storage_by_content() {
  local content="$1"
  pvesm status -content "${content}" 2>/dev/null | awk 'NR>1 {print $1; exit}'
}

list_storages_by_content() {
  local content="$1"
  pvesm status -content "${content}" 2>/dev/null | awk 'NR>1 {print $1}'
}

detect_debian_template() {
  local storage="$1"

  # Försök först via pvesm list
  local matches
  matches="$(pvesm list "${storage}" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Ei 'debian-12.*(amd64|standard)|debian.*12' || true)"

  if [[ -n "${matches}" ]]; then
    echo "${matches}" | head -n1
    return 0
  fi

  # Fallback: leta i template-cache
  local cache_dir="/var/lib/vz/template/cache"
  if [[ -d "${cache_dir}" ]]; then
    matches="$(find "${cache_dir}" -maxdepth 1 -type f | grep -Ei 'debian-12.*(amd64|standard)|debian.*12' || true)"
    if [[ -n "${matches}" ]]; then
      basename "$(echo "${matches}" | head -n1)"
      return 0
    fi
  fi

  return 1
}

print_template_choices() {
  local storage="$1"
  pvesm list "${storage}" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Ei 'debian-12.*(amd64|standard)|debian.*12' || true
}

check_root() {
  [[ "${EUID}" -eq 0 ]] || die "Scriptet måste köras som root på Proxmox-hosten."
}

check_proxmox_dependencies() {
  command_exists pct || die "Kommandot 'pct' hittades inte. Kör scriptet på en Proxmox-host."
  command_exists pvesm || die "Kommandot 'pvesm' hittades inte. Kör scriptet på en Proxmox-host."
}

load_defaults() {
  ROOTFS_STORAGE_DEFAULT="$(detect_first_storage_by_content images || true)"
  TEMPLATE_STORAGE_DEFAULT="$(detect_first_storage_by_content vztmpl || true)"

  [[ -n "${ROOTFS_STORAGE_DEFAULT}" ]] || ROOTFS_STORAGE_DEFAULT="local-lvm"
  [[ -n "${TEMPLATE_STORAGE_DEFAULT}" ]] || TEMPLATE_STORAGE_DEFAULT="local"

  DEBIAN_TEMPLATE_DEFAULT="$(detect_debian_template "${TEMPLATE_STORAGE_DEFAULT}" || true)"
}

detect_storages() {
  line
  log "Tillgänglig storage för rootfs (content: images):"
  list_storages_by_content images || true
  echo

  log "Tillgänglig storage för templates (content: vztmpl):"
  list_storages_by_content vztmpl || true
  echo
}

detect_debian_template_step() {
  line
  log "Försöker hitta Debian 12-template i storage '${TEMPLATE_STORAGE}'..."

  local found=""
  found="$(detect_debian_template "${TEMPLATE_STORAGE}" || true)"

  if [[ -n "${found}" ]]; then
    DEBIAN_TEMPLATE_DEFAULT="${found}"
    log "Föreslagen Debian 12-template: ${DEBIAN_TEMPLATE_DEFAULT}"
  else
    warn "Ingen Debian 12-template kunde hittas automatiskt i '${TEMPLATE_STORAGE}'."
    warn "Kontrollera att Debian 12 LXC-template är nedladdad i Proxmox."
    echo
    log "Matchande templates som hittades:"
    print_template_choices "${TEMPLATE_STORAGE}" || true
  fi
}

validate_numeric() {
  local value="$1"
  local label="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} måste vara ett heltal."
}

validate_inputs() {
  validate_numeric "${CTID}" "CTID"
  validate_numeric "${RAM_MB}" "RAM"
  validate_numeric "${SWAP_MB}" "Swap"
  validate_numeric "${CPU_CORES}" "CPU cores"
  validate_numeric "${DISK_GB}" "Diskstorlek"

  [[ -n "${HOSTNAME_CT}" ]] || die "Hostname får inte vara tomt."
  [[ -n "${IP_CIDR}" ]] || die "IP/CIDR får inte vara tomt."
  [[ -n "${GATEWAY}" ]] || die "Gateway får inte vara tom."
  [[ -n "${BRIDGE}" ]] || die "Bridge får inte vara tom."
  [[ -n "${DNS_SERVER}" ]] || die "DNS får inte vara tom."
  [[ -n "${ROOTFS_STORAGE}" ]] || die "Rootfs storage får inte vara tom."
  [[ -n "${TEMPLATE_STORAGE}" ]] || die "Template storage får inte vara tom."
  [[ -n "${DEBIAN_TEMPLATE}" ]] || die "Debian-template får inte vara tom."

  if [[ "${IP_CIDR}" != */* ]]; then
    die "IP/CIDR måste anges i formatet IP/CIDR, till exempel 192.168.0.206/24."
  fi

  PING_IP="${IP_CIDR%%/*}"
  NETMASK_CIDR="${IP_CIDR##*/}"
}

check_ip_conflict() {
  line
  log "Kontrollerar om IP-adressen ${PING_IP} verkar upptagen..."

  if ping -c 1 -W 1 "${PING_IP}" >/dev/null 2>&1; then
    warn "IP-adressen ${PING_IP} svarar redan på nätet."
    local answer=""
    while true; do
      read -r -p "Vill du fortsätta ändå? (ja/nej): " answer
      case "${answer,,}" in
        ja|j) return 0 ;;
        nej|n) die "Avbrutet av användaren på grund av möjlig IP-konflikt." ;;
        *) warn "Svara ja eller nej." ;;
      esac
    done
  else
    log "Ingen tydlig IP-konflikt upptäcktes för ${PING_IP}."
  fi
}

prompt_ctid_until_free() {
  while ctid_exists "${CTID}"; do
    warn "CTID ${CTID} är redan upptaget."
    CTID="$(prompt_with_default "Ange ett annat CTID" "$((CTID + 1))")"
    validate_numeric "${CTID}" "CTID"
  done
}

validate_environment() {
  line
  log "Kör förkontroller..."

  bridge_exists "${BRIDGE}" || die "Bridge '${BRIDGE}' hittades inte på Proxmox-hosten."
  storage_exists "${ROOTFS_STORAGE}" || die "Rootfs storage '${ROOTFS_STORAGE}' hittades inte."
  storage_exists "${TEMPLATE_STORAGE}" || die "Template storage '${TEMPLATE_STORAGE}' hittades inte."

  prompt_ctid_until_free

  if ! pvesm list "${TEMPLATE_STORAGE}" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${DEBIAN_TEMPLATE}"; then
    local cache_path="/var/lib/vz/template/cache/${DEBIAN_TEMPLATE}"
    [[ -f "${cache_path}" ]] || die "Debian-template '${DEBIAN_TEMPLATE}' hittades inte i storage '${TEMPLATE_STORAGE}'."
  fi

  check_ip_conflict
  log "Förkontroller klara."
}

prompt_values() {
  line
  log "Ange värden för containern. Tryck Enter för att använda standardvärdet."
  echo

  CTID="$(prompt_with_default "CTID" "${DEFAULT_CTID}")"
  HOSTNAME_CT="$(prompt_with_default "Hostname" "${DEFAULT_HOSTNAME}")"
  IP_CIDR="$(prompt_with_default "IP/CIDR" "${DEFAULT_IP_CIDR}")"
  GATEWAY="$(prompt_with_default "Gateway" "${DEFAULT_GATEWAY}")"
  BRIDGE="$(prompt_with_default "Bridge" "${DEFAULT_BRIDGE}")"
  DNS_SERVER="$(prompt_with_default "DNS" "${DEFAULT_DNS}")"
  RAM_MB="$(prompt_with_default "RAM (MB)" "${DEFAULT_RAM}")"
  SWAP_MB="$(prompt_with_default "Swap (MB)" "${DEFAULT_SWAP}")"
  CPU_CORES="$(prompt_with_default "CPU cores" "${DEFAULT_CPU}")"
  DISK_GB="$(prompt_with_default "Diskstorlek (GB)" "${DEFAULT_DISK}")"

  echo
  ROOTFS_STORAGE="$(prompt_with_default "Rootfs storage" "${ROOTFS_STORAGE_DEFAULT}")"
  TEMPLATE_STORAGE="$(prompt_with_default "Template storage" "${TEMPLATE_STORAGE_DEFAULT}")"

  detect_debian_template_step

  if [[ -n "${DEBIAN_TEMPLATE_DEFAULT}" ]]; then
    DEBIAN_TEMPLATE="$(prompt_with_default "Debian 12-template" "${DEBIAN_TEMPLATE_DEFAULT}")"
  else
    read -r -p "Debian 12-template: " DEBIAN_TEMPLATE
  fi

  echo
  prompt_password_twice
  echo
}

print_input_summary() {
  line
  log "Sammanfattning av valda värden:"
  echo "CTID:              ${CTID}"
  echo "Hostname:          ${HOSTNAME_CT}"
  echo "IP/CIDR:           ${IP_CIDR}"
  echo "Gateway:           ${GATEWAY}"
  echo "Bridge:            ${BRIDGE}"
  echo "DNS:               ${DNS_SERVER}"
  echo "RAM (MB):          ${RAM_MB}"
  echo "Swap (MB):         ${SWAP_MB}"
  echo "CPU cores:         ${CPU_CORES}"
  echo "Disk (GB):         ${DISK_GB}"
  echo "Rootfs storage:    ${ROOTFS_STORAGE}"
  echo "Template storage:  ${TEMPLATE_STORAGE}"
  echo "Debian-template:   ${DEBIAN_TEMPLATE}"
  line
}

confirm_to_continue() {
  local answer=""
  while true; do
    read -r -p "Vill du fortsätta och skapa containern? (ja/nej): " answer
    case "${answer,,}" in
      ja|j) return 0 ;;
      nej|n) die "Avbrutet av användaren." ;;
      *) warn "Svara ja eller nej." ;;
    esac
  done
}

resolve_template_volume() {
  # Om pvesm list hittar den, använd format storage:vztmpl/filename
  if pvesm list "${TEMPLATE_STORAGE}" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${DEBIAN_TEMPLATE}"; then
    echo "${TEMPLATE_STORAGE}:vztmpl/${DEBIAN_TEMPLATE}"
    return 0
  fi

  # Fallback om template ligger i /var/lib/vz/template/cache
  local cache_path="/var/lib/vz/template/cache/${DEBIAN_TEMPLATE}"
  if [[ -f "${cache_path}" ]]; then
    echo "${TEMPLATE_STORAGE}:vztmpl/${DEBIAN_TEMPLATE}"
    return 0
  fi

  return 1
}

create_container() {
  line
  log "Skapar Debian 12 LXC-container..."

  local template_volume
  template_volume="$(resolve_template_volume)" || die "Kunde inte lösa template-volym för '${DEBIAN_TEMPLATE}'."

  pct create "${CTID}" "${template_volume}" \
    --hostname "${HOSTNAME_CT}" \
    --password "${ROOT_PASSWORD}" \
    --cores "${CPU_CORES}" \
    --memory "${RAM_MB}" \
    --swap "${SWAP_MB}" \
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}" \
    --nameserver "${DNS_SERVER}" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 0

  log "Containern ${CTID} skapades."
}

start_container() {
  line
  log "Startar container ${CTID}..."
  pct start "${CTID}"
  log "Containern startkommando skickat."
}

wait_until_container_ready() {
  line
  log "Väntar tills containern är redo..."
  wait_for_container "${CTID}" || die "Containern blev inte redo inom ${CONTAINER_READY_TIMEOUT} sekunder."
  log "Containern svarar på kommandon."
}

bootstrap_container() {
  line
  log "Uppdaterar systemet i containern..."
  pct exec "${CTID}" -- bash -lc "export DEBIAN_FRONTEND=noninteractive && apt update && apt upgrade -y"

  line
  log "Installerar baspaket i containern..."
  pct exec "${CTID}" -- bash -lc "export DEBIAN_FRONTEND=noninteractive && apt install -y curl wget git nano ca-certificates openssh-server net-tools iproute2 lsof sudo bash-completion"

  log "Baspaket installerade."
}

verify_container_network() {
  line
  log "Verifierar nätverk i containern..."

  log "IP-adresser i containern:"
  pct exec "${CTID}" -- bash -lc "ip a"

  echo
  log "Routing i containern:"
  pct exec "${CTID}" -- bash -lc "ip route"

  echo
  log "Testar internetåtkomst via IP..."
  pct exec "${CTID}" -- bash -lc "ping -c 2 -W 2 1.1.1.1" >/dev/null \
    || die "Containern saknar fungerande internetåtkomst via IP."

  log "Testar DNS-upplösning..."
  pct exec "${CTID}" -- bash -lc "ping -c 2 -W 2 google.com" >/dev/null \
    || die "Containern saknar fungerande DNS/upplösning."

  log "Nätverk och internet verifierade."
}

verify_ssh_component() {
  line
  log "Verifierar att openssh-server är installerad..."
  pct exec "${CTID}" -- bash -lc "dpkg -l | grep -q '^ii  openssh-server '" \
    || die "openssh-server verkar inte vara installerad korrekt."

  log "openssh-server är installerad."
}

print_summary() {
  line
  echo "SLUTRAPPORT"
  line
  echo "Status:             ${SUMMARY_STATUS}"
  echo "CTID:               ${CTID}"
  echo "Hostname:           ${HOSTNAME_CT}"
  echo "IP/CIDR:            ${IP_CIDR}"
  echo "Gateway:            ${GATEWAY}"
  echo "Bridge:             ${BRIDGE}"
  echo "DNS:                ${DNS_SERVER}"
  echo "RAM (MB):           ${RAM_MB}"
  echo "Swap (MB):          ${SWAP_MB}"
  echo "CPU cores:          ${CPU_CORES}"
  echo "Disk (GB):          ${DISK_GB}"
  echo "Rootfs storage:     ${ROOTFS_STORAGE}"
  echo "Template storage:   ${TEMPLATE_STORAGE}"
  echo "Debian-template:    ${DEBIAN_TEMPLATE}"
  echo
  echo "Installerade baspaket:"
  echo "  - curl"
  echo "  - wget"
  echo "  - git"
  echo "  - nano"
  echo "  - ca-certificates"
  echo "  - openssh-server"
  echo "  - net-tools"
  echo "  - iproute2"
  echo "  - lsof"
  echo "  - sudo"
  echo "  - bash-completion"
  echo
  echo "Containern är nu redo för OpenClaw (Version 2)."
  echo
  echo "Praktiska nästa steg:"
  echo "  - Öppna konsol: pct enter ${CTID}"
  echo "  - SSH till containern: ssh root@${PING_IP}"
  echo "  - Nästa fas: installera och konfigurera OpenClaw"
  line
}

main() {
  check_root
  check_proxmox_dependencies
  load_defaults
  detect_storages
  prompt_values
  validate_inputs
  print_input_summary
  confirm_to_continue
  validate_environment
  create_container
  start_container
  wait_until_container_ready
  bootstrap_container
  verify_container_network
  verify_ssh_component
  print_summary
}

main "$@"