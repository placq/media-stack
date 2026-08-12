#!/usr/bin/env bash

# This script runs on the Proxmox VE host. It creates an unprivileged LXC,
# passes through the required devices, and launches install_media.sh inside it.

set -Eeuo pipefail
umask 077

readonly PROVISIONER_VERSION="4.0.0"
readonly PROJECT_REPOSITORY="placq/media-stack"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Media Stack LXC provisioner (run on a Proxmox VE host)

Usage:
  bash proxmox_lxc.sh
  bash proxmox_lxc.sh --help

The script creates a new unprivileged Debian 13 LXC and then runs the media
installer inside that LXC. It never runs Docker or media services on the
Proxmox host itself.
EOF
}

case "${1:-}" in
    "") ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
esac

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox VE host."
[[ -t 0 ]] || die "An interactive Proxmox shell is required; do not pipe this script to bash."
if ! command -v pveversion >/dev/null || ! command -v pct >/dev/null || ! command -v pveam >/dev/null; then
    die "This is not a Proxmox VE host (pveversion/pct/pveam are missing)."
fi
[[ -e /dev/net/tun ]] || die "The Proxmox host has no /dev/net/tun device."

mkdir -p /run/lock
exec 8>/run/lock/media-stack-lxc-provisioner.lock
flock -n 8 || die "Another Media Stack LXC provisioner is already running."

TEMP_DIR=$(mktemp -d)
CT_CREATED=false
CTID=""
cleanup() {
    local status=$?
    trap - EXIT
    rm -rf -- "$TEMP_DIR"
    if ((status != 0)) && $CT_CREATED; then
        warn "Provisioning stopped after CT $CTID was created. It was NOT deleted; inspect it with: pct config $CTID"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'printf "%b[ERROR]%b Failure at line %s.\n" "$RED" "$NC" "$LINENO" >&2' ERR

prompt() {
    local variable=$1 label=$2 default=${3:-} answer
    if [[ -n "$default" ]]; then
        read -r -p "$label [$default]: " answer
        printf -v "$variable" '%s' "${answer:-$default}"
    else
        read -r -p "$label: " answer
        printf -v "$variable" '%s' "$answer"
    fi
}

yes_no() {
    local variable=$1 label=$2 default=${3:-yes} answer suffix
    if [[ "$default" == yes ]]; then suffix=Y/n; else suffix=y/N; fi
    read -r -p "$label ($suffix): " answer
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) printf -v "$variable" yes ;;
        [Nn]|[Nn][Oo]) printf -v "$variable" no ;;
        "") printf -v "$variable" '%s' "$default" ;;
        *) die "Expected yes or no." ;;
    esac
}

first_storage_for() {
    local content=$1
    pvesm status --content "$content" 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}'
}

storage_supports() {
    local storage=$1 content=$2
    pvesm status --content "$content" 2>/dev/null | awk 'NR > 1 && $1 == storage && $3 == "active" {found=1} END {exit !found}' storage="$storage"
}

valid_ipv4() {
    local address=$1 octet
    local -a octets
    IFS=. read -r -a octets <<< "$address"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        if [[ ! "$octet" =~ ^[0-9]{1,3}$ ]] || ((10#$octet > 255)); then
            return 1
        fi
    done
}

PVE_VERSION=$(pveversion | head -n1)
printf '%b\n' "$BLUE============================================================$NC"
printf '%b\n' "$BLUE      MEDIA STACK — PROXMOX LXC PROVISIONER v${PROVISIONER_VERSION}$NC"
printf '%b\n\n' "$BLUE============================================================$NC"
info "Detected $PVE_VERSION"
info "Docker and all media applications will be installed only inside the new LXC."

NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')
prompt CTID "New CT ID" "$NEXT_ID"
[[ "$CTID" =~ ^[1-9][0-9]{2,8}$ ]] || die "CT ID must be an integer of at least 100."
[[ ! -e "/etc/pve/lxc/${CTID}.conf" ]] || die "CT $CTID already exists; this provisioner never overwrites a guest."

prompt HOSTNAME "LXC hostname" media
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Invalid hostname."

DEFAULT_ROOT_STORAGE=$(first_storage_for rootdir)
[[ -n "$DEFAULT_ROOT_STORAGE" ]] || die "No active Proxmox storage supports LXC root directories."
prompt ROOT_STORAGE "Root filesystem storage" "$DEFAULT_ROOT_STORAGE"
storage_supports "$ROOT_STORAGE" rootdir || die "Storage $ROOT_STORAGE is not active or does not support rootdir content."
prompt ROOT_DISK_GB "Root filesystem size in GiB" 32
if [[ ! "$ROOT_DISK_GB" =~ ^[0-9]+$ ]] || ((ROOT_DISK_GB < 16)); then
    die "Root disk must be at least 16 GiB."
fi

prompt CORES "CPU cores" 4
prompt MEMORY_MB "Memory in MiB" 8192
prompt SWAP_MB "Swap in MiB" 512
if [[ ! "$CORES" =~ ^[0-9]+$ ]] || ((CORES < 2)); then die "At least 2 CPU cores are required."; fi
if [[ ! "$MEMORY_MB" =~ ^[0-9]+$ ]] || ((MEMORY_MB < 2048)); then die "At least 2048 MiB of memory is required."; fi
[[ "$SWAP_MB" =~ ^[0-9]+$ ]] || die "Swap must be a non-negative integer."

prompt BRIDGE "Proxmox network bridge" vmbr0
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Network bridge $BRIDGE does not exist."
prompt NETWORK_MODE "IPv4 mode (dhcp/static)" dhcp
NET0="name=eth0,bridge=${BRIDGE},firewall=1,ip6=auto"
case "$NETWORK_MODE" in
    dhcp)
        NET0+=",ip=dhcp"
        ;;
    static)
        prompt IPV4_CIDR "LXC IPv4 address with prefix (for example 192.168.1.50/24)"
        prompt IPV4_GATEWAY "IPv4 gateway (for example 192.168.1.1)"
        if [[ ! "$IPV4_CIDR" =~ ^(.+)/([0-9]|[12][0-9]|3[0-2])$ ]]; then
            die "Invalid IPv4 CIDR."
        fi
        valid_ipv4 "${BASH_REMATCH[1]}" || die "Invalid IPv4 CIDR."
        valid_ipv4 "$IPV4_GATEWAY" || die "Invalid IPv4 gateway."
        NET0+=",ip=${IPV4_CIDR},gw=${IPV4_GATEWAY}"
        ;;
    *) die "IPv4 mode must be dhcp or static." ;;
