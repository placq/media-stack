#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

readonly INSTALLER_VERSION="4.0.0"
readonly DEFAULT_INSTALL_DIR="/opt/media-stack"
readonly PROJECT_REPOSITORY="placq/media-stack"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Media Stack installer for Debian/Ubuntu LXC

Usage:
  sudo bash install_media.sh
  sudo bash install_media.sh --preflight
  bash install_media.sh --help

Options:
  --preflight  Check the host/LXC without changing it.
  --help       Show this help.

The normal installation is interactive and safe to run again. Existing
credentials are retained when a secret prompt is left empty.
EOF
}

PREFLIGHT_ONLY=false
case "${1:-}" in
    "") ;;
    --preflight) PREFLIGHT_ONLY=true ;;
    --from-proxmox)
        [[ "${MEDIA_STACK_PROXMOX_LAUNCH:-}" == 1 ]] || die "--from-proxmox is reserved for proxmox_lxc.sh."
        ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
esac

[[ $EUID -eq 0 ]] || die "Run this installer as root (or with sudo)."
if ! $PREFLIGHT_ONLY && [[ "${MEDIA_STACK_PROXMOX_LAUNCH:-}" != 1 ]]; then
    [[ -t 0 ]] || die "An interactive terminal is required. Download the script first; do not pipe it to bash."
fi
[[ "$(ps -p 1 -o comm=)" == systemd ]] || die "systemd must be PID 1."

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "Supported systems: Debian and Ubuntu." ;;
esac
[[ -n "${VERSION_CODENAME:-}" ]] || die "Unable to determine the OS codename."

VIRT=$(systemd-detect-virt --container 2>/dev/null || true)
[[ "$VIRT" == lxc ]] ||
    die "This installer runs only inside an LXC (detected: ${VIRT:-none}). On the Proxmox host use proxmox_lxc.sh."
[[ -c /dev/net/tun && -r /dev/net/tun && -w /dev/net/tun ]] ||
    die "LXC has no usable /dev/net/tun. On Proxmox enable nesting,keyctl and pass /dev/net/tun, then stop/start the CT."
[[ -c /dev/net/tun ]] || die "/dev/net/tun is required by Gluetun and Tailscale."

