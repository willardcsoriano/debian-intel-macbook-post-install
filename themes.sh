#!/bin/bash
set -e

# ─────────────────────────────────────────────
# PREPARATION
# ─────────────────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ─────────────────────────────────────────────
# MODE SELECTION
# ─────────────────────────────────────────────
echo ""
echo "  Select desktop mode:"
echo ""
echo "  1) Classic  — desktop icons visible, Plank shows open apps"
echo "  2) Dock     — clean empty desktop, all apps in Plank"
echo "  3) Revert   — remove all themes, restore vanilla XFCE"
echo ""
read -p "  Enter 1, 2, or 3: " MODE

if [[ "$MODE" != "1" && "$MODE" != "2" && "$MODE" != "3" ]]; then
    echo "Invalid selection. Exiting."
    exit 1
fi

# ─────────────────────────────────────────────
# CURATED APP LIST (shared by all modes)
# ─────────────────────────────────────────────

# Each entry lists candidate .desktop basenames; the first that exists on
# disk wins. Using the system file preserves Icon, Categories,
# StartupWMClass, and translations.
CURATED_APPS=(
    "firefox-esr"
    "thunar org.xfce.thunar"
    "org.gnome.Terminal gnome-terminal"
    "org.gnome.gedit gedit"
    "simple-scan"
    "vlc"
    "org.flameshot.Flameshot flameshot"
    "blueman-manager"
    "xfce4-taskmanager"
    "xfce4-settings-manager"
    "htop"
    "libreoffice-writer"
    "libreoffice-calc"
    "libreoffice-impress"
    "mtpaint"
    "code"
    "org.gnome.Calculator gnome-calculator"
    "org.gnome.baobab baobab"
    "xfce4-display-settings"
    "gdebi gdebi-gtk"
    "xfce4-clipman"
)

