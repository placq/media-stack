#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
on_error() { echo -e "${RED}[ERROR]${NC} Installation failed at line $1." >&2; }
trap 'on_error "$LINENO"' ERR

[[ $EUID -eq 0 ]] || log_error "Run this installer with sudo or as root."
[[ -t 0 ]] || log_error "Interactive terminal required. Download the script first; do not pipe it directly to bash."

source /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) log_error "Supported systems: Ubuntu and Debian." ;;
esac
[[ -n "${VERSION_CODENAME:-}" ]] || log_error "Unable to determine the OS codename."

REAL_USER=${SUDO_USER:-root}
PUID=$(id -u "$REAL_USER")
PGID=$(id -g "$REAL_USER")
TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/Warsaw")

if [[ "$PUID" -eq 0 ]]; then
    if getent passwd 1000 >/dev/null; then
        REAL_USER=$(getent passwd 1000 | cut -d: -f1)
    else
        id media &>/dev/null || useradd -U -m -s /usr/sbin/nologin media
        REAL_USER=media
    fi
    PUID=$(id -u "$REAL_USER")
    PGID=$(id -g "$REAL_USER")
fi

clear
echo -e "${BLUE}===========================================${NC}"
echo -e "${BLUE}       MEDIA STACK INSTALLATION (v3.0)     ${NC}"
echo -e "${BLUE}===========================================${NC}"

