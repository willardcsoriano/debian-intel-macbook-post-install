#!/bin/bash
# setup.sh
# Post-installation setup for Debian 13 (Trixie) on Intel MacBooks
# Tested on MacBook Air 7,2 (2015) — should work on most Intel MacBooks
# https://github.com/willardcsoriano/debian-intel-macbook-post-install

set -uo pipefail

# ─────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────
LOG_FILE="$HOME/setup-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/setup-$(date +%Y%m%d-%H%M%S).log"

# ─────────────────────────────────────────────
# TRACKING
# ─────────────────────────────────────────────
INSTALLED=()
SKIPPED=()
FAILED=()
REBOOT_REQUIRED=false
HAS_DBUS=true
# Optional system-upgrade status, rendered as its own summary block (it's a
# system-currency status, not a package): current | upgraded | declined | failed
UPGRADE_STATE="current"
UPGRADE_COUNT=0

# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────
print_header() {
    echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}\n"
}

print_ok()      { echo -e "${GREEN}  ✔ $1${NC}"; }
print_skip()    { echo -e "${YELLOW}  ⊘ $1 — already installed, skipping${NC}"; }
print_fail()    { echo -e "${RED}  ✘ $1 — failed to install${NC}"; }
print_info()    { echo -e "${CYAN}  → $1${NC}"; }
print_warning() { echo -e "${YELLOW}  ⚠ $1${NC}"; }

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

# Returns: 0 = installed now, 1 = already installed, 2 = failed
install_pkg() {
    local pkg=$1
    local label=${2:-$1}
    if dpkg -s "$pkg" &>/dev/null; then
        print_skip "$label"
        SKIPPED+=("$label")
        return 1
    fi
    print_info "Installing $label..."
    log "apt install $pkg"
    if sudo apt install -y "$pkg" >>"$LOG_FILE" 2>&1; then
        print_ok "$label installed"
        INSTALLED+=("$label")
        return 0
    fi
    print_fail "$label"
    FAILED+=("$label")
    return 2
}

# Returns: 0 = installed now, 1 = already installed, 2 = failed
install_pkgs() {
    local label=$1
    shift
    local pkgs=("$@")
    local all_installed=true

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            all_installed=false
            break
        fi
    done

    if $all_installed; then
        print_skip "$label"
        SKIPPED+=("$label")
        return 1
    fi
    print_info "Installing $label..."
    log "apt install ${pkgs[*]}"
    if sudo apt install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1; then
        print_ok "$label installed"
        INSTALLED+=("$label")
        return 0
    fi
    print_fail "$label"
    FAILED+=("$label")
    return 2
}

xfconf_set() {
    # Safely call xfconf-query; warn if no session
    if ! $HAS_DBUS; then
        log "xfconf skipped (no dbus): $*"
        return 1
    fi
    xfconf-query "$@" 2>>"$LOG_FILE" || true
}