esac

prompt VLAN_TAG "Optional VLAN tag (empty means untagged)" ""
if [[ -n "$VLAN_TAG" ]]; then
    if [[ ! "$VLAN_TAG" =~ ^[0-9]+$ ]] || ((VLAN_TAG < 1 || VLAN_TAG > 4094)); then
        die "VLAN must be between 1 and 4094."
    fi
    NET0+=",tag=${VLAN_TAG}"
fi

yes_no ADD_DATA_DISK "Allocate a separate Proxmox-managed media volume" no
DATA_STORAGE=""
DATA_SIZE_GB=""
DATA_BACKUP=no
if [[ "$ADD_DATA_DISK" == yes ]]; then
    prompt DATA_STORAGE "Media volume storage" "$ROOT_STORAGE"
    storage_supports "$DATA_STORAGE" rootdir || die "Storage $DATA_STORAGE is not active or does not support LXC volumes."
    prompt DATA_SIZE_GB "Media volume size in GiB" 500
    if [[ ! "$DATA_SIZE_GB" =~ ^[0-9]+$ ]] || ((DATA_SIZE_GB < 20)); then
        die "Media volume must be at least 20 GiB."
    fi
    yes_no DATA_BACKUP "Include the media volume in Proxmox vzdump backups" no
fi

ENABLE_GPU=no
if [[ -e /dev/dri/renderD128 ]]; then
    yes_no ENABLE_GPU "Pass Intel/AMD render device to Jellyfin" yes
fi

TEMPLATE_STORAGE=$(first_storage_for vztmpl)
[[ -n "$TEMPLATE_STORAGE" ]] || die "No active storage supports vztmpl content."

printf '\nProvisioning plan:\n'
printf '  Proxmox host:    %s\n' "$(hostname)"
printf '  New guest:       CT %s (%s), unprivileged Debian 13\n' "$CTID" "$HOSTNAME"
printf '  Resources:       %s cores, %s MiB RAM, %s MiB swap\n' "$CORES" "$MEMORY_MB" "$SWAP_MB"
printf '  Root filesystem: %s:%s GiB\n' "$ROOT_STORAGE" "$ROOT_DISK_GB"
printf '  Network:         %s via %s%s\n' "$NETWORK_MODE" "$BRIDGE" "${VLAN_TAG:+, VLAN $VLAN_TAG}"
printf '  Required device: /dev/net/tun\n'
[[ "$ENABLE_GPU" == yes ]] && printf '  GPU device:      /dev/dri/renderD128\n'
[[ "$ADD_DATA_DISK" == yes ]] && printf '  Media volume:    %s:%s GiB → /opt/media-stack/data (vzdump: %s)\n' \
    "$DATA_STORAGE" "$DATA_SIZE_GB" "$DATA_BACKUP"
printf '  Proxmox host:    no Docker and no media services will be installed here\n\n'
yes_no CONFIRM "Create this LXC and launch its internal installer" no
[[ "$CONFIRM" == yes ]] || die "Cancelled before making changes."

info "Refreshing the Proxmox appliance catalog..."
pveam update
TEMPLATE_NAME=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2}' | sort -V | tail -n1)
[[ -n "$TEMPLATE_NAME" ]] || die "No Debian 13 amd64 standard template was found in the Proxmox appliance catalog."
TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
if ! pveam list "$TEMPLATE_STORAGE" | awk -v ref="$TEMPLATE_REF" '$1 == ref {found=1} END {exit !found}'; then
    info "Downloading $TEMPLATE_NAME to $TEMPLATE_STORAGE..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
else
    info "Using cached template $TEMPLATE_REF."
