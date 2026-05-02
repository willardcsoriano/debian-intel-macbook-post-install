#!/bin/bash
set -e

# ─────────────────────────────────────────────
# SHARED PATHS
# ─────────────────────────────────────────────
SEARCH_DIRS=(
    /usr/share/applications
    /usr/local/share/applications
    "$HOME/.local/share/applications"
)

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

# Generates the System Info launcher when fastfetch and a terminal are both
# available. Returns the launcher path on stdout (empty if not generated).
generate_sysinfo_launcher() {
    local sysinfo_src="$HOME/.local/share/applications/system-info.desktop"
    command -v fastfetch &>/dev/null || return 0
    command -v gnome-terminal &>/dev/null || return 0
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
    echo "$sysinfo_src"
}

# Marks a .desktop file as trusted so XFCE skips the "Untrusted application
# launcher" prompt on first click. Sets both metadata keys for compatibility
# across XFCE versions (checksum: 4.14+, trusted flag: 4.16+).
mark_desktop_trusted() {
    local file=$1
    gio set "$file" "metadata::xfce-exe-checksum" \
        "$(sha256sum "$file" | awk '{print $1}')" 2>/dev/null || true
    gio set "$file" "metadata::trusted" true 2>/dev/null || true
}

# Copies curated .desktop files to ~/Desktop, strips OnlyShowIn/NotShowIn,
# and marks each file trusted. Searches all standard app directories so apps
# installed outside /usr/share/applications are included.
place_desktop_icons() {
    local sysinfo_src
    sysinfo_src=$(generate_sysinfo_launcher)

    local desktop_dir="$HOME/Desktop"
    mkdir -p "$desktop_dir"

    for entry in "${CURATED_APPS[@]}"; do
        for cand in $entry; do
            for dir in "${SEARCH_DIRS[@]}"; do
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
                mark_desktop_trusted "$dest"
                break 2
            done
        done
    done

    if [ -n "$sysinfo_src" ] && [ -f "$sysinfo_src" ]; then
        local sysinfo_dest="$desktop_dir/system-info.desktop"
        cp "$sysinfo_src" "$sysinfo_dest"
        chmod +x "$sysinfo_dest"
        mark_desktop_trusted "$sysinfo_dest"
    fi
}

# ─────────────────────────────────────────────
# MODE 3 — REVERT TO VANILLA XFCE
# ─────────────────────────────────────────────
if [[ "$MODE" == "3" ]]; then
    echo ""
    echo "  This will remove WhiteSur themes/icons, Plank, the docklike plugin,"
    echo "  and reset XFCE panel/desktop config to defaults."
    echo ""
    read -p "  Continue? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi

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

# Check internet connectivity before proceeding. curl is part of the base
# system on Debian; wget is not always present on minimal installs.
echo "Checking internet connectivity..."
if ! curl --silent --head --max-time 5 https://deb.debian.org >/dev/null; then
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

# Align window title to the left (macOS style)
xfconf-query -c xfwm4 -p /general/title_alignment -s "left"

# Add docklike plugin to panel 1 only if not already added.
# Find the highest existing plugin ID across the entire panel config (not just
# panel-1's plugin-ids) so we never collide with a plugin defined elsewhere.
PANEL_XML="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
PANEL_CHANGED=0
if ! grep -q 'value="docklike"' "$PANEL_XML" 2>/dev/null; then
    MAX_ID=$(xfconf-query -c xfce4-panel -lv 2>/dev/null \
             | grep -oE '/plugins/plugin-[0-9]+' \
             | grep -oE '[0-9]+$' | sort -n | tail -1)
    MAX_ID=${MAX_ID:-0}
    DOCKLIKE_ID=$((MAX_ID + 1))
    xfconf-query -c xfce4-panel -p /plugins/plugin-$DOCKLIKE_ID --create -t string -s "docklike"
    ARGS=()
    while IFS= read -r id; do
        ARGS+=(-t int -s "$id")
    done < <(xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids 2>/dev/null | grep -oE '^[0-9]+$')
    ARGS+=(-t int -s "$DOCKLIKE_ID")
    xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids --force-array "${ARGS[@]}"
    PANEL_CHANGED=1
