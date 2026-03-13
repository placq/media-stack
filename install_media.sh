#!/bin/bash

# --- Konfiguracja Kolorów ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- 0. Sprawdzenie uprawnień i środowiska ---
if [[ $EUID -ne 0 ]]; then
   log_error "Ten skrypt musi być uruchomiony z uprawnieniami roota (sudo)."
fi

# Wykrywanie realnego użytkownika (za sudo)
REAL_USER=${SUDO_USER:-$USER}
PUID=$(id -u "$REAL_USER")
PGID=$(id -g "$REAL_USER")
TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/Warsaw")

# --- 1. Aktualizacja Systemu ---
log_info "Aktualizacja list pakietów..."
apt update && apt upgrade -y || log_error "Aktualizacja systemu nie powiodła się."

# --- 2. Instalacja Docker ---
if ! command -v docker &> /dev/null; then
    log_info "Instalacja Docker (oficjalne repozytorium)..."
    apt install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
log_success "Docker i Docker Compose są gotowe."

# --- 3. Konfiguracja Interaktywna ---
clear
echo -e "${BLUE}===========================================${NC}"
echo -e "${BLUE}       MEDIA STACK INSTALLATION (v2.2)     ${NC}"
echo -e "${BLUE}===========================================${NC}"

SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "Wykryte IP serwera: ${SERVER_IP}"
log_info "Użytkownik: ${REAL_USER} (PUID: ${PUID}, PGID: ${PGID})"
log_info "Strefa czasowa: ${TZ}"

read -p "Ścieżka instalacji [/home/${REAL_USER}/media-stack]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/home/${REAL_USER}/media-stack}

echo -e "\n--- VPN (PROTONVPN) ---"
read -p "Proton Username (OpenVPN): " VPN_USER
read -s -p "Proton Password (OpenVPN): " VPN_PASS
echo ""

echo -e "\n--- PANGOLIN (TUNNEL) ---"
read -p "Pangolin Endpoint: " PANGOLIN_URL
read -p "Newt ID: " NEWT_ID
read -s -p "Newt Secret: " NEWT_SECRET
echo ""

echo -e "\n--- TRANSMISSION ---"
read -p "Transmission Username [admin]: " TR_USER
TR_USER=${TR_USER:-admin}
read -s -p "Transmission Password [admin]: " TR_PASS
TR_PASS=${TR_PASS:-admin}
echo ""

# QuickSync detection
GPU_CONFIG=""
if [ -d "/dev/dri" ]; then
    log_info "Wykryto sterowniki GPU (/dev/dri)."
    read -p "Włączyć wsparcie GPU (Intel QuickSync) in Jellyfin? (y/n): " ENABLE_GPU
    if [[ "$ENABLE_GPU" == "y" ]]; then
        RENDER_GID=$(stat -c '%g' /dev/dri/renderD128 2>/dev/null || echo "107")
        GPU_CONFIG="devices:\n      - /dev/dri:/dev/dri\n    group_add:\n      - \"$RENDER_GID\""
    fi
fi

# --- 4. Struktura Katalogów ---
log_info "Przygotowanie struktury katalogów w $INSTALL_DIR..."
DIRS=(
    "config/gluetun" "config/transmission" "config/sonarr" "config/radarr" 
    "config/prowlarr" "config/bazarr" "config/jellyfin" "config/jellyseerr" "config/flaresolverr"
    "data/torrents/movies" "data/torrents/tv" "data/torrents/incomplete" 
    "data/media/movies" "data/media/tv" "watch"
)

for dir in "${DIRS[@]}"; do
    mkdir -p "$INSTALL_DIR/$dir"
done

# --- 5. Pliki Konfiguracyjne ---
[ -f "$INSTALL_DIR/.env" ] && mv "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.bak"

cat <<EOF > "$INSTALL_DIR"/.env
PUID=$PUID
PGID=$PGID
INSTALL_DIR=$INSTALL_DIR
VPN_USER=$VPN_USER+pmp
VPN_PASS=$VPN_PASS
PANGOLIN_URL=$PANGOLIN_URL
NEWT_ID=$NEWT_ID
NEWT_SECRET=$NEWT_SECRET
TZ=$TZ
TR_USER=$TR_USER
TR_PASS=$TR_PASS
EOF

# Generowanie docker-compose.yml
cat <<EOF > "$INSTALL_DIR"/docker-compose.yml
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
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
      - USER=\${TR_USER}
      - PASS=\${TR_PASS}
      - TRANSMISSION_DOWNLOAD_DIR=/data/torrents
      - TRANSMISSION_INCOMPLETE_DIR=/data/torrents/incomplete
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
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${INSTALL_DIR}/config/prowlarr:/config
    networks:
      - media-network
    ports:
      - 9696:9696
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
    networks:
      - media-network
    ports:
      - 7878:7878
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
    networks:
      - media-network
    ports:
      - 8096:8096
$(echo -e "$GPU_CONFIG" | sed 's/^/    /')
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${INSTALL_DIR}/config/jellyseerr:/app/config
    networks:
      - media-network
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
    networks:
      - media-network
    restart: unless-stopped
EOF

# Ustawienie uprawnień dla całego stosu
chown -R $PUID:$PGID "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 775 {} +
find "$INSTALL_DIR" -type f -exec chmod 664 {} +
chmod 600 "$INSTALL_DIR"/.env

# --- 6. Uruchomienie ---
log_info "Uruchamianie kontenerów..."
cd "$INSTALL_DIR" && docker compose up -d

# --- 7. Tworzenie info.md ---
cat <<EOF > "$INSTALL_DIR"/info.md
# Perfect Media Stack - Podsumowanie

| Serwis | Adres |
| :--- | :--- |
| 🎬 Jellyfin | http://${SERVER_IP}:8096 |
| 🎫 Jellyseerr | http://${SERVER_IP}:5055 |
| 📥 Transmission | http://${SERVER_IP}:9091 |
| 🎥 Radarr | http://${SERVER_IP}:7878 |
| 📺 Sonarr | http://${SERVER_IP}:8989 |
| 🔍 Prowlarr | http://${SERVER_IP}:9696 |
| 📝 Bazarr | http://${SERVER_IP}:6767 |

## 🛡️ VPN i Port Forwarding
1. Sprawdź port w logach: \`docker logs gluetun\`
2. Znajdź linię: \`port forwarded is XXXXX\`.
3. W Transmission (Ustawienia -> Network) wpisz ten port w "Peer listening port".

## ⚙️ Konfiguracja Prowlarr + FlareSolverr
W Prowlarr dodaj FlareSolverr jako Indexer Proxy:
- Host: \`http://flaresolverr:8191\`

*Wygenerowano: $(date)*
EOF

log_success "Instalacja zakończona sukcesem w $INSTALL_DIR!"
log_info "Wszystkie dane są w jednym miejscu. Hardlinki będą działać automatycznie."
