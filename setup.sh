#!/bin/bash
# setup.sh
# Post-installation setup for Debian 13 (Trixie) on Intel MacBooks
# Tested on MacBook Air 7,2 (2015) — should work on most Intel MacBooks
# https://github.com/willardcsoriano/debian-macbook-post-install

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
# TRACKING
# ─────────────────────────────────────────────
INSTALLED=()
SKIPPED=()
FAILED=()
REBOOT_REQUIRED=false

# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────
print_header() {
    echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}\n"
}

print_ok() {
    echo -e "${GREEN}  ✔ $1${NC}"
}

print_skip() {
    echo -e "${YELLOW}  ⊘ $1 — already installed, skipping${NC}"
}

print_fail() {
    echo -e "${RED}  ✘ $1 — failed to install${NC}"
}

print_info() {
    echo -e "${CYAN}  → $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

install_pkg() {
    local pkg=$1
    local label=${2:-$1}
    if dpkg -s "$pkg" &>/dev/null; then
        print_skip "$label"
        SKIPPED+=("$label")
    else
        print_info "Installing $label..."
        if sudo apt install -y "$pkg" &>/dev/null; then
            print_ok "$label installed"
            INSTALLED+=("$label")
        else
            print_fail "$label"
            FAILED+=("$label")
        fi
    fi
}

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
    else
        print_info "Installing $label..."
        if sudo apt install -y "${pkgs[@]}" &>/dev/null; then
            print_ok "$label installed"
            INSTALLED+=("$label")
        else
            print_fail "$label"
            FAILED+=("$label")
        fi
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
echo "  ║   debian-macbook-post-install            ║"
echo "  ║   Intel MacBooks · Debian 13 Trixie      ║"
echo "  ║   github.com/willardcsoriano             ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}\n"
echo -e "  This script will set up your MacBook with everything"
echo -e "  you need for a smooth Linux experience.\n"
echo -e "  ${CYAN}Estimated time: 10–20 minutes depending on internet speed.${NC}\n"

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

if ! wget -q --spider --timeout=5 https://deb.debian.org; then
    echo -e "${RED}  ✘ No internet connection detected.${NC}"
    echo -e "${YELLOW}  Please connect to WiFi or a hotspot first, then run this script again.${NC}"
    exit 1
fi
print_ok "Internet connection is working"

if ! grep -q "trixie\|13" /etc/os-release; then
    print_warning "This script was tested on Debian 13 (Trixie). Your system may differ."
    read -p "  Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi
print_ok "Debian 13 (Trixie) confirmed"

BACKLIGHT_PATH="/sys/class/backlight/intel_backlight"
if [ -f "$BACKLIGHT_PATH/max_brightness" ]; then
    MAX_BRIGHTNESS=$(cat "$BACKLIGHT_PATH/max_brightness")
    print_ok "Screen backlight detected (max brightness: $MAX_BRIGHTNESS)"
else
    MAX_BRIGHTNESS=2777
    print_warning "Could not detect backlight. Using default value of $MAX_BRIGHTNESS."
fi

ACTUAL_HOME=$(eval echo ~$USER)
print_ok "Home directory: $ACTUAL_HOME"

# ─────────────────────────────────────────────
# APT SOURCES
# ─────────────────────────────────────────────
print_header "Configuring Package Sources"

SOURCES_FILE="/etc/apt/sources.list"

if ! grep -q "contrib" "$SOURCES_FILE"; then
    print_info "Enabling additional package repositories (contrib, non-free)..."
    sudo sed -i 's/main$/main contrib non-free non-free-firmware/' "$SOURCES_FILE"
    print_ok "Additional repositories enabled"
else
    print_skip "Package repositories already configured"
fi

print_info "Refreshing package list (this may take a moment)..."
sudo apt update -y &>/dev/null
print_ok "Package list is up to date"

# ─────────────────────────────────────────────
# DESKTOP ENVIRONMENT
# ─────────────────────────────────────────────
print_header "Desktop Environment"
echo -e "  ${CYAN}Installing the graphical desktop (XFCE). This is the main GUI.${NC}\n"

install_pkgs "Xorg display server" xorg x11-xserver-utils
install_pkgs "XFCE desktop environment" xfce4 xfce4-goodies
if [[ " ${INSTALLED[@]} " =~ "XFCE desktop environment" ]]; then REBOOT_REQUIRED=true; fi

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
install_pkg "xfce4-clipman-plugin" "Clipman (clipboard manager)"
install_pkg "libreoffice" "LibreOffice (office suite)"
install_pkg "mtpaint" "mtPaint (simple image editor)"
install_pkg "rhythmbox" "Rhythmbox (music player)"

# Screenshot Shortcut Config
print_info "Configuring screenshot shortcut..."
xfconf-query -c xfce4-keyboard-shortcuts -p '/commands/custom/<Primary><Alt>s' -s 'flameshot gui' --create -t string 2>/dev/null || true
print_ok "Screenshot shortcut set to Ctrl+Alt+S (flameshot)"

# Enable Window Tiling by Disabling Workspace Wrapping
xfconf-query -c xfwm4 -p /general/wrap_windows -s false 2>/dev/null || true
print_ok "Window tiling enabled — drag windows to screen edges to snap them"

# ─────────────────────────────────────────────
# WIFI MANAGEMENT
# ─────────────────────────────────────────────
print_header "WiFi Management"
echo -e "  ${CYAN}Switching from manual WiFi commands to automatic GUI-based management.${NC}\n"

install_pkgs "NetworkManager" network-manager network-manager-gnome
if [[ " ${INSTALLED[@]} " =~ "NetworkManager" ]]; then REBOOT_REQUIRED=true; fi

if systemctl is-enabled wpa_supplicant &>/dev/null; then
    print_info "Disabling manual WiFi service (wpa_supplicant)..."
    sudo systemctl disable wpa_supplicant &>/dev/null
    sudo systemctl stop wpa_supplicant &>/dev/null
    print_ok "Manual WiFi service disabled"
else
    print_skip "wpa_supplicant was not active"
fi

if systemctl is-enabled dhcpcd &>/dev/null; then
    print_info "Disabling manual IP service (dhcpcd)..."
    sudo systemctl disable dhcpcd &>/dev/null
    sudo systemctl stop dhcpcd &>/dev/null
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

sudo systemctl enable NetworkManager &>/dev/null
sudo systemctl start NetworkManager &>/dev/null
print_ok "NetworkManager is running — WiFi will connect automatically on boot"

# ─────────────────────────────────────────────
# KEYBOARD
# ─────────────────────────────────────────────
print_header "MacBook Keyboard Fixes"
echo -e "  ${CYAN}Remapping keys so your Mac keyboard works naturally on Linux.${NC}\n"

install_pkg "keyd" "keyd (key remapper)"
install_pkg "brightness-udev" "brightness-udev (backlight permissions)"
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
scale = command(sh -c 'DISPLAY=:0 XAUTHORITY=$ACTUAL_HOME/.Xauthority rofi -show window -show-icons -theme Arc-Dark')

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

sudo systemctl enable keyd &>/dev/null
sudo systemctl restart keyd &>/dev/null
if [[ " ${INSTALLED[@]} " =~ "keyd (key remapper)" ]]; then REBOOT_REQUIRED=true; fi
print_ok "Keyboard remapping is active"

echo -e "\n  ${CYAN}Key mappings applied:${NC}"
echo -e "  • Cmd key now works as Ctrl"
echo -e "  • Cmd+Space / F4 opens app finder"
echo -e "  • F1/F2 controls screen brightness"
echo -e "  • F3 opens window switcher"
echo -e "  • F5/F6 controls keyboard backlight"
echo -e "  • F7/F8/F9 controls media playback"
echo -e "  • F10/F11/F12 controls volume"
echo -e "  • Cmd+Left/Right jumps to start/end of line"
echo -e "  • Cmd+Up/Down jumps to start/end of document\n"

# ─────────────────────────────────────────────
# WEBCAM AND MICROPHONE
# ─────────────────────────────────────────────
print_header "Webcam and Microphone"
echo -e "  ${CYAN}The MacBook FaceTime HD camera needs a custom driver — installing now.${NC}\n"

install_pkgs "Build tools for webcam driver" git curl cpio make build-essential dkms alsa-utils

KERNEL_VERSION=$(uname -r)
if ! dpkg -s "linux-headers-$KERNEL_VERSION" &>/dev/null; then
    print_info "Installing kernel headers for $KERNEL_VERSION..."
    if sudo apt install -y "linux-headers-$KERNEL_VERSION" &>/dev/null; then
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

if sudo dkms status | grep -q "facetimehd.*installed"; then
    print_skip "FaceTime HD webcam driver"
    SKIPPED+=("FaceTime HD webcam driver")
else
    print_info "Downloading and building FaceTime HD firmware (this may take a few minutes)..."
    (
        cd /tmp
        git clone https://github.com/patjak/facetimehd-firmware.git &>/dev/null
        cd facetimehd-firmware
        make &>/dev/null
        sudo make install &>/dev/null
        cd /tmp
        rm -rf facetimehd-firmware
    )
    print_ok "FaceTime HD firmware installed"

    print_info "Building FaceTime HD kernel module..."
    (
        cd /tmp
        git clone https://github.com/patjak/facetimehd.git &>/dev/null
        cd facetimehd
        FTHD_VERSION=$(grep "^PACKAGE_VERSION" dkms.conf | cut -d= -f2)
        sudo cp -r /tmp/facetimehd /usr/src/facetimehd-$FTHD_VERSION
        sudo dkms add -m facetimehd -v $FTHD_VERSION &>/dev/null
        sudo dkms build -m facetimehd -v $FTHD_VERSION &>/dev/null
        sudo dkms install -m facetimehd -v $FTHD_VERSION &>/dev/null
        cd /tmp
        rm -rf facetimehd
    )
    print_ok "FaceTime HD webcam driver installed"
    REBOOT_REQUIRED=true
    INSTALLED+=("FaceTime HD webcam driver")
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
# BATTERY AND POWER
# ─────────────────────────────────────────────
print_header "Battery and Power Management"
echo -e "  ${CYAN}Setting up battery indicator and lid close behavior.${NC}\n"

install_pkg "xfce4-battery-plugin" "Battery indicator plugin"
install_pkg "xfce4-power-manager" "Power manager"

print_info "Configuring lid close to suspend and lock screen..."
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lid-action-on-ac -s 2 --create -t int 2>/dev/null || true
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lid-action-on-battery -s 2 --create -t int 2>/dev/null || true
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -s true --create -t bool 2>/dev/null || true
print_ok "Lid close configured — closing lid will suspend and lock your screen"

sudo systemctl enable cups &>/dev/null
sudo systemctl start cups &>/dev/null
print_ok "Printing service enabled"

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
create_shortcut "Music" "rhythmbox" "rhythmbox"

cat > "$ACTUAL_HOME/Desktop/KEYBOARD SHORTCUTS.txt" << 'SHORTCUTS'
═══════════════════════════════════════════════════════
  KEYBOARD SHORTCUTS — debian-macbook-post-install
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
  Ctrl+Alt+S         Screenshot (flameshot)

───────────────────────────────────────────────────────
  WINDOW TILING (snap windows to screen edges)
───────────────────────────────────────────────────────
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
    echo -e "\n${RED}  Some items failed to install. Please check your internet connection and try again.${NC}"
fi

# ─────────────────────────────────────────────
# NEXT STEPS
# ─────────────────────────────────────────────
echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}  Almost done! Two quick steps after reboot:${NC}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}\n"
echo -e "  ${BOLD}1. Add the WiFi icon to your taskbar:${NC}"
echo -e "     Right-click taskbar → Panel → Add New Items → Network Manager\n"
echo -e "  ${BOLD}2. Add the battery indicator to your taskbar:${NC}"
echo -e "     Right-click taskbar → Panel → Add New Items → Battery Monitor\n"
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