read -r -p "Installation path [/opt/media-stack]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/media-stack}
[[ "$INSTALL_DIR" == /* ]] || log_error "Installation path must be absolute."
[[ "$INSTALL_DIR" != *"'"* && "$INSTALL_DIR" != *$'\n'* ]] || log_error "Installation path cannot contain apostrophes or newlines."

log_info "Installing required host packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -q ca-certificates curl gnupg iproute2 jq openssl tar util-linux

install_docker() {
    log_info "Configuring the official Docker repository for ${ID} ${VERSION_CODENAME}..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
    apt-get update
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    install_docker
fi
docker info >/dev/null 2>&1 || log_error "Docker daemon is not available."

if ! command -v tailscale >/dev/null; then
    log_info "Installing Tailscale on the host..."
    TAILSCALE_INSTALLER=$(mktemp)
    curl -fsSL https://tailscale.com/install.sh -o "$TAILSCALE_INSTALLER"
    sh "$TAILSCALE_INSTALLER"
    rm -f "$TAILSCALE_INSTALLER"
fi

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
if [[ -z "$TAILSCALE_IP" ]]; then
    log_info "Tailscale authentication is required. Open the URL shown below."
    tailscale up
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
fi
[[ -n "$TAILSCALE_IP" ]] || log_error "Tailscale is not connected."

LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
LAN_IP=${LAN_IP:-$(hostname -I | awk '{print $1}')}
[[ -n "$LAN_IP" ]] || log_error "Unable to determine the LAN address."

if [[ ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    log_info "Checking local service ports..."
    REQUIRED_PORTS=(8096 5055 9091 7878 8989 9696 6767)
    for port in "${REQUIRED_PORTS[@]}"; do
        if ss -H -tuln | awk '{print $5}' | grep -Eq "(^|:)$port$"; then
            log_error "Port $port is already in use."
        fi
    done
fi

echo -e "\n--- PROTONVPN ---"
read -r -p "OpenVPN username: " VPN_USER
read -r -s -p "OpenVPN password: " VPN_PASS
echo

echo -e "\n--- PANGOLIN / NEWT ---"
read -r -p "Pangolin endpoint (for example https://pangolin.example.com): " PANGOLIN_ENDPOINT
read -r -p "Newt ID: " NEWT_ID
read -r -s -p "Newt secret: " NEWT_SECRET
echo
[[ -n "$PANGOLIN_ENDPOINT" && -n "$NEWT_ID" && -n "$NEWT_SECRET" ]] || log_error "Pangolin endpoint and Newt credentials are required."
[[ "$PANGOLIN_ENDPOINT" =~ ^https?:// ]] || PANGOLIN_ENDPOINT="https://${PANGOLIN_ENDPOINT}"
PANGOLIN_ENDPOINT=${PANGOLIN_ENDPOINT%/}
PANGOLIN_HOST=${PANGOLIN_ENDPOINT#*://}
PANGOLIN_HOST=${PANGOLIN_HOST%%/*}
DETECTED_DOMAIN=${PANGOLIN_HOST#pangolin.}
[[ "$DETECTED_DOMAIN" != "$PANGOLIN_HOST" ]] || DETECTED_DOMAIN=${PANGOLIN_HOST#*.}
read -r -p "Public base domain [${DETECTED_DOMAIN}]: " PUBLIC_DOMAIN
PUBLIC_DOMAIN=${PUBLIC_DOMAIN:-$DETECTED_DOMAIN}

echo -e "\n--- TRANSMISSION ---"
DEFAULT_TR_PASS=$(openssl rand -hex 12)
read -r -p "Username [admin]: " TR_USER
TR_USER=${TR_USER:-admin}
read -r -p "Password [${DEFAULT_TR_PASS}]: " TR_PASS
TR_PASS=${TR_PASS:-$DEFAULT_TR_PASS}

for value in "$VPN_USER" "$VPN_PASS" "$PANGOLIN_ENDPOINT" "$NEWT_ID" "$NEWT_SECRET" "$TR_USER" "$TR_PASS" "$PUBLIC_DOMAIN"; do
    [[ "$value" != *"'"* && "$value" != *$'\n'* ]] || log_error "Credentials and configuration values cannot contain apostrophes or newlines."
done

GPU_CONFIG=""
if [[ -e /dev/dri/renderD128 ]]; then
    read -r -p "Enable Intel QuickSync for Jellyfin? (Y/n): " ENABLE_GPU
    if [[ ! "$ENABLE_GPU" =~ ^[Nn]$ ]]; then
        RENDER_GID=$(stat -c '%g' /dev/dri/renderD128)
        GPU_CONFIG="    devices:\n      - /dev/dri:/dev/dri\n    group_add:\n      - \"${RENDER_GID}\""
    fi
fi

log_info "Preparing directories in $INSTALL_DIR..."
DIRS=(
    config/gluetun config/transmission config/sonarr config/radarr config/prowlarr
    config/bazarr config/jellyfin config/seerr config/flaresolverr
    data/torrents/movies data/torrents/tv data/torrents/incomplete
    data/media/movies data/media/tv backups .update-state
)
for dir in "${DIRS[@]}"; do mkdir -p "$INSTALL_DIR/$dir"; done

if [[ -d "$INSTALL_DIR/config/jellyseerr" && ! -e "$INSTALL_DIR/config/seerr/settings.json" ]]; then
    log_info "Migrating the Jellyseerr configuration directory to Seerr..."
    cp -a "$INSTALL_DIR/config/jellyseerr/." "$INSTALL_DIR/config/seerr/"
fi

if [[ ! -f "$INSTALL_DIR/config/transmission/settings.json" ]]; then
    cat > "$INSTALL_DIR/config/transmission/settings.json" <<'TRANSMISSION_SETTINGS'
{
    "download-dir": "/data/torrents",
    "incomplete-dir": "/data/torrents/incomplete",
    "incomplete-dir-enabled": true
}
TRANSMISSION_SETTINGS
fi

if [[ -f "$INSTALL_DIR/.env" ]]; then
    cp -a "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.$(date +%Y%m%d-%H%M%S).bak"
fi
{
    printf "PUID='%s'\n" "$PUID"
    printf "PGID='%s'\n" "$PGID"
    printf "INSTALL_DIR='%s'\n" "$INSTALL_DIR"
    printf "LAN_IP='%s'\n" "$LAN_IP"
    printf "TAILSCALE_IP='%s'\n" "$TAILSCALE_IP"
    printf "VPN_USER='%s+pmp'\n" "$VPN_USER"
    printf "VPN_PASS='%s'\n" "$VPN_PASS"
    printf "PANGOLIN_ENDPOINT='%s'\n" "$PANGOLIN_ENDPOINT"
    printf "NEWT_ID='%s'\n" "$NEWT_ID"
    printf "NEWT_SECRET='%s'\n" "$NEWT_SECRET"
    printf "PUBLIC_DOMAIN='%s'\n" "$PUBLIC_DOMAIN"
    printf "TZ='%s'\n" "$TZ"
    printf "TR_USER='%s'\n" "$TR_USER"
    printf "TR_PASS='%s'\n" "$TR_PASS"
    printf "UPDATE_DELAY_DAYS='7'\n"
} > "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

log_info "Generating Docker Compose configuration..."
cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
networks:
  media-network:
    driver: bridge
  socket-proxy-network:
    driver: bridge
    internal: true

services:
  gluetun:
    image: qmcgaw/gluetun:v3
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=protonvpn
      - OPENVPN_USER=\${VPN_USER}
      - OPENVPN_PASSWORD=\${VPN_PASS}
      - VPN_TYPE=openvpn
      - PORT_FORWARD_ONLY=on
      - VPN_PORT_FORWARDING=on
    volumes:
      - \${INSTALL_DIR}/config/gluetun:/gluetun
    ports:
      - "127.0.0.1:9091:9091/tcp"
      - "\${LAN_IP}:9091:9091/tcp"
    networks:
      - media-network
    restart: unless-stopped

  transmission:
    image: lscr.io/linuxserver/transmission:latest
    container_name: transmission
    network_mode: service:gluetun
    depends_on:
      gluetun:
        condition: service_healthy
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
      - USER=\${TR_USER}
      - PASS=\${TR_PASS}
    volumes:
      - \${INSTALL_DIR}/config/transmission:/config
      - \${INSTALL_DIR}/data:/data
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - TZ=\${TZ}
    networks:
      - media-network
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    depends_on:
      - flaresolverr
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${INSTALL_DIR}/config/prowlarr:/config
    networks:
      - media-network
    ports:
      - "127.0.0.1:9696:9696"
      - "\${LAN_IP}:9696:9696"
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${INSTALL_DIR}/config/sonarr:/config
      - \${INSTALL_DIR}/data:/data
    networks:
      - media-network
    ports:
      - "127.0.0.1:8989:8989"
      - "\${LAN_IP}:8989:8989"
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${INSTALL_DIR}/config/radarr:/config
      - \${INSTALL_DIR}/data:/data
    networks:
      - media-network
    ports:
      - "127.0.0.1:7878:7878"
      - "\${LAN_IP}:7878:7878"
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${INSTALL_DIR}/config/bazarr:/config
      - \${INSTALL_DIR}/data:/data
    networks:
      - media-network
    ports:
      - "127.0.0.1:6767:6767"
      - "\${LAN_IP}:6767:6767"
    restart: unless-stopped

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${INSTALL_DIR}/config/jellyfin:/config
      - \${INSTALL_DIR}/data:/data
    networks:
      - media-network
    ports:
      - "127.0.0.1:8096:8096"
      - "\${LAN_IP}:8096:8096"
    labels:
      pangolin.public-resources.jellyfin.name: Jellyfin
      pangolin.public-resources.jellyfin.full-domain: jellyfin.\${PUBLIC_DOMAIN}
      pangolin.public-resources.jellyfin.protocol: http
      pangolin.public-resources.jellyfin.targets[0].method: http
      pangolin.public-resources.jellyfin.targets[0].hostname: jellyfin
      pangolin.public-resources.jellyfin.targets[0].port: "8096"
$(echo -e "$GPU_CONFIG")
    restart: unless-stopped

  seerr:
    image: ghcr.io/seerr-team/seerr:v3
    container_name: seerr
    init: true
    environment:
      - TZ=\${TZ}
      - PORT=5055
    volumes:
      - \${INSTALL_DIR}/config/seerr:/app/config
    networks:
      - media-network
    ports:
      - "127.0.0.1:5055:5055"
      - "\${LAN_IP}:5055:5055"
    labels:
      pangolin.public-resources.seerr.name: Seerr
      pangolin.public-resources.seerr.full-domain: seerr.\${PUBLIC_DOMAIN}
      pangolin.public-resources.seerr.protocol: http
      pangolin.public-resources.seerr.auth.sso-enabled: "true"
      pangolin.public-resources.seerr.targets[0].method: http
      pangolin.public-resources.seerr.targets[0].hostname: seerr
      pangolin.public-resources.seerr.targets[0].port: "5055"
    healthcheck:
      test: wget --no-verbose --tries=1 --spider http://localhost:5055/api/v1/settings/public || exit 1
      start_period: 20s
      timeout: 3s
      interval: 15s
      retries: 3
    read_only: true
    tmpfs:
      - /tmp
    restart: unless-stopped

  socket-proxy:
    image: lscr.io/linuxserver/socket-proxy:latest
    container_name: media-socket-proxy
    environment:
      - CONTAINERS=1
      - EVENTS=1
      - INFO=1
      - NETWORKS=1
      - PING=1
      - VERSION=1
      - POST=0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - socket-proxy-network
    read_only: true
    tmpfs:
      - /run
    restart: unless-stopped

  newt:
    image: fosrl/newt:latest
    container_name: newt
    depends_on:
      - socket-proxy
    environment:
      - PANGOLIN_ENDPOINT=\${PANGOLIN_ENDPOINT}
      - NEWT_ID=\${NEWT_ID}
      - NEWT_SECRET=\${NEWT_SECRET}
      - DOCKER_SOCKET=tcp://socket-proxy:2375
      - DOCKER_ENFORCE_NETWORK_VALIDATION=true
    networks:
      - media-network
      - socket-proxy-network
    restart: unless-stopped
EOF

curl -fsSL https://raw.githubusercontent.com/placq/media-stack/main/update_stack.sh -o "$INSTALL_DIR/update_stack.sh"
chmod 750 "$INSTALL_DIR/update_stack.sh"

cat > "$INSTALL_DIR/port.sh" <<'PORT_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
PORT=$(docker exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || true)
if [[ -n "$PORT" ]]; then
    echo "Current ProtonVPN forwarded port: $PORT"
else
    echo "No forwarded port is available yet. Check: docker logs gluetun"
    exit 1
fi
PORT_HELPER
chmod 750 "$INSTALL_DIR/port.sh"

cat > "$INSTALL_DIR/important_info.md" <<EOF
# Media Stack

## Local access

- Jellyfin: http://${LAN_IP}:8096
- Seerr: http://${LAN_IP}:5055
- Transmission: http://${LAN_IP}:9091
- Radarr: http://${LAN_IP}:7878
- Sonarr: http://${LAN_IP}:8989
- Prowlarr: http://${LAN_IP}:9696
- Bazarr: http://${LAN_IP}:6767

## Public access through Pangolin

- Jellyfin: https://jellyfin.${PUBLIC_DOMAIN}
- Seerr: https://seerr.${PUBLIC_DOMAIN}

Only Jellyfin and Seerr are published through Pangolin. Administrative services remain private.

## Remote administration through Tailscale

The installer configures Tailscale Serve on the same service ports. Use this machine's MagicDNS name or Tailscale IP from a device connected to your tailnet.

## Internal service addresses

- Transmission: gluetun:9091
- Prowlarr: prowlarr:9696
- FlareSolverr: http://flaresolverr:8191
- Jellyfin: jellyfin:8096
- Seerr: seerr:5055

Use category \`movies\` in Radarr and \`tv\` in Sonarr. All download and media paths share the \`/data\` mount, so hardlinks work without remote path mappings.

## Automatic updates

The stack checks for updates every night. A candidate image must remain unchanged for seven days before installation. Immediately before updating, the stack is stopped and its configuration is backed up. Failed health checks trigger an automatic rollback.
EOF

chown -R "$PUID:$PGID" "$INSTALL_DIR/config" "$INSTALL_DIR/data"
chown -R 1000:1000 "$INSTALL_DIR/config/seerr"
find "$INSTALL_DIR/config" -type d -exec chmod 750 {} +
find "$INSTALL_DIR/config" -type f -exec chmod 640 {} +
find "$INSTALL_DIR/data" -type d -exec chmod 775 {} +
chmod 600 "$INSTALL_DIR/.env"
chmod 640 "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/important_info.md"

log_info "Validating Docker Compose configuration..."
cd "$INSTALL_DIR"
docker compose config --quiet
docker compose up -d

log_info "Configuring private Tailscale access..."
for port in 8096 5055 9091 7878 8989 9696 6767; do
    if ! tailscale serve --bg --https="$port" "http://127.0.0.1:$port"; then
        log_warn "Tailscale Serve could not configure HTTPS port $port. You can retry after installation."
    fi
done

cat > /etc/systemd/system/media-stack-update.service <<EOF
[Unit]
Description=Delayed automatic updates for Media Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
WorkingDirectory="${INSTALL_DIR}"
ExecStart="${INSTALL_DIR}/update_stack.sh"
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

systemctl daemon-reload
systemctl enable --now media-stack-update.timer

log_success "Media Stack installed in $INSTALL_DIR."
echo
cat "$INSTALL_DIR/important_info.md"
