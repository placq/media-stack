#!/bin/bash

# --- Color Configuration ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- 1. System Update & Upgrade ---
log_info "Starting full system update..."
sudo apt update && sudo apt upgrade -y || log_error "System update failed."

# --- 2. Check and install Docker (official repository) ---
if ! command -v docker &> /dev/null; then
    log_info "Installing Docker (official repository, not snap)..."
    sudo apt install -y ca-certificates curl gnupg lsb-release
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
log_success "Docker and Docker Compose are ready."

# --- 3. Interactive Configuration ---
clear
echo -e "${BLUE}===========================================${NC}"
echo -e "${BLUE}       MEDIA STACK INSTALLATION            ${NC}"
echo -e "${BLUE}===========================================${NC}"

# IP Detection
SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "Detected server IP: ${SERVER_IP}"

read -p "Enter installation path [/opt/media-stack]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/media-stack}

echo -e "\n--- VPN CONFIGURATION (PROTONVPN) ---"
echo -e "${YELLOW}NOTE:${NC} Use 'OpenVPN Credentials' from the Proton panel, NOT your main password!"
read -p "Proton OpenVPN Username: " VPN_USER
read -s -p "Proton OpenVPN Password: " VPN_PASS
echo ""

echo -e "\n--- PANGOLIN CONFIGURATION (TUNNEL) ---"
read -p "Pangolin Endpoint: " PANGOLIN_URL
read -p "Newt ID: " NEWT_ID
read -s -p "Newt Secret: " NEWT_SECRET
echo -e "\n"

# PUID/PGID
PUID=$(id -u)
PGID=$(id -g)

# Intelligent QuickSync detection
GPU_CONFIG=""
if [ -d "/dev/dri" ]; then
    echo -e "${GREEN}Intel graphics support (QuickSync) detected.${NC}"
    read -p "Enable hardware transcoding in Jellyfin? (y/n): " ENABLE_GPU
    if [[ "$ENABLE_GPU" == "y" ]]; then
        GPU_CONFIG="devices:\n      - /dev/dri:/dev/dri\n    group_add:\n      - \"$(stat -c '%g' /dev/dri/renderD128)\""
    fi
fi

# --- 4. Folder Structure ---
log_info "Creating folder structure for Hardlinks..."
sudo mkdir -p "$INSTALL_DIR"/{config,data/{torrents/{movies,tv},media/{movies,tv}}}
sudo chown -R $USER:$USER "$INSTALL_DIR"

# --- 5. Environment File (.env) ---
cat <<EOF > "$INSTALL_DIR"/.env
PUID=$PUID
PGID=$PGID
INSTALL_DIR=$INSTALL_DIR
VPN_USER=$VPN_USER+pmp
VPN_PASS=$VPN_PASS
PANGOLIN_URL=$PANGOLIN_URL
NEWT_ID=$NEWT_ID
NEWT_SECRET=$NEWT_SECRET
TZ=Europe/Warsaw
EOF

# --- 6. Docker Compose File (docker-compose.yml) ---
cat <<EOF > "$INSTALL_DIR"/docker-compose.yml
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
    volumes:
      - \${INSTALL_DIR}/config/gluetun:/gluetun
    ports:
      - 9091:9091/tcp
      - 51413:51413/tcp
      - 51413:51413/udp
    restart: unless-stopped

  transmission:
    image: lscr.io/linuxserver/transmission:latest
    container_name: transmission
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_started
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
      - USER=admin
      - PASS=admin
      - TRANSMISSION_DOWNLOAD_DIR=/data/torrents
    volumes:
      - \${INSTALL_DIR}/config/transmission:/config
      - \${INSTALL_DIR}/data:/data
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
    ports:
      - 8989:8989
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
    ports:
      - 7878:7878
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    ports:
      - 8191:8191
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
    ports:
      - 9696:9696
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
    ports:
      - 6767:6767
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
    ports:
      - 8096:8096
    $(echo -e "$GPU_CONFIG")
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    depends_on:
      - sonarr
      - radarr
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${INSTALL_DIR}/config/jellyseerr:/app/config
    ports:
      - 5055:5055
    restart: unless-stopped

  newt:
    image: fosrl/newt:latest
    container_name: newt
    environment:
      - PANGOLIN_ENDPOINT=\${PANGOLIN_URL}
      - NEWT_ID=\${NEWT_ID}
      - NEWT_SECRET=\${NEWT_SECRET}
    restart: unless-stopped

  wud:
    image: fmartinou/whats-up-docker:latest
    container_name: wud
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - 3000:3000
    restart: unless-stopped