fi

info "Creating unprivileged CT $CTID..."
pct create "$CTID" "$TEMPLATE_REF" \
    --arch amd64 \
    --ostype debian \
    --hostname "$HOSTNAME" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --dev0 /dev/net/tun \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap "$SWAP_MB" \
    --rootfs "${ROOT_STORAGE}:${ROOT_DISK_GB}" \
    --net0 "$NET0" \
    --onboot 1 \
    --start 0 \
    --timezone host \
    --description "Media Stack LXC managed by ${PROJECT_REPOSITORY}"
CT_CREATED=true

if [[ "$ADD_DATA_DISK" == yes ]]; then
    info "Allocating the media volume..."
    if [[ "$DATA_BACKUP" == yes ]]; then
        DATA_BACKUP_FLAG=1
    else
        DATA_BACKUP_FLAG=0
    fi
    pct set "$CTID" --mp0 "${DATA_STORAGE}:${DATA_SIZE_GB},mp=/opt/media-stack/data,backup=${DATA_BACKUP_FLAG}"
fi

if [[ "$ENABLE_GPU" == yes ]]; then
    info "Passing through the render device..."
    pct set "$CTID" --dev1 "path=/dev/dri/renderD128,gid=1000,mode=0660"
fi

info "Starting CT $CTID..."
pct start "$CTID"

info "Waiting for systemd and IPv4 connectivity inside the LXC..."
READY=false
for ((_attempt = 1; _attempt <= 60; _attempt++)); do
    if pct exec "$CTID" -- bash -c '
        state=$(systemctl is-system-running 2>/dev/null || true)
        [[ "$state" == running || "$state" == degraded ]] &&
            ip -4 route show default | grep -q . &&
            test -c /dev/net/tun
    ' 2>/dev/null; then
        READY=true
        break
    fi
    sleep 2
done
$READY || die "CT $CTID did not become network-ready with a usable TUN device within 120 seconds."

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
info "Installing the minimal transfer/PTY tools inside CT $CTID..."
pct exec "$CTID" -- bash -c 'apt-get update && apt-get install -y ca-certificates curl util-linux'
if [[ -f "$SCRIPT_DIR/install_media.sh" && -f "$SCRIPT_DIR/templates/compose.yaml" ]]; then
    info "Copying this checked-out project snapshot into the LXC..."
    tar -czf "$TEMP_DIR/media-stack-source.tar.gz" \
        -C "$SCRIPT_DIR" \
        install_media.sh update_stack.sh sync_transmission_port.sh media_stack.sh templates
    pct push "$CTID" "$TEMP_DIR/media-stack-source.tar.gz" /root/media-stack-source.tar.gz --perms 0600
    pct exec "$CTID" -- mkdir -p /root/media-stack-source
    pct exec "$CTID" -- tar -xzf /root/media-stack-source.tar.gz -C /root/media-stack-source
    INSTALLER_PATH=/root/media-stack-source/install_media.sh
else
    info "Downloading one consistent project snapshot inside CT $CTID..."
    pct exec "$CTID" -- curl --fail --silent --show-error --location --retry 3 \
        "https://github.com/${PROJECT_REPOSITORY}/archive/main.tar.gz" \
        -o /root/media-stack-source.tar.gz
    pct exec "$CTID" -- mkdir -p /root/media-stack-source
    pct exec "$CTID" -- tar -xzf /root/media-stack-source.tar.gz \
        --strip-components=1 -C /root/media-stack-source
    INSTALLER_PATH=/root/media-stack-source/install_media.sh
fi

printf '\n%bThe following questions configure services INSIDE CT %s.%b\n' "$GREEN" "$CTID" "$NC"
printf '%bNo Docker command will run on the Proxmox host.%b\n\n' "$GREEN" "$NC"

set +e
pct exec "$CTID" -- env MEDIA_STACK_PROXMOX_LAUNCH=1 \
    script --quiet --return --command "bash $INSTALLER_PATH --from-proxmox" /dev/null
INSTALL_STATUS=$?
set -e
if ((INSTALL_STATUS != 0)); then
    die "The internal installer exited with status $INSTALL_STATUS. CT $CTID is preserved for diagnosis: pct enter $CTID"
fi

pct set "$CTID" --protection 1
CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
CT_MAC=$(pct config "$CTID" | sed -n 's/^net0:.*hwaddr=\([^,]*\).*/\1/p')
ok "Media Stack is running exclusively inside CT $CTID (${CT_IP:-IP unavailable})."
printf '\nManagement:\n'
[[ "$NETWORK_MODE" != dhcp ]] || printf '  DHCP reservation: reserve MAC %s for CT %s\n' "${CT_MAC:-unavailable}" "$CTID"
printf '  Enter LXC:       pct enter %s\n' "$CTID"
printf '  Stack status:    pct exec %s -- media-stack status\n' "$CTID"
printf '  Full diagnosis:  pct exec %s -- media-stack doctor\n' "$CTID"
printf '  Remove protection before intentionally deleting the CT:\n'
printf '                    pct set %s --protection 0\n' "$CTID"
