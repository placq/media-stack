#!/bin/bash

# --- Konfiguracja Kolorów ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- 1. Aktualizacja Systemu ---
log_info "Aktualizacja systemu..."
sudo apt update && sudo apt upgrade -y || log_error "Aktualizacja nie powiodła się."

# --- 2. Instalacja Docker ---
if ! command -v docker &> /dev/null; then
    log_info "Instalacja Docker (oficjalne repozytorium)..."
    sudo apt install -y ca-certificates curl gnupg lsb-release
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
log_success "Docker jest gotowy."

# --- 3. Konfiguracja Interaktywna ---
clear
echo -e "${BLUE}===========================================${NC}"
echo -e "${BLUE}       MEDIA STACK INSTALLATION (FIXED)    ${NC}"
echo -e "${BLUE}===========================================${NC}"

SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "Wykryte IP serwera: ${SERVER_IP}"

read -p "Ścieżka instalacji [/root/media-stack]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/root/media-stack}

echo -e "\n--- VPN CONFIGURATION (PROTONVPN) ---"
echo -e "${YELLOW}UWAGA:${NC} Użyj 'OpenVPN Credentials' z panelu Proton, NIE głównego hasła!"
read -p "Proton Username: " VPN_USER
read -s -p "Proton Password: " VPN_PASS
echo ""

echo -e "\n--- PANGOLIN CONFIGURATION (TUNNEL) ---"
read -p "Pangolin Endpoint: " PANGOLIN_URL
read -p "Newt ID: " NEWT_ID
read -s -p "Newt Secret: " NEWT_SECRET
echo ""

# PUID/PGID - Standard dla LSIO
PUID=1000
PGID=1000

# QuickSync detection
GPU_CONFIG=""
if [ -d "/dev/dri" ]; then
    log_info "Wykryto wsparcie dla Intel QuickSync."
    read -p "Włączyć transkodowanie sprzętowe w Jellyfin? (y/n): " ENABLE_GPU
    if [[ "$ENABLE_GPU" == "y" ]]; then
        GPU_CONFIG="devices:\n      - /dev/dri:/dev/dri\n    group_add:\n      - \"$(stat -c '%g' /dev/dri/renderD128)\""
    fi
fi

# --- 4. Struktura Katalogów (Pod Hardlinki) ---
log_info "Tworzenie struktury katalogów i ustawianie uprawnień..."
# Tworzymy czystą strukturę
sudo mkdir -p "$INSTALL_DIR"/{config,data,watch}
sudo mkdir -p "$INSTALL_DIR"/config/{gluetun,transmission,sonarr,radarr,prowlarr,bazarr,jellyfin,jellyseerr}
sudo mkdir -p "$INSTALL_DIR"/data/{torrents/{movies,tv,incomplete},media/{movies,tv}}

# Kluczowe: uprawnienia dla użytkownika 1000 (abc w kontenerach)
sudo chown -R 1000:1000 "$INSTALL_DIR"
sudo chmod -R 775 "$INSTALL_DIR"

# --- 5. Plik .env ---
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

# --- 6. Docker Compose (Ujednolicone mapowanie /data) ---
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
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
      - USER=admin
      - PASS=admin
      - TRANSMISSION_DOWNLOAD_DIR=/data/torrents
      - TRANSMISSION_INCOMPLETE_DIR=/data/torrents/incomplete
      - TRANSMISSION_INCOMPLETE_DIR_ENABLED=true
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

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
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
EOF

# --- 7. Uruchomienie ---
log_info "Uruchamianie kontenerów..."
cd "$INSTALL_DIR" && sudo docker compose up -d

# --- 8. Tworzenie info.md ---
cat <<EOF > "$INSTALL_DIR"/info.md
# Perfect Media Stack - Service Information

Twoje aplikacje są dostępne pod adresami:

| Serwis | URL | Poświadczenia |
| :--- | :--- | :--- |
| 🎬 Jellyfin | http://${SERVER_IP}:8096 | Zdefiniuj przy starcie |
| 📥 Transmission | http://${SERVER_IP}:9091 | admin / admin |
| 🎥 Radarr | http://${SERVER_IP}:7878 | - |
| 📺 Sonarr | http://${SERVER_IP}:8989 | - |
| 🔍 Prowlarr | http://${SERVER_IP}:9696 | - |

## 🚀 KLUCZOWA KONFIGURACJA (Aby uniknąć błędów ścieżek):

1. **W Radarr/Sonarr (Download Clients):**
   - Dodaj Transmission (Host: \`gluetun\`, Port: \`9091\`).
   - W polu **Category** wpisz odpowiednio: \`movies\` (dla Radarr) lub \`tv\` (dla Sonarr).
   - Dzięki temu pliki trafią do \`/data/torrents/movies\` lub \`/data/torrents/tv\`.

2. **W Radarr/Sonarr (Root Folders):**
   - Radarr: \`/data/media/movies\`
   - Sonarr: \`/data/media/tv\`

3. **Dlaczego to działa?**
   Wszystkie kontenery widzą ten sam folder \`/data\`. Kiedy Transmission pobierze plik do \`/data/torrents/movies\`, Radarr widzi go tam natychmiast i może utworzyć **Hardlink** do biblioteki media bez kopiowania danych.

*Plik wygenerowany: $(date)*
EOF

log_success "Instalacja zakończona sukcesem!"
log_info "Szczegóły znajdziesz w: $INSTALL_DIR/info.md"
