#!/bin/bash

# --- Color Configuration ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- 0. Permission and Environment Check ---
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run with root privileges (sudo)."
fi

# Detect real user (behind sudo or root)
REAL_USER=${SUDO_USER:-$USER}
PUID=$(id -u "$REAL_USER")
PGID=$(id -g "$REAL_USER")
TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/London")

# --- 1. Pre-Flight Port Check ---
log_info "Running pre-flight checks..."
REQUIRED_PORTS=(8096 5055 9091 7878 8989 9696 6767 3000)
for port in "${REQUIRED_PORTS[@]}"; do
    if ss -tuln | grep -q ":$port "; then
        log_error "Port $port is already in use! Please stop the conflicting service and try again."
    fi
done
log_success "All required ports are available."

# --- 2. System Update ---
log_info "Updating package lists..."
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y -q || log_error "System update failed."

# --- 3. Docker Installation ---
if ! command -v docker &> /dev/null; then
    log_info "Installing Docker (official repository)..."
    apt-get install -y -q ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update && apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
log_success "Docker and Docker Compose are ready."

# --- 4. Interactive Configuration ---
clear
echo -e "${BLUE}===========================================${NC}"
echo -e "${BLUE}       MEDIA STACK INSTALLATION (v2.4)     ${NC}"
echo -e "${BLUE}===========================================${NC}"

SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "Detected Server IP: ${SERVER_IP}"
log_info "User: ${REAL_USER} (PUID: ${PUID}, PGID: ${PGID})"
log_info "Timezone: ${TZ}"

# Avoid running containers as root (PUID 0)
if [ "$PUID" -eq 0 ]; then
    log_warn "Detected root user. Running containers as root is not recommended."
    read -p "Create a dedicated 'media' user (UID 1000) for containers? (Y/n): " CREATE_USER
    if [[ "$CREATE_USER" != "n" && "$CREATE_USER" != "N" ]]; then
        if ! id "media" &>/dev/null; then
            useradd -u 1000 -U -d /opt/media-stack -s /bin/false media
        fi
        PUID=$(id -u media)
        PGID=$(id -g media)
        log_success "Using PUID: $PUID, PGID: $PGID (User: media)"
    fi
fi

read -p "Installation path [/opt/media-stack]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/media-stack}

echo -e "\n--- VPN (PROTONVPN) ---"
read -p "Proton Username (OpenVPN): " VPN_USER
read -s -p "Proton Password (OpenVPN): " VPN_PASS
echo ""

echo -e "\n--- PANGOLIN (TUNNEL) ---"
read -p "Pangolin Endpoint: " PANGOLIN_URL
read -p "Newt ID: " NEWT_ID
read -s -p "Newt Secret: " NEWT_SECRET
echo ""

# Extract base domain from Pangolin URL (e.g., pangolin.wphl.eu -> wphl.eu)
PANGOLIN_DOMAIN="${PANGOLIN_URL#pangolin.}"
if [ "$PANGOLIN_DOMAIN" = "$PANGOLIN_URL" ]; then
    # No "pangolin." prefix found, try to extract domain
    PANGOLIN_DOMAIN="${PANGOLIN_URL#*.}"
fi

# Pangolin service selection
echo -e "\n--- PANGOLIN SERVICES ---"
echo "Select services to expose via Pangolin (default: 3,4):"
echo "  1. Sonarr       5. Prowlarr"
echo "  2. Radarr       6. Bazarr"
echo "  3. Jellyfin     7. WUD"
echo "  4. Jellyseerr   8. Transmission"
read -p "Selection (comma-separated, e.g. 1,3,4 or 'all') [3,4]: " PANGOLIN_SVCS
PANGOLIN_SVCS=${PANGOLIN_SVCS:-"3,4"}

# Define Pangolin services: index:service:hostname:port:name
declare -A PANGOLIN_SERVICE_MAP
PANGOLIN_SERVICE_MAP[1]="sonarr:sonarr:8989"
PANGOLIN_SERVICE_MAP[2]="radarr:radarr:7878"
PANGOLIN_SERVICE_MAP[3]="jellyfin:jellyfin:8096"
PANGOLIN_SERVICE_MAP[4]="jellyseerr:jellyseerr:5055"
PANGOLIN_SERVICE_MAP[5]="prowlarr:prowlarr:9696"
PANGOLIN_SERVICE_MAP[6]="bazarr:bazarr:6767"
PANGOLIN_SERVICE_MAP[7]="wud:wud:3000"
PANGOLIN_SERVICE_MAP[8]="transmission:gluetun:9099"

