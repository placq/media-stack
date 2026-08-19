#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly INSTALLER_VERSION="5.0.0"
readonly DEFAULT_INSTALL_DIR="/opt/media-stack"
readonly PROJECT_REPOSITORY="placq/media-stack"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Media Stack installer for Debian/Ubuntu LXC

Usage:
  sudo bash install_media.sh
  sudo bash install_media.sh --preflight
  bash install_media.sh --help

Options:
  --preflight      Check the LXC without changing it
  --from-proxmox   Internal mode used by proxmox_lxc.sh
  --help           Show this help
USAGE
}

PREFLIGHT_ONLY=false
case "${1:-}" in
  "") ;;
  --preflight) PREFLIGHT_ONLY=true ;;
  --from-proxmox) [[ "${MEDIA_STACK_PROXMOX_LAUNCH:-}" == 1 ]] || die "--from-proxmox is reserved for proxmox_lxc.sh" ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; die "Unknown option: $1" ;;
esac

[[ $EUID -eq 0 ]] || die "Run this installer as root"
if ! $PREFLIGHT_ONLY && [[ "${MEDIA_STACK_PROXMOX_LAUNCH:-}" != 1 ]]; then
  [[ -t 0 ]] || die "Interactive terminal required; download the script first instead of piping it to bash"
fi
[[ "$(ps -p 1 -o comm=)" == systemd ]] || die "systemd must be PID 1"
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "Supported systems: Debian and Ubuntu" ;; esac
[[ -n "${VERSION_CODENAME:-}" ]] || die "Unable to determine OS codename"
VIRT=$(systemd-detect-virt --container 2>/dev/null || true)
[[ "$VIRT" == lxc ]] || die "This installer runs only inside LXC (detected: ${VIRT:-none})"
[[ -c /dev/net/tun && -r /dev/net/tun && -w /dev/net/tun ]] || die "LXC has no usable /dev/net/tun; Gluetun requires it"

AVAILABLE_MEMORY_MB=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
((AVAILABLE_MEMORY_MB >= 1800)) || log_warn "Only ${AVAILABLE_MEMORY_MB} MiB RAM is currently available"
ROOT_FREE_MB=$(df -Pm / | awk 'NR==2 {print $4}')
((ROOT_FREE_MB >= 8192)) || log_warn "Less than 8 GiB is free on the root filesystem"
if $PREFLIGHT_ONLY; then
  command -v ip >/dev/null || die "Missing iproute2"
  ip -4 route show default | grep -q . || die "No IPv4 default route"
  log_success "Preflight passed: ${PRETTY_NAME:-$ID}, LXC, TUN usable, ${AVAILABLE_MEMORY_MB} MiB available"
  exit 0
fi

mkdir -p /run/lock
exec 8>/run/lock/media-stack-installer.lock
flock -n 8 || die "Another Media Stack installation is running"
TEMP_DIR=$(mktemp -d)
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
      log_warn "Restoring previous generated configuration"
      rm -f "$INSTALL_DIR/.env" "$INSTALL_DIR/compose.yaml" "$INSTALL_DIR/compose.openvpn.yaml" "$INSTALL_DIR/compose.wireguard.yaml" "$INSTALL_DIR/compose.gpu.yaml" \
        "$INSTALL_DIR/update_stack.sh" "$INSTALL_DIR/sync_transmission_port.sh" "$INSTALL_DIR/media_stack.sh" "$INSTALL_DIR/important_info.md"
      rm -rf -- "$INSTALL_DIR/secrets"
      tar -xzf "$ROLLBACK_ARCHIVE" -C "$INSTALL_DIR" || true
      (cd "$INSTALL_DIR" && docker compose up -d --remove-orphans) || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'printf "%b[ERROR]%b Failure at line %s.\n" "$RED" "$NC" "$LINENO" >&2' ERR

