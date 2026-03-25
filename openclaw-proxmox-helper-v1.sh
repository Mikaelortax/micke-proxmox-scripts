#!/usr/bin/env bash
set -Ee
set -u
set -o pipefail

# ============================================================
# OpenClaw Proxmox Helper Script - Version 1.1
# Syfte:
# - Skapa en Debian 12 LXC på Proxmox
# - Visa tydlig vägledning för CTID, IP, storage och templates
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
  echo "----------------------------------------------------------------"
}

section() {
  echo
  line
  echo "$1"
  line
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
# Grundhjälpare
# -----------------------------
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

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

validate_numeric() {
  local value="$1"
  local label="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} måste vara ett heltal."
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

vmid_exists_any() {
  local id="$1"
  qm status "${id}" >/dev/null 2>&1 || pct status "${id}" >/dev/null 2>&1
}

next_free_ctid() {
  local start="${1:-100}"
  local current="$start"
  while vmid_exists_any "${current}"; do
    current=$((current + 1))
  done
  echo "${current}"
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

# -----------------------------
# Formatering / hjälp
# -----------------------------
bytes_to_human() {
  local bytes="${1:-0}"
  if ! [[ "${bytes}" =~ ^[0-9]+$ ]]; then
    echo "${bytes}"
    return 0
  fi

  awk -v b="${bytes}" '
    function human(x) {
      s="B KB MB GB TB PB";
      n=split(s,arr," ");
      i=1;
      while (x>=1024 && i<n) { x/=1024; i++ }
      if (i==1) printf "%.0f %s", x, arr[i];
      else printf "%.1f %s", x, arr[i];
    }
    BEGIN { human(b) }
  '
}

print_kv() {
  printf "  %-22s %s\n" "$1" "$2"
}

# -----------------------------
# Proxmox-insikt / listningar
# -----------------------------
show_existing_cts_and_vms() {
  section "Befintliga containrar och virtuella maskiner"

  if command_exists pct; then
    echo "LXC-containrar:"
    if pct list 2>/dev/null | awk 'NR>1 {print}' | grep -q .; then
      printf "  %-8s %-24s %-12s\n" "VMID" "NAMN" "STATUS"
      pct list 2>/dev/null | awk 'NR>1 {printf "  %-8s %-24s %-12s\n", $1, $3, $2}'
    else
      echo "  Inga LXC-containrar hittades."
    fi
  fi

  echo
  echo "Virtuella maskiner:"
  if command_exists qm && qm list 2>/dev/null | awk 'NR>1 {print}' | grep -q .; then
    printf "  %-8s %-24s %-12s\n" "VMID" "NAMN" "STATUS"
    qm list 2>/dev/null | awk 'NR>1 {printf "  %-8s %-24s %-12s\n", $1, $2, $3}'
  else
    echo "  Inga virtuella maskiner hittades eller qm är inte tillgängligt."
  fi

  echo
  echo "Föreslaget nästa lediga CTID från ${DEFAULT_CTID}: $(next_free_ctid "${DEFAULT_CTID}")"
}

show_used_ips_from_configs() {
  section "IP-adresser som hittades i befintliga Proxmox-konfigurationer"

  local found=0

  # LXC-configs
  if [[ -d /etc/pve/lxc ]]; then
    while IFS= read -r file; do
      local vmid
      vmid="$(basename "${file}" .conf)"
      awk -v vmid="${vmid}" '
        match($0, /ip=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+)/, m) {
          printf "  LXC %-6s %s\n", vmid, m[1]
        }
      ' "${file}"
    done < <(find /etc/pve/lxc -maxdepth 1 -type f -name '*.conf' | sort)
  fi

  # QEMU-configs
  if [[ -d /etc/pve/qemu-server ]]; then
    while IFS= read -r file; do
      local vmid
      vmid="$(basename "${file}" .conf)"
      awk -v vmid="${vmid}" '
        match($0, /ip=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+)/, m) {
          printf "  VM  %-6s %s\n", vmid, m[1]
        }
      ' "${file}"
    done < <(find /etc/pve/qemu-server -maxdepth 1 -type f -name '*.conf' | sort)
  fi

  local lines
  lines="$(
    {
      if [[ -d /etc/pve/lxc ]]; then
        grep -RhoE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' /etc/pve/lxc 2>/dev/null || true
      fi
      if [[ -d /etc/pve/qemu-server ]]; then
        grep -RhoE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' /etc/pve/qemu-server 2>/dev/null || true
      fi
    } | sed 's/^ip=//' | sort -Vu
  )"

  if [[ -n "${lines}" ]]; then
    echo
    echo "Unika IP-adresser i konfig:"
    while IFS= read -r ip; do
      [[ -n "${ip}" ]] && echo "  - ${ip}"
      found=1
    done <<< "${lines}"
  fi

  if [[ "${found}" -eq 0 && -z "${lines}" ]]; then
    echo "  Inga IP-adresser kunde läsas ut från befintliga konfigfiler."
  fi
}

