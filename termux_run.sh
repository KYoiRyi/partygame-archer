#!/usr/bin/env bash
set -e

# Colors for terminal styling
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}      ARCHER PUSH MOBA - TERMUX AUTOMATIC RUNNER      ${NC}"
echo -e "${BLUE}======================================================${NC}"

# 1. Verify if we are running in Termux
if [ -d "/data/data/com.termux" ]; then
    echo -e "${GREEN}[✔] Termux environment detected.${NC}"
else
    echo -e "${YELLOW}[!] Warning: Not running inside Termux, but proceeding anyway...${NC}"
fi

# 2. Check and install Go compiler
if ! command -v go &> /dev/null; then
    echo -e "${YELLOW}[!] Go compiler not found. Installing golang...${NC}"
    if command -v pkg &> /dev/null; then
        pkg update -y && pkg install -y golang
    else
        echo -e "${RED}[✗] Error: 'pkg' command not found. Please install Go manually.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}[✔] Go compiler is already installed: $(go version)${NC}"
fi

# 3. Compile the Go game server
echo -e "${BLUE}[*] Compiling the multiplayer backend server...${NC}"
if [ -d "server" ]; then
    cd server
    go build -o ../game_server
    cd ..
    echo -e "${GREEN}[✔] Compilation completed successfully!${NC}"
else
    echo -e "${RED}[✗] Error: 'server' directory not found in this folder.${NC}"
    exit 1
fi

# 4. Check for exported web client directory
if [ -d "dist" ] && [ -f "dist/index.html" ]; then
    echo -e "${GREEN}[✔] Web client static assets found.${NC}"
else
    echo -e "${RED}[✗] Error: 'dist' folder with exported client is missing.${NC}"
    exit 1
fi

# 5. Extract local IP addresses to make local network play super easy
echo -e "${BLUE}[*] Resolving network IP addresses...${NC}"
IP_LIST=$(ip addr show | grep -w inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1)

# Make sure executable permissions are set
chmod +x game_server

# Ask for SSL mode (HTTPS)
echo -e "${YELLOW}------------------------------------------------------${NC}"
echo -e "${YELLOW}Do you want to run the server in HTTPS (SSL) mode? (y/N)${NC}"
echo -e "${YELLOW}(Required for Wi-Fi LAN multiplayer due to browser security restrictions)${NC}"
echo -e "${YELLOW}Default is 'n' (HTTP mode) after 5 seconds.${NC}"
read -r -t 5 -p "Selection: " SSL_ANSWER || SSL_ANSWER="n"
echo ""

SSL_FLAG=""
PROTOCOL="http"
if [[ "$SSL_ANSWER" =~ ^[Yy]$ ]]; then
    SSL_FLAG="-ssl"
    PROTOCOL="https"
    echo -e "${GREEN}[✔] Running in HTTPS/SSL mode.${NC}"
else
    echo -e "${GREEN}[✔] Running in HTTP mode.${NC}"
fi

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}      SERVER IS READY TO RUN ON PORT 8090!            ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo -e "${YELLOW}To play on this Android device, open:${NC}"
echo -e "   👉 ${GREEN}${PROTOCOL}://localhost:8090${NC}"
echo ""
if [ -n "$IP_LIST" ]; then
    echo -e "${YELLOW}To play with friends on the same Wi-Fi network,${NC}"
    echo -e "${YELLOW}have them open one of these links on their browser:${NC}"
    for ip in $IP_LIST; do
        echo -e "   👉 ${GREEN}${PROTOCOL}://$ip:8090${NC}"
    done
fi
echo -e "${BLUE}======================================================${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop the server.${NC}"
echo -e "${BLUE}======================================================${NC}"

# 6. Run the server
./game_server -port=8090 $SSL_FLAG