fi

# Remove panel 2 (default bottom taskbar) — competes with Plank
if xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -q "^2$"; then
    xfconf-query -c xfce4-panel -p /panels --force-array -t int -s 1
    xfconf-query -c xfce4-panel -p /panels/panel-2 -r -R 2>/dev/null || true
    PANEL_CHANGED=1
fi

# Restart panel once if anything changed, so plugin/panel edits take effect now
# instead of waiting for next login.
if [ "$PANEL_CHANGED" = "1" ]; then
    xfce4-panel --restart 2>/dev/null || true
fi

# Seeds Plank's default config by starting it briefly, waiting for the
# settings file to materialize (poll up to ~10 s), then stopping it. Using
# a poll instead of a fixed sleep keeps this reliable on slow hardware.
seed_plank_config() {
    pkill plank 2>/dev/null || true
    sleep 1
    plank &
    local i
    for i in $(seq 1 20); do
        [ -f "$HOME/.config/plank/dock1/settings" ] && break
        sleep 0.5
    done
    pkill plank 2>/dev/null || true
    sleep 1
}

# Wallpaper — auto-detect monitor name, apply solid near-black.
# Prefer the primary output; fall back to the first connected output.
MONITOR=$(xrandr --query 2>/dev/null | awk '/ connected primary/{print $1; exit}')
[ -z "$MONITOR" ] && MONITOR=$(xrandr --query 2>/dev/null | awk '/ connected/{print $1; exit}')
BASE="/backdrop/screen0/monitor${MONITOR}/workspace0"
xfconf-query -c xfce4-desktop -p "${BASE}/color-style" --create -t int -s 0
xfconf-query -c xfce4-desktop -p "${BASE}/rgba1" --create --force-array \
    -t double -s 0.08 -t double -s 0.08 -t double -s 0.10 -t double -s 1.0
xfconf-query -c xfce4-desktop -p "${BASE}/image-style" --create -t int -s 0

# System Info — generated here for Mode 2's dock launcher reference.
# place_desktop_icons() also generates it independently for Modes 1 and 3.
SYSINFO_SRC=$(generate_sysinfo_launcher)

# ─────────────────────────────────────────────
# MODE 1 — CLASSIC
# ─────────────────────────────────────────────
if [[ "$MODE" == "1" ]]; then

    # Keep desktop icons visible
    xfconf-query -c xfce4-desktop -p /desktop-icons/style --create -t int -s 2

    place_desktop_icons

    # Plank settings — default theme, shows open apps only
    seed_plank_config

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
    seed_plank_config

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

    # Sort= positions each item left-to-right; lower = leftmost. Increment as
    # we place each launcher so curated order is preserved regardless of
    # filename-based sorting Plank may otherwise apply.
    sort_idx=10
    for entry in "${CURATED_APPS[@]}"; do
        for cand in $entry; do
            for dir in "${SEARCH_DIRS[@]}"; do
                src="$dir/${cand}.desktop"
                [ -f "$src" ] || continue
                cat > ~/.config/plank/dock1/launchers/${cand}.dockitem << EOF
[PlankDockItemPreferences]
Launcher=file://${src}
Sort=${sort_idx}
EOF
                sort_idx=$((sort_idx + 1))
                break 2
            done
        done
    done

    # System Info dock launcher
    if [ -n "$SYSINFO_SRC" ] && [ -f "$SYSINFO_SRC" ]; then
        cat > ~/.config/plank/dock1/launchers/system-info.dockitem << EOF
[PlankDockItemPreferences]
Launcher=file://${SYSINFO_SRC}
Sort=${sort_idx}
EOF
        sort_idx=$((sort_idx + 1))
    fi

    # Trash docklet — explicit high Sort so it always lands rightmost.
    cat > ~/.config/plank/dock1/launchers/zzz-trash.dockitem << EOF
[PlankDockItemPreferences]
Launcher=docklet://trash
Sort=9999
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