AVAILABLE_MEMORY_MB=$(awk '/MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
((AVAILABLE_MEMORY_MB >= 1800)) || log_warn "Only ${AVAILABLE_MEMORY_MB} MiB of memory is currently available; 4 GiB or more is recommended."

ROOT_FREE_MB=$(df -Pm / | awk 'NR == 2 {print $4}')
((ROOT_FREE_MB >= 8192)) || log_warn "Less than 8 GiB is free on the root filesystem. Image pulls may fail."

if $PREFLIGHT_ONLY; then
    command -v ip >/dev/null || die "Missing iproute2 (the ip command)."
    ip -4 route show default | grep -q . || die "No IPv4 default route was found."
    log_success "Preflight passed: ${PRETTY_NAME:-$ID}, virtualization=${VIRT:-none}, TUN usable, ${AVAILABLE_MEMORY_MB} MiB available."
    exit 0
fi

mkdir -p /run/lock
exec 8>/run/lock/media-stack-installer.lock
flock -n 8 || die "Another Media Stack installation is already running."

TEMP_DIR=$(mktemp -d)
JELLYSEERR_WAS_RUNNING=false
JELLYSEERR_MIGRATED=false
DEPLOYMENT_STARTED=false
DEPLOYMENT_FINISHED=false
ROLLBACK_ARCHIVE=""
INSTALL_DIR=""

cleanup() {
    local status=$?
    trap - EXIT
    rm -rf -- "$TEMP_DIR"
    if ((status != 0)); then
        printf '%b[ERROR]%b Installation failed.\n' "$RED" "$NC" >&2
        if $DEPLOYMENT_STARTED && ! $DEPLOYMENT_FINISHED && [[ -n "$ROLLBACK_ARCHIVE" && -s "$ROLLBACK_ARCHIVE" ]]; then
            log_warn "Restoring the previous generated configuration."
            rm -f "$INSTALL_DIR/.env" "$INSTALL_DIR/compose.yaml" "$INSTALL_DIR/compose.openvpn.yaml" \
                "$INSTALL_DIR/compose.wireguard.yaml" "$INSTALL_DIR/compose.gpu.yaml" \
                "$INSTALL_DIR/update_stack.sh" "$INSTALL_DIR/sync_transmission_port.sh" \
                "$INSTALL_DIR/media_stack.sh" "$INSTALL_DIR/important_info.md" \
                "$INSTALL_DIR/config/newt/config.json"
            rm -rf -- "$INSTALL_DIR/secrets"
            tar -xzf "$ROLLBACK_ARCHIVE" -C "$INSTALL_DIR" || true
            (
                if cd "$INSTALL_DIR"; then
                    docker compose up -d --remove-orphans
                fi
            ) || true
        fi
        if $JELLYSEERR_WAS_RUNNING && command -v docker >/dev/null; then
            docker start jellyseerr >/dev/null 2>&1 || true
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'printf "%b[ERROR]%b Failure at line %s.\n" "$RED" "$NC" "$LINENO" >&2' ERR

log_info "Installing prerequisites inside the LXC..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -q ca-certificates curl findutils gnupg iproute2 jq openssl tar unattended-upgrades util-linux

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades.service >/dev/null

install_docker() {
    log_info "Installing Docker Engine from Docker's signed APT repository..."
    conflicting_packages=()
    for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii' && conflicting_packages+=("$package")
    done
    if ((${#conflicting_packages[@]} > 0)); then
        log_warn "Replacing conflicting distribution packages with Docker CE: ${conflicting_packages[*]}"
        apt-get remove -y "${conflicting_packages[@]}"
    fi
    install -m 0755 -d /etc/apt/keyrings
    curl --fail --silent --show-error --location --retry 3 \
        "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    install_docker
fi
systemctl enable --now docker >/dev/null
docker info >/dev/null 2>&1 || die "The Docker daemon is unavailable."

log_info "Verifying Docker support inside the container..."
docker run --rm --pull=missing hello-world >/dev/null ||
    die "Docker cannot start a container. In Proxmox enable nesting and keyctl, then fully stop/start the LXC."

read_env() {
    local key=$1 file=$2 line value
    [[ -f "$file" ]] || return 0
    line=$(awk -v key="$key" 'index($0, key "=") == 1 {print; exit}' "$file")
    [[ -n "$line" ]] || return 0
    value=${line#*=}
    if [[ "$value" == "'"*"'" && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    elif [[ "$value" == '"'*'"' && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    fi
    printf '%s' "$value"
}

prompt_value() {
    local variable=$1 label=$2 default=${3:-} answer
    if [[ -n "$default" ]]; then
        read -r -p "$label [$default]: " answer
        printf -v "$variable" '%s' "${answer:-$default}"
    else
        read -r -p "$label: " answer
        printf -v "$variable" '%s' "$answer"
    fi
}

prompt_secret() {
    local variable=$1 label=$2 current=${3:-} answer
    if [[ -n "$current" ]]; then
        read -r -s -p "$label [Enter keeps the existing value]: " answer
    else
        read -r -s -p "$label: " answer
    fi
    printf '\n'
    printf -v "$variable" '%s' "${answer:-$current}"
}

prompt_yes_no() {
    local variable=$1 label=$2 default=${3:-yes} answer suffix
    if [[ "$default" == yes ]]; then suffix="Y/n"; else suffix="y/N"; fi
    read -r -p "$label ($suffix): " answer
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) printf -v "$variable" yes ;;
        [Nn]|[Nn][Oo]) printf -v "$variable" no ;;
        "") printf -v "$variable" '%s' "$default" ;;
        *) die "Expected yes or no." ;;
    esac
}

safe_value() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *"'"* ]]
}

detect_lan_ip() {
    local detected
    detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    [[ -n "$detected" ]] || detected=$(hostname -I | awk '{print $1}')
    printf '%s' "$detected"
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

printf '%b\n' "$BLUE============================================================$NC"
printf '%b\n' "$BLUE          MEDIA STACK INSTALLER v${INSTALLER_VERSION}$NC"
printf '%b\n\n' "$BLUE============================================================$NC"

prompt_value INSTALL_DIR "Installation path" "$DEFAULT_INSTALL_DIR"
[[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "The installation path must be absolute and may contain only letters, digits, /, ., _ and -."
[[ "$INSTALL_DIR" != / && "$INSTALL_DIR" != /opt && "$INSTALL_DIR" != /srv && "$INSTALL_DIR" != /mnt &&
    "$INSTALL_DIR" != /usr && "$INSTALL_DIR" != /var ]] || die "Choose a dedicated installation directory."
case "$INSTALL_DIR" in
    /etc/*|/boot/*|/run/*|/usr/*|/var/lib/docker|/var/lib/docker/*)
        die "Choose a data location such as /opt/media-stack, /srv/media-stack or /mnt/media-stack."
        ;;
esac

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/.update-state"
exec 9>"$INSTALL_DIR/.update-state/update.lock"
flock -n 9 || die "A Media Stack update or backup is already running in $INSTALL_DIR."
OLD_ENV="$INSTALL_DIR/.env"

CURRENT_LAN_IP=$(read_env LAN_IP "$OLD_ENV")
DETECTED_LAN_IP=$(detect_lan_ip)
prompt_value LAN_IP "LAN IPv4 address" "${CURRENT_LAN_IP:-$DETECTED_LAN_IP}"
valid_ipv4 "$LAN_IP" || die "Invalid IPv4 address: $LAN_IP"
ip -4 addr show | grep -Fq " $LAN_IP/" || die "$LAN_IP is not currently assigned to this system."

CURRENT_VPN_TYPE=$(read_env VPN_TYPE "$OLD_ENV")
[[ "$CURRENT_VPN_TYPE" == wireguard || "$CURRENT_VPN_TYPE" == openvpn ]] || CURRENT_VPN_TYPE=openvpn
prompt_value VPN_TYPE "ProtonVPN protocol (wireguard/openvpn)" "$CURRENT_VPN_TYPE"
[[ "$VPN_TYPE" == wireguard || "$VPN_TYPE" == openvpn ]] || die "VPN protocol must be wireguard or openvpn."

LEGACY_VPN_USER=$(read_env VPN_USER "$OLD_ENV")
LEGACY_VPN_PASS=$(read_env VPN_PASS "$OLD_ENV")
CURRENT_OPENVPN_USER=""
CURRENT_OPENVPN_PASSWORD=""
CURRENT_WIREGUARD_KEY=""
[[ -f "$INSTALL_DIR/secrets/proton_openvpn_user" ]] && CURRENT_OPENVPN_USER=$(<"$INSTALL_DIR/secrets/proton_openvpn_user")
[[ -f "$INSTALL_DIR/secrets/proton_openvpn_password" ]] && CURRENT_OPENVPN_PASSWORD=$(<"$INSTALL_DIR/secrets/proton_openvpn_password")
[[ -f "$INSTALL_DIR/secrets/proton_wireguard_private_key" ]] && CURRENT_WIREGUARD_KEY=$(<"$INSTALL_DIR/secrets/proton_wireguard_private_key")
CURRENT_OPENVPN_USER=${CURRENT_OPENVPN_USER:-$LEGACY_VPN_USER}
CURRENT_OPENVPN_PASSWORD=${CURRENT_OPENVPN_PASSWORD:-$LEGACY_VPN_PASS}

OPENVPN_USER=""
OPENVPN_PASSWORD=""
WIREGUARD_PRIVATE_KEY=""
if [[ "$VPN_TYPE" == openvpn ]]; then
    printf '\n--- ProtonVPN / OpenVPN ---\n'
    prompt_value OPENVPN_USER "OpenVPN username (the installer adds +pmp)" "${CURRENT_OPENVPN_USER%%+pmp*}"
    prompt_secret OPENVPN_PASSWORD "OpenVPN password" "$CURRENT_OPENVPN_PASSWORD"
    [[ -n "$OPENVPN_USER" && -n "$OPENVPN_PASSWORD" ]] || die "OpenVPN credentials are required."
    [[ "$OPENVPN_USER" != *[[:space:]]* ]] || die "The OpenVPN username cannot contain whitespace."
    [[ "$OPENVPN_USER" == *+pmp* ]] || OPENVPN_USER="${OPENVPN_USER}+pmp"
else
    printf '\n--- ProtonVPN / WireGuard ---\n'
    log_info "Use the PrivateKey from a ProtonVPN WireGuard configuration generated with NAT-PMP enabled."
    prompt_secret WIREGUARD_PRIVATE_KEY "WireGuard private key" "$CURRENT_WIREGUARD_KEY"
    [[ "$WIREGUARD_PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "The WireGuard private key is not valid base64 key material."
fi

CURRENT_PROFILES=$(read_env COMPOSE_PROFILES "$OLD_ENV")
PANGOLIN_DEFAULT=yes
[[ -f "$OLD_ENV" && ",$CURRENT_PROFILES," != *,pangolin,* ]] && PANGOLIN_DEFAULT=no
prompt_yes_no ENABLE_PANGOLIN "Enable public Jellyfin/Seerr access through Pangolin" "$PANGOLIN_DEFAULT"

LEGACY_PANGOLIN_ENDPOINT=$(read_env PANGOLIN_ENDPOINT "$OLD_ENV")
LEGACY_NEWT_ID=$(read_env NEWT_ID "$OLD_ENV")
LEGACY_NEWT_SECRET=$(read_env NEWT_SECRET "$OLD_ENV")
CURRENT_PUBLIC_DOMAIN=$(read_env PUBLIC_DOMAIN "$OLD_ENV")
PANGOLIN_ENDPOINT=$LEGACY_PANGOLIN_ENDPOINT
NEWT_ID=$LEGACY_NEWT_ID
NEWT_SECRET=$LEGACY_NEWT_SECRET
if [[ -f "$INSTALL_DIR/config/newt/config.json" ]]; then
    JSON_PANGOLIN_ENDPOINT=$(jq -r '.endpoint // empty' "$INSTALL_DIR/config/newt/config.json" 2>/dev/null || true)
    JSON_NEWT_ID=$(jq -r '.id // empty' "$INSTALL_DIR/config/newt/config.json" 2>/dev/null || true)
    JSON_NEWT_SECRET=$(jq -r '.secret // empty' "$INSTALL_DIR/config/newt/config.json" 2>/dev/null || true)
    PANGOLIN_ENDPOINT=${JSON_PANGOLIN_ENDPOINT:-$PANGOLIN_ENDPOINT}
    NEWT_ID=${JSON_NEWT_ID:-$NEWT_ID}
    NEWT_SECRET=${JSON_NEWT_SECRET:-$NEWT_SECRET}
fi

PUBLIC_DOMAIN=${CURRENT_PUBLIC_DOMAIN:-disabled.invalid}
if [[ "$ENABLE_PANGOLIN" == yes ]]; then
    printf '\n--- Pangolin / Newt ---\n'
    prompt_value PANGOLIN_ENDPOINT "Pangolin endpoint" "$PANGOLIN_ENDPOINT"
    prompt_value NEWT_ID "Newt ID" "$NEWT_ID"
    prompt_secret NEWT_SECRET "Newt secret" "$NEWT_SECRET"
    [[ "$PANGOLIN_ENDPOINT" =~ ^https?://[^/[:space:]]+/?$ ]] || die "Use a full Pangolin endpoint URL, for example https://pangolin.example.com."
    PANGOLIN_ENDPOINT=${PANGOLIN_ENDPOINT%/}
    [[ "$PANGOLIN_ENDPOINT" == https://* ]] || log_warn "The Pangolin endpoint is using plain HTTP. HTTPS is strongly recommended."
    [[ -n "$NEWT_ID" && -n "$NEWT_SECRET" ]] || die "Newt ID and secret are required."
    PANGOLIN_HOST=${PANGOLIN_ENDPOINT#*://}
    DETECTED_DOMAIN=${PANGOLIN_HOST#pangolin.}
    [[ "$DETECTED_DOMAIN" != "$PANGOLIN_HOST" ]] || DETECTED_DOMAIN=${PANGOLIN_HOST#*.}
    prompt_value PUBLIC_DOMAIN "Public base domain" "${CURRENT_PUBLIC_DOMAIN:-$DETECTED_DOMAIN}"
    [[ "$PUBLIC_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Invalid public domain: $PUBLIC_DOMAIN"
fi

printf '\n--- Transmission ---\n'
CURRENT_TR_USER=$(read_env TR_USER "$OLD_ENV")
CURRENT_TR_PASS=$(read_env TR_PASS "$OLD_ENV")
[[ -f "$INSTALL_DIR/secrets/transmission_user" ]] && CURRENT_TR_USER=$(<"$INSTALL_DIR/secrets/transmission_user")
[[ -f "$INSTALL_DIR/secrets/transmission_password" ]] && CURRENT_TR_PASS=$(<"$INSTALL_DIR/secrets/transmission_password")
prompt_value TR_USER "Transmission username" "${CURRENT_TR_USER:-admin}"
GENERATED_TR_PASSWORD=false
if [[ -z "$CURRENT_TR_PASS" ]]; then
    RANDOM_PASSWORD_MATERIAL=$(openssl rand -hex 16)
    CURRENT_TR_PASS=${RANDOM_PASSWORD_MATERIAL:0:24}
    GENERATED_TR_PASSWORD=true
fi
prompt_secret TR_PASS "Transmission password" "$CURRENT_TR_PASS"
[[ -n "$TR_USER" && -n "$TR_PASS" ]] || die "Transmission credentials are required."

FLARESOLVERR_DEFAULT=yes
[[ -f "$OLD_ENV" && ",$CURRENT_PROFILES," != *,flaresolverr,* ]] && FLARESOLVERR_DEFAULT=no
prompt_yes_no ENABLE_FLARESOLVERR "Enable FlareSolverr" "$FLARESOLVERR_DEFAULT"

TAILSCALE_DEFAULT=$(read_env ENABLE_TAILSCALE "$OLD_ENV")
[[ "$TAILSCALE_DEFAULT" == yes || "$TAILSCALE_DEFAULT" == no ]] || TAILSCALE_DEFAULT=yes
prompt_yes_no ENABLE_TAILSCALE "Enable private remote access through Tailscale" "$TAILSCALE_DEFAULT"

CURRENT_OFFSITE=$(read_env OFFSITE_BACKUP_DIR "$OLD_ENV")
prompt_value OFFSITE_BACKUP_DIR "External backup directory (empty disables it)" "$CURRENT_OFFSITE"
OFFSITE_BACKUP_SOURCE=""
OFFSITE_BACKUP_MOUNTPOINT=""
if [[ -n "$OFFSITE_BACKUP_DIR" ]]; then
    [[ "$OFFSITE_BACKUP_DIR" == /* ]] || die "The external backup path must be absolute."
    safe_value "$OFFSITE_BACKUP_DIR" || die "The external backup path contains unsupported characters."
    [[ -d "$OFFSITE_BACKUP_DIR" && -w "$OFFSITE_BACKUP_DIR" ]] || die "Mount the external backup directory and make it writable first."
    read -r OFFSITE_BACKUP_SOURCE OFFSITE_BACKUP_MOUNTPOINT < <(findmnt -T "$OFFSITE_BACKUP_DIR" -n -o SOURCE,TARGET --first)
    [[ -n "$OFFSITE_BACKUP_SOURCE" && "$OFFSITE_BACKUP_MOUNTPOINT" != / ]] ||
        die "The external backup directory must be on a separately mounted filesystem, not the LXC root filesystem."
fi

GPU_DEFAULT=no
[[ -n "$(read_env RENDER_GID "$OLD_ENV")" ]] && GPU_DEFAULT=yes
ENABLE_GPU=no
RENDER_GID=""
if [[ -e /dev/dri/renderD128 ]]; then
    prompt_yes_no ENABLE_GPU "Enable Intel/AMD hardware transcoding for Jellyfin" "$GPU_DEFAULT"
    [[ "$ENABLE_GPU" == no ]] || RENDER_GID=$(stat -c '%g' /dev/dri/renderD128)
fi

for value in "$LAN_IP" "$OPENVPN_USER" "$OPENVPN_PASSWORD" "$WIREGUARD_PRIVATE_KEY" \
    "$PANGOLIN_ENDPOINT" "$NEWT_ID" "$NEWT_SECRET" "$PUBLIC_DOMAIN" "$TR_USER" "$TR_PASS"; do
    safe_value "$value" || die "A value contains an unsupported apostrophe or newline."
done

if [[ ! -f "$INSTALL_DIR/compose.yaml" && ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    log_info "Checking service ports on $LAN_IP..."
    for port in 5055 6767 7878 8096 8989 9091 9696; do
        if ss -H -ltn "sport = :$port" | grep -q .; then
            die "TCP port $port is already in use."
        fi
    done
fi

REAL_USER=${SUDO_USER:-}
if [[ -z "$REAL_USER" || "$REAL_USER" == root ]]; then
    if id media >/dev/null 2>&1; then
        REAL_USER=media
    elif getent passwd 1000 >/dev/null; then
        REAL_USER=$(getent passwd 1000 | cut -d: -f1)
    else
        useradd --create-home --user-group --shell /usr/sbin/nologin media
        REAL_USER=media
    fi
fi
PUID=$(id -u "$REAL_USER")
PGID=$(id -g "$REAL_USER")
TZ=$(cat /etc/timezone 2>/dev/null || printf 'Etc/UTC')

log_info "Preparing persistent directories without recursively changing existing media ownership..."
DIRS=(
    config/gluetun config/transmission config/sonarr config/radarr config/prowlarr
    config/bazarr config/jellyfin config/seerr config/newt
    data/torrents/movies data/torrents/tv data/torrents/incomplete
    data/media/movies data/media/tv backups .update-state secrets
)
for relative_dir in "${DIRS[@]}"; do
    mkdir -p "$INSTALL_DIR/$relative_dir"
done
for relative_dir in config/gluetun config/transmission config/sonarr config/radarr config/prowlarr config/bazarr config/jellyfin \
    data data/torrents data/torrents/movies data/torrents/tv data/torrents/incomplete data/media data/media/movies data/media/tv; do
    chown "$PUID:$PGID" "$INSTALL_DIR/$relative_dir" 2>/dev/null ||
        die "Cannot assign $INSTALL_DIR/$relative_dir to UID:GID $PUID:$PGID. Fix the Proxmox bind-mount ID mapping."
    chmod 0775 "$INSTALL_DIR/$relative_dir"
done
chown 1000:1000 "$INSTALL_DIR/config/seerr" 2>/dev/null ||
    die "Cannot assign the Seerr config directory to UID:GID 1000:1000. Fix the bind-mount ID mapping."
chmod 0750 "$INSTALL_DIR/config" "$INSTALL_DIR/secrets" "$INSTALL_DIR/.update-state"

PERMISSION_TEST="$INSTALL_DIR/data/.media-stack-write-test"
if ! runuser -u "$REAL_USER" -- touch "$PERMISSION_TEST"; then
    die "UID $PUID cannot write to $INSTALL_DIR/data. Fix storage ownership or the LXC UID/GID mapping."
fi
rm -f "$PERMISSION_TEST"

HARDLINK_SOURCE="$INSTALL_DIR/data/torrents/.hardlink-test"
HARDLINK_TARGET="$INSTALL_DIR/data/media/.hardlink-test"
runuser -u "$REAL_USER" -- touch "$HARDLINK_SOURCE"
if ! runuser -u "$REAL_USER" -- ln "$HARDLINK_SOURCE" "$HARDLINK_TARGET" 2>/dev/null; then
    log_warn "The data filesystem does not support hardlinks across torrents and media; imports will copy instead."
fi
rm -f "$HARDLINK_SOURCE" "$HARDLINK_TARGET"

if [[ -d "$INSTALL_DIR/config/jellyseerr" && ! -e "$INSTALL_DIR/config/seerr/settings.json" ]] &&
    docker container inspect jellyseerr >/dev/null 2>&1; then
    if [[ "$(docker inspect --format '{{.State.Running}}' jellyseerr)" == true ]]; then
        log_info "Stopping the legacy Jellyseerr container for a consistent migration..."
        docker stop jellyseerr >/dev/null
        JELLYSEERR_WAS_RUNNING=true
    fi
fi
if [[ -d "$INSTALL_DIR/config/jellyseerr" && ! -e "$INSTALL_DIR/config/seerr/settings.json" ]]; then
    tar -czf "$INSTALL_DIR/backups/jellyseerr-before-seerr-$(date +%Y%m%d-%H%M%S).tar.gz" \
        -C "$INSTALL_DIR" config/jellyseerr
    cp -a "$INSTALL_DIR/config/jellyseerr/." "$INSTALL_DIR/config/seerr/"
    chown -R 1000:1000 "$INSTALL_DIR/config/seerr"
    JELLYSEERR_MIGRATED=true
fi

if [[ ! -f "$INSTALL_DIR/config/transmission/settings.json" ]]; then
    cat > "$INSTALL_DIR/config/transmission/settings.json" <<'EOF'
{
    "download-dir": "/data/torrents",
    "incomplete-dir": "/data/torrents/incomplete",
    "incomplete-dir-enabled": true,
    "peer-port-random-on-start": false,
    "port-forwarding-enabled": false,
    "rename-partial-files": true
}
EOF
    chown "$PUID:$PGID" "$INSTALL_DIR/config/transmission/settings.json"
    chmod 0640 "$INSTALL_DIR/config/transmission/settings.json"
fi

acquire_bundle() {
    local script_dir archive ref
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [[ -f "$script_dir/templates/compose.yaml" && -f "$script_dir/update_stack.sh" && -f "$script_dir/media_stack.sh" ]]; then
        printf '%s' "$script_dir"
        return
    fi
    ref=${MEDIA_STACK_REF:-main}
    [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || die "MEDIA_STACK_REF contains unsupported characters."
    archive="$TEMP_DIR/media-stack.tar.gz"
    log_info "Downloading one consistent project snapshot (${PROJECT_REPOSITORY}@${ref})..." >&2
    curl --fail --silent --show-error --location --retry 3 \
        "https://github.com/${PROJECT_REPOSITORY}/archive/${ref}.tar.gz" -o "$archive"
    mkdir -p "$TEMP_DIR/bundle"
    tar -xzf "$archive" --strip-components=1 -C "$TEMP_DIR/bundle"
    printf '%s' "$TEMP_DIR/bundle"
}

BUNDLE_DIR=$(acquire_bundle)
REQUIRED_FILES=(
    templates/compose.yaml templates/compose.openvpn.yaml templates/compose.wireguard.yaml templates/compose.gpu.yaml
    update_stack.sh sync_transmission_port.sh media_stack.sh
)
for required_file in "${REQUIRED_FILES[@]}"; do
    [[ -f "$BUNDLE_DIR/$required_file" ]] || die "The project snapshot is missing $required_file."
done
bash -n "$BUNDLE_DIR/update_stack.sh" "$BUNDLE_DIR/sync_transmission_port.sh" "$BUNDLE_DIR/media_stack.sh"

STAGE_DIR="$TEMP_DIR/stage"
mkdir -p "$STAGE_DIR/secrets" "$STAGE_DIR/config/newt"
cp "$BUNDLE_DIR/templates/"*.yaml "$STAGE_DIR/"
cp "$BUNDLE_DIR/update_stack.sh" "$BUNDLE_DIR/sync_transmission_port.sh" "$BUNDLE_DIR/media_stack.sh" "$STAGE_DIR/"

printf '%s' "$TR_USER" > "$STAGE_DIR/secrets/transmission_user"
printf '%s' "$TR_PASS" > "$STAGE_DIR/secrets/transmission_password"
if [[ "$VPN_TYPE" == openvpn ]]; then
    printf '%s' "$OPENVPN_USER" > "$STAGE_DIR/secrets/proton_openvpn_user"
    printf '%s' "$OPENVPN_PASSWORD" > "$STAGE_DIR/secrets/proton_openvpn_password"
else
    printf '%s' "$WIREGUARD_PRIVATE_KEY" > "$STAGE_DIR/secrets/proton_wireguard_private_key"
fi
chmod 0600 "$STAGE_DIR/secrets/"*

if [[ "$ENABLE_PANGOLIN" == yes ]]; then
    jq -n --arg id "$NEWT_ID" --arg secret "$NEWT_SECRET" --arg endpoint "$PANGOLIN_ENDPOINT" \
        '{id:$id, secret:$secret, endpoint:$endpoint, tlsClientCert:""}' > "$STAGE_DIR/config/newt/config.json"
elif [[ -s "$INSTALL_DIR/config/newt/config.json" ]]; then
    cp "$INSTALL_DIR/config/newt/config.json" "$STAGE_DIR/config/newt/config.json"
else
    printf '{}\n' > "$STAGE_DIR/config/newt/config.json"
fi
chmod 0600 "$STAGE_DIR/config/newt/config.json"

COMPOSE_PROFILES=()
[[ "$ENABLE_PANGOLIN" == yes ]] && COMPOSE_PROFILES+=(pangolin)
[[ "$ENABLE_FLARESOLVERR" == yes ]] && COMPOSE_PROFILES+=(flaresolverr)
PROFILE_LIST=$(IFS=,; printf '%s' "${COMPOSE_PROFILES[*]}")
COMPOSE_FILES="compose.yaml:compose.${VPN_TYPE}.yaml"
[[ "$ENABLE_GPU" == yes ]] && COMPOSE_FILES="${COMPOSE_FILES}:compose.gpu.yaml"

write_env_line() {
    printf "%s='%s'\n" "$1" "$2"
}
{
    write_env_line PUID "$PUID"
    write_env_line PGID "$PGID"
    write_env_line TZ "$TZ"
    write_env_line LAN_IP "$LAN_IP"
    write_env_line PUBLIC_DOMAIN "$PUBLIC_DOMAIN"
    write_env_line VPN_TYPE "$VPN_TYPE"
    write_env_line COMPOSE_FILE "$COMPOSE_FILES"
    write_env_line COMPOSE_PROFILES "$PROFILE_LIST"
    write_env_line ENABLE_TAILSCALE "$ENABLE_TAILSCALE"
    write_env_line RENDER_GID "$RENDER_GID"
    write_env_line UPDATE_DELAY_DAYS "7"
    write_env_line OFFSITE_BACKUP_DIR "$OFFSITE_BACKUP_DIR"
    write_env_line OFFSITE_BACKUP_SOURCE "$OFFSITE_BACKUP_SOURCE"
    write_env_line OFFSITE_BACKUP_MOUNTPOINT "$OFFSITE_BACKUP_MOUNTPOINT"
} > "$STAGE_DIR/.env"
chmod 0600 "$STAGE_DIR/.env"

log_info "Validating the exact Compose model before changing the running stack..."
(
    cd "$STAGE_DIR" || exit 1
    docker compose config --quiet
    mapfile -t declared_services < <(docker compose config --services)
    [[ " ${declared_services[*]} " == *" gluetun "* && " ${declared_services[*]} " == *" transmission "* ]] || exit 1
)

if [[ -f "$INSTALL_DIR/.env" || -f "$INSTALL_DIR/compose.yaml" || -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    timestamp=$(date +%Y%m%d-%H%M%S)
    ROLLBACK_ARCHIVE="$INSTALL_DIR/backups/installer-before-${timestamp}.tar.gz"
    old_items=()
    for item in .env compose.yaml compose.openvpn.yaml compose.wireguard.yaml compose.gpu.yaml docker-compose.yml \
        update_stack.sh sync_transmission_port.sh media_stack.sh important_info.md secrets config/newt/config.json; do
        [[ -e "$INSTALL_DIR/$item" ]] && old_items+=("$item")
    done
    if ((${#old_items[@]} > 0)); then
        tar -czf "$ROLLBACK_ARCHIVE" -C "$INSTALL_DIR" "${old_items[@]}"
        tar -tzf "$ROLLBACK_ARCHIVE" >/dev/null
    fi
fi

DEPLOYMENT_STARTED=true
install -m 0600 "$STAGE_DIR/.env" "$INSTALL_DIR/.env"
install -m 0640 "$STAGE_DIR/compose.yaml" "$STAGE_DIR/compose.openvpn.yaml" \
    "$STAGE_DIR/compose.wireguard.yaml" "$STAGE_DIR/compose.gpu.yaml" "$INSTALL_DIR/"
install -m 0750 "$STAGE_DIR/update_stack.sh" "$STAGE_DIR/sync_transmission_port.sh" "$STAGE_DIR/media_stack.sh" "$INSTALL_DIR/"
install -m 0600 "$STAGE_DIR/secrets/"* "$INSTALL_DIR/secrets/"
if [[ "$VPN_TYPE" == openvpn ]]; then
    rm -f "$INSTALL_DIR/secrets/proton_wireguard_private_key"
else
    rm -f "$INSTALL_DIR/secrets/proton_openvpn_user" "$INSTALL_DIR/secrets/proton_openvpn_password"
fi
install -m 0600 "$STAGE_DIR/config/newt/config.json" "$INSTALL_DIR/config/newt/config.json"
rm -f "$INSTALL_DIR/docker-compose.yml"

if [[ "$ENABLE_TAILSCALE" == yes ]]; then
    if ! command -v tailscale >/dev/null; then
        log_info "Installing Tailscale from its signed APT repository..."
        install -m 0755 -d /usr/share/keyrings
        curl --fail --silent --show-error --location --retry 3 \
            "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        curl --fail --silent --show-error --location --retry 3 \
            "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list
        apt-get update
        apt-get install -y -q tailscale
    fi
    systemctl enable --now tailscaled >/dev/null
    if [[ -z "$(tailscale ip -4 2>/dev/null | head -n1)" ]]; then
        log_info "Authenticate Tailscale using the URL displayed below."
        tailscale up --timeout=10m
    fi
    [[ -n "$(tailscale ip -4 2>/dev/null | head -n1)" ]] || die "Tailscale did not connect."
fi

log_info "Pulling images and starting the stack (this can take several minutes)..."
(
    cd "$INSTALL_DIR" || exit 1
    docker compose config --quiet
    docker compose pull
    docker compose up -d --remove-orphans --wait --wait-timeout 420
)

if $JELLYSEERR_MIGRATED && docker container inspect jellyseerr >/dev/null 2>&1; then
    docker rm jellyseerr >/dev/null
    JELLYSEERR_WAS_RUNNING=false
fi

if [[ "$ENABLE_TAILSCALE" == yes ]]; then
    log_info "Configuring private HTTPS endpoints with Tailscale Serve..."
    for port in 5055 6767 7878 8096 8989 9091 9696; do
        tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >/dev/null ||
            log_warn "Tailscale Serve could not configure HTTPS port $port; retry with: media-stack repair-ip"
    done
fi

cat > /etc/systemd/system/media-stack-update.service <<EOF
[Unit]
Description=Delayed and rollback-safe Media Stack updates
Requires=docker.service
After=docker.service network-online.target
ConditionPathExists=${INSTALL_DIR}/compose.yaml

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/update_stack.sh
TimeoutStartSec=30min
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
LockPersonality=true
RestrictSUIDSGID=true
EOF

cat > /etc/systemd/system/media-stack-update.timer <<'EOF'
[Unit]
Description=Nightly Media Stack update check

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/media-stack-port-sync.service <<EOF
[Unit]
Description=Synchronize ProtonVPN's forwarded port with Transmission
Requires=docker.service
After=docker.service network-online.target
ConditionPathExists=${INSTALL_DIR}/compose.yaml

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/sync_transmission_port.sh
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
LockPersonality=true
RestrictSUIDSGID=true
EOF

cat > /etc/systemd/system/media-stack-port-sync.timer <<'EOF'
[Unit]
Description=Periodic Transmission port synchronization

[Timer]
OnBootSec=90s
OnUnitActiveSec=1m
RandomizedDelaySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now media-stack-update.timer media-stack-port-sync.timer >/dev/null
ln -sfn "$INSTALL_DIR/media_stack.sh" /usr/local/sbin/media-stack

cat > "$INSTALL_DIR/important_info.md" <<EOF
# Media Stack

LAN address: \`${LAN_IP}\`

| Service | Address |
| --- | --- |
| Jellyfin | http://${LAN_IP}:8096 |
| Seerr | http://${LAN_IP}:5055 |
| Transmission | http://${LAN_IP}:9091 |
| Radarr | http://${LAN_IP}:7878 |
| Sonarr | http://${LAN_IP}:8989 |
| Prowlarr | http://${LAN_IP}:9696 |
| Bazarr | http://${LAN_IP}:6767 |

Internal addresses: Transmission \`gluetun:9091\`, Radarr \`radarr:7878\`, Sonarr
\`sonarr:8989\`, Prowlarr \`prowlarr:9696\`, FlareSolverr \`flaresolverr:8191\`.

Use \`media-stack status\`, \`media-stack doctor\` and \`media-stack configure\` for maintenance.
Secrets are stored as root-only files in \`${INSTALL_DIR}/secrets\`.
EOF
if [[ "$ENABLE_PANGOLIN" == yes ]]; then
    cat >> "$INSTALL_DIR/important_info.md" <<EOF

Public Pangolin addresses: https://jellyfin.${PUBLIC_DOMAIN} and https://seerr.${PUBLIC_DOMAIN}.
Only these two applications are declared as public resources.
EOF
fi
chmod 0640 "$INSTALL_DIR/important_info.md"

log_info "Applying idempotent ARR wiring (root folders, Transmission, Prowlarr)..."
if ! "$INSTALL_DIR/media_stack.sh" configure --quiet; then
    log_warn "The stack is running, but automatic ARR wiring was not completed. Retry with: media-stack configure"
fi

DEPLOYMENT_FINISHED=true
log_success "Media Stack is installed in $INSTALL_DIR."
printf '\nUseful commands:\n'
printf '  media-stack status\n  media-stack doctor\n  media-stack configure\n  media-stack logs gluetun\n'
printf '\nTransmission login: %s\n' "$TR_USER"
if $GENERATED_TR_PASSWORD; then
    printf 'Generated Transmission password: %s\n' "$TR_PASS"
    printf 'It is also available to root in %s/secrets/transmission_password\n' "$INSTALL_DIR"
fi
printf '\n'
cat "$INSTALL_DIR/important_info.md"