log_info "Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -q ca-certificates curl findutils gnupg iproute2 jq openssl python3-yaml tar unattended-upgrades util-linux
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT
systemctl enable --now unattended-upgrades.service >/dev/null

install_docker() {
  local -a conflicting=()
  local package
  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii' && conflicting+=("$package")
  done
  ((${#conflicting[@]}==0)) || apt-get remove -y "${conflicting[@]}"
  install -m 0755 -d /etc/apt/keyrings
  curl --fail --silent --show-error --location --retry 3 "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<DOCKER
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER
  apt-get update
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then install_docker; fi
systemctl enable --now docker >/dev/null
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
docker run --rm --pull=missing hello-world >/dev/null || die "Docker cannot start a container; check LXC nesting/keyctl"

read_env() {
  local key=$1 file=$2 line value
  [[ -f "$file" ]] || return 0
  line=$(awk -v key="$key" 'index($0,key "=")==1 {print; exit}' "$file")
  [[ -n "$line" ]] || return 0
  value=${line#*=}
  if [[ "$value" == "'"*"'" && ${#value} -ge 2 ]]; then value=${value:1:${#value}-2};
  elif [[ "$value" == '"'*'"' && ${#value} -ge 2 ]]; then value=${value:1:${#value}-2}; fi
  printf '%s' "$value"
}
prompt_value() {
  local variable=$1 label=$2 default=${3:-} answer
  if [[ -n "$default" ]]; then read -r -p "$label [$default]: " answer; printf -v "$variable" '%s' "${answer:-$default}";
  else read -r -p "$label: " answer; printf -v "$variable" '%s' "$answer"; fi
}
prompt_secret() {
  local variable=$1 label=$2 current=${3:-} answer
  if [[ -n "$current" ]]; then read -r -s -p "$label [Enter keeps existing]: " answer; else read -r -s -p "$label: " answer; fi
  printf '\n'; printf -v "$variable" '%s' "${answer:-$current}"
}
prompt_yes_no() {
  local variable=$1 label=$2 default=${3:-yes} answer suffix
  [[ "$default" == yes ]] && suffix=Y/n || suffix=y/N
  read -r -p "$label ($suffix): " answer
  case "$answer" in [Yy]|[Yy][Ee][Ss]) printf -v "$variable" yes ;; [Nn]|[Nn][Oo]) printf -v "$variable" no ;; "") printf -v "$variable" '%s' "$default" ;; *) die "Expected yes or no" ;; esac
}
safe_value() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *"'"* ]]; }
detect_lan_ip() {
  local detected
  detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
  [[ -n "$detected" ]] || detected=$(hostname -I | awk '{print $1}')
  printf '%s' "$detected"
}
valid_ipv4() {
  local address=$1 octet; local -a octets; IFS=. read -r -a octets <<<"$address"; ((${#octets[@]}==4)) || return 1
  for octet in "${octets[@]}"; do [[ "$octet" =~ ^[0-9]{1,3}$ ]] && ((10#$octet<=255)) || return 1; done
}

printf '%b\n' "$BLUE============================================================$NC"
printf '%b\n' "$BLUE          MEDIA STACK INSTALLER v${INSTALLER_VERSION}$NC"
printf '%b\n\n' "$BLUE============================================================$NC"
prompt_value INSTALL_DIR "Installation path" "$DEFAULT_INSTALL_DIR"
[[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Installation path contains unsupported characters"
case "$INSTALL_DIR" in /|/opt|/srv|/mnt|/usr|/var|/etc/*|/boot/*|/run/*|/usr/*|/var/lib/docker|/var/lib/docker/*) die "Choose a dedicated data directory" ;; esac
mkdir -p "$INSTALL_DIR/.update-state" "$INSTALL_DIR/backups"
exec 9>"$INSTALL_DIR/.update-state/update.lock"
flock -n 9 || die "An update or backup is already running in $INSTALL_DIR"
OLD_ENV="$INSTALL_DIR/.env"

CURRENT_LAN_IP=$(read_env LAN_IP "$OLD_ENV"); DETECTED_LAN_IP=$(detect_lan_ip)
prompt_value LAN_IP "LAN IPv4 address" "${CURRENT_LAN_IP:-$DETECTED_LAN_IP}"
valid_ipv4 "$LAN_IP" || die "Invalid IPv4 address: $LAN_IP"
ip -4 addr show | grep -Fq " $LAN_IP/" || die "$LAN_IP is not assigned to this LXC"

CURRENT_VPN_TYPE=$(read_env VPN_TYPE "$OLD_ENV")
[[ "$CURRENT_VPN_TYPE" == wireguard || "$CURRENT_VPN_TYPE" == openvpn ]] || CURRENT_VPN_TYPE=wireguard
prompt_value VPN_TYPE "ProtonVPN protocol (wireguard/openvpn)" "$CURRENT_VPN_TYPE"
[[ "$VPN_TYPE" == wireguard || "$VPN_TYPE" == openvpn ]] || die "VPN protocol must be wireguard or openvpn"

CURRENT_OPENVPN_USER=""; CURRENT_OPENVPN_PASSWORD=""; CURRENT_WIREGUARD_KEY=""
[[ -f "$INSTALL_DIR/secrets/proton_openvpn_user" ]] && CURRENT_OPENVPN_USER=$(<"$INSTALL_DIR/secrets/proton_openvpn_user")
[[ -f "$INSTALL_DIR/secrets/proton_openvpn_password" ]] && CURRENT_OPENVPN_PASSWORD=$(<"$INSTALL_DIR/secrets/proton_openvpn_password")
[[ -f "$INSTALL_DIR/secrets/proton_wireguard_private_key" ]] && CURRENT_WIREGUARD_KEY=$(<"$INSTALL_DIR/secrets/proton_wireguard_private_key")
OPENVPN_USER=""; OPENVPN_PASSWORD=""; WIREGUARD_PRIVATE_KEY=""
if [[ "$VPN_TYPE" == wireguard ]]; then
  printf '\n--- ProtonVPN / WireGuard (recommended) ---\n'
  log_info "Use PrivateKey from a ProtonVPN WireGuard configuration generated with NAT-PMP/port forwarding enabled"
  prompt_secret WIREGUARD_PRIVATE_KEY "WireGuard private key" "$CURRENT_WIREGUARD_KEY"
  [[ "$WIREGUARD_PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "Invalid WireGuard private key"
else
  printf '\n--- ProtonVPN / OpenVPN fallback ---\n'
  prompt_value OPENVPN_USER "OpenVPN username (installer adds +pmp)" "${CURRENT_OPENVPN_USER%%+pmp*}"
  prompt_secret OPENVPN_PASSWORD "OpenVPN password" "$CURRENT_OPENVPN_PASSWORD"
  [[ -n "$OPENVPN_USER" && -n "$OPENVPN_PASSWORD" ]] || die "OpenVPN credentials are required"
  [[ "$OPENVPN_USER" != *[[:space:]]* ]] || die "OpenVPN username cannot contain whitespace"
  [[ "$OPENVPN_USER" == *+pmp* ]] || OPENVPN_USER="${OPENVPN_USER}+pmp"
fi

printf '\n--- Transmission ---\n'
CURRENT_TR_USER=""; CURRENT_TR_PASS=""
[[ -f "$INSTALL_DIR/secrets/transmission_user" ]] && CURRENT_TR_USER=$(<"$INSTALL_DIR/secrets/transmission_user")
[[ -f "$INSTALL_DIR/secrets/transmission_password" ]] && CURRENT_TR_PASS=$(<"$INSTALL_DIR/secrets/transmission_password")
prompt_value TR_USER "Transmission username" "${CURRENT_TR_USER:-admin}"
GENERATED_TR_PASSWORD=false
if [[ -z "$CURRENT_TR_PASS" ]]; then CURRENT_TR_PASS=$(openssl rand -hex 16 | cut -c1-24); GENERATED_TR_PASSWORD=true; fi
prompt_secret TR_PASS "Transmission password" "$CURRENT_TR_PASS"
[[ -n "$TR_USER" && -n "$TR_PASS" ]] || die "Transmission credentials are required"

CURRENT_PROFILES=$(read_env COMPOSE_PROFILES "$OLD_ENV")
FLARESOLVERR_DEFAULT=yes; [[ -f "$OLD_ENV" && ",$CURRENT_PROFILES," != *,flaresolverr,* ]] && FLARESOLVERR_DEFAULT=no
prompt_yes_no ENABLE_FLARESOLVERR "Enable optional FlareSolverr" "$FLARESOLVERR_DEFAULT"

CURRENT_OFFSITE=$(read_env OFFSITE_BACKUP_DIR "$OLD_ENV")
prompt_value OFFSITE_BACKUP_DIR "External backup directory (empty disables it)" "$CURRENT_OFFSITE"
OFFSITE_BACKUP_SOURCE=""; OFFSITE_BACKUP_MOUNTPOINT=""
if [[ -n "$OFFSITE_BACKUP_DIR" ]]; then
  [[ "$OFFSITE_BACKUP_DIR" == /* ]] || die "External backup path must be absolute"
  safe_value "$OFFSITE_BACKUP_DIR" || die "External backup path contains unsupported characters"
  [[ -d "$OFFSITE_BACKUP_DIR" && -w "$OFFSITE_BACKUP_DIR" ]] || die "External backup directory must already be mounted and writable"
  read -r OFFSITE_BACKUP_SOURCE OFFSITE_BACKUP_MOUNTPOINT < <(findmnt -T "$OFFSITE_BACKUP_DIR" -n -o SOURCE,TARGET --first)
  [[ -n "$OFFSITE_BACKUP_SOURCE" && "$OFFSITE_BACKUP_MOUNTPOINT" != / ]] || die "External backup must be on a separately mounted filesystem"
fi

GPU_DEFAULT=no; [[ -n "$(read_env RENDER_GID "$OLD_ENV")" ]] && GPU_DEFAULT=yes
ENABLE_GPU=no; RENDER_GID=""
if [[ -e /dev/dri/renderD128 ]]; then
  prompt_yes_no ENABLE_GPU "Enable hardware transcoding for Jellyfin" "$GPU_DEFAULT"
  [[ "$ENABLE_GPU" == no ]] || RENDER_GID=$(stat -c '%g' /dev/dri/renderD128)
fi

for value in "$LAN_IP" "$OPENVPN_USER" "$OPENVPN_PASSWORD" "$WIREGUARD_PRIVATE_KEY" "$TR_USER" "$TR_PASS"; do safe_value "$value" || die "A value contains an unsupported apostrophe or newline"; done

if [[ ! -f "$INSTALL_DIR/compose.yaml" ]]; then
  log_info "Checking service ports on $LAN_IP..."
  for port in 5055 6767 7878 8096 8989 9091 9696; do ss -H -ltn "sport = :$port" | grep -q . && die "TCP port $port is already in use"; done
fi

REAL_USER=${SUDO_USER:-}
if [[ -z "$REAL_USER" || "$REAL_USER" == root ]]; then
  if id media >/dev/null 2>&1; then REAL_USER=media
  elif getent passwd 1000 >/dev/null; then REAL_USER=$(getent passwd 1000 | cut -d: -f1)
  else useradd --create-home --user-group --shell /usr/sbin/nologin media; REAL_USER=media; fi
fi
PUID=$(id -u "$REAL_USER"); PGID=$(id -g "$REAL_USER"); TZ=$(cat /etc/timezone 2>/dev/null || printf 'Etc/UTC')

DIRS=(config/gluetun/auth config/transmission config/sonarr config/radarr config/prowlarr config/bazarr config/jellyfin config/seerr data/torrents/movies data/torrents/tv data/torrents/incomplete data/media/movies data/media/tv backups .update-state secrets)
for d in "${DIRS[@]}"; do mkdir -p "$INSTALL_DIR/$d"; done
# Do not chown the root of a host bind mount: in an unprivileged LXC it may\n# be owned by the host root mapping and is intentionally not chownable here.\n# The media subdirectories below are prepared and ownership-checked separately.\nfor d in config/gluetun config/transmission config/sonarr config/radarr config/prowlarr config/bazarr config/jellyfin data/torrents data/torrents/movies data/torrents/tv data/torrents/incomplete data/media data/media/movies data/media/tv; do\n  chown "$PUID:$PGID" "$INSTALL_DIR/$d" 2>/dev/null || die "Cannot assign $INSTALL_DIR/$d to UID:GID $PUID:$PGID; fix bind-mount mapping"\n  chmod 0775 "$INSTALL_DIR/$d"\ndone
chown 1000:1000 "$INSTALL_DIR/config/seerr" 2>/dev/null || die "Cannot assign Seerr config to UID:GID 1000:1000"
chmod 0750 "$INSTALL_DIR/config" "$INSTALL_DIR/secrets" "$INSTALL_DIR/.update-state"

# Test a directory that the media user owns. The root of a host bind mount\n# may intentionally remain owned by the host root mapping.\nPERMISSION_TEST="$INSTALL_DIR/data/torrents/incomplete/.media-stack-write-test"\nrunuser -u "$REAL_USER" -- touch "$PERMISSION_TEST" || die "UID $PUID cannot write to $INSTALL_DIR/data/torrents/incomplete"\nrm -f "$PERMISSION_TEST"
HARDLINK_SOURCE="$INSTALL_DIR/data/torrents/.hardlink-test"; HARDLINK_TARGET="$INSTALL_DIR/data/media/.hardlink-test"
runuser -u "$REAL_USER" -- touch "$HARDLINK_SOURCE"
runuser -u "$REAL_USER" -- ln "$HARDLINK_SOURCE" "$HARDLINK_TARGET" || { rm -f "$HARDLINK_SOURCE" "$HARDLINK_TARGET"; die "Hardlinks do not work between torrents and media; keep them on one filesystem"; }
rm -f "$HARDLINK_SOURCE" "$HARDLINK_TARGET"

# Obtain one consistent source snapshot. proxmox_lxc.sh provides it locally; a direct install downloads it.
SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -f "$SOURCE_DIR/templates/compose.yaml" || ! -f "$SOURCE_DIR/media_stack.sh" ]]; then
  log_info "Downloading a consistent media-stack source snapshot..."
  curl --fail --silent --show-error --location --retry 3 "https://github.com/${PROJECT_REPOSITORY}/archive/main.tar.gz" -o "$TEMP_DIR/source.tar.gz"
  mkdir -p "$TEMP_DIR/source"
  tar -xzf "$TEMP_DIR/source.tar.gz" --strip-components=1 -C "$TEMP_DIR/source"
  SOURCE_DIR="$TEMP_DIR/source"
fi
for required in templates/compose.yaml templates/compose.wireguard.yaml templates/compose.openvpn.yaml templates/compose.gpu.yaml media_stack.sh update_stack.sh sync_transmission_port.sh; do [[ -f "$SOURCE_DIR/$required" ]] || die "Source snapshot is missing $required"; done

STAGE_DIR="$TEMP_DIR/stage"; mkdir -p "$STAGE_DIR/secrets" "$STAGE_DIR/config/gluetun/auth"
cp "$SOURCE_DIR/templates/compose.yaml" "$STAGE_DIR/compose.yaml"
cp "$SOURCE_DIR/templates/compose.wireguard.yaml" "$STAGE_DIR/compose.wireguard.yaml"
cp "$SOURCE_DIR/templates/compose.openvpn.yaml" "$STAGE_DIR/compose.openvpn.yaml"
cp "$SOURCE_DIR/templates/compose.gpu.yaml" "$STAGE_DIR/compose.gpu.yaml"
cp "$SOURCE_DIR/media_stack.sh" "$SOURCE_DIR/update_stack.sh" "$SOURCE_DIR/sync_transmission_port.sh" "$STAGE_DIR/"
printf '%s' "$TR_USER" >"$STAGE_DIR/secrets/transmission_user"; printf '%s' "$TR_PASS" >"$STAGE_DIR/secrets/transmission_password"
if [[ "$VPN_TYPE" == wireguard ]]; then printf '%s' "$WIREGUARD_PRIVATE_KEY" >"$STAGE_DIR/secrets/proton_wireguard_private_key"; else printf '%s' "$OPENVPN_USER" >"$STAGE_DIR/secrets/proton_openvpn_user"; printf '%s' "$OPENVPN_PASSWORD" >"$STAGE_DIR/secrets/proton_openvpn_password"; fi
chmod 0600 "$STAGE_DIR/secrets/"*
cat >"$STAGE_DIR/config/gluetun/auth/config.toml" <<'GLUETUN_AUTH'
[[roles]]
name = "media-stack-readonly"
routes = ["GET /v1/portforward", "GET /v1/publicip/ip", "GET /v1/vpn/status"]
auth = "none"
GLUETUN_AUTH
chmod 0640 "$STAGE_DIR/config/gluetun/auth/config.toml"

COMPOSE_PROFILES=(); [[ "$ENABLE_FLARESOLVERR" == yes ]] && COMPOSE_PROFILES+=(flaresolverr)
PROFILE_LIST=$(IFS=,; printf '%s' "${COMPOSE_PROFILES[*]}")
COMPOSE_FILES="compose.yaml:compose.${VPN_TYPE}.yaml"; [[ "$ENABLE_GPU" == yes ]] && COMPOSE_FILES="${COMPOSE_FILES}:compose.gpu.yaml"
write_env_line() { printf "%s='%s'\n" "$1" "$2"; }
{
  write_env_line PUID "$PUID"; write_env_line PGID "$PGID"; write_env_line TZ "$TZ"; write_env_line LAN_IP "$LAN_IP"
  write_env_line VPN_TYPE "$VPN_TYPE"; write_env_line COMPOSE_FILE "$COMPOSE_FILES"; write_env_line COMPOSE_PROFILES "$PROFILE_LIST"
  write_env_line RENDER_GID "$RENDER_GID"; write_env_line UPDATE_DELAY_DAYS "7"
  write_env_line OFFSITE_BACKUP_DIR "$OFFSITE_BACKUP_DIR"; write_env_line OFFSITE_BACKUP_SOURCE "$OFFSITE_BACKUP_SOURCE"; write_env_line OFFSITE_BACKUP_MOUNTPOINT "$OFFSITE_BACKUP_MOUNTPOINT"
} >"$STAGE_DIR/.env"
chmod 0600 "$STAGE_DIR/.env"

log_info "Validating generated Compose configuration..."
(cd "$STAGE_DIR" && docker compose config --quiet && mapfile -t services < <(docker compose config --services) && [[ " ${services[*]} " == *" gluetun "* && " ${services[*]} " == *" transmission "* && " ${services[*]} " == *" bazarr "* ]])

if [[ -f "$INSTALL_DIR/.env" || -f "$INSTALL_DIR/compose.yaml" ]]; then
  timestamp=$(date +%Y%m%d-%H%M%S); ROLLBACK_ARCHIVE="$INSTALL_DIR/backups/installer-before-${timestamp}.tar.gz"
  old_items=(); for item in .env compose.yaml compose.openvpn.yaml compose.wireguard.yaml compose.gpu.yaml update_stack.sh sync_transmission_port.sh media_stack.sh important_info.md secrets config/gluetun/auth/config.toml; do [[ -e "$INSTALL_DIR/$item" ]] && old_items+=("$item"); done
  ((${#old_items[@]}==0)) || { tar -czf "$ROLLBACK_ARCHIVE" -C "$INSTALL_DIR" "${old_items[@]}"; tar -tzf "$ROLLBACK_ARCHIVE" >/dev/null; }
fi

DEPLOYMENT_STARTED=true
install -m 0600 "$STAGE_DIR/.env" "$INSTALL_DIR/.env"
install -m 0640 "$STAGE_DIR/compose.yaml" "$STAGE_DIR/compose.openvpn.yaml" "$STAGE_DIR/compose.wireguard.yaml" "$STAGE_DIR/compose.gpu.yaml" "$INSTALL_DIR/"
install -m 0750 "$STAGE_DIR/update_stack.sh" "$STAGE_DIR/sync_transmission_port.sh" "$STAGE_DIR/media_stack.sh" "$INSTALL_DIR/"
rm -rf "$INSTALL_DIR/secrets"; install -d -m 0750 "$INSTALL_DIR/secrets"; install -m 0600 "$STAGE_DIR/secrets/"* "$INSTALL_DIR/secrets/"
install -d -m 0750 "$INSTALL_DIR/config/gluetun/auth"; install -m 0640 "$STAGE_DIR/config/gluetun/auth/config.toml" "$INSTALL_DIR/config/gluetun/auth/config.toml"

log_info "Pulling images and starting the stack..."
(cd "$INSTALL_DIR" && docker compose config --quiet && docker compose pull && docker compose up -d --remove-orphans --wait --wait-timeout 420)

cat >/etc/systemd/system/media-stack-update.service <<UNIT
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
UNIT
cat >/etc/systemd/system/media-stack-update.timer <<'UNIT'
[Unit]
Description=Nightly Media Stack update check

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
cat >/etc/systemd/system/media-stack-port-sync.service <<UNIT
[Unit]
Description=Synchronize ProtonVPN forwarded port with Transmission
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
UNIT
cat >/etc/systemd/system/media-stack-port-sync.timer <<'UNIT'
[Unit]
Description=Periodic Transmission port synchronization

[Timer]
OnBootSec=90s
OnUnitActiveSec=1m
RandomizedDelaySec=10s
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now media-stack-update.timer media-stack-port-sync.timer >/dev/null
ln -sfn "$INSTALL_DIR/media_stack.sh" /usr/local/sbin/media-stack

cat >"$INSTALL_DIR/important_info.md" <<INFO
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

Transmission is isolated behind Gluetun/ProtonVPN. Sonarr/Radarr use \`gluetun:9091\` as their download client. Prowlarr, Bazarr and the root folders are wired automatically by \`media-stack configure\`.

Remote/private access and public ingress are intentionally not managed by this project; keep them outside the media LXC.

Use \`media-stack status\`, \`media-stack doctor\`, \`media-stack configure\` and \`media-stack backup\` for maintenance.
INFO
chmod 0640 "$INSTALL_DIR/important_info.md"

log_info "Applying automatic *Arr and Bazarr wiring..."
if ! "$INSTALL_DIR/media_stack.sh" configure --quiet; then
  log_warn "The stack is running, but automatic wiring was not completed. Retry with: media-stack configure"
fi

DEPLOYMENT_FINISHED=true
log_success "Media Stack is installed in $INSTALL_DIR"
printf '\nUseful commands:\n  media-stack status\n  media-stack doctor\n  media-stack configure\n  media-stack logs gluetun\n'
printf '\nTransmission login: %s\n' "$TR_USER"
if $GENERATED_TR_PASSWORD; then printf 'Generated Transmission password: %s\n' "$TR_PASS"; fi
printf '\n'; cat "$INSTALL_DIR/important_info.md"
