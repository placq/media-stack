#!/bin/bash

# Colors for better readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}--- Checking VPN Port (Gluetun) ---${NC}"

# 1. Check if gluetun container is running
if ! docker ps --format '{{.Names}}' | grep -q "^gluetun$"; then
    echo -e "${RED}[ERROR] 'gluetun' container is not running.${NC}"
    exit 1
fi

# 2. Extract port from logs (looking for the last "port forwarded is" line)
PORT=$(docker logs gluetun 2>&1 | grep "port forwarded is" | tail -n 1 | grep -oE '[0-9]+$')

# 3. Display result
if [ -z "$PORT" ]; then
    echo -e "${YELLOW}[INFO] No forwarded port found yet.${NC}"
    echo -e "Ensure VPN is connected and Gluetun has requested a port from ProtonVPN."
    echo -e "You can check full logs with: ${BLUE}docker logs gluetun${NC}"
else
    echo -e "${GREEN}[SUCCESS] Your current port is: ${PORT}${NC}"
    echo -e ""
    echo -e "What to do next?"
    echo -e "1. Open Transmission Web UI in your browser."
    echo -e "2. Click the settings icon (wrench/screwdriver) in the bottom left corner."
    echo -e "3. Go to the ${BLUE}Network${NC} tab."
    echo -e "4. In the ${BLUE}Peer listening port${NC} field, enter: ${GREEN}${PORT}${NC}"
    echo -e "5. Click outside the field or close the window to save."
fi
