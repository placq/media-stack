#!/usr/bin/env bash

# Runs on the Proxmox VE host. Creates an unprivileged Debian LXC, passes the
# devices needed by Gluetun/Jellyfin, optionally attaches media storage and then
# executes install_media.sh inside the guest. Docker never runs on the PVE host.

set -Eeuo pipefail
umask 077

readonly PROVISIONER_VERSION="5.0.0"
readonly PROJECT_REPOSITORY="placq/media-stack"
readonly MEDIA_MOUNTPOINT="/opt/media-stack/data"
readonly DEFAULT_HOST_MEDIA_PATH="/srv/media"
readonly DEFAULT_UNPRIV_BASE_ID=100000
readonly MEDIA_CONTAINER_UID=1000
readonly MEDIA_CONTAINER_GID=1000
readonly MEDIA_HOST_UID=$((DEFAULT_UNPRIV_BASE_ID + MEDIA_CONTAINER_UID))
readonly MEDIA_HOST_GID=$((DEFAULT_UNPRIV_BASE_ID + MEDIA_CONTAINER_GID))

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Media Stack LXC provisioner (run on a Proxmox VE host)

Usage:
  bash proxmox_lxc.sh
  bash proxmox_lxc.sh --help

Creates an unprivileged Debian 13 LXC for the media stack. The guest gets:
  - nesting/keyctl for Docker
  - /dev/net/tun for Gluetun/ProtonVPN
  - optional /dev/dri/renderD128 for Jellyfin hardware transcoding
  - optional dedicated media storage

Media storage modes:
  host     bind-mount an already-mounted host filesystem/directory
  proxmox  create a Proxmox-managed mount-point volume
  none     keep /data inside the LXC root filesystem

The "host" mode refuses paths backed by the Proxmox root filesystem, validates
UID/GID mapping and hardlinks, writes a storage sentinel and installs a Docker
startup guard. This prevents a missing media disk from silently filling rootfs.
USAGE
}

case "${1:-}" in
    "") ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
esac

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox VE host."
[[ -t 0 ]] || die "An interactive Proxmox shell is required; do not pipe this script to bash."
for cmd in pveversion pct pveam pvesm pvesh; do
    command -v "$cmd" >/dev/null || die "Missing Proxmox command: $cmd"
done
[[ -c /dev/net/tun ]] || die "The Proxmox host has no /dev/net/tun character device."

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
    [[ "$default" == yes ]] && suffix=Y/n || suffix=y/N
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
    pvesm status --content "$content" 2>/dev/null |
        awk 'NR > 1 && $1 == storage && $3 == "active" {found=1} END {exit !found}' storage="$storage"
}

