#!/bin/bash
# teams.sh
# Optional: installs the unofficial teams-for-linux client (Microsoft ships
# no native Debian package). Run standalone, separately from setup.sh.
# https://github.com/willardcsoriano/debian-intel-macbook-post-install

set -e

# ─────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "\n${BOLD}${CYAN}Microsoft Teams (unofficial teams-for-linux client)${NC}\n"

if command -v teams-for-linux &>/dev/null; then
    echo -e "${YELLOW}  Already installed — nothing to do.${NC}\n"
    exit 0
fi

if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}  Please do not run this script as root. Run it as your regular user.${NC}"
    exit 1
fi

if ! command -v apt &>/dev/null; then
    echo -e "${RED}  Error: apt not found. This script targets Debian/Ubuntu-based systems.${NC}"
    exit 1
fi

TEAMS_KEYRING="/etc/apt/keyrings/teams-for-linux.asc"
TEAMS_SOURCE="/etc/apt/sources.list.d/teams-for-linux-packages.sources"

if [ ! -f "$TEAMS_KEYRING" ]; then
    echo "  Adding teams-for-linux signing key..."
    sudo mkdir -p /etc/apt/keyrings
    sudo wget -qO "$TEAMS_KEYRING" https://repo.teamsforlinux.de/teams-for-linux.asc
fi

if [ ! -f "$TEAMS_SOURCE" ]; then
    echo "  Adding teams-for-linux apt repository..."
    ARCH=$(dpkg --print-architecture)
    sudo tee "$TEAMS_SOURCE" > /dev/null << EOF
Types: deb
URIs: https://repo.teamsforlinux.de/debian/
Suites: stable
Components: main
Signed-By: $TEAMS_KEYRING
Architectures: $ARCH
EOF
    sudo apt update -y
fi

echo "  Installing teams-for-linux..."
sudo apt install -y teams-for-linux

ACTUAL_HOME=$(getent passwd "$USER" | cut -d: -f6)
DESKTOP_DIR="$ACTUAL_HOME/Desktop"
if [ -d "$DESKTOP_DIR" ] && [ ! -f "$DESKTOP_DIR/Microsoft Teams.desktop" ]; then
    cat > "$DESKTOP_DIR/Microsoft Teams.desktop" << SHORTCUT
[Desktop Entry]
Version=1.0
Type=Application
Name=Microsoft Teams
Exec=teams-for-linux
Icon=teams-for-linux
Terminal=false
SHORTCUT
    chmod +x "$DESKTOP_DIR/Microsoft Teams.desktop"
    echo "  Desktop shortcut created."
fi

echo -e "\n${GREEN}${BOLD}  Done.${NC} Launch with: teams-for-linux\n"
echo -e "${CYAN}  Note: if first sign-in shows \"account is temporarily locked\", that's${NC}"
echo -e "${CYAN}  Microsoft Entra ID Smart Lockout (server-side, unrelated to this install).${NC}"
echo -e "${CYAN}  It clears after a short cooldown; if not, contact your org's admin.${NC}\n"