# Generate labels for selected services
SONARR_LABELS=""
RADARR_LABELS=""
JELLYFIN_LABELS=""
JELLYSEERR_LABELS=""
PROWLARR_LABELS=""
BAZARR_LABELS=""
WUD_LABELS=""
TRANSMISSION_LABELS=""

generate_pangolin_labels() {
    local service=$1
    local hostname=$2
    local port=$3
    local full_domain="${service}.${PANGOLIN_DOMAIN}"
    
    echo "      - pangolin.public-resources.${service}.name=${service^}"
    echo "      - pangolin.public-resources.${service}.full-domain=${full_domain}"
    echo "      - pangolin.public-resources.${service}.protocol=http"
    echo "      - pangolin.public-resources.${service}.targets[0].method=http"
    echo "      - pangolin.public-resources.${service}.targets[0].hostname=${hostname}"
    echo "      - pangolin.public-resources.${service}.targets[0].port=${port}"
}

# Parse selection and generate labels
IFS=',' read -ra SELECTED <<< "$PANGOLIN_SVCS"
for idx in "${SELECTED[@]}"; do
    idx=$(echo $idx | xargs)  # trim whitespace
    if [[ -n "${PANGOLIN_SERVICE_MAP[$idx]}" ]]; then
        IFS=':' read -r svc host port <<< "${PANGOLIN_SERVICE_MAP[$idx]}"
        case $svc in
            sonarr)     SONARR_LABELS=$(generate_pangolin_labels "sonarr" "$host" "$port") ;;
            radarr)     RADARR_LABELS=$(generate_pangolin_labels "radarr" "$host" "$port") ;;
            jellyfin)   JELLYFIN_LABELS=$(generate_pangolin_labels "jellyfin" "$host" "$port") ;;
            jellyseerr) JELLYSEERR_LABELS=$(generate_pangolin_labels "jellyseerr" "$host" "$port") ;;
            prowlarr)   PROWLARR_LABELS=$(generate_pangolin_labels "prowlarr" "$host" "$port") ;;
            bazarr)     BAZARR_LABELS=$(generate_pangolin_labels "bazarr" "$host" "$port") ;;
            wud)        WUD_LABELS=$(generate_pangolin_labels "wud" "$host" "$port") ;;
            transmission) TRANSMISSION_LABELS=$(generate_pangolin_labels "transmission" "$host" "$port") ;;
        esac
    fi
done

# Determine if any Pangolin services are selected
if [[ -n "$SONARR_LABELS" || -n "$RADARR_LABELS" || -n "$JELLYFIN_LABELS" || -n "$JELLYSEERR_LABELS" || -n "$PROWLARR_LABELS" || -n "$BAZARR_LABELS" || -n "$WUD_LABELS" || -n "$TRANSMISSION_LABELS" ]]; then
    NEWT_DOCKER_SOCKET="      - /var/run/docker.sock:/var/run/docker.sock"
    NEWT_DOCKER_ENV="      - DOCKER_SOCKET=/var/run/docker.sock"
    log_info "Pangolin auto-discovery enabled for selected services."
fi

echo -e "\n--- TRANSMISSION ---"
# Generate secure default password instead of 'admin'
DEFAULT_TR_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
read -p "Transmission Username [admin]: " TR_USER
TR_USER=${TR_USER:-admin}
read -p "Transmission Password [${DEFAULT_TR_PASS}]: " TR_PASS
TR_PASS=${TR_PASS:-$DEFAULT_TR_PASS}
echo ""

# QuickSync detection
GPU_CONFIG=""
if [ -d "/dev/dri" ]; then
    log_info "GPU drivers detected (/dev/dri)."
    read -p "Enable GPU support (Intel QuickSync) in Jellyfin? (y/n): " ENABLE_GPU
    if [[ "$ENABLE_GPU" == "y" || "$ENABLE_GPU" == "Y" ]]; then
        RENDER_GID=$(stat -c '%g' /dev/dri/renderD128 2>/dev/null || echo "107")
        GPU_CONFIG="    devices:\n      - /dev/dri:/dev/dri\n    group_add:\n      - \"$RENDER_GID\""
    fi
fi

# --- 5. Directory Structure ---
log_info "Preparing directory structure in $INSTALL_DIR..."
DIRS=(
    "config/gluetun" "config/transmission" "config/sonarr" "config/radarr"
    "config/prowlarr" "config/bazarr" "config/jellyfin" "config/jellyseerr" "config/flaresolverr" "config/wud"
    "data/torrents/movies" "data/torrents/tv" "data/torrents/incomplete"
    "data/media/movies" "data/media/tv"
)