valid_ipv4() {
    local address=$1 octet
    local -a octets
    IFS=. read -r -a octets <<< "$address"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

validate_host_media_path() {
    local path=$1 backing_target backing_source backing_fstype
    [[ "$path" == /* ]] || die "Host media path must be absolute."
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
        die "Host media path may contain only letters, digits, /, ., _ and -."
    [[ -d "$path" ]] || die "Host media path does not exist or is not a directory: $path"
    [[ ! -L "$path" ]] || die "Host media path must not be a symlink: $path"

    backing_target=$(findmnt -T "$path" -n -o TARGET --first 2>/dev/null || true)
    backing_source=$(findmnt -T "$path" -n -o SOURCE --first 2>/dev/null || true)
    backing_fstype=$(findmnt -T "$path" -n -o FSTYPE --first 2>/dev/null || true)
    [[ -n "$backing_target" && -n "$backing_source" ]] || die "Unable to determine the filesystem backing $path."
    [[ "$backing_target" != / ]] || die "$path is backed by the Proxmox root filesystem. Mount the media disk first."
    [[ -w "$path" ]] || die "Host media path is not writable by root: $path"

    HOST_MEDIA_BACKING_TARGET=$backing_target
    HOST_MEDIA_BACKING_SOURCE=$backing_source
    HOST_MEDIA_BACKING_FSTYPE=$backing_fstype
}

prepare_host_media_path() {
    local path=$1 test_source test_target
    command -v setpriv >/dev/null || die "setpriv is required on the Proxmox host (util-linux)."

    info "Preparing media directories on $path without recursively changing existing files..."
    install -d -m 0775 -o "$MEDIA_HOST_UID" -g "$MEDIA_HOST_GID" \
        "$path/torrents" "$path/torrents/movies" "$path/torrents/tv" "$path/torrents/incomplete" \
        "$path/media" "$path/media/movies" "$path/media/tv"

    STORAGE_TOKEN=$(cat /proc/sys/kernel/random/uuid)
    printf '%s\n' "$STORAGE_TOKEN" > "$path/.media-stack-storage"
    chmod 0444 "$path/.media-stack-storage"

    test_source="$path/torrents/.media-stack-write-test-$$"
    test_target="$path/media/.media-stack-hardlink-test-$$"
    rm -f -- "$test_source" "$test_target"
    if ! setpriv --reuid="$MEDIA_HOST_UID" --regid="$MEDIA_HOST_GID" --clear-groups -- touch "$test_source"; then
        die "Mapped LXC UID $MEDIA_CONTAINER_UID (host UID $MEDIA_HOST_UID) cannot write to $path/torrents."
    fi
    if ! setpriv --reuid="$MEDIA_HOST_UID" --regid="$MEDIA_HOST_GID" --clear-groups -- ln "$test_source" "$test_target"; then
        rm -f -- "$test_source" "$test_target"
        die "Hardlinks do not work between torrents and media. Keep both on one filesystem."
    fi
    rm -f -- "$test_source" "$test_target"
}

install_host_media_guard() {
    local escaped_token
    escaped_token=$(printf '%q' "$STORAGE_TOKEN")
    info "Installing Docker startup guard for the media filesystem..."
    pct exec "$CTID" -- bash -c "
        set -Eeuo pipefail
        install -d -m 0755 /usr/local/sbin /etc/systemd/system/docker.service.d
        cat > /usr/local/sbin/media-stack-storage-guard <<'GUARD'
#!/bin/sh
set -eu
expected=$escaped_token
actual=\$(cat '$MEDIA_MOUNTPOINT/.media-stack-storage' 2>/dev/null || true)
if [ \"\$actual\" != \"\$expected\" ]; then
    echo 'Media Stack storage guard: expected media filesystem is not mounted at $MEDIA_MOUNTPOINT.' >&2
    exit 1
fi
GUARD
        chmod 0755 /usr/local/sbin/media-stack-storage-guard
        cat > /etc/systemd/system/docker.service.d/10-media-stack-storage.conf <<'DROPIN'
[Service]
ExecStartPre=/usr/local/sbin/media-stack-storage-guard
DROPIN
        systemctl daemon-reload
        /usr/local/sbin/media-stack-storage-guard
    "
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
prompt ROOT_DISK_GB "Root filesystem size in GiB" 64
if [[ ! "$ROOT_DISK_GB" =~ ^[0-9]+$ ]] || ((ROOT_DISK_GB < 24)); then
    die "Root disk must be at least 24 GiB."
fi

prompt CORES "CPU cores" 4
prompt MEMORY_MB "Memory in MiB" 8192
prompt SWAP_MB "Swap in MiB" 512
[[ "$CORES" =~ ^[0-9]+$ ]] && ((CORES >= 2)) || die "At least 2 CPU cores are required."
[[ "$MEMORY_MB" =~ ^[0-9]+$ ]] && ((MEMORY_MB >= 2048)) || die "At least 2048 MiB of memory is required."
[[ "$SWAP_MB" =~ ^[0-9]+$ ]] || die "Swap must be a non-negative integer."

prompt BRIDGE "Proxmox network bridge" vmbr0
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Network bridge $BRIDGE does not exist."
prompt NETWORK_MODE "IPv4 mode (dhcp/static)" dhcp
NET0="name=eth0,bridge=${BRIDGE},firewall=1,ip6=auto"
case "$NETWORK_MODE" in
    dhcp) NET0+=",ip=dhcp" ;;
    static)
        prompt IPV4_CIDR "LXC IPv4 address with prefix (for example 192.168.1.50/24)"
        prompt IPV4_GATEWAY "IPv4 gateway (for example 192.168.1.1)"
        [[ "$IPV4_CIDR" =~ ^(.+)/([0-9]|[12][0-9]|3[0-2])$ ]] || die "Invalid IPv4 CIDR."
        valid_ipv4 "${BASH_REMATCH[1]}" || die "Invalid IPv4 CIDR."
        valid_ipv4 "$IPV4_GATEWAY" || die "Invalid IPv4 gateway."
        NET0+=",ip=${IPV4_CIDR},gw=${IPV4_GATEWAY}"
        ;;
    *) die "IPv4 mode must be dhcp or static." ;;
esac

prompt VLAN_TAG "Optional VLAN tag (empty means untagged)" ""
if [[ -n "$VLAN_TAG" ]]; then
    [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] && ((VLAN_TAG >= 1 && VLAN_TAG <= 4094)) || die "VLAN must be between 1 and 4094."
    NET0+=",tag=${VLAN_TAG}"
fi

DEFAULT_MEDIA_MODE=none
if [[ -d "$DEFAULT_HOST_MEDIA_PATH" ]]; then
    DEFAULT_MEDIA_TARGET=$(findmnt -T "$DEFAULT_HOST_MEDIA_PATH" -n -o TARGET --first 2>/dev/null || true)
    [[ -n "$DEFAULT_MEDIA_TARGET" && "$DEFAULT_MEDIA_TARGET" != / ]] && DEFAULT_MEDIA_MODE=host
fi

prompt MEDIA_STORAGE_MODE "Media storage mode (host/proxmox/none)" "$DEFAULT_MEDIA_MODE"
HOST_DATA_PATH=""; HOST_MEDIA_BACKING_TARGET=""; HOST_MEDIA_BACKING_SOURCE=""; HOST_MEDIA_BACKING_FSTYPE=""
DATA_STORAGE=""; DATA_SIZE_GB=""; DATA_BACKUP=no; STORAGE_TOKEN=""
case "$MEDIA_STORAGE_MODE" in
    host)
        prompt HOST_DATA_PATH "Existing host media path" "$DEFAULT_HOST_MEDIA_PATH"
        validate_host_media_path "$HOST_DATA_PATH"
        HOST_DATA_PATH=$(readlink -f -- "$HOST_DATA_PATH")
        validate_host_media_path "$HOST_DATA_PATH"
        prepare_host_media_path "$HOST_DATA_PATH"
        ;;
    proxmox)
        prompt DATA_STORAGE "Media volume storage" "$ROOT_STORAGE"
        storage_supports "$DATA_STORAGE" rootdir || die "Storage $DATA_STORAGE is not active or does not support LXC volumes."
        prompt DATA_SIZE_GB "Media volume size in GiB" 500
        [[ "$DATA_SIZE_GB" =~ ^[0-9]+$ ]] && ((DATA_SIZE_GB >= 20)) || die "Media volume must be at least 20 GiB."
        yes_no DATA_BACKUP "Include the media volume in Proxmox vzdump backups" no
        ;;
    none) ;;
    *) die "Media storage mode must be host, proxmox or none." ;;
esac

ENABLE_GPU=no
if [[ -c /dev/dri/renderD128 ]]; then
    yes_no ENABLE_GPU "Pass /dev/dri/renderD128 to Jellyfin for hardware transcoding" yes
fi

TEMPLATE_STORAGE=$(first_storage_for vztmpl)
[[ -n "$TEMPLATE_STORAGE" ]] || die "No active storage supports vztmpl content."

printf '\nProvisioning plan:\n'
printf '  Proxmox host:    %s\n' "$(hostname)"
printf '  New guest:       CT %s (%s), unprivileged Debian 13\n' "$CTID" "$HOSTNAME"
printf '  Resources:       %s cores, %s MiB RAM, %s MiB swap\n' "$CORES" "$MEMORY_MB" "$SWAP_MB"
printf '  Root filesystem: %s:%s GiB\n' "$ROOT_STORAGE" "$ROOT_DISK_GB"
printf '  Network:         %s via %s%s\n' "$NETWORK_MODE" "$BRIDGE" "${VLAN_TAG:+, VLAN $VLAN_TAG}"
printf '  VPN device:      /dev/net/tun (Gluetun)\n'
[[ "$ENABLE_GPU" == yes ]] && printf '  GPU device:      /dev/dri/renderD128\n'
case "$MEDIA_STORAGE_MODE" in
    host)
        printf '  Media storage:   host bind mount %s → %s\n' "$HOST_DATA_PATH" "$MEDIA_MOUNTPOINT"
        printf '  Backing fs:      %s (%s, %s)\n' "$HOST_MEDIA_BACKING_SOURCE" "$HOST_MEDIA_BACKING_FSTYPE" "$HOST_MEDIA_BACKING_TARGET"
        printf '  LXC data UID:    %s:%s → host %s:%s\n' "$MEDIA_CONTAINER_UID" "$MEDIA_CONTAINER_GID" "$MEDIA_HOST_UID" "$MEDIA_HOST_GID"
        printf '  vzdump media:    no (bind mount)\n'
        ;;
    proxmox)
        printf '  Media storage:   %s:%s GiB → %s (vzdump: %s)\n' "$DATA_STORAGE" "$DATA_SIZE_GB" "$MEDIA_MOUNTPOINT" "$DATA_BACKUP"
        ;;
    none) printf '  Media storage:   LXC root filesystem (no separate media volume)\n' ;;
esac
printf '  PVE host:        no Docker and no media services installed here\n\n'
yes_no CONFIRM "Create this LXC and launch its internal installer" no
[[ "$CONFIRM" == yes ]] || die "Cancelled before making changes."

info "Refreshing the Proxmox appliance catalog..."
pveam update
TEMPLATE_NAME=$(pveam available --section system |
    awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2}' |
    sort -V | tail -n1)
[[ -n "$TEMPLATE_NAME" ]] || die "No Debian 13 amd64 standard template was found."
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

case "$MEDIA_STORAGE_MODE" in
    host)
        info "Bind-mounting $HOST_DATA_PATH into CT $CTID at $MEDIA_MOUNTPOINT..."
        pct set "$CTID" --mp0 "${HOST_DATA_PATH},mp=${MEDIA_MOUNTPOINT},backup=0"
        ;;
    proxmox)
        info "Allocating the media volume..."
        [[ "$DATA_BACKUP" == yes ]] && DATA_BACKUP_FLAG=1 || DATA_BACKUP_FLAG=0
        pct set "$CTID" --mp0 "${DATA_STORAGE}:${DATA_SIZE_GB},mp=${MEDIA_MOUNTPOINT},backup=${DATA_BACKUP_FLAG}"
        ;;
esac

if [[ "$ENABLE_GPU" == yes ]]; then
    info "Passing through the render device..."
    pct set "$CTID" --dev1 "path=/dev/dri/renderD128,gid=1000,mode=0660"
fi

info "Starting CT $CTID..."
pct start "$CTID"

info "Waiting for systemd, IPv4 connectivity and TUN inside the LXC..."
READY=false
for ((_attempt = 1; _attempt <= 60; _attempt++)); do
    if pct exec "$CTID" -- bash -c '
        state=$(systemctl is-system-running 2>/dev/null || true)
        [[ "$state" == running || "$state" == degraded ]] &&
            ip -4 route show default | grep -q . && test -c /dev/net/tun
    ' 2>/dev/null; then
        READY=true
        break
    fi
    sleep 2
done
$READY || die "CT $CTID did not become network-ready with a usable TUN device within 120 seconds."

if [[ "$MEDIA_STORAGE_MODE" == host ]]; then
    info "Verifying the expected media filesystem inside CT $CTID..."
    pct exec "$CTID" -- env EXPECTED_MEDIA_TOKEN="$STORAGE_TOKEN" MEDIA_MOUNTPOINT="$MEDIA_MOUNTPOINT" bash -c '
        set -Eeuo pipefail
        actual=$(cat "$MEDIA_MOUNTPOINT/.media-stack-storage" 2>/dev/null || true)
        [[ "$actual" == "$EXPECTED_MEDIA_TOKEN" ]] || { echo "Expected media filesystem is not mounted." >&2; exit 1; }
        test -d "$MEDIA_MOUNTPOINT/torrents"
        test -d "$MEDIA_MOUNTPOINT/media"
    '
    install_host_media_guard
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
info "Installing minimal transfer/PTY tools inside CT $CTID..."
pct exec "$CTID" -- bash -c 'apt-get update && apt-get install -y ca-certificates curl util-linux'
if [[ -f "$SCRIPT_DIR/install_media.sh" && -f "$SCRIPT_DIR/templates/compose.yaml" ]]; then
    info "Copying this checked-out project snapshot into the LXC..."
    tar -czf "$TEMP_DIR/media-stack-source.tar.gz" -C "$SCRIPT_DIR" \
        install_media.sh update_stack.sh sync_transmission_port.sh media_stack.sh templates
    pct push "$CTID" "$TEMP_DIR/media-stack-source.tar.gz" /root/media-stack-source.tar.gz --perms 0600
    pct exec "$CTID" -- mkdir -p /root/media-stack-source
    pct exec "$CTID" -- tar -xzf /root/media-stack-source.tar.gz -C /root/media-stack-source
    INSTALLER_PATH=/root/media-stack-source/install_media.sh
else
    info "Downloading one consistent project snapshot inside CT $CTID..."
    pct exec "$CTID" -- curl --fail --silent --show-error --location --retry 3 \
        "https://github.com/${PROJECT_REPOSITORY}/archive/main.tar.gz" -o /root/media-stack-source.tar.gz
    pct exec "$CTID" -- mkdir -p /root/media-stack-source
    pct exec "$CTID" -- tar -xzf /root/media-stack-source.tar.gz --strip-components=1 -C /root/media-stack-source
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
if [[ "$MEDIA_STORAGE_MODE" == host ]]; then
    ok "Media data is stored on $HOST_DATA_PATH and exposed inside the LXC as $MEDIA_MOUNTPOINT."
    info "Docker will refuse to start if the expected host media filesystem is missing or replaced."
fi
printf '\nManagement:\n'
[[ "$NETWORK_MODE" != dhcp ]] || printf '  DHCP reservation: reserve MAC %s for CT %s\n' "${CT_MAC:-unavailable}" "$CTID"
printf '  Enter LXC:       pct enter %s\n' "$CTID"
printf '  Stack status:    pct exec %s -- media-stack status\n' "$CTID"
printf '  Full diagnosis:  pct exec %s -- media-stack doctor\n' "$CTID"
printf '  Remove protection before intentionally deleting the CT:\n'
printf '                    pct set %s --protection 0\n' "$CTID"