fix_desktop_launchers() {
    local apps_dir="/usr/share/applications"
    local local_dir="$ACTUAL_HOME/.local/share/applications"
    local fixed=0
    mkdir -p "$local_dir"

    for desktop_file in "$apps_dir"/*.desktop; do
        local app_name
        app_name=$(basename "$desktop_file")

        if [ -f "$local_dir/$app_name" ] && ! grep -qE "Exec=.*%[FfUu]" "$local_dir/$app_name"; then
            continue
        fi

        if ! grep -qE "Exec=.*%[FfUu]" "$desktop_file"; then
            continue
        fi

        sed 's/ *%[FfUu]//g' "$desktop_file" > "$local_dir/$app_name"
        ((fixed++))
    done

    if [ "$fixed" -gt 0 ]; then
        update-desktop-database "$local_dir"
        print_ok "Fixed $fixed app launcher(s) for XFCE App Finder"
    else
        print_skip "App launcher fix — all already clean"
    fi
}

create_shortcut() {
    local name=$1
    local exec=$2
    local icon=$3
    local terminal=${4:-false}
    local file="$DESKTOP_DIR/${name}.desktop"
    if [ -f "$file" ]; then
        print_skip "$name desktop shortcut"
    else
        cat > "$file" <<SHORTCUT
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Exec=$exec
Icon=$icon
Terminal=$terminal
SHORTCUT
        chmod +x "$file"
        print_ok "$name shortcut created on Desktop"
    fi
}

# ─────────────────────────────────────────────
# WELCOME
# ─────────────────────────────────────────────
echo -e "\n${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   debian-intel-macbook-post-install      ║"
echo "  ║   Intel MacBooks · Debian 13 Trixie      ║"
echo "  ║   github.com/willardcsoriano             ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}\n"
echo -e "  This script will set up your MacBook with everything"
echo -e "  you need for a smooth Linux experience.\n"
echo -e "  ${CYAN}Estimated time: 10–20 minutes depending on internet speed.${NC}"
echo -e "  ${CYAN}Full log: $LOG_FILE${NC}\n"

# ─────────────────────────────────────────────
# CHECKS
# ─────────────────────────────────────────────
print_header "Pre-flight Checks"

if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}  ✘ Please do not run this script as root.${NC}"
    echo -e "${YELLOW}  Run it as your regular user. See the README for setup instructions.${NC}"
    exit 1
fi
print_ok "Running as regular user (${USER})"

if ! sudo -v &>/dev/null; then
    echo -e "${RED}  ✘ sudo is not configured for your user.${NC}"
    echo -e "${YELLOW}  Fix it by running: su -${NC}"
    echo -e "${YELLOW}  Then: usermod -aG sudo ${USER}${NC}"
    echo -e "${YELLOW}  Then log out and back in, and run this script again.${NC}"
    exit 1
fi
print_ok "sudo access confirmed"

# Keep sudo alive for the full run (webcam build can take several minutes)
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT INT TERM

# Use whichever HTTP client is on the system; minimal Debian may lack wget
if command -v wget &>/dev/null; then
    NET_CHECK="wget -q --spider --timeout=5 https://deb.debian.org"
elif command -v curl &>/dev/null; then
    NET_CHECK="curl -fsS --max-time 5 -o /dev/null https://deb.debian.org"
else
    NET_CHECK=""
fi
if [ -z "$NET_CHECK" ] || ! eval "$NET_CHECK"; then
    if [ -z "$NET_CHECK" ]; then
        print_warning "Neither wget nor curl found — skipping connectivity check."
    else
        echo -e "${RED}  ✘ No internet connection detected.${NC}"
        echo -e "${YELLOW}  Please connect to WiFi or a hotspot first, then run this script again.${NC}"
        exit 1
    fi
else
    print_ok "Internet connection is working"
fi

if ! grep -q "trixie\|13" /etc/os-release; then
    print_warning "This script was tested on Debian 13 (Trixie). Your system may differ."
    read -p "  Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi
print_ok "Debian 13 (Trixie) confirmed"

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    HAS_DBUS=false
    print_warning "No active dbus session detected."
    print_warning "XFCE settings (shortcuts, power, tiling) will NOT persist."
    print_warning "For best results, run this script from inside an XFCE session."
    read -p "  Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
else
    print_ok "dbus user session detected"
fi

BACKLIGHT_PATH="/sys/class/backlight/intel_backlight"
if [ -f "$BACKLIGHT_PATH/max_brightness" ]; then
    MAX_BRIGHTNESS=$(cat "$BACKLIGHT_PATH/max_brightness")
    print_ok "Screen backlight detected (max brightness: $MAX_BRIGHTNESS)"
else
    MAX_BRIGHTNESS=2777
    print_warning "Could not detect backlight. Using default value of $MAX_BRIGHTNESS."
fi

ACTUAL_HOME=$(getent passwd "$USER" | cut -d: -f6)
print_ok "Home directory: $ACTUAL_HOME"

# ─────────────────────────────────────────────
# APT SOURCES
# ─────────────────────────────────────────────
print_header "Configuring Package Sources"

# Debian 13 may use either the legacy /etc/apt/sources.list OR the new
# deb822 format at /etc/apt/sources.list.d/debian.sources. Handle both.
SOURCES_LEGACY="/etc/apt/sources.list"
SOURCES_DEB822="/etc/apt/sources.list.d/debian.sources"

enable_component() {
    # $1 = file, $2 = component name (contrib, non-free, non-free-firmware)
    local file=$1 comp=$2
    if [[ "$file" == *.sources ]]; then
        # deb822 format: Components: main non-free-firmware
        if ! grep -qE "^Components:.*\b${comp}\b([^-]|$)" "$file"; then
            sudo sed -i -E "/^Components:/ s/\$/ ${comp}/" "$file"
            return 0
        fi
    else
        # Legacy format: deb ... main non-free-firmware
        if ! grep -qE "\b${comp}\b([^-]|$)" "$file"; then
            sudo sed -i -E "s/(^deb[^\n]*main[^\n]*)$/\1 ${comp}/" "$file"
            return 0
        fi
    fi
    return 1
}

if [ -f "$SOURCES_DEB822" ]; then
    SOURCES_FILE="$SOURCES_DEB822"
    FORMAT="deb822"
elif [ -s "$SOURCES_LEGACY" ]; then
    SOURCES_FILE="$SOURCES_LEGACY"
    FORMAT="legacy"
else
    SOURCES_FILE=""
    FORMAT="none"
fi

if [ -n "$SOURCES_FILE" ]; then
    print_info "Detected APT sources format: $FORMAT ($SOURCES_FILE)"
    changed=false
    for comp in contrib non-free non-free-firmware; do
        if enable_component "$SOURCES_FILE" "$comp"; then
            changed=true
        fi
    done
    if $changed; then
        print_ok "Additional repositories enabled (contrib, non-free, non-free-firmware)"
    else
        print_skip "Package repositories already configured"
    fi
else
    print_warning "No APT sources file found — skipping component enable"
fi

print_info "Refreshing package list (this may take a moment)..."
sudo apt update -y >>"$LOG_FILE" 2>&1
print_ok "Package list is up to date"

# ─────────────────────────────────────────────
# BROADCOM WIFI HARDENING
# ─────────────────────────────────────────────
print_header "Broadcom WiFi Hardening"
echo -e "  ${CYAN}Locking in the Broadcom driver rebuild chain so WiFi survives kernel updates.${NC}\n"

# DKMS and kernel headers — without these, the Broadcom driver
# vanishes silently on every kernel update
install_pkg "dkms" "DKMS (kernel module rebuild framework)"
install_pkg "linux-headers-amd64" "linux-headers-amd64 (kernel headers meta-package)"
print_ok "Broadcom driver rebuild chain secured"

# Blacklist conflicting open-source Broadcom modules — b43, bcma, and ssb
# fight with the proprietary wl driver and win, causing random WiFi drops
BLACKLIST_FILE="/etc/modprobe.d/broadcom-blacklist.conf"
if [ ! -f "$BLACKLIST_FILE" ]; then
    print_info "Blacklisting conflicting Broadcom modules (b43, bcma, ssb)..."
    sudo tee "$BLACKLIST_FILE" > /dev/null << 'EOF'
blacklist b43
blacklist bcma
blacklist ssb
EOF
    print_ok "Conflicting modules blacklisted"
else
    print_skip "Broadcom blacklist already configured"
fi

# Persist the wl module across reboots — modprobe alone doesn't survive a restart
if ! grep -q "wl" /etc/modules-load.d/broadcom.conf 2>/dev/null; then
    print_info "Setting wl module to load automatically on boot..."
    echo "wl" | sudo tee /etc/modules-load.d/broadcom.conf > /dev/null
    print_ok "wl module set to load on boot"
else
    print_skip "wl boot config already set"
fi

# Swap check — 8GB RAM with no swap will hard freeze on OOM with no warning
if ! /usr/sbin/swapon --show 2>/dev/null | grep -q .; then
    print_warning "No swap detected — consider adding a swapfile to prevent out-of-memory freezes"
fi

# ─────────────────────────────────────────────
# AUTOMATIC SECURITY UPDATES
# ─────────────────────────────────────────────
print_header "Automatic Security Updates"
echo -e "  ${CYAN}Enabling unattended security patches, kernel updates, CPU microcode, and firmware updates.${NC}\n"

install_pkg "linux-image-amd64" "linux-image-amd64 (kernel meta-package)"
install_pkg "intel-microcode" "Intel CPU microcode (security mitigations)"
install_pkg "unattended-upgrades" "unattended-upgrades (auto security patches)"
install_pkg "needrestart" "needrestart (reboot-needed notifier)"
install_pkg "fwupd" "fwupd (firmware updater)"

# Create /etc/apt/apt.conf.d/20auto-upgrades so the apt periodic timers actually fire
sudo dpkg-reconfigure -f noninteractive unattended-upgrades >>"$LOG_FILE" 2>&1 || true

# Default 50unattended-upgrades only patches the -security pocket and Debian origins.
# Extend to the stable -updates pocket and the VS Code repo (third-party origins are
# excluded by default, so VS Code would otherwise never auto-update).
UU_EXTRA="/etc/apt/apt.conf.d/52unattended-upgrades-extra"
if [ ! -f "$UU_EXTRA" ]; then
    print_info "Extending unattended-upgrades to cover -updates pocket and VS Code..."
    sudo tee "$UU_EXTRA" > /dev/null << 'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-updates";
    "site=packages.microsoft.com";
};
EOF
    print_ok "unattended-upgrades extended"
else
    print_skip "unattended-upgrades extra origins"
fi

# Installing fwupd doesn't auto-refresh metadata; the timer does
if systemctl list-unit-files fwupd-refresh.timer &>/dev/null; then
    sudo systemctl enable --now fwupd-refresh.timer >>"$LOG_FILE" 2>&1 || true
    print_ok "Firmware metadata refresh timer enabled"
fi

# AppArmor ships enabled on Debian 13; only warn if it has been disabled
if systemctl is-active apparmor &>/dev/null; then
    print_ok "AppArmor is active"
else
    print_warning "AppArmor is not active — consider: sudo systemctl enable --now apparmor"
fi

# ─────────────────────────────────────────────
# DESKTOP ENVIRONMENT
# ─────────────────────────────────────────────
print_header "Desktop Environment"
echo -e "  ${CYAN}Installing the graphical desktop (XFCE). This is the main GUI.${NC}\n"

install_pkgs "Xorg display server" xorg x11-xserver-utils
install_pkgs "XFCE desktop environment" xfce4 xfce4-goodies && REBOOT_REQUIRED=true

# ─────────────────────────────────────────────
# TERMINAL
# ─────────────────────────────────────────────
print_header "Terminal"
echo -e "  ${CYAN}Installing a modern terminal with proper copy-paste support.${NC}\n"

install_pkg "gnome-terminal" "GNOME Terminal"

BASHRC="/etc/bash.bashrc"
if ! grep -q "enable-bracketed-paste" "$BASHRC"; then
    print_info "Fixing paste behavior in terminal (disabling bracketed paste mode)..."
    echo 'bind "set enable-bracketed-paste off"' | sudo tee -a "$BASHRC" > /dev/null
    print_ok "Terminal paste fixed"
else
    print_skip "Terminal paste fix already applied"
fi

# ─────────────────────────────────────────────
# BROWSER AND APPS
# ─────────────────────────────────────────────
print_header "Browser and Core Applications"
echo -e "  ${CYAN}Installing Firefox, a text editor, and printing support.${NC}\n"

install_pkg "firefox-esr" "Firefox web browser"
install_pkg "gedit" "gedit text editor"
install_pkg "cups" "CUPS printing system"

sudo systemctl enable cups >>"$LOG_FILE" 2>&1 || true
sudo systemctl start cups >>"$LOG_FILE" 2>&1 || true
print_ok "Printing service enabled"

# ─────────────────────────────────────────────
# VISUAL STUDIO CODE
# ─────────────────────────────────────────────
print_header "Visual Studio Code"
echo -e "  ${CYAN}Installing VS Code from Microsoft's official apt repository.${NC}\n"

install_pkgs "VS Code prerequisites" wget gpg apt-transport-https

VSCODE_KEY="/usr/share/keyrings/packages.microsoft.gpg"
VSCODE_LIST="/etc/apt/sources.list.d/vscode.list"

if [ ! -f "$VSCODE_KEY" ]; then
    print_info "Adding Microsoft GPG key..."
    if wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor 2>>"$LOG_FILE" \
        | sudo tee "$VSCODE_KEY" > /dev/null; then
        print_ok "Microsoft GPG key added"
    else
        print_fail "Microsoft GPG key"
        FAILED+=("Microsoft GPG key")
    fi
else
    print_skip "Microsoft GPG key"
fi

if [ ! -f "$VSCODE_LIST" ]; then
    print_info "Adding VS Code apt repository..."
    echo "deb [arch=amd64,arm64,armhf signed-by=$VSCODE_KEY] https://packages.microsoft.com/repos/code stable main" \
        | sudo tee "$VSCODE_LIST" > /dev/null
    sudo apt update -y >>"$LOG_FILE" 2>&1
    print_ok "VS Code repository added"
else
    # VS Code's own updater can auto-create vscode.sources pointing to a different keyring,
    # which conflicts with our vscode.list and breaks all apt commands.
    if [ -f "/etc/apt/sources.list.d/vscode.sources" ]; then
        sudo rm /etc/apt/sources.list.d/vscode.sources >>"$LOG_FILE" 2>&1
    fi
    print_skip "VS Code repository"
fi

install_pkg "code" "Visual Studio Code"

install_pkg "libgtk-3-0t64" "GTK3 library (VS Code PDF viewer)"

# VS Code PDF viewer — renders PDFs natively inside VS Code tabs
if command -v code &>/dev/null && ! code --list-extensions 2>/dev/null | grep -q "tomoki1207.pdf"; then
    print_info "Installing VS Code PDF extension..."
    if code --install-extension tomoki1207.pdf --force >>"$LOG_FILE" 2>&1; then
        print_ok "VS Code PDF extension installed"
        INSTALLED+=("VS Code PDF extension")
    else
        print_fail "VS Code PDF extension"
        FAILED+=("VS Code PDF extension")
    fi
else
    print_skip "VS Code PDF extension"
    SKIPPED+=("VS Code PDF extension")
fi

# ─────────────────────────────────────────────
# MEDIA AND UTILITIES
# ─────────────────────────────────────────────
print_header "Media and Utilities"
echo -e "  ${CYAN}Installing tools for screenshots, scanning, media playback, and more.${NC}\n"

install_pkg "flameshot" "Flameshot (screenshot tool)"
install_pkg "file-roller" "File Roller (archive manager)"
install_pkg "vlc" "VLC media player"
install_pkg "blueman" "Blueman (Bluetooth manager)"
install_pkg "fastfetch" "fastfetch (system info)"
install_pkg "sane-utils" "SANE (scanner support)"
install_pkg "simple-scan" "Simple Scan (scanning app)"
install_pkg "xfce4-pulseaudio-plugin" "PulseAudio volume plugin"
install_pkg "libreoffice" "LibreOffice (office suite)"
install_pkg "mtpaint" "mtPaint (simple image editor)"
install_pkg "gdebi" "gdebi (package installer)"
install_pkg "poppler-utils" "poppler-utils (PDF command-line tools)"
install_pkg "speech-dispatcher" "speech-dispatcher (text-to-speech)"

print_info "Configuring screenshot shortcut..."
xfconf_set -c xfce4-keyboard-shortcuts -p '/commands/custom/<Primary><Alt>s' -s 'flameshot gui' --create -t string
print_ok "Screenshot shortcut set to Ctrl+Alt+S (flameshot)"

# Real window tiling — tile_on_move is the setting that snaps windows
# to screen edges when dragged. wrap_windows is about workspace wrapping.
xfconf_set -c xfwm4 -p /general/tile_on_move -s true --create -t bool
xfconf_set -c xfwm4 -p /general/snap_to_border -s true --create -t bool
xfconf_set -c xfwm4 -p /general/wrap_windows -s false --create -t bool
print_ok "Window tiling enabled — drag windows to screen edges to snap them"

# ─────────────────────────────────────────────
# WIFI MANAGEMENT
# ─────────────────────────────────────────────
print_header "WiFi Management"
echo -e "  ${CYAN}Switching from manual WiFi commands to automatic GUI-based management.${NC}\n"

install_pkgs "NetworkManager" network-manager network-manager-gnome && REBOOT_REQUIRED=true

if systemctl is-enabled wpa_supplicant &>/dev/null; then
    print_info "Disabling manual WiFi service (wpa_supplicant)..."
    sudo systemctl disable wpa_supplicant >>"$LOG_FILE" 2>&1 || true
    sudo systemctl stop wpa_supplicant >>"$LOG_FILE" 2>&1 || true
    print_ok "Manual WiFi service disabled"
else
    print_skip "wpa_supplicant was not active"
fi

if systemctl is-enabled dhcpcd &>/dev/null; then
    print_info "Disabling manual IP service (dhcpcd)..."
    sudo systemctl disable dhcpcd >>"$LOG_FILE" 2>&1 || true
    sudo systemctl stop dhcpcd >>"$LOG_FILE" 2>&1 || true
    print_ok "Manual IP service disabled"
else
    print_skip "dhcpcd was not active"
fi

NM_CONF="/etc/NetworkManager/NetworkManager.conf"
if [ -f "$NM_CONF" ] && grep -q "managed=false" "$NM_CONF"; then
    print_info "Enabling NetworkManager to manage all interfaces..."
    sudo sed -i 's/managed=false/managed=true/' "$NM_CONF"
    print_ok "NetworkManager set to manage all interfaces"
else
    print_skip "NetworkManager already managing all interfaces"
fi

sudo systemctl enable NetworkManager >>"$LOG_FILE" 2>&1 || true
sudo systemctl start NetworkManager >>"$LOG_FILE" 2>&1 || true
print_ok "NetworkManager is running — WiFi will connect automatically on boot"

# ─────────────────────────────────────────────
# KEYBOARD
# ─────────────────────────────────────────────
print_header "MacBook Keyboard Fixes"
echo -e "  ${CYAN}Remapping keys so your Mac keyboard works naturally on Linux.${NC}\n"

install_pkg "keyd" "keyd (key remapper)" && REBOOT_REQUIRED=true
install_pkg "brightness-udev" "brightness-udev (backlight permissions)" || true
install_pkg "rofi" "rofi (window switcher for F3)"

KEYD_CONF="/etc/keyd/default.conf"
if [ -f "$KEYD_CONF" ]; then
    print_info "Backing up existing keyboard config..."
    sudo cp "$KEYD_CONF" "$KEYD_CONF.bak"
    print_ok "Backup saved to $KEYD_CONF.bak"
fi

print_info "Writing keyboard configuration..."
sudo mkdir -p /etc/keyd
sudo tee "$KEYD_CONF" > /dev/null << EOF
[ids]
*

[main]
# Cmd key acts as Ctrl (Mac muscle memory)
meta = leftcontrol

# Cmd+Space / F4 opens XFCE app finder
meta+space = A-f2
dashboard = A-f2

# F3 - Mission Control equivalent (rofi window switcher)
scale = command(sh -c 'DISPLAY=:0 XAUTHORITY=$ACTUAL_HOME/.Xauthority rofi -show window -show-icons')

# Brightness keys (via sysfs)
brightnessdown = command(sh -c 'val=\$(cat /sys/class/backlight/intel_backlight/brightness); echo \$((val > 200 ? val - 200 : 100)) | tee /sys/class/backlight/intel_backlight/brightness')
brightnessup = command(sh -c 'val=\$(cat /sys/class/backlight/intel_backlight/brightness); echo \$((val + 200 > $MAX_BRIGHTNESS ? $MAX_BRIGHTNESS : val + 200)) | tee /sys/class/backlight/intel_backlight/brightness')

# Cmd+arrow text navigation (Mac style)
meta+left = home
meta+right = end
meta+up = C-home
meta+down = C-end
meta+shift+left = S-home
meta+shift+right = S-end
meta+shift+up = C-S-home
meta+shift+down = C-S-end
meta+backspace = S-home delete
EOF

print_ok "Keyboard config written"

sudo systemctl enable keyd >>"$LOG_FILE" 2>&1 || true
sudo systemctl restart keyd >>"$LOG_FILE" 2>&1 || true
print_ok "Keyboard remapping is active"

echo -e "\n  ${CYAN}Key mappings applied:${NC}"
echo -e "  • Cmd key now works as Ctrl"
echo -e "  • Cmd+Space / F4 opens app finder"
echo -e "  • F1/F2 controls screen brightness"
echo -e "  • F3 opens window switcher"
echo -e "  • F5/F6 controls keyboard backlight (via kernel)"
echo -e "  • F7/F8/F9 controls media playback (via kernel)"
echo -e "  • F10/F11/F12 controls volume (via kernel)"
echo -e "  • Cmd+Left/Right jumps to start/end of line"
echo -e "  • Cmd+Up/Down jumps to start/end of document\n"

# ─────────────────────────────────────────────
# TOUCHPAD RESUME FIX
# ─────────────────────────────────────────────
print_header "MacBook Touchpad Resume Fix"
echo -e "  ${CYAN}Keeping the bcm5974 trackpad alive across lid-close and resume.${NC}\n"

# The bcm5974 trackpad re-enumerates as a USB device on lid-open/resume. When it
# reconnects, xfsettingsd replays stored xinput properties — and if it has a stale
# Device_Enabled=0, it disables the trackpad before anything can re-enable it,
# leaving a dead pad until reboot. Fix is two parts: clear the stored disabled
# state, and add a sleep hook that force-enables the device after it settles.

# 1. Stop XFCE from storing/replaying Device_Enabled=0
xfconf_set -c pointers -p /bcm5974/Properties/Device_Enabled -s 1 --create -t int
print_ok "Cleared any stale XFCE trackpad-disabled state"

# 2. systemd sleep hook — re-enable the trackpad after resume
print_info "Installing resume hook /etc/systemd/system-sleep/touchpad-resume..."
sudo mkdir -p /etc/systemd/system-sleep
sudo tee /etc/systemd/system-sleep/touchpad-resume > /dev/null << 'EOF'
#!/bin/sh
# Re-enable bcm5974 touchpad after resume.
# xfsettingsd replays stored xinput properties on device reconnect; if it has
# Device_Enabled=0 stored, it disables the touchpad before xorg.conf.d can
# re-enable it. This hook runs after the device settles and forces it back on.
[ "$1" = "post" ] && [ "$2" = "resume" ] || exit 0
sleep 2
XUSER=$(who | awk '/:0/{print $1; exit}')
[ -z "$XUSER" ] && exit 0
XAUTH="/home/$XUSER/.Xauthority"
su "$XUSER" -c "DISPLAY=:0 XAUTHORITY=$XAUTH xinput enable bcm5974" 2>/dev/null || true
EOF
sudo chmod +x /etc/systemd/system-sleep/touchpad-resume
print_ok "Trackpad will re-enable automatically after lid-open/resume"

# ─────────────────────────────────────────────
# WEBCAM AND MICROPHONE
# ─────────────────────────────────────────────
print_header "Webcam and Microphone"
echo -e "  ${CYAN}The MacBook FaceTime HD camera needs a custom driver — installing now.${NC}\n"

install_pkgs "Build tools for webcam driver" git curl cpio make build-essential dkms alsa-utils

KERNEL_VERSION=$(uname -r)
if ! dpkg -s "linux-headers-$KERNEL_VERSION" &>/dev/null; then
    print_info "Installing kernel headers for $KERNEL_VERSION..."
    if sudo apt install -y "linux-headers-$KERNEL_VERSION" >>"$LOG_FILE" 2>&1; then
        print_ok "Kernel headers installed"
        INSTALLED+=("Kernel headers")
    else
        print_fail "Kernel headers — webcam driver may not work"
        FAILED+=("Kernel headers")
    fi
else
    print_skip "Kernel headers"
    SKIPPED+=("Kernel headers")
fi

# FaceTime HD firmware — idempotent build
if compgen -G "/lib/firmware/facetimehd/*" >/dev/null; then
    print_skip "FaceTime HD firmware"
    SKIPPED+=("FaceTime HD firmware")
else
    print_info "Downloading and building FaceTime HD firmware (this may take a few minutes)..."
    if (
        set -e
        cd /tmp
        rm -rf facetimehd-firmware
        git clone https://github.com/patjak/facetimehd-firmware.git
        cd facetimehd-firmware
        make
        sudo make install
        cd /tmp
        rm -rf facetimehd-firmware
    ) >>"$LOG_FILE" 2>&1; then
        print_ok "FaceTime HD firmware installed"
        INSTALLED+=("FaceTime HD firmware")
    else
        print_fail "FaceTime HD firmware (see $LOG_FILE)"
        FAILED+=("FaceTime HD firmware")
    fi
fi

# FaceTime HD kernel module — idempotent DKMS build
if find /lib/modules/$(uname -r) -name "facetimehd.ko*" 2>/dev/null | grep -q .; then
    print_skip "FaceTime HD webcam driver"
    SKIPPED+=("FaceTime HD webcam driver")
else
    print_info "Building FaceTime HD kernel module..."
    if (
        set -e
        cd /tmp
        rm -rf facetimehd
        git clone https://github.com/patjak/facetimehd.git
        cd facetimehd
        FTHD_VERSION=$(grep "^PACKAGE_VERSION" dkms.conf | cut -d= -f2 | tr -d '"')
        sudo rm -rf "/usr/src/facetimehd-$FTHD_VERSION"
        sudo cp -r /tmp/facetimehd "/usr/src/facetimehd-$FTHD_VERSION"
        sudo dkms add -m facetimehd -v "$FTHD_VERSION" || true
        sudo dkms build -m facetimehd -v "$FTHD_VERSION"
        sudo dkms install -m facetimehd -v "$FTHD_VERSION"
        sudo depmod -a
        cd /tmp
        rm -rf facetimehd
    ) >>"$LOG_FILE" 2>&1; then
        print_ok "FaceTime HD webcam driver installed"
        INSTALLED+=("FaceTime HD webcam driver")
        REBOOT_REQUIRED=true
    else
        print_fail "FaceTime HD webcam driver (see $LOG_FILE)"
        FAILED+=("FaceTime HD webcam driver")
    fi
fi

if ! grep -q "facetimehd" /etc/modules-load.d/facetimehd.conf 2>/dev/null; then
    print_info "Configuring webcam to load automatically on boot..."
    echo "facetimehd" | sudo tee /etc/modules-load.d/facetimehd.conf > /dev/null
    print_ok "Webcam will load automatically on every boot"
    REBOOT_REQUIRED=true
else
    print_skip "Webcam boot config already set"
fi

if ! grep -q "options snd-hda-intel" /etc/modprobe.d/alsa-base.conf 2>/dev/null; then
    print_info "Configuring microphone for MacBook Air hardware..."
    echo "options snd-hda-intel model=mbp101" | sudo tee /etc/modprobe.d/alsa-base.conf > /dev/null
    print_ok "Microphone configured"
    REBOOT_REQUIRED=true
else
    print_skip "Microphone already configured"
fi

# ─────────────────────────────────────────────
# BATTERY AND POWER MANAGEMENT
# ─────────────────────────────────────────────
print_header "Battery and Power Management"
echo -e "  ${CYAN}Configuring power behavior (suspend + automatic hibernate).${NC}\n"

# XFCE (user input layer)
install_pkg "xfce4-battery-plugin" "Battery indicator plugin"
install_pkg "xfce4-power-manager" "Power manager"

print_info "Configuring lid + screen lock, and delegating the lid to logind..."
xfconf_set -c xfce4-power-manager -p /xfce4-power-manager/lid-action-on-ac -s 2 --create -t int
xfconf_set -c xfce4-power-manager -p /xfce4-power-manager/lid-action-on-battery -s 2 --create -t int
xfconf_set -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -s true --create -t bool
# Hand the lid switch to systemd-logind: XFCE has no native suspend-then-hibernate
# lid action, so we let logind own it. With this true, XFCE drops its lid inhibitor
# and logind's HandleLidSwitch= (set below) takes over. The lid-action-* values
# above then become inert fallbacks. See https://docs.xfce.org/xfce/xfce4-power-manager/faq
xfconf_set -c xfce4-power-manager -p /xfce4-power-manager/logind-handle-lid-switch -s true --create -t bool
print_ok "XFCE configured — lid handling delegated to logind"

# kernel (suspend mechanism layer)
# Intel MacBooks (Broadwell, e.g. MacBookAir7,2) default to deep/S3 suspend,
# which enters fine but never resumes — the machine is dead on lid-open until a
# hard power-off. Force s2idle (suspend-to-idle), which resumes reliably on this
# firmware. See https://github.com/basecamp/omarchy/issues/1840
if ! grep -q "mem_sleep_default=s2idle" /etc/default/grub; then
    print_info "Forcing s2idle suspend via kernel parameter (deep/S3 won't resume on this hardware)..."
    sudo sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mem_sleep_default=s2idle"/' /etc/default/grub
    sudo update-grub
    print_ok "Kernel set to s2idle suspend (takes full effect after reboot)"
    REBOOT_REQUIRED=true
else
    print_skip "s2idle kernel parameter already set"
fi

# systemd (power policy layer)
# MemorySleepMode=s2idle makes systemd write s2idle to /sys/power/mem_sleep on
# every mem suspend, so the fix holds even before the next reboot / if GRUB is
# regenerated without the param.
print_info "Configuring systemd suspend-then-hibernate (s2idle)..."
sudo mkdir -p /etc/systemd
sudo tee /etc/systemd/sleep.conf > /dev/null << 'EOF'
[Sleep]
AllowSuspendThenHibernate=yes
HibernateDelaySec=30min
MemorySleepMode=s2idle
EOF
print_ok "systemd configured — s2idle suspend → hibernate after 30 minutes"

# logind (lid policy layer)
# logind now owns the lid (see logind-handle-lid-switch above). suspend-then-
# hibernate = s2idle first for fast resume, then hibernate to swap after
# HibernateDelaySec — so a long/overnight close can't drain the battery flat and
# lose work. logind-initiated lid actions bypass polkit, so the hibernate-blocking
# rule below does not interfere. Applies on next reboot (no logind restart, which
# would kill the session).
print_info "Configuring logind: lid close → suspend-then-hibernate..."
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/10-lid.conf > /dev/null << 'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandleLidSwitchDocked=ignore
EOF
print_ok "logind configured — lid → suspend-then-hibernate (effective after reboot)"

# polkit (authority / safety layer)
print_info "Restricting user-space hibernate requests (XFCE)..."
sudo mkdir -p /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/50-disable-hibernate.rules > /dev/null << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.login1.hibernate") {
        return polkit.Result.NO;
    }
});
EOF
print_ok "Hibernate restricted to system-level control only"

# sleep.conf is re-read by systemd-logind on demand, so no restart needed.
# (Restarting systemd-logind can terminate the active user session.)
print_ok "Power management changes will take effect after reboot"

# ─────────────────────────────────────────────
# SYSTEM MONITORING
# ─────────────────────────────────────────────
print_header "System Monitoring"
echo -e "  ${CYAN}Installing tools to monitor CPU, RAM, and running processes.${NC}\n"

install_pkg "xfce4-taskmanager" "XFCE Task Manager (like Activity Monitor)"
install_pkg "htop" "htop (terminal process viewer)"

# ─────────────────────────────────────────────
# FONTS
# ─────────────────────────────────────────────
print_header "Fonts"
echo -e "  ${CYAN}Installing fonts for better text rendering across the system.${NC}\n"

install_pkg "fonts-liberation" "Liberation fonts (Arial/Times/Courier replacements)"
install_pkg "fonts-noto" "Noto fonts (broad Unicode coverage)"

# ─────────────────────────────────────────────
# APP FINDER LAUNCHER FIX
# ─────────────────────────────────────────────
print_header "App Finder Launcher Fix"
echo -e "  ${CYAN}Removing file argument placeholders so all apps launch cleanly from App Finder.${NC}\n"
fix_desktop_launchers

# ─────────────────────────────────────────────
# DESKTOP SHORTCUTS
# ─────────────────────────────────────────────
print_header "Desktop Shortcuts"
echo -e "  ${CYAN}Creating shortcuts on your Desktop so you can find everything easily.${NC}\n"

DESKTOP_DIR="$ACTUAL_HOME/Desktop"
mkdir -p "$DESKTOP_DIR"

create_shortcut "Firefox" "firefox-esr" "firefox-esr"
create_shortcut "Files" "thunar" "file-manager"
create_shortcut "Terminal" "gnome-terminal" "utilities-terminal"
create_shortcut "Text Editor" "gedit" "gedit"
create_shortcut "Simple Scan" "simple-scan" "scanner"
create_shortcut "VLC" "vlc" "vlc"
create_shortcut "Screenshot" "flameshot gui" "flameshot"
create_shortcut "Bluetooth" "blueman-manager" "bluetooth"
create_shortcut "Task Manager" "xfce4-taskmanager" "utilities-system-monitor"
create_shortcut "System Settings" "xfce4-settings-manager" "preferences-system"
create_shortcut "htop" "gnome-terminal -- htop" "utilities-system-monitor" "true"
create_shortcut "System Info" "gnome-terminal -- fastfetch" "computer" "true"
create_shortcut "LibreOffice Writer" "libreoffice --writer" "libreoffice-writer"
create_shortcut "LibreOffice Calc" "libreoffice --calc" "libreoffice-calc"
create_shortcut "LibreOffice Impress" "libreoffice --impress" "libreoffice-impress"
create_shortcut "Image Editor" "mtpaint" "applications-graphics"
create_shortcut "VS Code" "code" "code"

cat > "$ACTUAL_HOME/Desktop/KEYBOARD SHORTCUTS.txt" << 'SHORTCUTS'
═══════════════════════════════════════════════════════
  KEYBOARD SHORTCUTS — debian-intel-macbook-post-install
  Intel MacBooks · Debian 13 Trixie · XFCE
═══════════════════════════════════════════════════════

NOTE: On this setup, the Cmd key works as Ctrl.
      So Cmd+C = Ctrl+C, Cmd+V = Ctrl+V, etc.

───────────────────────────────────────────────────────
  GENERAL (works in most apps)
───────────────────────────────────────────────────────
  Cmd+C              Copy
  Cmd+V              Paste
  Cmd+X              Cut
  Cmd+Z              Undo
  Cmd+A              Select All
  Cmd+S              Save
  Cmd+F              Find
  Cmd+W              Close window
  Cmd+Q              Quit app
  Cmd+Tab            Switch between open apps

───────────────────────────────────────────────────────
  TEXT NAVIGATION
───────────────────────────────────────────────────────
  Cmd+Left           Jump to start of line
  Cmd+Right          Jump to end of line
  Cmd+Up             Jump to start of document
  Cmd+Down           Jump to end of document
  Cmd+Shift+Left     Select to start of line
  Cmd+Shift+Right    Select to end of line
  Cmd+Shift+Up       Select to start of document
  Cmd+Shift+Down     Select to end of document
  Cmd+Backspace      Delete entire line to left of cursor

───────────────────────────────────────────────────────
  DESKTOP AND WINDOWS
───────────────────────────────────────────────────────
  Cmd+Space          Open app finder (like Spotlight)
  Ctrl+Alt+D         Show desktop (hide all windows)
  Ctrl+Alt+L         Lock screen
  Ctrl+Alt+T         Open terminal
  Ctrl+Alt+F         Open file manager
  Alt+Tab            Switch between open windows
  Alt+Shift+Tab      Switch windows in reverse
  Alt+F4             Close window
  Alt+F10            Maximize window
  Alt+F9             Minimize window
  Alt+F11            Fullscreen

───────────────────────────────────────────────────────
  MAC-STYLE FUNCTION KEYS
───────────────────────────────────────────────────────
  F1                 Brightness down
  F2                 Brightness up
  F3                 Window switcher (like Mission Control)
  F4                 Open app finder (like Launchpad)
  F5                 Keyboard backlight down
  F6                 Keyboard backlight up
  F7                 Previous track
  F8                 Play / Pause
  F9                 Next track
  F10                Mute / Unmute
  F11                Volume down
  F12                Volume up
  Fn+F1-F12          Use as standard F1-F12 keys

───────────────────────────────────────────────────────
  SCREENSHOTS
───────────────────────────────────────────────────────
  Ctrl+Alt+S         Screenshot with annotation (flameshot)
  Print              Full screen screenshot (screenshooter)
  Shift+Print        Region screenshot (screenshooter)
  Alt+Print          Active window screenshot

───────────────────────────────────────────────────────
  SYSTEM
───────────────────────────────────────────────────────
  Ctrl+Shift+Esc     Open task manager
  Ctrl+Alt+Esc       Click a window to force quit it
  Ctrl+Alt+Delete    Log out / shutdown menu

───────────────────────────────────────────────────────
  WINDOW TILING (drag to edge OR use keys)
───────────────────────────────────────────────────────
  Drag to edge       Snap window to that half of screen
  Cmd+KP_Left        Tile window to left half
  Cmd+KP_Right       Tile window to right half
  Cmd+KP_Up          Tile window to top half
  Cmd+KP_Down        Tile window to bottom half

───────────────────────────────────────────────────────
  WORKSPACES (virtual desktops)
───────────────────────────────────────────────────────
  Ctrl+Alt+Left      Switch to left workspace
  Ctrl+Alt+Right     Switch to right workspace
  Ctrl+F1            Go to workspace 1
  Ctrl+F2            Go to workspace 2
  Ctrl+F3            Go to workspace 3
  Ctrl+F4            Go to workspace 4

───────────────────────────────────────────────────────
  DESKTOP ICONS (first time only)
───────────────────────────────────────────────────────
  When clicking a desktop icon for the first time,
  XFCE will ask "Untrusted application launcher" —
  click Launch to confirm. It won't ask again.

═══════════════════════════════════════════════════════
SHORTCUTS
print_ok "Keyboard shortcuts cheat sheet saved to Desktop"

# ─────────────────────────────────────────────
# PANEL SETUP
# ─────────────────────────────────────────────
print_header "Panel Setup"
echo -e "  ${CYAN}Scheduling a clean panel layout for first login.${NC}\n"

PANEL_SETUP_SCRIPT="$ACTUAL_HOME/.local/bin/setup-panel-once.sh"
PANEL_MARKER="$ACTUAL_HOME/.local/share/panel-configured"

mkdir -p "$ACTUAL_HOME/.local/bin"
mkdir -p "$ACTUAL_HOME/.config/autostart"
mkdir -p "$ACTUAL_HOME/.local/share"

cat > "$PANEL_SETUP_SCRIPT" << 'PANEL_SCRIPT'
#!/bin/bash
# One-shot: builds a clean panel layout on first XFCE login.
MARKER="$HOME/.local/share/panel-configured"
[ -f "$MARKER" ] && exit 0

# Wait up to 15 seconds for xfce4-panel to be running
for i in $(seq 1 15); do
    pgrep -x xfce4-panel > /dev/null && break
    sleep 1
done
pgrep -x xfce4-panel > /dev/null || exit 1

# Use docklike (icon-only window buttons) if installed, otherwise tasklist
if dpkg -s xfce4-docklike-plugin &>/dev/null; then
    WIN="docklike"
else
    WIN="tasklist"
fi

# Clear all existing plugin entries
while IFS= read -r id; do
    xfconf-query -c xfce4-panel -p "/plugins/plugin-$id" -r -R 2>/dev/null || true
done < <(xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids 2>/dev/null | grep -oE '^[0-9]+$')

# Register plugins
#  1 — app menu
xfconf-query -c xfce4-panel -p /plugins/plugin-1 --create -t string -s "applicationsmenu"

#  2 — thin separator
xfconf-query -c xfce4-panel -p /plugins/plugin-2        --create -t string -s "separator"
xfconf-query -c xfce4-panel -p /plugins/plugin-2/style  --create -t uint   -s 0
xfconf-query -c xfce4-panel -p /plugins/plugin-2/expand --create -t bool   -s false

#  3 — open window icons
xfconf-query -c xfce4-panel -p /plugins/plugin-3 --create -t string -s "$WIN"

#  4 — expanding spacer (pushes right-side items to the right)
xfconf-query -c xfce4-panel -p /plugins/plugin-4        --create -t string -s "separator"
xfconf-query -c xfce4-panel -p /plugins/plugin-4/style  --create -t uint   -s 0
xfconf-query -c xfce4-panel -p /plugins/plugin-4/expand --create -t bool   -s true

#  5 — system tray (nm-applet WiFi icon lives here)
xfconf-query -c xfce4-panel -p /plugins/plugin-5 --create -t string -s "systray"

#  6 — volume
xfconf-query -c xfce4-panel -p /plugins/plugin-6 --create -t string -s "pulseaudio"

#  7 — battery
xfconf-query -c xfce4-panel -p /plugins/plugin-7 --create -t string -s "battery"

#  8 — clock
xfconf-query -c xfce4-panel -p /plugins/plugin-8                --create -t string -s "clock"
xfconf-query -c xfce4-panel -p /plugins/plugin-8/digital-format --create -t string -s "%Y-%m-%d  %H:%M"

# Set panel order
xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids \
    --force-array \
    -t int -s 1 \
    -t int -s 2 \
    -t int -s 3 \
    -t int -s 4 \
    -t int -s 5 \
    -t int -s 6 \
    -t int -s 7 \
    -t int -s 8

# Ensure nm-applet is running (WiFi tray icon)
pgrep -x nm-applet > /dev/null || nm-applet &

xfce4-panel --restart &
sleep 2

touch "$MARKER"
rm -f "$HOME/.config/autostart/setup-panel-once.desktop"
PANEL_SCRIPT

chmod +x "$PANEL_SETUP_SCRIPT"

cat > "$ACTUAL_HOME/.config/autostart/setup-panel-once.desktop" << PANEL_DESKTOP
[Desktop Entry]
Type=Application
Name=Panel Setup (once)
Exec=$PANEL_SETUP_SCRIPT
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
PANEL_DESKTOP

if [ -f "$PANEL_MARKER" ]; then
    print_skip "Panel already configured"
else
    print_ok "Panel setup scheduled — clean layout will apply on first login"
fi

# ─────────────────────────────────────────────
# OPTIONAL SYSTEM UPGRADE
# ─────────────────────────────────────────────
# Runs last, after every DKMS driver (Broadcom wl, facetimehd) is already
# registered — so if this pulls a new kernel, its post-install triggers a DKMS
# rebuild of those drivers for the new kernel automatically. Upgrading earlier
# would leave the webcam driver built only for the old running kernel.
print_header "System Upgrade (optional)"

# Simulate the upgrade to see if anything is actually pending. The package list
# was refreshed earlier, so this reflects the current state. Count the package
# actions (Inst = install/upgrade, Remv = remove) apt would perform.
UPGRADE_COUNT=$(apt-get -s full-upgrade 2>/dev/null | grep -cE '^(Inst|Remv) ')

if [ "$UPGRADE_COUNT" -eq 0 ]; then
    UPGRADE_STATE="current"
    echo -e "  ${CYAN}Every installed package is already at the latest Debian 13 point release.${NC}\n"
    print_ok "Nothing to upgrade"
else
    echo -e "  ${CYAN}$UPGRADE_COUNT package(s) can be upgraded to the latest Debian 13 point release.${NC}\n"
    echo -e "  ${YELLOW}Safe to skip: security updates already install automatically via"
    echo -e "  unattended-upgrades. A full upgrade can download a lot and may install a"
    echo -e "  new kernel — the Broadcom/webcam DKMS drivers rebuild for it automatically,"
    echo -e "  but you must reboot to use it.${NC}\n"

    read -p "$(echo -e ${BOLD}"  Run a full system upgrade now? [y/N] "${NC})" do_upgrade
    if [[ "$do_upgrade" =~ ^[Yy]$ ]]; then
        RUNNING_KERNEL=$(uname -r)
        print_info "Upgrading all packages (this can take a while)..."
        log "apt full-upgrade"
        if sudo apt full-upgrade -y >>"$LOG_FILE" 2>&1; then
            UPGRADE_STATE="upgraded"
            print_ok "System upgraded to the latest available packages"
            sudo apt autoremove -y >>"$LOG_FILE" 2>&1 || true
        else
            UPGRADE_STATE="failed"
            echo -e "${RED}  ✘ System upgrade failed — see $LOG_FILE${NC}"
        fi
        # A newer kernel only becomes active after a reboot; flag it so the reboot
        # prompt fires and the DKMS drivers run on the kernel you actually boot into.
        NEWEST_KERNEL=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
        if [ -n "$NEWEST_KERNEL" ] && [ "$NEWEST_KERNEL" != "$RUNNING_KERNEL" ]; then
            REBOOT_REQUIRED=true
            print_warning "New kernel installed ($NEWEST_KERNEL) — reboot to activate it,"
            print_warning "then verify WiFi and the webcam still work."
        fi
    else
        # Declined with updates pending: this machine is knowingly behind, so warn
        # (not a neutral skip) and hand over the one command to catch up later.
        UPGRADE_STATE="declined"
        print_warning "$UPGRADE_COUNT update(s) available but not applied"
        print_warning "Apply later with: sudo apt full-upgrade"
    fi
fi

# ─────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────
print_header "Installation Summary"

echo -e "${GREEN}${BOLD}  Installed (${#INSTALLED[@]})${NC}"
for item in "${INSTALLED[@]}"; do
    echo -e "  ${GREEN}✔ $item${NC}"
done

if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}  Already installed, skipped (${#SKIPPED[@]})${NC}"
    for item in "${SKIPPED[@]}"; do
        echo -e "  ${YELLOW}⊘ $item${NC}"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo -e "\n${RED}${BOLD}  Failed (${#FAILED[@]})${NC}"
    for item in "${FAILED[@]}"; do
        echo -e "  ${RED}✘ $item${NC}"
    done
    echo -e "\n${RED}  Some items failed. Full details in: $LOG_FILE${NC}"
fi

# System-currency status — rendered on its own, not lumped in with the package
# tallies, because "is this system up to date?" is a different question from
# "is this package installed?".
echo -e "\n${BOLD}  System status${NC}"
case "$UPGRADE_STATE" in
    upgraded)
        echo -e "  ${GREEN}✔ System upgraded — $UPGRADE_COUNT package(s) updated this run${NC}"
        ;;
    declined)
        echo -e "  ${YELLOW}⚠ $UPGRADE_COUNT update(s) available — not applied${NC}"
        echo -e "  ${YELLOW}  Apply later with:  sudo apt full-upgrade${NC}"
        ;;
    failed)
        echo -e "  ${RED}✘ System upgrade failed — see the log below${NC}"
        echo -e "  ${RED}  Retry later with:  sudo apt full-upgrade${NC}"
        ;;
    *)
        echo -e "  ${GREEN}✔ Fully up to date${NC}"
        ;;
esac

echo -e "\n${CYAN}  Full log saved to: $LOG_FILE${NC}"

# ─────────────────────────────────────────────
# NEXT STEPS
# ─────────────────────────────────────────────
echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"
if [ "$REBOOT_REQUIRED" = true ]; then
    echo -e "${BLUE}${BOLD}  All done! Just reboot when ready.${NC}"
else
    echo -e "${BLUE}${BOLD}  All done! Your MacBook is ready to use.${NC}"
fi
echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}\n"
echo -e "  ${CYAN}A clean panel (app menu, window icons, WiFi, volume, battery, clock) will appear on first login.${NC}"
echo -e "  ${CYAN}Your saved WiFi password will be picked up automatically.${NC}"
echo -e "  ${CYAN}All your desktop shortcuts are ready on the Desktop.${NC}\n"

# ─────────────────────────────────────────────
# REBOOT
# ─────────────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════════${NC}"
if [ "$REBOOT_REQUIRED" = true ]; then
    echo -e "\n${YELLOW}  A reboot is required to apply all changes.${NC}\n"
    read -p "$(echo -e ${BOLD}"  Reboot now? [Y/n] "${NC})" reboot_confirm
    if [[ "$reboot_confirm" =~ ^[Nn]$ ]]; then
        echo -e "\n${YELLOW}  Please reboot before using the desktop.${NC}\n"
    else
        echo -e "\n${GREEN}  Rebooting now — see you on the other side!${NC}\n"
        sudo reboot
    fi
else
    echo -e "\n${GREEN}  All done! No reboot needed — changes are already active.${NC}\n"
fi