# Efficient folder creation
for dir in "${DIRS[@]}"; do
    mkdir -p "$INSTALL_DIR/$dir"
done

# --- 6. Fix Transmission Pathing (Pre-generate settings.json) ---
# We ONLY enforce the correct paths here to fix hardlinks.
# Authentication is left to the linuxserver container variables (USER/PASS).
log_info "Pre-configuring Transmission settings to use /data volume..."
cat <<EOF > "$INSTALL_DIR/config/transmission/settings.json"
{
    "download-dir": "/data/torrents",
    "incomplete-dir": "/data/torrents/incomplete",
    "incomplete-dir-enabled": true
}
EOF

# --- 7. Configuration Files ---
[ -f "$INSTALL_DIR/.env" ] && mv "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.bak"

# Wrap all values in quotes to prevent issues with spaces/special characters
cat <<EOF > "$INSTALL_DIR/.env"
PUID="$PUID"
PGID="$PGID"
INSTALL_DIR="$INSTALL_DIR"
VPN_USER="$VPN_USER+pmp"
VPN_PASS="$VPN_PASS"
PANGOLIN_URL="$PANGOLIN_URL"
NEWT_ID="$NEWT_ID"
NEWT_SECRET="$NEWT_SECRET"
TZ="$TZ"
TR_USER="$TR_USER"
TR_PASS="$TR_PASS"
EOF

# Generate docker-compose.yml
log_info "Generating docker-compose.yml..."
cat <<EOF > "$INSTALL_DIR/docker-compose.yml"
networks:
  media-network:
    driver: bridge

services:
  gluetun:
    image: qmcgaw/gluetun:latest
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
      - VPN_PORT_FORWARDING_PROVIDER=protonvpn
    volumes:
      - \${INSTALL_DIR}/config/gluetun:/gluetun
    ports:
      - 9091:9091/tcp      # Transmission Web UI
      - 51413:51413/tcp    # Transmission Torrent Port
      - 51413:51413/udp
    networks:
      - media-network
    restart: unless-stopped

  transmission:
    image: lscr.io/linuxserver/transmission:latest
    container_name: transmission
    network_mode: "service:gluetun"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - USER=${TR_USER}
      - PASS=${TR_PASS}
    volumes:
      - ${INSTALL_DIR}/config/transmission:/config
      - ${INSTALL_DIR}/data:/data
    labels:
${TRANSMISSION_LABELS:-      - pangolin.public-resources.transmission.enabled=false}
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
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${INSTALL_DIR}/config/prowlarr:/config
    networks:
      - media-network
    ports:
      - 9696:9696
    labels:
${PROWLARR_LABELS:-      - pangolin.public-resources.prowlarr.enabled=false}
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${INSTALL_DIR}/config/sonarr:/config
      - ${INSTALL_DIR}/data:/data
    networks:
      - media-network
    ports:
      - 8989:8989
    labels:
${SONARR_LABELS:-      - pangolin.public-resources.sonarr.enabled=false}
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${INSTALL_DIR}/config/radarr:/config
      - ${INSTALL_DIR}/data:/data
    networks:
      - media-network
    ports:
      - 7878:7878
    labels:
${RADARR_LABELS:-      - pangolin.public-resources.radarr.enabled=false}
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${INSTALL_DIR}/config/bazarr:/config
      - ${INSTALL_DIR}/data:/data
    networks:
      - media-network
    ports:
      - 6767:6767
    labels:
${BAZARR_LABELS:-      - pangolin.public-resources.bazarr.enabled=false}
    restart: unless-stopped

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${INSTALL_DIR}/config/jellyfin:/config
      - ${INSTALL_DIR}/data:/data
    networks:
      - media-network
    ports:
      - 8096:8096
    labels:
${JELLYFIN_LABELS:-      - pangolin.public-resources.jellyfin.enabled=false}
$(echo -e "$GPU_CONFIG")
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${INSTALL_DIR}/config/jellyseerr:/app/config
    networks:
      - media-network
    ports:
      - 5055:5055
    labels:
${JELLYSEERR_LABELS:-      - pangolin.public-resources.jellyseerr.enabled=false}
    restart: unless-stopped

  newt:
    image: fosrl/newt:latest
    container_name: newt
    volumes:
${NEWT_DOCKER_SOCKET:-#      - /var/run/docker.sock:/var/run/docker.sock}
    environment:
      - PANGOLIN_ENDPOINT=${PANGOLIN_URL}
      - NEWT_ID=${NEWT_ID}
      - NEWT_SECRET=${NEWT_SECRET}
${NEWT_DOCKER_ENV:-#      - DOCKER_SOCKET=/var/run/docker.sock}
    networks:
      - media-network
    restart: unless-stopped

  wud:
    image: fmartinou/whats-up-docker:latest
    container_name: wud
    environment:
      - TZ=${TZ}
      - WUD_LOG_LEVEL=INFO
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - 3000:3000
    networks:
      - media-network
    labels:
${WUD_LABELS:-      - pangolin.public-resources.wud.enabled=false}
    restart: unless-stopped
EOF

# Set permissions for the stack
chown -R $PUID:$PGID "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 775 {} +
find "$INSTALL_DIR" -type f -exec chmod 664 {} +
chmod 600 "$INSTALL_DIR/.env"

# --- 8. Create important_info.md ---
cat <<EOF > "$INSTALL_DIR/important_info.md"
# Media Stack - Important Information

## 🌐 Services and Addresses
You can access your services locally via your server's IP address:
*   **Jellyfin:** \`http://${SERVER_IP}:8096\`
*   **Jellyseerr:** \`http://${SERVER_IP}:5055\`
*   **Transmission:** \`http://${SERVER_IP}:9091\`
*   **Radarr:** \`http://${SERVER_IP}:7878\`
*   **Sonarr:** \`http://${SERVER_IP}:8989\`
*   **Prowlarr:** \`http://${SERVER_IP}:9696\`
*   **Bazarr:** \`http://${SERVER_IP}:6767\`
*   **WUD:** \`http://${SERVER_IP}:3000\`

## 🔑 Transmission Credentials
*   **Username:** \`${TR_USER}\`
*   **Password:** \`${TR_PASS}\`

## 🔗 Inter-Container Communication (IMPORTANT!)
When configuring services to talk to each other (e.g., adding Transmission or Prowlarr to Radarr), **DO NOT use the server's IP address**.
Instead, use the container names. This is significantly faster and prevents timeouts.

*   **Transmission Host:** \`gluetun\` (Port: \`9091\`)
    *(Note: Transmission routes its network through Gluetun, so Gluetun acts as the host on the Docker network)*
*   **Prowlarr Host:** \`prowlarr\` (Port: \`9696\`)
*   **FlareSolverr Host:** \`flaresolverr\` (Port: \`8191\`) - Add this as an Indexer Proxy in Prowlarr as \`http://flaresolverr:8191\`

## ⚙️ Radarr & Sonarr Configuration (Crucial!)
When you add Transmission as your Download Client in Radarr or Sonarr, you MUST set the correct **Category** to prevent path errors:
*   In **Radarr** (Settings -> Download Clients): Set Category to \`movies\`
*   In **Sonarr** (Settings -> Download Clients): Set Category to \`tv\`
*(This tells Transmission to put files in \`/data/torrents/movies\` or \`tv\`, which exactly matches our automated folder structure).*

## 🛡️ VPN and Port Forwarding (ProtonVPN)
Transmission is routed through the Gluetun VPN container. For optimal download speeds and active peer connections, you must configure the forwarded port in Transmission:
1. Run this command in your terminal to check the Gluetun logs:
   \`docker logs gluetun | grep "port forwarded"\`
2. Note the port number (e.g., \`port forwarded is 45678\`).
3. Open the Transmission Web UI (\`http://${SERVER_IP}:9091\`).
4. Go to **Settings -> Network** and enter this port number in the **"Peer listening port"** field.
5. *(Note: This port might change occasionally depending on ProtonVPN. If downloads ever slow down, check the logs and update the port again.)*

## 📁 Folder Mapping and Hardlinks
We have pre-configured Transmission to download directly to \`/data/torrents\`.
Because all containers use the unified \`/data\` volume mapping, **hardlinks will work automatically**.
When Radarr/Sonarr imports a movie/show from the torrents folder, it will create a hardlink in \`/data/media\` instead of copying the file, saving disk space and time. No remote path mappings are required in Radarr or Sonarr!

*Generated on: $(date)*
EOF

# --- 9. Startup ---
log_info "Starting Docker containers..."
cd "$INSTALL_DIR" && docker compose up -d

log_success "Installation successful in $INSTALL_DIR!"
echo ""
echo -e "${BLUE}=================================================================${NC}"
cat "$INSTALL_DIR/important_info.md"
echo -e "${BLUE}=================================================================${NC}"
echo -e "${GREEN}A copy of this summary has been saved to $INSTALL_DIR/important_info.md${NC}"
echo -e "${GREEN}You can also manually edit $INSTALL_DIR/docker-compose.yml anytime.${NC}"