# Copies curated .desktop files to ~/Desktop, strips OnlyShowIn/NotShowIn,
# and marks each file trusted. Searches all three standard app directories
# so apps installed outside /usr/share/applications are included.
place_desktop_icons() {
    local sysinfo_src="$HOME/.local/share/applications/system-info.desktop"
    if command -v fastfetch &>/dev/null; then
        mkdir -p "$HOME/.local/share/applications"
        cat > "$sysinfo_src" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=System Info
Comment=Show system information
Exec=gnome-terminal -- fastfetch
Icon=computer
Terminal=false
Categories=System;
EOF
    fi

    local desktop_dir="$HOME/Desktop"
    mkdir -p "$desktop_dir"

    local search_dirs=(
        /usr/share/applications
        /usr/local/share/applications
        "$HOME/.local/share/applications"
    )

    for entry in "${CURATED_APPS[@]}"; do
        for cand in $entry; do
            for dir in "${search_dirs[@]}"; do
                local src="$dir/${cand}.desktop"
                [ -f "$src" ] || continue
                local dest="$desktop_dir/${cand}.desktop"
                if [ ! -f "$dest" ]; then
                    cp "$src" "$dest"
                    chmod +x "$dest"
                fi
                # Strip OnlyShowIn=/NotShowIn= — some upstream launchers (notably
                # org.gnome.Terminal with OnlyShowIn=GNOME;Unity;) would otherwise
                # be filtered out by XFCE and never render on the desktop.
                # Runs unconditionally so reruns repair files left by older versions.
                sed -i -E '/^(OnlyShowIn|NotShowIn)=/d' "$dest"
                # Mark trusted so XFCE skips the "Untrusted application launcher"
                # prompt on first click. Recomputed each run since the strip
                # above changes the file's checksum.
                gio set "$dest" "metadata::xfce-exe-checksum" \
                    "$(sha256sum "$dest" | awk '{print $1}')" 2>/dev/null || true
                break 2
            done
        done
    done

    if [ -f "$sysinfo_src" ]; then
        local sysinfo_dest="$desktop_dir/system-info.desktop"
        cp "$sysinfo_src" "$sysinfo_dest"
        chmod +x "$sysinfo_dest"
        gio set "$sysinfo_dest" "metadata::xfce-exe-checksum" \
            "$(sha256sum "$sysinfo_dest" | awk '{print $1}')" 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────
# MODE 3 — REVERT TO VANILLA XFCE
# ─────────────────────────────────────────────
if [[ "$MODE" == "3" ]]; then
    echo "Reverting to vanilla XFCE..."

    # Stop Plank before removing its files
    pkill plank 2>/dev/null || true

    # Remove WhiteSur theme and icon files
    rm -rf ~/.themes/WhiteSur* ~/.local/share/themes/WhiteSur*
    rm -rf ~/.icons/WhiteSur* ~/.local/share/icons/WhiteSur*

    # Remove generated desktop and launcher files
    rm -f ~/Desktop/*.desktop
    rm -f ~/.local/share/applications/system-info.desktop

    # Remove Plank config and autostart entry
    rm -rf ~/.config/plank
    rm -f ~/.config/autostart/plank.desktop

    # Remove packages installed by this script
    sudo apt remove -y plank gtk2-engines-murrine xfce4-docklike-plugin 2>/dev/null || true
    sudo apt autoremove -y 2>/dev/null || true

    # Reset XFCE to defaults by deleting the channel XMLs.
    # XFCE regenerates them with built-in defaults on next login.
    pkill -x xfconfd 2>/dev/null || true
    XFCONF_DIR="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
    rm -f "$XFCONF_DIR/xsettings.xml"
    rm -f "$XFCONF_DIR/xfwm4.xml"
    rm -f "$XFCONF_DIR/xfce4-desktop.xml"
    rm -f "$XFCONF_DIR/xfce4-panel.xml"

    # Deleting xfce4-panel.xml wipes the battery and volume panel plugins that
    # setup.sh added. Reset the marker and restore the autostart entry so they
    # get re-added automatically on next login.
    PANEL_SETUP_SCRIPT="$HOME/.local/bin/setup-panel-once.sh"
    if [ -f "$PANEL_SETUP_SCRIPT" ]; then
        rm -f "$HOME/.local/share/panel-configured"
        mkdir -p "$HOME/.config/autostart"
        cat > "$HOME/.config/autostart/setup-panel-once.desktop" << PANEL_DESKTOP
[Desktop Entry]
Type=Application
Name=Panel Setup (once)
Exec=$PANEL_SETUP_SCRIPT
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
PANEL_DESKTOP
    fi

    # Place curated shortcuts on the desktop
    xfconf-query -c xfce4-desktop -p /desktop-icons/style --create -t int -s 2
    place_desktop_icons

    echo ""
    echo -e "\033[0;32m✔ Done.\033[0m"
    echo ""
    echo "  Log out and back in to see vanilla XFCE."
    echo ""
    exit 0
fi

# ─────────────────────────────────────────────
# RECOVERY & CONNECTIVITY CHECK
# ─────────────────────────────────────────────

# Fix any broken apt state from previous interrupted installs
echo "Checking for broken package state..."
sudo apt --fix-broken install -y >>/dev/null 2>&1 || true
sudo apt clean >>/dev/null 2>&1 || true

# Check internet connectivity before proceeding
echo "Checking internet connectivity..."
if ! wget -q --spider --timeout=5 https://deb.debian.org; then
    echo -e "\033[0;31m✘ No internet connection detected.\033[0m"
    echo "Please connect to WiFi or check your network, then run this script again."
    exit 1
fi
echo -e "\033[0;32m✔ Internet connection confirmed\033[0m"

# ─────────────────────────────────────────────
# PACKAGES AND THEMES (same for both modes)
# ─────────────────────────────────────────────

# Packages
sudo apt install -y plank gtk2-engines-murrine gtk2-engines-pixbuf git xfce4-docklike-plugin
sudo apt install -y fonts-inter 2>/dev/null || echo "fonts-inter not available, skipping"

# Shallow-clone with retry — handles flaky connections without restarting
# the whole script. Shallow (--depth=1) cuts the download to ~10% of full.
clone_with_retry() {
    local url=$1 dest=$2 max=3 attempt=1
    while [ $attempt -le $max ]; do
        echo "Cloning $(basename "$url") (attempt $attempt/$max)..."
        rm -rf "$dest"
        if git -c http.postBuffer=524288000 clone --depth=1 "$url" "$dest"; then
            return 0
        fi
        attempt=$((attempt + 1))
        [ $attempt -le $max ] && { echo "Retrying in 5s..."; sleep 5; }
    done
    echo "✘ Failed to clone $url after $max attempts. Check your connection and re-run the script."
    exit 1
}

# WhiteSur GTK theme — skip if already installed
if [ ! -d "$HOME/.themes/WhiteSur-Dark" ] && [ ! -d "$HOME/.local/share/themes/WhiteSur-Dark" ]; then
    clone_with_retry https://github.com/vinceliuice/WhiteSur-gtk-theme.git /tmp/WhiteSur-gtk
    bash /tmp/WhiteSur-gtk/install.sh -c dark
    rm -rf /tmp/WhiteSur-gtk
else
    echo "WhiteSur GTK theme already installed, skipping."
fi

# WhiteSur icons — skip if already installed
if [ ! -d "$HOME/.icons/WhiteSur-dark" ] && [ ! -d "$HOME/.local/share/icons/WhiteSur-dark" ]; then
    clone_with_retry https://github.com/vinceliuice/WhiteSur-icon-theme.git /tmp/WhiteSur-icons
    bash /tmp/WhiteSur-icons/install.sh -a
    rm -rf /tmp/WhiteSur-icons
else
    echo "WhiteSur icons already installed, skipping."
fi

# Apply GTK theme and icons
xfconf-query -c xsettings -p /Net/ThemeName -s "WhiteSur-Dark"
xfconf-query -c xsettings -p /Net/IconThemeName -s "WhiteSur-dark"

# Apply window manager theme
xfconf-query -c xfwm4 -p /general/theme -s "WhiteSur-Dark"

# Move window buttons to the left (macOS style: close, minimize, maximize)
xfconf-query -c xfwm4 -p /general/button_layout -s "CMH|L"

# Add docklike plugin to panel 1 only if not already added
PANEL_XML="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
if ! grep -q 'value="docklike"' "$PANEL_XML" 2>/dev/null; then
    MAX_ID=$(xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids 2>/dev/null \
             | grep -oE '[0-9]+' | sort -n | tail -1)
    MAX_ID=${MAX_ID:-30}
    DOCKLIKE_ID=$((MAX_ID + 1))
    xfconf-query -c xfce4-panel -p /plugins/plugin-$DOCKLIKE_ID --create -t string -s "docklike"
    ARGS=()
    while IFS= read -r id; do
        ARGS+=(-t int -s "$id")
    done < <(xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids 2>/dev/null | grep -oE '[0-9]+')
    ARGS+=(-t int -s "$DOCKLIKE_ID")
    xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids --force-array "${ARGS[@]}"
fi

# Remove panel 2 (default bottom taskbar) — competes with Plank
if xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -q "^2$"; then
    xfconf-query -c xfce4-panel -p /panels --force-array -t int -s 1
    xfconf-query -c xfce4-panel -p /panels/panel-2 -r -R 2>/dev/null || true
    xfce4-panel --restart 2>/dev/null || true
fi

# Wallpaper — auto-detect monitor name, apply solid near-black
MONITOR=$(xrandr | awk '/ connected/{print $1; exit}')
BASE="/backdrop/screen0/monitor${MONITOR}/workspace0"
xfconf-query -c xfce4-desktop -p "${BASE}/color-style" --create -t int -s 0
xfconf-query -c xfce4-desktop -p "${BASE}/rgba1" --create -t double -s 0.08 -t double -s 0.08 -t double -s 0.10 -t double -s 1.0
xfconf-query -c xfce4-desktop -p "${BASE}/image-style" --create -t int -s 0

# System Info — generated here for Mode 2's dock launcher reference.
# place_desktop_icons() also generates it independently for Modes 1 and 3.
SYSINFO_SRC="$HOME/.local/share/applications/system-info.desktop"
if command -v fastfetch &>/dev/null; then
    mkdir -p "$HOME/.local/share/applications"
    cat > "$SYSINFO_SRC" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=System Info
Comment=Show system information
Exec=gnome-terminal -- fastfetch
Icon=computer
Terminal=false
Categories=System;
EOF
fi

# ─────────────────────────────────────────────
# MODE 1 — CLASSIC
# ─────────────────────────────────────────────
if [[ "$MODE" == "1" ]]; then

    # Keep desktop icons visible
    xfconf-query -c xfce4-desktop -p /desktop-icons/style --create -t int -s 2

    place_desktop_icons

    # Plank settings — default theme, shows open apps only
    pkill plank 2>/dev/null || true
    sleep 1
    plank &
    sleep 3
    pkill plank 2>/dev/null || true
    sleep 1

    mkdir -p ~/.config/plank/dock1
    cat > ~/.config/plank/dock1/settings << EOF
[PlankDockPreferences]
CurrentWorkspaceOnly=false
IconSize=48
HideMode=1
UnhideDelay=0
Monitor=
PrimaryMonitor=true
Position=0
Offset=0
Theme=Default
ItemHoverAnimation=1
ZoomPercent=150
LockItems=false
ProcessWithUrgency=true
EOF

    # No launchers in classic mode — Plank shows open apps naturally
    rm -f ~/.config/plank/dock1/launchers/*.dockitem

fi

# ─────────────────────────────────────────────
# MODE 2 — DOCK
# ─────────────────────────────────────────────
if [[ "$MODE" == "2" ]]; then

    # Hide desktop icons and clear shortcuts
    xfconf-query -c xfce4-desktop -p /desktop-icons/style --create -t int -s 0
    rm -f ~/Desktop/*.desktop

    # Plank settings — transparent theme, all apps as launchers
    pkill plank 2>/dev/null || true
    sleep 1
    plank &
    sleep 3
    pkill plank 2>/dev/null || true
    sleep 1

    mkdir -p ~/.config/plank/dock1
    cat > ~/.config/plank/dock1/settings << EOF
[PlankDockPreferences]
CurrentWorkspaceOnly=false
IconSize=48
HideMode=1
UnhideDelay=0
Monitor=
PrimaryMonitor=true
Position=0
Offset=0
Theme=Transparent
ItemHoverAnimation=1
ZoomPercent=150
LockItems=false
ProcessWithUrgency=true
EOF

    # Populate Plank with the same curated list used for Mode 1 desktop icons.
    mkdir -p ~/.config/plank/dock1/launchers
    rm -f ~/.config/plank/dock1/launchers/*.dockitem

    SEARCH_DIRS=(
        /usr/share/applications
        /usr/local/share/applications
        "$HOME/.local/share/applications"
    )

    for entry in "${CURATED_APPS[@]}"; do
        for cand in $entry; do
            for dir in "${SEARCH_DIRS[@]}"; do
                src="$dir/${cand}.desktop"
                [ -f "$src" ] || continue
                cat > ~/.config/plank/dock1/launchers/${cand}.dockitem << EOF
[PlankDockItemPreferences]
Launcher=file://${src}
EOF
                break 2
            done
        done
    done

    # System Info dock launcher
    if [ -f "$SYSINFO_SRC" ]; then
        cat > ~/.config/plank/dock1/launchers/system-info.dockitem << EOF
[PlankDockItemPreferences]
Launcher=file://${SYSINFO_SRC}
EOF
    fi

    # Trash docklet — prefixed with zzz_ so it sorts last (rightmost)
    cat > ~/.config/plank/dock1/launchers/zzz-trash.dockitem << EOF
[PlankDockItemPreferences]
Launcher=docklet://trash
EOF

fi

# ─────────────────────────────────────────────
# AUTOSTART AND LAUNCH (same for both modes)
# ─────────────────────────────────────────────
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/plank.desktop << EOF
[Desktop Entry]
Type=Application
Name=Plank
Exec=bash -c "sleep 3 && plank"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

plank &

echo ""
echo -e "\033[0;32m✔ Done.\033[0m"
echo ""
echo "  Log out and back in for all changes to take full effect."
echo ""