EOF

# --- 7. Start ---
log_info "Starting containers..."
cd "$INSTALL_DIR" && sudo docker compose up -d

# --- 8. Create info.md ---
log_info "Creating info.md with service details..."
cat <<EOF > "$INSTALL_DIR"/info.md
# Perfect Media Stack - Service Information

Your applications are available at the following addresses:

| Service | URL | Credentials |
| :--- | :--- | :--- |
| 🎬 Jellyfin (Media) | http://${SERVER_IP}:8096 | User-defined |
| 🎫 Jellyseerr (Requests) | http://${SERVER_IP}:5055 | User-defined |
| 📥 Transmission (Downloads) | http://${SERVER_IP}:9091 | admin / admin |
| 🎥 Radarr (Movies) | http://${SERVER_IP}:7878 | - |
| 📺 Sonarr (TV Shows) | http://${SERVER_IP}:8989 | - |
| 🔍 Prowlarr (Indexers) | http://${SERVER_IP}:9696 | - |
| 📝 Bazarr (Subtitles) | http://${SERVER_IP}:6767 | - |
| 🔄 WUD (Updates) | http://${SERVER_IP}:3000 | - |

## Critical Post-Installation Steps

1. **Transmission Host:** In Sonarr/Radarr/Prowlarr use host: \`gluetun\` (port 9091).
2. **Download Paths:** In Transmission set: \`/data/torrents\`.
3. **Library Paths:** In Sonarr/Radarr set: \`/data/media/tv\` and \`/data/media/movies\`.
4. **FlareSolverr:** In Prowlarr add Indexer Proxy: \`http://flaresolverr:8191\`.

*File generated on: $(date)*
EOF

# --- 9. Summary ---
clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}      INSTALLATION COMPLETED SUCCESSFULLY!          ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "\nYour applications are available at the following addresses:\n"

echo -e "🎬  ${BLUE}Jellyfin (Media):${NC}       http://${SERVER_IP}:8096"
echo -e "🎫  ${BLUE}Jellyseerr (Requests):${NC}    http://${SERVER_IP}:5055"
echo -e "📥  ${BLUE}Transmission (Downloads):${NC} http://${SERVER_IP}:9091 (Login: admin / admin)"
echo -e "🎥  ${BLUE}Radarr (Movies):${NC}         http://${SERVER_IP}:7878"
echo -e "📺  ${BLUE}Sonarr (TV Shows):${NC}       http://${SERVER_IP}:8989"
echo -e "🔍  ${BLUE}Prowlarr (Indexers):${NC}    http://${SERVER_IP}:9696"
echo -e "📝  ${BLUE}Bazarr (Subtitles):${NC}        http://${SERVER_IP}:6767"
echo -e "🔄  ${BLUE}WUD (Updates):${NC}           http://${SERVER_IP}:3000"

echo -e "\n${YELLOW}CRITICAL POST-INSTALLATION STEPS (Saved in $INSTALL_DIR/info.md):${NC}"
echo -e "1. ${YELLOW}Transmission Host:${NC} In Sonarr/Radarr/Prowlarr use host: ${GREEN}gluetun${NC} (port 9091)."
echo -e "2. ${YELLOW}Download Paths:${NC} In Transmission set: ${GREEN}/data/torrents${NC}."
echo -e "3. ${YELLOW}Library Paths:${NC} In Sonarr/Radarr set: ${GREEN}/data/media/tv${NC} and ${GREEN}/data/media/movies${NC}."
echo -e "4. ${YELLOW}FlareSolverr:${NC} In Prowlarr add Indexer Proxy: ${GREEN}http://flaresolverr:8191${NC}."
echo -e "====================================================\n"