show_network_bridges() {
  section "Tillgängliga nätverksbroar på hosten"
  if ip -o link show type bridge >/dev/null 2>&1; then
    ip -o link show type bridge | awk -F': ' '{print "  - " $2}'
  else
    echo "  Inga bridges kunde listas."
  fi
}

show_storage_table_for_content() {
  local content="$1"
  local title="$2"

  section "${title}"

  local output
  output="$(pvesm status -content "${content}" 2>/dev/null | awk 'NR>1 {print}')"

  if [[ -z "${output}" ]]; then
    echo "  Inga storages hittades för content-typen '${content}'."
    return 0
  fi

  printf "  %-22s %-10s %-14s %-14s %-14s\n" "STORAGE" "TYP" "TOTALT" "ANVÄNT" "LEDIGT"

  while read -r name type status total used avail rest; do
    [[ -z "${name:-}" ]] && continue
    printf "  %-22s %-10s %-14s %-14s %-14s\n" \
      "${name}" \
      "${type}" \
      "$(bytes_to_human "${total}")" \
      "$(bytes_to_human "${used}")" \
      "$(bytes_to_human "${avail}")"
  done <<< "${output}"

  echo
  echo "  Content-typ:"
  case "${content}" in
    images) echo "  - images = containerdiskar / rootfs" ;;
    vztmpl) echo "  - vztmpl = LXC-templates" ;;
    *) echo "  - ${content}" ;;
  esac
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
  local matches
  matches="$(pvesm list "${storage}" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Ei 'debian-12.*(amd64|standard)|debian.*12' || true)"

  if [[ -n "${matches}" ]]; then
    echo "${matches}" | head -n1
    return 0
  fi

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

show_template_choices() {
  local storage="$1"

  section "Hittade Debian 12-templates i storage '${storage}'"

  local matches
  matches="$(print_template_choices "${storage}" || true)"

  if [[ -n "${matches}" ]]; then
    while IFS= read -r tpl; do
      [[ -n "${tpl}" ]] && echo "  - ${tpl}"
    done <<< "${matches}"
  else
    echo "  Inga Debian 12-templates hittades via pvesm list."
    echo "  Om du redan har template-filen lokalt kan scriptet fortfarande hitta den via cache."
  fi

  local cache_dir="/var/lib/vz/template/cache"
  if [[ -d "${cache_dir}" ]]; then
    local cache_matches
    cache_matches="$(find "${cache_dir}" -maxdepth 1 -type f | grep -Ei 'debian-12.*(amd64|standard)|debian.*12' | xargs -r -n1 basename || true)"
    if [[ -n "${cache_matches}" ]]; then
      echo
      echo "  Matchande Debian 12-templates i lokal cache:"
      while IFS= read -r tpl; do
        [[ -n "${tpl}" ]] && echo "  - ${tpl}"
      done <<< "${cache_matches}"
    fi
  fi
}

# -----------------------------
# Kontroller
# -----------------------------
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
  section "Kontroll av vald IP-adress"
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
    CTID="$(prompt_with_default "Ange ett annat CTID" "$(next_free_ctid "$((CTID + 1))")")"
    validate_numeric "${CTID}" "CTID"
  done
}

