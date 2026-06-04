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

IS_TERMUX=false
if [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=true
    echo -e "${GREEN}[✔] Termux environment detected.${NC}"
else
    echo -e "${YELLOW}[!] Warning: Not running inside Termux, but proceeding anyway...${NC}"
fi

# 1. Check and install Go compiler
if ! command -v go &> /dev/null; then
    echo -e "${YELLOW}[!] Go compiler not found. Installing golang...${NC}"
    if [ "$IS_TERMUX" = true ] && command -v pkg &> /dev/null; then
        pkg update -y && pkg install -y golang
    else
        echo -e "${RED}[✗] Error: Please install Go manually.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}[✔] Go compiler is already installed: $(go version)${NC}"
fi

# 2. Check and install PostgreSQL for Termux
if [ "$IS_TERMUX" = true ]; then
    if ! command -v psql &> /dev/null; then
        echo -e "${YELLOW}[!] PostgreSQL not found. Installing postgresql...${NC}"
        pkg install -y postgresql
    else
        echo -e "${GREEN}[✔] PostgreSQL is already installed.${NC}"
    fi

    # Initialize PostgreSQL Data Directory if not done
    PGDATA="$PREFIX/var/lib/postgresql"
    if [ ! -d "$PGDATA" ]; then
        echo -e "${YELLOW}[*] Initializing PostgreSQL database cluster...${NC}"
        initdb "$PGDATA"
    fi

    # Start PostgreSQL service if not running
    if ! pg_isready &>/dev/null; then
        echo -e "${YELLOW}[*] Starting PostgreSQL database server...${NC}"
        pg_ctl -D "$PGDATA" start
        sleep 2
    fi

    # Create postgres role and database with password
    echo -e "${BLUE}[*] Setting up PostgreSQL users and database...${NC}"
    if pg_isready &>/dev/null; then
        # Check if role postgres exists
        role_exists=$(psql -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='postgres'")
        if [ "$role_exists" != "1" ]; then
            createuser -s postgres || true
        fi
        
        # Set postgres user password to postgres
        psql -d postgres -c "ALTER USER postgres WITH PASSWORD 'postgres';" || true
        
        # Create partygame database if not exists
        db_exists=$(psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='partygame'")
        if [ "$db_exists" != "1" ]; then
            psql -U postgres -d postgres -c "CREATE DATABASE partygame;" || true
        fi
        echo -e "${GREEN}[✔] PostgreSQL configured successfully.${NC}"
    else
        echo -e "${RED}[✗] Warning: PostgreSQL server did not start. Persistence may be disabled.${NC}"
    fi
fi

# 3. Compile the Go game server
echo -e "${BLUE}[*] Compiling the Go game server...${NC}"
if [ -d "server" ]; then
    cd server
    go build -o ../game_server
    cd ..
    echo -e "${GREEN}[✔] Server compilation completed successfully!${NC}"
else
    echo -e "${RED}[✗] Error: 'server' directory not found.${NC}"
    exit 1
fi

# 4. Check for exported web client directory
echo -e "${BLUE}[*] Checking game client static assets in 'dist/'...${NC}"
REQUIRED_FILES=("index.html" "index.js" "index.wasm" "index.pck" "index.audio.worklet.js")
MISSING_FILE=false

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "dist/$file" ]; then
        echo -e "${RED}[✗] Missing: dist/$file${NC}"
        MISSING_FILE=true
    else
        echo -e "${GREEN}[✔] Found: dist/$file${NC}"
    fi
done

if [ "$MISSING_FILE" = true ]; then
    echo -e "${RED}[✗] Error: Some client compilation outputs are missing.${NC}"
    echo -e "${YELLOW}Please build the Godot client first (e.g. using build_and_run.sh on PC) before running Termux.${NC}"
    exit 1
fi

# 5. Git Push (推送) helper for developer
echo -e "${YELLOW}------------------------------------------------------${NC}"
echo -e "${YELLOW}Do you want to push/deploy the new compilation products to GitHub? (y/N)${NC}"
read -r -t 10 -p "Selection (default: N): " PUSH_ANSWER || PUSH_ANSWER="n"
echo ""

if [[ "$PUSH_ANSWER" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}[*] Staging compilation outputs to Git...${NC}"
    git add client/Main.gd dist/index.html dist/index.pck dist/index.js dist/index.wasm dist/index.audio.worklet.js server/go.mod server/go.sum server/main.go server/player.go server/room.go server/types.go server/api.go server/db.go .gitignore
    
    echo -e "${BLUE}[*] Committing changes...${NC}"
    git commit -m "Deploy: Compile game server and update Web client assets" || echo "No changes to commit."
    
    echo -e "${BLUE}[*] Pushing to remote repository...${NC}"
    git push origin main
    echo -e "${GREEN}[✔] Pushed successfully!${NC}"
fi

# 6. Resolve local IP addresses
echo -e "${BLUE}[*] Resolving network IP addresses for LAN multiplayer...${NC}"
IP_LIST=$(ip addr show | grep -w inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1)

# Ensure execution rights
chmod +x game_server

# 7. Ask for SSL mode (HTTPS)
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

# 8. Run the server
./game_server -port=8090 $SSL_FLAG