validate_environment() {
  section "Förkontroller"
  log "Kontrollerar Proxmox-miljön..."

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

# -----------------------------
# Guidat promptflöde
# -----------------------------
show_intro() {
  section "OpenClaw Proxmox Helper Script - Version 1.1"
  echo "Det här scriptet hjälper dig att skapa en Debian 12 LXC för OpenClaw."
  echo "Du får nu en tydlig översikt över:"
  echo "  - befintliga CTID och namn"
  echo "  - använda IP-adresser som hittas i Proxmox-konfig"
  echo "  - tillgängliga nätverksbroar"
  echo "  - rootfs storage med ledigt utrymme"
  echo "  - template storage med ledigt utrymme"
  echo "  - Debian 12-templates som hittas"
  echo
  echo "Tryck Enter på en fråga för att använda standardvärdet."
}

prompt_values() {
  show_intro
  show_existing_cts_and_vms
  show_used_ips_from_configs
  show_network_bridges
  show_storage_table_for_content "images" "Tillgänglig rootfs storage (containerdiskar)"
  show_storage_table_for_content "vztmpl" "Tillgänglig template storage (LXC-templates)"

  section "Välj CTID och grundidentitet"
  echo "Tips:"
  echo "  - CTID måste vara ledigt."
  echo "  - Standard är ${DEFAULT_CTID}, men du kan ange något annat."
  echo "  - Föreslaget nästa lediga CTID: $(next_free_ctid "${DEFAULT_CTID}")"
  echo
  CTID="$(prompt_with_default "CTID" "$(next_free_ctid "${DEFAULT_CTID}")")"
  HOSTNAME_CT="$(prompt_with_default "Hostname" "${DEFAULT_HOSTNAME}")"

  section "Välj nätverksinställningar"
  echo "Tips:"
  echo "  - IP/CIDR ska vara statisk adress för containern, t.ex. 192.168.0.206/24"
  echo "  - Gateway är normalt din router, t.ex. 192.168.0.1"
  echo "  - Bridge är normalt vmbr0 om du inte använder annat nät"
  echo
  IP_CIDR="$(prompt_with_default "IP/CIDR" "${DEFAULT_IP_CIDR}")"
  GATEWAY="$(prompt_with_default "Gateway" "${DEFAULT_GATEWAY}")"
  BRIDGE="$(prompt_with_default "Bridge" "${DEFAULT_BRIDGE}")"
  DNS_SERVER="$(prompt_with_default "DNS" "${DEFAULT_DNS}")"

  section "Välj resurser för containern"
  echo "Tips:"
  echo "  - RAM och CPU styr hur mycket resurser containern får"
  echo "  - Diskstorleken gäller rootfs-disken på vald storage"
  echo
  RAM_MB="$(prompt_with_default "RAM (MB)" "${DEFAULT_RAM}")"
  SWAP_MB="$(prompt_with_default "Swap (MB)" "${DEFAULT_SWAP}")"
  CPU_CORES="$(prompt_with_default "CPU cores" "${DEFAULT_CPU}")"
  DISK_GB="$(prompt_with_default "Diskstorlek (GB)" "${DEFAULT_DISK}")"

  section "Välj rootfs storage"
  echo "Rootfs storage är där själva containerdisken ska ligga."
  echo "Vanligt val är local-lvm om den finns."
  echo
  ROOTFS_STORAGE="$(prompt_with_default "Rootfs storage" "${ROOTFS_STORAGE_DEFAULT}")"

  section "Välj template storage"
  echo "Template storage är där Debian 12-mallen ligger lagrad."
  echo "Vanligt val är local om templates ligger där."
  echo
  TEMPLATE_STORAGE="$(prompt_with_default "Template storage" "${TEMPLATE_STORAGE_DEFAULT}")"

  DEBIAN_TEMPLATE_DEFAULT="$(detect_debian_template "${TEMPLATE_STORAGE}" || true)"
  show_template_choices "${TEMPLATE_STORAGE}"

  section "Välj Debian 12-template"
  echo "Här väljer du vilken Debian 12 LXC-template som ska användas."
  echo
  if [[ -n "${DEBIAN_TEMPLATE_DEFAULT}" ]]; then
    DEBIAN_TEMPLATE="$(prompt_with_default "Debian 12-template" "${DEBIAN_TEMPLATE_DEFAULT}")"
  else
    read -r -p "Debian 12-template: " DEBIAN_TEMPLATE
  fi

  section "Ange root-lösenord för containern"
  echo "Detta blir lösenordet för root-kontot inne i den nya containern."
  echo
  prompt_password_twice
  echo
}

print_input_summary() {
  section "Sammanfattning av valda värden"
  print_kv "CTID" "${CTID}"
  print_kv "Hostname" "${HOSTNAME_CT}"
  print_kv "IP/CIDR" "${IP_CIDR}"
  print_kv "Gateway" "${GATEWAY}"
  print_kv "Bridge" "${BRIDGE}"
  print_kv "DNS" "${DNS_SERVER}"
  print_kv "RAM (MB)" "${RAM_MB}"
  print_kv "Swap (MB)" "${SWAP_MB}"
  print_kv "CPU cores" "${CPU_CORES}"
  print_kv "Disk (GB)" "${DISK_GB}"
  print_kv "Rootfs storage" "${ROOTFS_STORAGE}"
  print_kv "Template storage" "${TEMPLATE_STORAGE}"
  print_kv "Debian-template" "${DEBIAN_TEMPLATE}"
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

# -----------------------------
# Template-resolve och skapande
# -----------------------------
resolve_template_volume() {
  if pvesm list "${TEMPLATE_STORAGE}" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${DEBIAN_TEMPLATE}"; then
    echo "${TEMPLATE_STORAGE}:vztmpl/${DEBIAN_TEMPLATE}"
    return 0
  fi

  local cache_path="/var/lib/vz/template/cache/${DEBIAN_TEMPLATE}"
  if [[ -f "${cache_path}" ]]; then
    echo "${TEMPLATE_STORAGE}:vztmpl/${DEBIAN_TEMPLATE}"
    return 0
  fi

  return 1
}

create_container() {
  section "Skapar Debian 12 LXC-container"

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
  section "Startar containern"
  pct start "${CTID}"
  log "Containern ${CTID} har startats."
}

wait_until_container_ready() {
  section "Väntar tills containern är redo"
  wait_for_container "${CTID}" || die "Containern blev inte redo inom ${CONTAINER_READY_TIMEOUT} sekunder."
  log "Containern svarar på kommandon."
}

bootstrap_container() {
  section "Installerar grundmiljö i containern"

  log "Kör apt update och apt upgrade..."
  pct exec "${CTID}" -- bash -lc "export DEBIAN_FRONTEND=noninteractive && apt update && apt upgrade -y"

  log "Installerar baspaket..."
  pct exec "${CTID}" -- bash -lc "export DEBIAN_FRONTEND=noninteractive && apt install -y curl wget git nano ca-certificates openssh-server net-tools iproute2 lsof sudo bash-completion"

  log "Baspaket installerade."
}

verify_container_network() {
  section "Verifierar nätverk i containern"

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
  section "Verifierar SSH-komponenten"
  pct exec "${CTID}" -- bash -lc "dpkg -l | grep -q '^ii  openssh-server '" \
    || die "openssh-server verkar inte vara installerad korrekt."

  log "openssh-server är installerad."
}

print_summary() {
  section "SLUTRAPPORT"
  print_kv "Status" "${SUMMARY_STATUS}"
  print_kv "CTID" "${CTID}"
  print_kv "Hostname" "${HOSTNAME_CT}"
  print_kv "IP/CIDR" "${IP_CIDR}"
  print_kv "Gateway" "${GATEWAY}"
  print_kv "Bridge" "${BRIDGE}"
  print_kv "DNS" "${DNS_SERVER}"
  print_kv "RAM (MB)" "${RAM_MB}"
  print_kv "Swap (MB)" "${SWAP_MB}"
  print_kv "CPU cores" "${CPU_CORES}"
  print_kv "Disk (GB)" "${DISK_GB}"
  print_kv "Rootfs storage" "${ROOTFS_STORAGE}"
  print_kv "Template storage" "${TEMPLATE_STORAGE}"
  print_kv "Debian-template" "${DEBIAN_TEMPLATE}"

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
