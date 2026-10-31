#!/bin/bash
# setup.sh
# Post-installation setup for Debian 13 (Trixie) on Intel MacBooks
# Tested on MacBook Air 7,2 (2015) — should work on most Intel MacBooks
# https://github.com/willardcsoriano/debian-intel-macbook-post-install

set -uo pipefail

# ─────────────────────────────────────────────
# OPTIONS
# ─────────────────────────────────────────────
# --no-snapshot: skip the pre-change Timeshift snapshot, for a quick re-run by
# someone who knows they don't need an undo point for it.
NO_SNAPSHOT=false
for arg in "$@"; do
    case "$arg" in
        --no-snapshot) NO_SNAPSHOT=true ;;
        *) echo "Unknown option: $arg (supported: --no-snapshot)" >&2; exit 2 ;;
    esac
done

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
# Logs go in the XDG state directory (~/.local/state by default), not $HOME —
# re-running the installer shouldn't scatter timestamped files across the home
# directory. We keep a short rolling history plus a stable 'latest.log' symlink,
# and fall back to /tmp if the state dir can't be created or written.
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/macbook-postinstall"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_DIR="/tmp"
    LOG_FILE="$LOG_DIR/macbook-postinstall-$(date +%Y%m%d-%H%M%S).log"
    touch "$LOG_FILE"
fi

# 'latest.log' always points at the current run; prune older runs so the log dir
# keeps only the five most recent (skipped for the /tmp fallback, which the OS
# clears on its own). The timestamped names sort oldest first, so the glob is
# already in age order.
if [ "$LOG_DIR" != "/tmp" ]; then
    ln -sfn "$LOG_FILE" "$LOG_DIR/latest.log" 2>/dev/null || true
    OLD_LOGS=("$LOG_DIR"/setup-*.log)
    if [ "${#OLD_LOGS[@]}" -gt 5 ]; then
        rm -f "${OLD_LOGS[@]:0:${#OLD_LOGS[@]}-5}"
    fi
fi

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

# Report a service step by what systemd says, not by having run the command.
check_active() {
    if systemctl is-active --quiet "$1"; then
        print_ok "$2"
    else
        print_warning "$1 is not running — details: sudo journalctl -u $1 -n 30"
    fi
}

# Returns: 0 = installed now, 1 = already installed, 2 = failed
# dpkg-query, not dpkg -s: with a foreign architecture enabled (e.g. i386), a
# package installed for both is "ambiguous" to dpkg -s and looks missing.
is_installed() {
    dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null | grep -qx installed
}

install_pkg() {
    local pkg=$1
    local label=${2:-$1}
    if is_installed "$pkg"; then
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
        if ! is_installed "$pkg"; then
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

# Creates a Desktop shortcut, or rewrites one this script generated earlier
# with different content (e.g. a launcher that changed terminal), so re-runs
# converge on the current list instead of keeping stale shortcuts.
create_shortcut() {
    local name=$1
    local exec=$2
    local icon=$3
    local terminal=${4:-false}
    local file="$DESKTOP_DIR/${name}.desktop"
    local content
    content=$(cat <<SHORTCUT
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Exec=$exec
Icon=$icon
Terminal=$terminal
SHORTCUT
)
    if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
        print_skip "$name desktop shortcut"
        return
    fi
    local verb="created"
    [ -f "$file" ] && verb="updated"
    printf '%s\n' "$content" > "$file"
    chmod +x "$file"
    # Trusted, so XFCE doesn't ask "Untrusted application launcher" on the
    # first click: the checksum key for XFCE 4.14+, the flag for 4.16+.
    gio set "$file" "metadata::xfce-exe-checksum" "$(sha256sum "$file" | awk '{print $1}')" 2>/dev/null || true
    gio set "$file" "metadata::trusted" true 2>/dev/null || true
    print_ok "$name shortcut $verb on Desktop"
}

# Removes a shortcut an earlier version of this script generated, but only if
# its Exec line is still exactly what that version wrote -- a same-named
# shortcut the user made or edited is left alone.
retire_shortcut() {
    local name=$1
    local exec=$2
    local file="$DESKTOP_DIR/${name}.desktop"
    if [ -f "$file" ] && grep -qxF "Exec=$exec" "$file"; then
        rm -f "$file"
        print_ok "Removed retired $name shortcut"
    fi
}

# Sets <desktop-id> as the default app for each MIME type that has no default
# yet in the user's mimeapps.list, so a choice the user already made wins and
# re-runs change nothing.
set_default_app() {
    local app=$1
    shift
    local mime list="$ACTUAL_HOME/.config/mimeapps.list"
    [ -f "/usr/share/applications/$app" ] || return 0
    for mime in "$@"; do
        if [ -f "$list" ] && awk -v m="$mime=" '
            /^\[/ { sect = $0; next }
            sect == "[Default Applications]" && index($0, m) == 1 { found = 1 }
            END { exit !found }' "$list"; then
            continue
        fi
        xdg-mime default "$app" "$mime"
    done
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
echo -e "  ${CYAN}This takes a while: large downloads (LibreOffice alone is ~300 MB) and a webcam driver build. Leave it running.${NC}"
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
# PRE-CHANGE SAFETY SNAPSHOT
# ─────────────────────────────────────────────
# Runs before anything below touches the system (GRUB, kernel params, logind,
# polkit, NetworkManager, the whole network stack). This script is aimed at
# people with no way to self-rescue if a step goes wrong on their specific
# hardware — a free undo button matters more here than it would for someone
# comfortable debugging a broken boot. Always runs, no prompt: a snapshot
# that only exists for users who knew to ask for one defeats the point.
print_header "Pre-Change Safety Snapshot"
echo -e "  ${CYAN}Creating a system snapshot before changing anything, so this run can be undone.${NC}\n"

install_pkg "timeshift" "Timeshift (system snapshot tool)"

TIMESHIFT_CONF="/etc/timeshift/timeshift.json"
if [ ! -f "$TIMESHIFT_CONF" ]; then
    print_info "Configuring Timeshift (RSYNC mode, on-demand snapshots only — no recurring schedule)..."
    ROOT_UUID=$(findmnt -n -o UUID / 2>/dev/null)
    if [ -n "$ROOT_UUID" ]; then
        sudo mkdir -p /etc/timeshift
        sudo tee "$TIMESHIFT_CONF" > /dev/null << EOF
{
  "backup_device_uuid" : "$ROOT_UUID",
  "parent_device_uuid" : "",
  "do_first_run" : "false",
  "btrfs_mode" : "false",
  "include_btrfs_home_for_backup" : "false",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "schedule_monthly" : "false",
  "schedule_weekly" : "false",
  "schedule_daily" : "false",
  "schedule_hourly" : "false",
  "schedule_boot" : "false",
  "count_monthly" : "0",
  "count_weekly" : "0",
  "count_daily" : "0",
  "count_hourly" : "0",
  "count_boot" : "0",
  "snapshot_size" : "0",
  "snapshot_count" : "0",
  "exclude" : [],
  "exclude-apps" : []
}
EOF
        print_ok "Timeshift configured for on-demand snapshots on this disk"
    else
        print_warning "Could not determine root filesystem UUID — skipping automatic snapshot this run"
    fi
else
    print_skip "Timeshift already configured"
fi

# A snapshot takes minutes on every run, not just the first: rsync checks every
# system file even when little changed. So:
# - One per version of this script. The snapshot exists to undo what the script
#   changes, and re-running the same version changes nothing new, so the one
#   taken before that version first ran still covers it. The version is a hash
#   of this file; run from a pipe (bash <(curl ...)) the file can't be re-read,
#   so every run snapshots.
# - Only two kept: the oldest (closest to before this script first ran) and the
#   newest. Older ones in between are deleted. Snapshots you take yourself are
#   never touched: the script's own are found by their comment, on the root
#   filesystem where the config above stores them. If that folder can't be
#   read, nothing is skipped or deleted.
SNAP_COMMENT="Before debian-intel-macbook-post-install setup.sh"
SNAP_DIR="/timeshift/snapshots"
SCRIPT_SUM=""
[ -f "$0" ] && SCRIPT_SUM=$(sha256sum "$0" | cut -c1-12)

# This script's snapshots, oldest first (their names are timestamps).
script_snapshots() {
    local info
    for info in "$SNAP_DIR"/*/info.json; do
        [ -f "$info" ] || continue
        grep -qF "\"comments\" : \"$SNAP_COMMENT" "$info" && basename "$(dirname "$info")"
    done | sort
}

LAST_SNAP=$(script_snapshots | tail -n 1)
if [ "$NO_SNAPSHOT" = true ]; then
    print_warning "Snapshot skipped (--no-snapshot) — this run can't be undone with Timeshift"
elif [ ! -f "$TIMESHIFT_CONF" ]; then
    :
elif [ -n "$SCRIPT_SUM" ] && [ -n "$LAST_SNAP" ] && grep -qF "(script $SCRIPT_SUM)" "$SNAP_DIR/$LAST_SNAP/info.json"; then
    print_ok "This version of the script already has an undo point (snapshot $LAST_SNAP) — not taking another"
else
    print_info "Creating snapshot (takes a few minutes: Timeshift checks every system file)..."
    # No --tags: on-demand (O) is the default, and Timeshift 24.06 rejects an
    # explicit "--tags O" (its validator lists O as valid but doesn't accept it).
    if TS_OUT=$(sudo timeshift --create --comments "$SNAP_COMMENT${SCRIPT_SUM:+ (script $SCRIPT_SUM)}" 2>&1); then
        printf '%s\n' "$TS_OUT" | tr '\r' '\n' | grep -v '% complete' >>"$LOG_FILE"
        print_ok "Snapshot created — undo this entire run with: sudo timeshift --restore"
        mapfile -t SNAPS < <(script_snapshots)
        if [ "${#SNAPS[@]}" -gt 2 ]; then
            PRUNE_FAILED=false
            for snap in "${SNAPS[@]:1:${#SNAPS[@]}-2}"; do
                if sudo timeshift --delete --snapshot "$snap" --scripted --yes >>"$LOG_FILE" 2>&1; then
                    log "Deleted older setup snapshot $snap"
                else
                    PRUNE_FAILED=true
                    print_warning "Could not delete older setup snapshot $snap (see $LOG_FILE)"
                fi
            done
            [ "$PRUNE_FAILED" = false ] && print_ok "Older setup snapshots removed — kept the first (${SNAPS[0]}) and this run's"
        fi
    else
        printf '%s\n' "$TS_OUT" | tr '\r' '\n' | grep -v '% complete' >>"$LOG_FILE"
        TS_ERR=$(printf '%s\n' "$TS_OUT" | grep -m1 '^E:' || true)
        print_warning "Snapshot creation failed: ${TS_ERR:-no error message, see $LOG_FILE} — continuing without one"
    fi
fi

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

# ─────────────────────────────────────────────
# SWAP / MEMORY SAFETY NET
# ─────────────────────────────────────────────
print_header "Swap / Memory Safety Net"
echo -e "  ${CYAN}8GB RAM with no swap will hard freeze on OOM with no warning — adding compressed RAM swap.${NC}\n"

if /usr/sbin/swapon --show 2>/dev/null | grep -q .; then
    print_skip "Swap already configured"
else
    install_pkg "zram-tools" "zram-tools (compressed RAM swap)"
    if systemctl list-unit-files zramswap.service &>/dev/null; then
        sudo systemctl enable --now zramswap.service >>"$LOG_FILE" 2>&1 || true
        check_active zramswap.service "Compressed RAM swap active (survives reboot, no disk wear)"
    else
        print_warning "zram-tools installed but zramswap.service not found — swap may need a manual check"
    fi
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

# Debian 13's default 50unattended-upgrades covers the -security pocket and stable
# point releases (label=Debian), but leaves the -updates pocket commented out.
# Extend to -updates and the VS Code repo (third-party origins are excluded by
# default, so VS Code would otherwise never auto-update).
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
    check_active fwupd-refresh.timer "Firmware metadata refresh timer enabled"
fi

# apt-daily-upgrade.service ships with ConditionACPower=true, so it silently
# skips every firing while running on battery. This is a laptop by definition —
# for a user who is mostly unplugged, that condition alone can mean security
# updates never actually run despite everything above being configured
# correctly. Clear it with a drop-in rather than editing the shipped unit file,
# so a package update to apt doesn't just overwrite the change.
ACPOWER_OVERRIDE_DIR="/etc/systemd/system/apt-daily-upgrade.service.d"
ACPOWER_OVERRIDE_FILE="$ACPOWER_OVERRIDE_DIR/override.conf"
if [ ! -f "$ACPOWER_OVERRIDE_FILE" ]; then
    print_info "Allowing daily security updates to run on battery, not just AC power..."
    sudo mkdir -p "$ACPOWER_OVERRIDE_DIR"
    sudo tee "$ACPOWER_OVERRIDE_FILE" > /dev/null << 'EOF'
[Unit]
ConditionACPower=
EOF
    sudo systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
    print_ok "apt-daily-upgrade.service will now run regardless of power source"
else
    print_skip "apt-daily-upgrade.service AC power condition already cleared"
fi

# AppArmor ships enabled on Debian 13; only warn if it has been disabled
if systemctl is-active apparmor &>/dev/null; then
    print_ok "AppArmor is active"
else
    print_warning "AppArmor is not active — consider: sudo systemctl enable --now apparmor"
fi

# Firewall: refuse incoming connections, allow everything outgoing. A laptop
# joins networks it doesn't control; anything that happens to listen on all
# interfaces (a dev web server, say) is then reachable by everyone on that
# network. mDNS stays open so printers and other devices are still found.
# Enabled only on the run that installs ufw: if ufw is already installed but
# off, that looks deliberate and is left alone.
install_pkg "ufw" "ufw (firewall)"
UFW_RC=$?
if sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
    print_skip "Firewall (ufw already on)"
elif [ "$UFW_RC" -eq 0 ]; then
    if {
        sudo ufw default deny incoming &&
        sudo ufw default allow outgoing &&
        sudo ufw allow 5353/udp comment 'mDNS: printer and device discovery' &&
        sudo ufw --force enable
    } >>"$LOG_FILE" 2>&1; then
        print_ok "Firewall on: incoming connections blocked (open a port with: sudo ufw allow <port>)"
    else
        print_fail "Firewall (ufw could not be enabled -- see the log)"
        FAILED+=("Firewall")
    fi
elif [ "$UFW_RC" -eq 1 ]; then
    print_warning "ufw is installed but off -- left off. Turn it on with: sudo ufw enable"
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
echo -e "  ${CYAN}Setting XFCE's own terminal as the default terminal.${NC}\n"

# xfce4-terminal is a dependency of xfce4-goodies (installed above), so it is
# always present: copy-paste, right-click menu, mouse support, and theming
# through XFCE's own settings. Make it the default for both XFCE's "Terminal
# Emulator" (Ctrl+Alt+T, Thunar's "Open Terminal Here") and the system-wide
# x-terminal-emulator.
if [ -x /usr/bin/xfce4-terminal.wrapper ]; then
    if [ "$(readlink -f /etc/alternatives/x-terminal-emulator)" != "/usr/bin/xfce4-terminal.wrapper" ]; then
        sudo update-alternatives --set x-terminal-emulator /usr/bin/xfce4-terminal.wrapper >>"$LOG_FILE" 2>&1 \
            && print_ok "xfce4-terminal set as the system default terminal"
    else
        print_skip "Default terminal (xfce4-terminal)"
    fi
fi
HELPERS_RC="$ACTUAL_HOME/.config/xfce4/helpers.rc"
mkdir -p "$(dirname "$HELPERS_RC")"
if grep -qx "TerminalEmulator=xfce4-terminal" "$HELPERS_RC" 2>/dev/null; then
    print_skip "XFCE preferred terminal (xfce4-terminal)"
elif grep -q "^TerminalEmulator=" "$HELPERS_RC" 2>/dev/null; then
    sed -i 's/^TerminalEmulator=.*/TerminalEmulator=xfce4-terminal/' "$HELPERS_RC"
    print_ok "XFCE preferred terminal set to xfce4-terminal"
else
    echo "TerminalEmulator=xfce4-terminal" >> "$HELPERS_RC"
    print_ok "XFCE preferred terminal set to xfce4-terminal"
fi

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
echo -e "  ${CYAN}Installing Firefox, a calculator, and printing support.${NC}\n"

install_pkg "firefox-esr" "Firefox web browser"
install_pkg "chromium" "Chromium web browser"
# Text editing uses Mousepad, XFCE's own editor (a dependency of xfce4-goodies).
install_pkg "galculator" "galculator (calculator)"
install_pkg "cups" "CUPS printing system"

sudo systemctl enable cups >>"$LOG_FILE" 2>&1 || true
sudo systemctl start cups >>"$LOG_FILE" 2>&1 || true
check_active cups "Printing service enabled"

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
install_pkg "playerctl" "playerctl (media key control backend)"
install_pkg "libreoffice" "LibreOffice (office suite)"
install_pkg "mtpaint" "mtPaint (simple image editor)"
install_pkg "gdebi" "gdebi (package installer)"
install_pkg "poppler-utils" "poppler-utils (PDF command-line tools)"
install_pkg "speech-dispatcher" "speech-dispatcher (text-to-speech)"

print_info "Configuring screenshot shortcut..."
xfconf_set -c xfce4-keyboard-shortcuts -p '/commands/custom/<Primary><Alt>s' -s 'flameshot gui' --create -t string
print_ok "Screenshot shortcut set (Cmd+Shift+4 / 5 draw a region)"

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
check_active NetworkManager "NetworkManager is running — WiFi will connect automatically on boot"

# polkit (authority / safety layer)
# Debian lets a local, *active* sudo/netdev user change system network
# settings without a password. Lock the screen and light-locker switches to
# the greeter VT, logind marks the session inactive, and that rule stops
# matching: a background process (nm-applet, for one) can then fall through
# to an admin password dialog nobody asked for, waiting for you on unlock.
# Nothing on a locked seat needs to reconfigure the network, and a password
# prompt you didn't trigger is one you should never get used to answering,
# so refuse outright instead. This only removes a path: active sessions and
# sudo/root are unaffected, and NetworkManager itself still reconnects on
# its own while locked.
print_info "Refusing NetworkManager changes from locked/background sessions..."
sudo mkdir -p /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/50-networkmanager-inactive-session.rules > /dev/null << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        subject.local && !subject.active) {
        return polkit.Result.NO;
    }
});
EOF
print_ok "NetworkManager changes refused while the session is locked or in the background"

# ─────────────────────────────────────────────
# KEYBOARD
# ─────────────────────────────────────────────
print_header "MacBook Keyboard Fixes"
echo -e "  ${CYAN}Remapping keys so your Mac keyboard works naturally on Linux.${NC}\n"

install_pkg "keyd" "keyd (key remapper)" && REBOOT_REQUIRED=true
install_pkg "brightness-udev" "brightness-udev (backlight permissions)" || true
install_pkg "rofi" "rofi (Mission Control window switcher)"
install_pkg "python3-xlib" "python3-xlib (lets the terminal get its own Mac keys)"

# How the Mac keyboard maps, and why (see "MacBook Keyboard Fixes" in the README):
# macOS Monterey's keys (unchanged in later macOS), with one deliberate
# exception for the Tab keys, which follow how Mac users reach for them on
# Linux: Cmd+Tab = next tab, Option+Tab = switch apps.
# - Cmd is a held keyd *layer* that behaves as Ctrl, so every Ctrl shortcut
#   works as Cmd+<key>, plus macOS overrides (Cmd+arrows, Cmd+H, ...). Earlier
#   versions wrote "meta+left = home" in [main], which keyd reads as a 50 ms
#   *chord*, so Cmd+Space and Cmd+arrows never worked.
# - Left Option is a layer that never sends Alt itself: one that holds Alt
#   (option:A) lets apps see the Alt press, and Option+Right opened the File
#   menu. Its keys are explicit bindings; Right Option stays plain Alt for
#   Alt+F4, Alt+drag and the like.
# - control does what it does on macOS (text-field keys, Mission Control,
#   desktops); everything else stays Ctrl, so Ctrl+C still stops a program.
# - keyd only emits keys. Anything that launches a program (F3, screenshots)
#   emits a combo that XFCE binds below, so it runs as you, not as root.
# - Fn (Globe) is a layer for the macOS Fn shortcuts. The keyboard translates
#   Fn+arrows, Fn+Backspace and Fn+F1-F12 itself, before keyd sees them.
# The full audit against Apple's shortcut list: docs/apple-shortcuts.tsv.
# Composite layers ([cmd+shift] ...) must come after the layers they combine.
KEYD_CONF="/etc/keyd/default.conf"
if [ -f "$KEYD_CONF" ] && [ ! -f "$KEYD_CONF.bak" ]; then
    print_info "Backing up the original keyboard config..."
    sudo cp "$KEYD_CONF" "$KEYD_CONF.bak"
    print_ok "Original saved to $KEYD_CONF.bak"
fi

print_info "Writing keyboard configuration..."
sudo mkdir -p /etc/keyd
sudo tee "$KEYD_CONF" > /dev/null << EOF
# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.
[ids]
*

[main]
# Cmd: a Ctrl layer with macOS overrides
meta = layer(cmd)
# Left Option: word keys and the app switcher (see above)
leftalt = layer(option)
# Fn (Globe)
fn = layer(globe)

# F3 (Mission Control): Super+W, which XFCE binds to the rofi window switcher
scale = M-w
# F4 (Launchpad): the app finder, full window with the app list (Alt+F2 is
# XFCE's small run-a-command box, which doesn't search app names)
dashboard = M-A-space
# Fn+F11: show the desktop, as on a Mac (F11 alone is volume down). Apps lose
# plain F11; Ctrl+Cmd+F is full screen.
f11 = C-A-d

# Brightness keys (via sysfs)
brightnessdown = command(sh -c 'val=\$(cat /sys/class/backlight/intel_backlight/brightness); echo \$((val > 200 ? val - 200 : 100)) | tee /sys/class/backlight/intel_backlight/brightness')
brightnessup = command(sh -c 'val=\$(cat /sys/class/backlight/intel_backlight/brightness); echo \$((val + 200 > $MAX_BRIGHTNESS ? $MAX_BRIGHTNESS : val + 200)) | tee /sys/class/backlight/intel_backlight/brightness')

[cmd:C]
# Spotlight -> app finder (full window, like F4)
space = M-A-space
# Line and document navigation
left = home
right = end
up = C-home
down = C-end
# Delete to the start of the line
backspace = macro(S-home delete)
# Tab is left as Ctrl+Tab: next tab (Cmd+Shift+Tab: previous)
# Windows of the current app: hold Cmd, tap the grave key (XFCE's Super+Tab switcher)
grave = swapm(app_windows, M-tab)
# Hide the front app (all its windows, via mac-hide below) / minimize the window
h = M-S-h
m = A-f9
# Cmd+Mission Control (F3): show the desktop
scale = C-A-d
# Cmd+Brightness Down: display arrangement and mirroring (XFCE's Super+P)
brightnessdown = M-p

[option]
# Word navigation and word delete (Fn+Backspace is forward delete)
left = C-left
right = C-right
backspace = C-backspace
delete = C-delete
# Paragraph start / end
up = C-up
down = C-down
# App switcher: hold Option, tap Tab to cycle (Alt stays held until Option is released)
tab = swapm(app_switch, A-tab)
# Option + a top-row key opens its settings (XFCE runs these, see below)
brightnessdown = M-A-1
brightnessup = M-A-1
volumedown = M-A-2
volumeup = M-A-2
mute = M-A-2
kbdillumdown = M-A-3
kbdillumup = M-A-3
scale = M-A-4

[app_switch:A]

[app_windows:M]
grave = M-tab

[control]
# The control key does what it does on a Mac. Text fields: Ctrl+A/E line
# start/end, F/B/N/P move the cursor, H/D delete back/forward, K cuts to the
# end of the line, O opens a line. (The terminal keeps the real Ctrl keys:
# see ~/.config/keyd/app.conf.)
a = home
e = end
f = right
b = left
n = down
p = up
h = backspace
d = delete
k = macro(S-end C-x)
o = macro(enter left)
# Ctrl+Up: Mission Control (window switcher). Ctrl+Down: windows of the front
# app. Ctrl+Left/Right: previous / next desktop (Space).
up = M-w
down = M-tab
left = C-A-left
right = C-A-right
# Fn+Control+F2: the menu bar (F10). Fn+Control+F4: the previous window
f2 = f10
f4 = A-tab
# Control+Power: the restart / sleep / shut down dialog
power = M-A-q

[cmd+shift]
# Selection to line / document edges
left = S-home
right = S-end
up = C-S-home
down = C-S-end
# Previous / next tab (browsers, VS Code, terminal, editors)
leftbrace = C-pageup
rightbrace = C-pagedown
# Log out (XFCE's log-out dialog asks to confirm, as on a Mac)
q = C-A-delete
# Help (Cmd+?)
slash = f1
# Screenshots: 3 = whole screen to ~/Pictures and the clipboard, 4 and 5 = Flameshot
3 = M-3
4 = C-A-s
5 = C-A-s

[option+shift]
# Select by word / to paragraph start and end
left = C-S-left
right = C-S-right
up = C-S-up
down = C-S-down
# Brightness, keyboard light and volume in quarter steps
brightnessdown = command(sh -c 'val=\$(cat /sys/class/backlight/intel_backlight/brightness); echo \$((val > 150 ? val - 50 : 100)) | tee /sys/class/backlight/intel_backlight/brightness')
brightnessup = command(sh -c 'val=\$(cat /sys/class/backlight/intel_backlight/brightness); echo \$((val + 50 > $MAX_BRIGHTNESS ? $MAX_BRIGHTNESS : val + 50)) | tee /sys/class/backlight/intel_backlight/brightness')
kbdillumdown = command(sh -c 'for d in /sys/class/leds/*kbd_backlight; do val=\$(cat \$d/brightness); echo \$((val > 4 ? val - 4 : 0)) | tee \$d/brightness; done')
kbdillumup = command(sh -c 'for d in /sys/class/leds/*kbd_backlight; do val=\$(cat \$d/brightness); max=\$(cat \$d/max_brightness); echo \$((val + 4 > max ? max : val + 4)) | tee \$d/brightness; done')
volumedown = M-A-minus
volumeup = M-A-equal

[control+shift]
# Control+Shift+Power: display sleep
power = M-A-z

[control+cmd]
# Lock screen / full screen
q = C-A-l
f = A-f11
# Emoji and symbols
space = M-A-e

[cmd+option]
# Force Quit: click a window to close it
escape = C-A-escape
# Hide every other app / minimize every window of the front app (mac-hide)
h = M-A-h
m = M-S-h
# Find and Replace (Linux apps use Ctrl+H)
f = C-h
# Previous / next tab, as in Safari and Chrome on a Mac
left = C-pageup
right = C-pagedown
# Inspector / developer tools
i = C-S-i
# Area screenshot (Flameshot), the key earlier versions gave it, beside Cmd+Shift+4 / 5
s = C-A-s
# New terminal window (macOS uses Cmd+Option+T for a toolbar toggle these apps lack)
t = M-A-t
# Show or hide the Dock / the Accessibility settings (Fn+F5)
d = M-A-d
f5 = M-A-5

[control+cmd+option]
# Invert colors
8 = M-A-8

[cmd+option+shift]
# Paste and Match Style: paste as plain text
v = C-S-v

[globe]
# Fn+H: show the desktop. Fn+E: emoji. Fn+A: show or hide the Dock
h = C-A-d
e = M-A-e
a = M-A-d

[globe+shift]
# Fn+Shift+A: Apps (Launchpad)
a = M-A-space
EOF

print_ok "Keyboard config written"

sudo systemctl enable keyd >>"$LOG_FILE" 2>&1 || true
# keyd skips any line it can't parse and runs with the rest, so a clean
# restart doesn't mean the config loaded: read its startup errors back.
KEYD_SINCE=$(date +%s)
sudo systemctl restart keyd >>"$LOG_FILE" 2>&1 || true
sleep 1
KEYD_ERRORS=$(sudo journalctl -u keyd --since "@$KEYD_SINCE" --no-pager -o cat 2>/dev/null | grep 'ERROR' || true)
if ! systemctl is-active --quiet keyd; then
    print_warning "keyd failed to start — Mac key mappings are off. Details: sudo journalctl -u keyd -n 30"
elif [ -n "$KEYD_ERRORS" ]; then
    log "keyd config errors: $KEYD_ERRORS"
    print_warning "keyd is running but rejected part of /etc/keyd/default.conf (those keys are unmapped):"
    printf '%s\n' "$KEYD_ERRORS" | sed 's/^[[:space:]]*/      /'
else
    print_ok "Keyboard remapping is active"
fi

# XFCE runs the programs those combos stand for, as you.
xfconf_set -c xfce4-keyboard-shortcuts -p '/commands/custom/<Super>w' -s 'rofi -show window -show-icons' --create -t string
xfconf_set -c xfce4-keyboard-shortcuts -p '/commands/custom/<Super>3' -s "sh -c 'mkdir -p \"\$HOME/Pictures\" && flameshot full -c -p \"\$HOME/Pictures\"'" --create -t string

# Cmd+H hides the front app and Cmd+Option+H every other app, as on a Mac.
# XFCE minimizes one window at a time, so mac-hide minimizes the set: every
# normal window of the app (by WM_CLASS) on the current desktop, never panels,
# docks or the desktop itself.
install_pkg "xdotool" "xdotool (minimizes windows for Cmd+H)" || true
install_pkg "x11-utils" "xprop (reads the window list for Cmd+H)" || true
MAC_HIDE="/usr/local/bin/mac-hide"
sudo tee "$MAC_HIDE" > /dev/null << 'MACHIDE'
#!/usr/bin/python3
# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.
"""Hide windows the way macOS does.

    mac-hide app       Cmd+H: minimize every window of the front app
    mac-hide others    Cmd+Option+H: minimize every window of the other apps
    add --dry-run      print the window ids instead of minimizing them

Only normal windows on the front window's desktop (or on all desktops) count.
"""
import re
import subprocess
import sys

ALL_DESKTOPS = 0xFFFFFFFF


def window_ids(xprop_output):
    """Ids in an xprop WINDOW property, e.g. '..._NET_CLIENT_LIST(WINDOW): window id # 0x1, 0x2'."""
    _, _, ids = xprop_output.partition("#")
    return [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", ids)]


def window_info(window_id, xprop_output):
    props = {}
    for line in xprop_output.splitlines():
        name, sep, value = line.partition(" = ")
        if sep:
            props[name.split("(")[0]] = value.strip()
    classes = re.findall(r'"((?:[^"\\]|\\.)*)"', props.get("WM_CLASS", ""))
    desktop = props.get("_NET_WM_DESKTOP")
    return {
        "id": window_id,
        # EWMH: a managed window without a type is a normal window
        "normal": "_NET_WM_WINDOW_TYPE" not in props
                  or "_NET_WM_WINDOW_TYPE_NORMAL" in props["_NET_WM_WINDOW_TYPE"],
        "hidden": "_NET_WM_STATE_HIDDEN" in props.get("_NET_WM_STATE", ""),
        "desktop": int(desktop) if desktop and desktop.isdigit() else None,
        "wm_class": tuple(classes) or None,
    }


def to_hide(windows, active, mode):
    """Ids to minimize. Nothing when the front window is not a normal window
    (the desktop or a panel has focus)."""
    front = next((w for w in windows if w["id"] == active), None)
    if front is None or not front["normal"]:
        return []
    chosen = []
    for w in windows:
        if not w["normal"] or w["hidden"]:
            continue
        if w["desktop"] not in (front["desktop"], ALL_DESKTOPS):
            continue
        same_app = w["id"] == active or (front["wm_class"] is not None
                                         and w["wm_class"] == front["wm_class"])
        if same_app == (mode == "app"):
            chosen.append(w["id"])
    return chosen


def xprop(*args):
    return subprocess.run(["xprop", *args], capture_output=True, text=True, check=True).stdout


def main(argv):
    args = [a for a in argv[1:] if a != "--dry-run"]
    if len(args) != 1 or args[0] not in ("app", "others"):
        print(__doc__, file=sys.stderr)
        return 2
    active = (window_ids(xprop("-root", "_NET_ACTIVE_WINDOW")) or [0])[0]
    windows = []
    for wid in window_ids(xprop("-root", "_NET_CLIENT_LIST")):
        try:
            out = xprop("-id", hex(wid), "_NET_WM_WINDOW_TYPE", "_NET_WM_DESKTOP",
                        "WM_CLASS", "_NET_WM_STATE")
        except subprocess.CalledProcessError:
            continue  # closed since the list was read
        windows.append(window_info(wid, out))
    for wid in to_hide(windows, active, args[0]):
        if "--dry-run" in argv:
            print(hex(wid))
        else:
            subprocess.run(["xdotool", "windowminimize", str(wid)], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
MACHIDE
sudo chmod 755 "$MAC_HIDE"
xfconf_set -c xfce4-keyboard-shortcuts -p '/commands/custom/<Super><Shift>h' -s "$MAC_HIDE app" --create -t string
xfconf_set -c xfce4-keyboard-shortcuts -p '/commands/custom/<Super><Alt>h' -s "$MAC_HIDE others" --create -t string

# The rest of the macOS keys that start something: keyd sends Super+Alt+<key>
# (see the keyd config above) and XFCE runs it, as you. mac-shortcut holds the
# three that need more than one command: the emoji picker (rofi over Debian's
# Unicode emoji list), showing or hiding the Dock (Plank), and volume in small
# steps that stop at 100% (PulseAudio's own step can go past it).
install_pkg "unicode-data" "Unicode emoji list (for the emoji picker)" || true
install_pkg "xcalib" "xcalib (Invert colors)" || true
install_pkg "xclip" "xclip (copies the picked emoji)" || true
MAC_SHORTCUT="/usr/local/bin/mac-shortcut"
sudo tee "$MAC_SHORTCUT" > /dev/null << 'MACSHORTCUT'
#!/usr/bin/python3
# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.
"""macOS keys that need more than one command.

    mac-shortcut emoji          Ctrl+Cmd+Space / Fn+E: pick an emoji, type it
                                and copy it to the clipboard
    mac-shortcut toggle-dock    Option+Cmd+D / Fn+A: Dock auto-hide on or off
    mac-shortcut volume STEP    Option+Shift+volume keys: change the volume by
                                STEP percent (e.g. -1), between 0 and 100
"""
import os
import re
import subprocess
import sys

EMOJI_TEST = "/usr/share/unicode/emoji/emoji-test.txt"
PLANK = "net.launchpad.plank"
DOCK_SCHEMA = "net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/{}/"
DOCK_DEFAULT_MODE = "'intelligent'"


def emoji_entries(text):
    """'😀 grinning face' for each fully-qualified emoji in emoji-test.txt."""
    entries = []
    for line in text.splitlines():
        code, _, rest = line.partition("#")
        if "; fully-qualified" not in code:
            continue
        parts = rest.strip().split(" ", 2)  # emoji, Unicode version, name
        if len(parts) == 3:
            entries.append(f"{parts[0]} {parts[2]}")
    return entries


def next_dock_mode(current, saved):
    """(mode to set, mode to remember). Auto-hide on remembers the mode it
    replaces; off restores it."""
    if current == "'auto'":
        return saved or DOCK_DEFAULT_MODE, None
    return "'auto'", current


def new_volume(pactl_output, step):
    """The default sink's volume after a step, from `pactl get-sink-volume`."""
    m = re.search(r"(\d+)%", pactl_output)
    if not m:
        raise ValueError("no volume in pactl output")
    return max(0, min(100, int(m.group(1)) + step))


def run(*cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, check=True, **kw).stdout


def emoji():
    with open(EMOJI_TEST, encoding="utf-8") as f:
        entries = emoji_entries(f.read())
    picked = subprocess.run(["rofi", "-dmenu", "-i", "-p", "Emoji"], input="\n".join(entries),
                            capture_output=True, text=True)
    if picked.returncode != 0 or not picked.stdout.strip():
        return 0  # closed without choosing
    char = picked.stdout.split(" ", 1)[0].strip()
    subprocess.run(["xclip", "-selection", "clipboard"], input=char, text=True, check=False)
    subprocess.run(["xdotool", "type", "--clearmodifiers", "--", char], check=False)
    return 0


def toggle_dock():
    docks = re.findall(r"'([^']+)'", run("gsettings", "get", PLANK, "enabled-docks"))
    if not docks:
        return 1
    schema = DOCK_SCHEMA.format(docks[0])
    state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                         "mac-shortcut-dock-mode")
    try:
        with open(state) as f:
            saved = f.read().strip() or None
    except OSError:
        saved = None
    mode, remember = next_dock_mode(run("gsettings", "get", schema, "hide-mode").strip(), saved)
    run("gsettings", "set", schema, "hide-mode", mode)
    if remember:
        os.makedirs(os.path.dirname(state), exist_ok=True)
        with open(state, "w") as f:
            f.write(remember + "\n")
    return 0


def volume(step):
    level = new_volume(run("pactl", "get-sink-volume", "@DEFAULT_SINK@"), step)
    run("pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{level}%")
    return 0


def main(argv):
    if argv[1:] == ["emoji"]:
        return emoji()
    if argv[1:] == ["toggle-dock"]:
        return toggle_dock()
    if len(argv) == 3 and argv[1] == "volume" and re.fullmatch(r"[+-]?\d+", argv[2]):
        return volume(int(argv[2]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
MACSHORTCUT
sudo chmod 755 "$MAC_SHORTCUT"
while IFS='|' read -r combo command; do
    xfconf_set -c xfce4-keyboard-shortcuts -p "/commands/custom/$combo" -s "$command" --create -t string
done << SHORTCUTS
<Super><Alt>e|$MAC_SHORTCUT emoji
<Super><Alt>d|$MAC_SHORTCUT toggle-dock
<Super><Alt>minus|$MAC_SHORTCUT volume -1
<Super><Alt>equal|$MAC_SHORTCUT volume +1
<Super><Alt>z|xset dpms force off
<Super><Alt>q|xfce4-session-logout
<Super><Alt>1|xfce4-display-settings
<Super><Alt>2|pavucontrol
<Super><Alt>3|xfce4-keyboard-settings
<Super><Alt>4|xfwm4-settings
<Super><Alt>5|xfce4-accessibility-settings
<Super><Alt>8|xcalib -invert -alter
<Super><Alt>space|xfce4-appfinder
<Super><Alt>t|exo-open --launch TerminalEmulator
SHORTCUTS

# Per-app keys. A few Cmd keys must mean something else in some apps: in a
# terminal Cmd+C has to copy rather than interrupt, and in Files Cmd+Backspace
# has to trash the selection. mac-app-keys gives keyd the bindings in
# ~/.config/keyd/app.conf for the app in front. It replaces keyd's own
# keyd-application-mapper, which rescanned every window on each title change
# and fell minutes behind on a busy desktop (wrong keys, a CPU core at 100%).
MAC_APP_KEYS="/usr/local/bin/mac-app-keys"
sudo tee "$MAC_APP_KEYS" > /dev/null << 'MACAPPKEYS'
#!/usr/bin/python3
# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.
"""Per-app Mac keys: give keyd the bindings in ~/.config/keyd/app.conf for
the app in front, and switch them when another app comes to the front.

Started at login. It reacts only to the window manager's "active window
changed" notice on the root window: never to title changes, and it never
walks the window tree, so it stays idle while windows redraw. SIGUSR1
applies the front app's keys again (keyd forgets them when it restarts).

    mac-app-keys                 run
    mac-app-keys --show CLASS    print the bindings for a window class
"""
import fcntl
import fnmatch
import os
import re
import select
import shutil
import signal
import subprocess
import sys

CONFIG = os.path.expanduser("~/.config/keyd/app.conf")
PIDFILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}",
                       "mac-app-keys.pid")


def log(message):
    print(f"mac-app-keys: {message}", file=sys.stderr, flush=True)


def normalize_class(wm_class):
    """The section names app.conf uses: 'Xfce4-terminal' -> 'xfce4-terminal'."""
    return re.sub(r"[^A-Za-z0-9]+", "-", wm_class).strip("-").lower()


def parse_config(text):
    """([(class pattern, [bindings])] in file order, [problems]). A
    [class|title] section is skipped: matching titles would mean reacting to
    every title change, which is what made keyd's own mapper fall behind."""
    sections, problems, current, skipping = [], [], None, False
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            name = line[1:-1].strip()
            skipping = "|" in name
            if skipping:
                problems.append(f"line {n}: [{name}] matches a window title, which isn't supported; skipped")
                current = None
            else:
                current = []
                sections.append((name, current))
        elif current is not None:
            current.append(line)
        elif not skipping:
            problems.append(f"line {n}: binding outside a section; skipped")
    return sections, problems


def bindings_for(sections, app_class):
    """Every matching section's bindings, in file order."""
    found = []
    for pattern, bindings in sections:
        if fnmatch.fnmatchcase(app_class, pattern):
            found.extend(bindings)
    return found


class Config:
    """app.conf, read again whenever the file changes."""

    def __init__(self, path):
        self.path, self.stamp, self.sections = path, None, []

    def current(self):
        try:
            st = os.stat(self.path)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError:
            stamp = None
        if stamp != self.stamp:
            self.stamp = stamp
            self.sections = []
            if stamp is None:
                log(f"{self.path} not found: no per-app keys")
            else:
                with open(self.path, encoding="utf-8") as f:
                    self.sections, problems = parse_config(f.read())
                for p in problems:
                    log(f"{self.path}: {p}")
        return self.sections


class Keyd:
    """Applies bindings with `keyd bind`, skipping a call that would change
    nothing. A failed call is retried at the next chance."""

    def __init__(self, command):
        self.command, self.applied = command, None

    def apply(self, bindings, force=False):
        bindings = tuple(bindings)
        if bindings == self.applied and not force:
            return True
        try:
            result = subprocess.run([*self.command, "bind", "reset", *bindings],
                                    capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as err:
            log(f"keyd bind: {err}")
            self.applied = None
            return False
        if result.returncode != 0:
            log(f"keyd bind: {(result.stderr or result.stdout).strip()}")
            self.applied = None
            return False
        self.applied = bindings
        return True


def keyd_command():
    """Debian names the binary keyd.rvaiya (keyd clashes with another package)."""
    for name in ("keyd.rvaiya", "keyd"):
        path = shutil.which(name)
        if path:
            return [path]
    return None


def take_lock(path):
    """The pid file, locked for as long as this process runs; None when
    another instance holds it."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode())
    return fd


def run():
    from Xlib import X, Xatom, display, error

    command = keyd_command()
    if command is None:
        log("keyd is not installed")
        return 1
    if take_lock(PIDFILE) is None:
        log("already running")
        return 0
    dpy = display.Display()
    dpy.set_error_handler(lambda err, request: None)  # a window can vanish mid-query
    root = dpy.screen().root
    active = dpy.intern_atom("_NET_ACTIVE_WINDOW")
    root.change_attributes(event_mask=X.PropertyChangeMask)

    def front_class():
        try:
            prop = root.get_full_property(active, Xatom.WINDOW)
            if not prop or not prop.value or not prop.value[0]:
                return ""
            wm_class = dpy.create_resource_object("window", prop.value[0]).get_wm_class()
        except error.XError:
            return ""
        return normalize_class(wm_class[1]) if wm_class else ""

    config, keyd = Config(CONFIG), Keyd(command)
    wake_r, wake_w = os.pipe()
    signal.signal(signal.SIGUSR1, lambda *_: os.write(wake_w, b"u"))
    signal.signal(signal.SIGTERM, lambda *_: os.write(wake_w, b"t"))
    signal.signal(signal.SIGINT, lambda *_: os.write(wake_w, b"t"))

    changed, force = True, True
    while True:
        # Drain everything queued, then update once: a burst of focus
        # changes costs one keyd call, not one per event.
        while dpy.pending_events():
            event = dpy.next_event()
            if event.type == X.PropertyNotify and event.atom == active:
                changed = True
        if changed or force:
            keyd.apply(bindings_for(config.current(), front_class()), force)
            changed = force = False
        if dpy.pending_events():
            continue  # arrived while asking X for the class
        ready, _, _ = select.select([dpy.fileno(), wake_r], [], [])
        if wake_r in ready:
            signals = os.read(wake_r, 64)
            if b"t" in signals:
                keyd.apply([])  # leave no app's keys behind
                return 0
            force = b"u" in signals


def main(argv):
    if len(argv) == 3 and argv[1] == "--show":
        with open(CONFIG, encoding="utf-8") as f:
            sections, problems = parse_config(f.read())
        for p in problems:
            log(p)
        print("\n".join(bindings_for(sections, argv[2])))
        return 0
    if len(argv) == 1:
        return run()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
MACAPPKEYS
sudo chmod 755 "$MAC_APP_KEYS"

# Retire what earlier versions installed for keyd's mapper: the script (only
# while it is the exact v2.5.0 file they downloaded), its keyd name shim and
# its login entry. A copy of it still running would fight mac-app-keys.
KAM_BIN="/usr/local/bin/keyd-application-mapper"
KAM_SHA256="147778345f1fa65fb2f10992520ab4aa74be1b0fc8aa50d0282acca76e690b16"
if [ -f "$KAM_BIN" ] && echo "$KAM_SHA256  $KAM_BIN" | sha256sum -c --status 2>/dev/null; then
    pkill -u "$USER" -x -f "/usr/bin/python3 $KAM_BIN -d" || true
    sudo rm -f "$KAM_BIN"
    rm -f "$ACTUAL_HOME/.config/keyd/app.lock" "$ACTUAL_HOME/.config/keyd/app.log"
    print_ok "Replaced keyd's per-app mapper with mac-app-keys"
fi
KAM_SHIM="/usr/local/lib/macbook-postinstall/bin/keyd"
if [ "$(readlink "$KAM_SHIM" 2>/dev/null)" = "/usr/bin/keyd.rvaiya" ]; then
    sudo rm -f "$KAM_SHIM"
    sudo rmdir --ignore-fail-on-non-empty "$(dirname "$KAM_SHIM")"
fi
KAM_AUTOSTART="$ACTUAL_HOME/.config/autostart/keyd-application-mapper.desktop"
if grep -q "(debian-intel-macbook-post-install)" "$KAM_AUTOSTART" 2>/dev/null; then
    rm -f "$KAM_AUTOSTART"
fi
# Its log and lock outlive it when an earlier version removed the script
# without them; nothing else uses these two files.
if [ ! -e "$KAM_BIN" ]; then
    rm -f "$ACTUAL_HOME/.config/keyd/app.lock" "$ACTUAL_HOME/.config/keyd/app.log"
fi

# The mapper talks to keyd over /var/run/keyd.socket, which belongs to the keyd
# group. That group can remap the keyboard, so treat it like sudo -- this user
# already is a sudoer, so it grants nothing new. Takes effect at next login.
if id -nG "$USER" | tr ' ' '\n' | grep -qx keyd; then
    print_skip "keyd group membership"
elif getent group keyd > /dev/null; then
    sudo usermod -aG keyd "$USER" && print_ok "Added $USER to the keyd group (active from next login)"
    REBOOT_REQUIRED=true
fi

# Terminal bindings. Rewritten only while it is still the file this script
# manages, so an app.conf you wrote yourself is never overwritten.
KAM_CONF="$ACTUAL_HOME/.config/keyd/app.conf"
KAM_MARKER="# Managed by debian-intel-macbook-post-install"
mkdir -p "$(dirname "$KAM_CONF")"
if [ -f "$KAM_CONF" ] && [[ "$(head -n 1 "$KAM_CONF")" != "$KAM_MARKER"* ]]; then
    print_warning "Your own .config/keyd/app.conf was found -- left as is (terminal Mac keys not added)"
else
    {
        # A Files key that types a folder's path into the location bar. keyd
        # types a macro's text as is, so a path with other characters is left
        # out rather than typed wrong.
        folder_key() {
            # C locale: elsewhere [A-Za-z] also matches letters like é
            local dir LC_ALL=C
            dir=$(xdg-user-dir "$2" 2>/dev/null)
            [ -n "$dir" ] || dir="$ACTUAL_HOME/$3"
            if [[ "$dir" =~ ^[A-Za-z0-9/._-]+$ ]]; then
                echo "$1 = macro(C-l 50ms $dir enter)"
            else
                echo "# $1: $dir has characters keyd can't type"
            fi
        }
        echo "$KAM_MARKER -- re-running setup.sh rewrites it."
        cat << APPCONF

[xfce4-terminal]
# Cmd+C/V copy and paste (plain Ctrl+C still interrupts), Cmd+T/N/W/Q/F tabs,
# windows and find
cmd.c = C-S-c
cmd.v = C-S-v
cmd.t = C-S-t
cmd.n = C-S-n
cmd.w = C-S-w
cmd.q = C-S-q
cmd.f = C-S-f
# Cmd+Backspace: delete to the start of the line, the shell way
cmd.backspace = C-u
# Cmd+Tab / Cmd+Shift+Tab need nothing here: the terminal's own next / previous
# tab keys are Ctrl+Tab / Ctrl+Shift+Tab (set below), what they send everywhere.
# Cmd+Shift+[ / ] and Cmd+Option+Left / Right: previous / next tab
cmd+shift.leftbrace = C-S-tab
cmd+shift.rightbrace = C-tab
cmd+option.left = C-S-tab
cmd+option.right = C-tab
# Option+Backspace: the shell's word delete. Option+arrows need no override: the
# Ctrl+arrows they send are word moves in Debian's /etc/inputrc, while Alt+F
# (the shell's other forward-word) opens the terminal's File menu.
option.backspace = A-backspace
# Option+Up/Down move by paragraph elsewhere; the shell has no paragraphs
option.up = noop
option.down = noop
# The control key reaches the shell unchanged, as in macOS Terminal
control.a = C-a
control.e = C-e
control.f = C-f
control.b = C-b
control.n = C-n
control.p = C-p
control.h = C-h
control.d = C-d
control.k = C-k
control.o = C-o
APPCONF
        cat << APPCONF

[thunar]
# Finder keys. Cmd+Backspace must move the selection to the Trash here: the
# global "delete to line start" (Shift+Home, Delete) would select every file
# from the cursor up to the first one and trash them all.
cmd.backspace = delete
cmd.up = A-up
cmd.down = enter
# Show / hide hidden files (Files' own key is Ctrl+H; Cmd+H hides the app)
cmd+shift.dot = C-h
cmd.i = A-enter
cmd.leftbrace = A-left
cmd.rightbrace = A-right
# Go to Folder, Home, sidebar, close all windows, make alias. The other Finder
# keys are Files' own actions, given Finder's keys in Thunar's accels.scm.
cmd+shift.g = C-l
cmd+shift.h = A-home
cmd+option.s = f9
cmd+option.w = C-S-w
control+cmd.a = C-A-a
# Connect to Server: the location bar takes sftp:// and smb:// addresses
cmd.k = C-l
# Add to the sidebar
control+cmd.t = C-A-b
# Downloads / Documents: typed into the location bar
$(folder_key cmd+option.l DOWNLOAD Downloads)
$(folder_key cmd+shift.o DOCUMENTS Documents)

[libreoffice*]
# Spelling and grammar, and alignment (Cmd+{ and Cmd+} are tabs elsewhere)
cmd+shift.semicolon = f7
cmd.semicolon = f7
cmd+shift.leftbrace = C-l
cmd+shift.rightbrace = C-r
cmd+shift.backslash = C-e

[chromium]
# Back / forward
cmd.leftbrace = A-left
cmd.rightbrace = A-right

[firefox*]
cmd.leftbrace = A-left
cmd.rightbrace = A-right
APPCONF
    } > "$KAM_CONF"
    print_ok "Terminal Mac keys written to ~/.config/keyd/app.conf"
fi

# Give GTK app actions keys in an accels.scm file, one "action|accel" line each
# on stdin. Cmd sends Ctrl, so <Primary> is Cmd. Only these actions' lines are
# replaced; anything else in the file is kept. Apps read it when they start.
set_gtk_accels() {
    local file=$1 action accel
    mkdir -p "$(dirname "$file")"
    touch "$file"
    while IFS='|' read -r action accel; do
        sed -i "\\|\"<Actions>/$action\"|d" "$file"
        printf '(gtk_accel_path "<Actions>/%s" "%s")\n' "$action" "$accel" >> "$file"
    done
}

# Finder keys in Files (Thunar): give Thunar's actions the keys Finder uses.
set_gtk_accels "$ACTUAL_HOME/.config/Thunar/accels.scm" << 'ACCELS'
ThunarStandardView/duplicate|<Primary>d
ThunarShortcutsPane/sendto-shortcuts|<Primary><Alt>b
ThunarWindow/open-desktop|<Primary><Shift>d
ThunarWindow/open-computer|<Primary><Shift>c
ThunarWindow/open-network|<Primary><Shift>k
ThunarWindow/open-recent|<Primary><Shift>f
ThunarWindow/empty-trash|<Primary><Shift>BackSpace
ThunarWindow/view-statusbar|<Primary>slash
ThunarStandardView/make-link|<Primary><Alt>a
ACCELS
print_ok "Finder keys set in Files (from the next time it opens)"

# The terminal's next / previous tab on Ctrl+Tab / Ctrl+Shift+Tab, which Cmd+Tab
# and Cmd+Shift+Tab send everywhere: tabs switch without the per-app keys. GTK
# sees Shift+Tab as ISO_Left_Tab, so "<Shift>Tab" would never match. The
# terminal reads this when it starts (once every terminal window is closed).
set_gtk_accels "$ACTUAL_HOME/.config/xfce4/terminal/accels.scm" << 'TERMINAL_ACCELS'
terminal-window/next-tab|<Primary>Tab
terminal-window/prev-tab|<Primary><Shift>ISO_Left_Tab
TERMINAL_ACCELS
print_ok "Terminal tabs on Cmd+Tab / Cmd+Shift+Tab (once every terminal window has been closed)"

# mac-app-keys runs as a systemd user service, so a crash is restarted rather
# than leaving Cmd+C sending Ctrl+C in the terminal until the next login. XFCE
# 4.20 never starts graphical-session.target, so the login entry starts the
# service instead of the target pulling it in. At log-out the X connection
# closes and the helper exits with an error; the start limit stops the retries
# against the dead display, and the next login clears it with reset-failed.
APP_KEYS_UNIT="$ACTUAL_HOME/.config/systemd/user/mac-app-keys.service"
mkdir -p "$(dirname "$APP_KEYS_UNIT")"
cat > "$APP_KEYS_UNIT" << APP_KEYS_SERVICE
# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.
[Unit]
Description=Per-app Mac keys
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=$MAC_APP_KEYS
Restart=on-failure
RestartSec=2
APP_KEYS_SERVICE

mkdir -p "$ACTUAL_HOME/.config/autostart"
cat > "$ACTUAL_HOME/.config/autostart/mac-app-keys.desktop" << APP_KEYS_AUTOSTART
[Desktop Entry]
Type=Application
Name=Per-app Mac keys
Comment=Switches Mac keys for the app in front (debian-intel-macbook-post-install)
Exec=sh -c 'systemctl --user reset-failed mac-app-keys.service; systemctl --user restart mac-app-keys.service'
NoDisplay=true
X-GNOME-Autostart-enabled=true
APP_KEYS_AUTOSTART

# Restart it now, so this run's helper and app.conf are what's in use and the
# keys keyd forgot when it restarted above come back. A copy started by an
# earlier version's login entry runs outside the service, so it is stopped
# through its pid file, checked against the process's command line first.
APP_KEYS_PIDFILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mac-app-keys.pid"
APP_KEYS_PID=$(cat "$APP_KEYS_PIDFILE" 2>/dev/null || true)
if [[ "$APP_KEYS_PID" =~ ^[0-9]+$ ]] \
    && [ "$(tr '\0' ' ' < "/proc/$APP_KEYS_PID/cmdline" 2>/dev/null)" = "/usr/bin/python3 $MAC_APP_KEYS " ]; then
    kill "$APP_KEYS_PID"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -d "/proc/$APP_KEYS_PID" ] || break
        sleep 0.2
    done
fi
if [ -n "${DISPLAY:-}" ] && systemctl --user daemon-reload 2>>"$LOG_FILE"; then
    systemctl --user reset-failed mac-app-keys.service 2>/dev/null || true
    if systemctl --user restart mac-app-keys.service >>"$LOG_FILE" 2>&1; then
        print_ok "Per-app keys running (and started at each login)"
    else
        print_warning "Per-app keys didn't start -- see: systemctl --user status mac-app-keys"
    fi
else
    print_info "Per-app keys start at your next login"
fi

echo -e "\n  ${CYAN}Key mappings applied (full list: KEYBOARD SHORTCUTS.txt):${NC}"
echo -e "  • Keys work as on macOS Monterey: Cmd+C, Cmd+V, Cmd+Q, Cmd+H, Cmd+Space, ..."
echo -e "  • Except Tab: Cmd+Tab = next tab, Option+Tab = switch apps"
echo -e "  • Cmd+Left/Right line start/end, Option+Left/Right jump a word"
echo -e "  • Ctrl+Up Mission Control, Ctrl+Left/Right switch desktops"
echo -e "  • Cmd+Shift+3 / 4 take screenshots; Ctrl+Cmd+Q locks the screen"
echo -e "  • In the terminal, Cmd+C / Cmd+V copy and paste (Ctrl+C still stops a program)\n"

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
[ "$1" = "post" ] || exit 0
sleep 2
XUSER=$(who | awk '/:0/{print $1; exit}')
[ -z "$XUSER" ] && exit 0
XAUTH="/home/$XUSER/.Xauthority"
su "$XUSER" -c "DISPLAY=:0 XAUTHORITY=$XAUTH xinput enable bcm5974" 2>/dev/null || true
EOF
sudo chmod +x /etc/systemd/system-sleep/touchpad-resume
print_ok "Trackpad will re-enable automatically after lid-open/resume"

# Trackpad feel, as on a Mac: natural scrolling, two-finger click for a right
# click, no stray clicks while typing -- plus tap-to-click. These are defaults:
# Settings > Mouse and Touchpad still changes them per user. A later-numbered
# file in xorg.conf.d (your own, say) overrides any of these options.
TOUCHPAD_CONF="/etc/X11/xorg.conf.d/30-macbook-postinstall-touchpad.conf"
TOUCHPAD_CONTENT='# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.
Section "InputClass"
    Identifier "macbook-postinstall touchpad"
    MatchIsTouchpad "on"
    Driver "libinput"
    Option "NaturalScrolling" "on"
    Option "ClickMethod" "clickfinger"
    Option "DisableWhileTyping" "on"
    Option "Tapping" "on"
EndSection'
if [ "$(cat "$TOUCHPAD_CONF" 2>/dev/null)" = "$TOUCHPAD_CONTENT" ]; then
    print_skip "Trackpad settings"
else
    sudo mkdir -p /etc/X11/xorg.conf.d
    printf '%s\n' "$TOUCHPAD_CONTENT" | sudo tee "$TOUCHPAD_CONF" > /dev/null
    print_ok "Trackpad: natural scrolling, two-finger right click, tap to click (after reboot)"
    REBOOT_REQUIRED=true
fi

# ─────────────────────────────────────────────
# WEBCAM AND MICROPHONE
# ─────────────────────────────────────────────
print_header "Webcam and Microphone"
echo -e "  ${CYAN}The MacBook FaceTime HD camera needs a custom driver — installing now.${NC}\n"

install_pkgs "Build tools for webcam driver" git curl cpio make build-essential dkms alsa-utils

KERNEL_VERSION=$(uname -r)
if ! is_installed "linux-headers-$KERNEL_VERSION"; then
    print_info "Installing kernel headers for $KERNEL_VERSION..."
    if sudo apt install -y "linux-headers-$KERNEL_VERSION" >>"$LOG_FILE" 2>&1; then
        # apt install marks the package manual, and versioned headers depend on
        # their exact kernel image, which would pin this kernel forever. Marked
        # auto, apt's versioned-kernel protection still keeps them while this
        # kernel is running or among the newest, and autoremove clears them
        # along with the kernel once it is superseded.
        sudo apt-mark auto "linux-headers-$KERNEL_VERSION" >>"$LOG_FILE" 2>&1 || true
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

# A reverse-engineered driver is the kind of thing you want to verify works
# before trusting it in an actual video call. cheese gives an immediate,
# obvious "yes, the camera and mic work" check without needing Zoom or Teams.
install_pkg "cheese" "Cheese (webcam test app)"

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

# keyboard backlight (SMC-controlled peripheral layer)
# The keyboard backlight is driven by applesmc on a separate power rail from
# the display panel (intel_backlight). s2idle -- forced above because deep/S3
# never resumes on this hardware -- keeps far more of the system powered than
# a real S3 sleep would have, and this LED is one of the things that stays lit
# as a result: nothing tells it to turn off. Install a sleep hook that forces
# it to 0 before suspend and restores whatever level was set beforehand, on
# resume.
print_info "Installing keyboard backlight suspend hook..."
sudo mkdir -p /etc/systemd/system-sleep
sudo tee /etc/systemd/system-sleep/kbd-backlight-suspend > /dev/null << 'EOF'
#!/bin/sh
# Force the SMC keyboard backlight off before suspend and restore it after.
# s2idle (see setup.sh) does not power this LED down on its own, so without
# this it stays lit for the entire time the lid is closed.
LED=/sys/class/leds/smc::kbd_backlight/brightness
STATE=/run/kbd-backlight-suspend.state
[ -e "$LED" ] || exit 0
case "$1" in
    pre)
        cat "$LED" > "$STATE" 2>/dev/null
        echo 0 > "$LED"
        ;;
    post)
        [ -f "$STATE" ] && cat "$STATE" > "$LED" 2>/dev/null
        rm -f "$STATE"
        ;;
esac
EOF
sudo chmod +x /etc/systemd/system-sleep/kbd-backlight-suspend
print_ok "Keyboard backlight will turn off during suspend and restore on resume"

# The keyboard backlight also stays lit while the display is off, since nothing
# ties the two together. On a Mac it goes dark with the display. A small
# watcher started with the desktop reads the panel's power state from the
# kernel (DRM), which is true whichever display server drives the screen, the
# lock screen's included, and switches the light through UPower: UPower puts no
# authorization on the keyboard light, so this works without root, extra
# groups, or an active session.
KBD_WATCH="/usr/local/bin/kbd-backlight-follow-display"
if compgen -G "/sys/class/leds/*kbd_backlight" > /dev/null; then
    install_pkg "libglib2.0-bin" "gdbus (lets the keyboard light follow the display)" || true
    sudo tee "$KBD_WATCH" > /dev/null << 'KBDWATCH'
#!/usr/bin/python3
"""Turn the keyboard backlight off while the display is off, and restore it
when the display wakes. Installed and started at login by
debian-intel-macbook-post-install; exits when its login session ends."""
import glob
import os
import re
import signal
import subprocess
import sys
import time

POLL_SECONDS = 2
DRM_DIR = "/sys/class/drm"
SESSIONS_DIR = "/run/systemd/sessions"
UPOWER = ["gdbus", "call", "--system", "--dest", "org.freedesktop.UPower",
          "--object-path", "/org/freedesktop/UPower/KbdBacklight", "--method"]
IFACE = "org.freedesktop.UPower.KbdBacklight."


def decide(display_on, brightness, saved):
    """One poll. saved is the level to restore, or None when this watcher
    hasn't dimmed the light. Returns (level to set or None, new saved)."""
    if not display_on:
        if saved is None and brightness > 0:
            return 0, brightness
        return None, saved
    if saved is not None:
        # Restore only if the light is still off: a level set meanwhile wins.
        return (saved if brightness == 0 else None), None
    return None, None


def display_is_on(drm_dir=DRM_DIR):
    """True while any enabled display output is powered, per the kernel. With
    no readable output, assume on: never dim on a guess."""
    states = []
    for output in glob.glob(os.path.join(drm_dir, "card*-*")):
        try:
            with open(os.path.join(output, "enabled")) as f:
                enabled = f.read().strip()
            with open(os.path.join(output, "dpms")) as f:
                dpms = f.read().strip()
        except OSError:
            continue
        if enabled == "enabled":
            states.append(dpms)
    return not states or "On" in states


def session_alive(session_id, sessions_dir=SESSIONS_DIR):
    """False once logind has closed (or is closing) the session."""
    try:
        with open(os.path.join(sessions_dir, session_id)) as f:
            return "STATE=closing" not in f.read().split("\n")
    except OSError:
        return False


def upower(method, *args):
    out = subprocess.run(UPOWER + [IFACE + method, *map(str, args)],
                         capture_output=True, text=True, check=True).stdout
    numbers = re.findall(r"-?\d+", out)
    return int(numbers[0]) if numbers else None


def main():
    session = os.environ.get("XDG_SESSION_ID", "")
    try:
        upower("GetMaxBrightness")
    except (subprocess.CalledProcessError, OSError) as err:
        print(f"kbd-backlight-follow-display: no keyboard backlight: {err}", file=sys.stderr)
        return 0
    saved = None

    def restore_and_exit(*_):
        if saved is not None and upower("GetBrightness") == 0:
            upower("SetBrightness", saved)
        sys.exit(0)

    signal.signal(signal.SIGTERM, restore_and_exit)
    signal.signal(signal.SIGINT, restore_and_exit)
    while not session or session_alive(session):
        try:
            level, saved = decide(display_is_on(), upower("GetBrightness"), saved)
            if level is not None:
                upower("SetBrightness", level)
        except (subprocess.CalledProcessError, OSError):
            pass  # UPower briefly unavailable; try again next poll
        time.sleep(POLL_SECONDS)
    restore_and_exit()


if __name__ == "__main__":
    sys.exit(main())
KBDWATCH
    sudo chmod 755 "$KBD_WATCH"
    mkdir -p "$ACTUAL_HOME/.config/autostart"
    cat > "$ACTUAL_HOME/.config/autostart/kbd-backlight-follow-display.desktop" << KBD_AUTOSTART
[Desktop Entry]
Type=Application
Name=Keyboard light follows display
Comment=Turns the keyboard backlight off while the display is off (debian-intel-macbook-post-install)
Exec=$KBD_WATCH
NoDisplay=true
X-GNOME-Autostart-enabled=true
KBD_AUTOSTART
    print_ok "Keyboard backlight will turn off with the display (from your next login)"
fi

# The lock screen (lightdm-gtk-greeter) only blanks the display: black, but the
# panel stays powered, so the keyboard watcher can't tell and the screen keeps
# drawing power. LightDM runs greeter-setup-script as root on each lock and
# login screen's display before the greeter starts; use it to power the
# display off after a minute without input, as a Mac does at the lock screen.
# LightDM reads its config when it starts, so this applies from the next boot.
if is_installed lightdm; then
    install_pkg "x11-xserver-utils" "xset (display power control)" || true
    GREETER_SCRIPT="/usr/local/lib/macbook-postinstall/greeter-display-sleep"
    GREETER_SCRIPT_CONTENT='#!/bin/sh
# Managed by debian-intel-macbook-post-install. Run by LightDM as root on the
# greeter display (greeter-setup-script): power the display off after a minute
# without input. Always exits 0, so it can never keep the greeter from starting.
xset +dpms dpms 60 60 60 2>/dev/null
exit 0'
    LIGHTDM_CONF="/etc/lightdm/lightdm.conf.d/50-macbook-postinstall.conf"
    LIGHTDM_CONTENT="# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.
[Seat:*]
greeter-setup-script=$GREETER_SCRIPT"
    if [ "$(cat "$GREETER_SCRIPT" 2>/dev/null)" = "$GREETER_SCRIPT_CONTENT" ] \
        && [ "$(cat "$LIGHTDM_CONF" 2>/dev/null)" = "$LIGHTDM_CONTENT" ]; then
        print_skip "Lock screen display sleep"
    else
        sudo mkdir -p "$(dirname "$GREETER_SCRIPT")" "$(dirname "$LIGHTDM_CONF")"
        printf '%s\n' "$GREETER_SCRIPT_CONTENT" | sudo tee "$GREETER_SCRIPT" > /dev/null
        sudo chmod 755 "$GREETER_SCRIPT"
        printf '%s\n' "$LIGHTDM_CONTENT" | sudo tee "$LIGHTDM_CONF" > /dev/null
        # Another config file that LightDM reads later could override this:
        # check what LightDM itself will use (it prints the config to stderr).
        if /usr/sbin/lightdm --show-config 2>&1 | grep -q "greeter-setup-script=$GREETER_SCRIPT\$"; then
            print_ok "Lock screen turns the display off after a minute idle (after reboot)"
            REBOOT_REQUIRED=true
        else
            print_warning "LightDM isn't using $LIGHTDM_CONF (another greeter-setup-script overrides it) -- lock screen display sleep not set"
        fi
    fi
fi

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

# Prints the package's xfce4-terminal launcher with its English name changed
# from "Xfce Terminal" to "Terminal", as on a Mac. Built from the package's
# own file every run, so the copy follows package updates.
terminal_launcher() {
    sed -e '1a # Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.' \
        -e 's/^\(Name\(\[en_[A-Z][A-Z]\]\)\{0,1\}\)=Xfce Terminal$/\1=Terminal/' "$1"
}
TERMINAL_LAUNCHER="$ACTUAL_HOME/.local/share/applications/xfce4-terminal.desktop"
if [ ! -f /usr/share/applications/xfce4-terminal.desktop ]; then
    print_skip "Terminal name (xfce4-terminal not installed)"
elif [ -f "$TERMINAL_LAUNCHER" ] && ! grep -q "debian-intel-macbook-post-install" "$TERMINAL_LAUNCHER"; then
    print_skip "Terminal name (you have your own $TERMINAL_LAUNCHER)"
else
    terminal_launcher /usr/share/applications/xfce4-terminal.desktop > "$TERMINAL_LAUNCHER"
    print_ok "The terminal is listed as Terminal in the menu and App Finder"
fi

# An App Finder left running (F4 keeps one in the background) still shows the
# launchers it read when it started, so the fixes above would not appear until
# the next login. Ask it to quit; the next F4 starts a fresh one. Its exit
# status is 1 whether or not it quit (4.20), so check the process instead.
if pgrep -u "$USER" -x xfce4-appfinder > /dev/null; then
    xfce4-appfinder --quit >>"$LOG_FILE" 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -u "$USER" -x xfce4-appfinder > /dev/null || break
        sleep 0.2
    done
    if pgrep -u "$USER" -x xfce4-appfinder > /dev/null; then
        print_warning "App Finder is still running; it shows the updated launchers after your next login"
    else
        print_ok "App Finder reloaded (the next F4 shows the updated launchers)"
    fi
fi

# ─────────────────────────────────────────────
# DESKTOP SHORTCUTS
# ─────────────────────────────────────────────
print_header "Desktop Shortcuts"
echo -e "  ${CYAN}Creating shortcuts on your Desktop so you can find everything easily.${NC}\n"

DESKTOP_DIR="$ACTUAL_HOME/Desktop"
mkdir -p "$DESKTOP_DIR"

# The everyday apps, the same ones themes.sh pins to the Dock. Developer and
# system tools (Terminal, VS Code, Task Manager, ...) are in the App Finder.
create_shortcut "Files" "thunar" "file-manager"
create_shortcut "App Finder" "xfce4-appfinder" "org.xfce.appfinder"
create_shortcut "Chromium" "chromium" "chromium"
create_shortcut "Text Editor" "mousepad" "org.xfce.mousepad"
create_shortcut "LibreOffice Writer" "libreoffice --writer" "libreoffice-writer"
create_shortcut "LibreOffice Calc" "libreoffice --calc" "libreoffice-calc"
create_shortcut "LibreOffice Impress" "libreoffice --impress" "libreoffice-impress"
create_shortcut "Images" "ristretto" "org.xfce.ristretto"
create_shortcut "VLC" "vlc" "vlc"
create_shortcut "Calculator" "galculator" "accessories-calculator"
create_shortcut "System Settings" "xfce4-settings-manager" "preferences-system"

# Shortcuts earlier versions created. Still in the app menu; no longer on the
# Desktop. Removed only while they are exactly what the script wrote. (Renamed
# targets like Terminal and Text Editor are rewritten by create_shortcut above.)
retire_shortcut "Simple Scan" "simple-scan"
retire_shortcut "Cheese" "cheese"
retire_shortcut "htop" "gnome-terminal -- htop"
retire_shortcut "Image Editor" "mtpaint"
retire_shortcut "Firefox" "firefox-esr"
retire_shortcut "Terminal" "xfce4-terminal"
retire_shortcut "VS Code" "code"
retire_shortcut "Screenshot" "flameshot gui"
retire_shortcut "Task Manager" "xfce4-taskmanager"
retire_shortcut "Bluetooth" "blueman-manager"
retire_shortcut "System Info" "xfce4-terminal --hold -x fastfetch"
retire_shortcut "System Info" "gnome-terminal -- fastfetch"

# Default apps: plain text opened in LibreOffice Writer and images in
# ImageMagick's bare viewer. Point them at the light XFCE apps, for every MIME
# type each one declares it handles -- unless the user already chose a default.
# Web pages open in Chromium: the MacBook camera works in Microsoft Teams there,
# not in Firefox (docs/teams-for-linux-camera.md).
print_info "Setting default apps for web pages, text files and images (where none is chosen yet)..."
set_default_app "chromium.desktop" x-scheme-handler/http x-scheme-handler/https text/html application/xhtml+xml
set_default_app "org.xfce.mousepad.desktop" text/plain
mapfile -t RISTRETTO_MIMES < <(sed -n 's/^MimeType=//p' /usr/share/applications/org.xfce.ristretto.desktop 2>/dev/null | tr ';' '\n' | grep -v '^$')
set_default_app "org.xfce.ristretto.desktop" "${RISTRETTO_MIMES[@]}"
print_ok "Default apps set"

# The two guides live in one place the app menu can always reach (Dock mode
# hides everything on the Desktop), and are copied to the Desktop for Classic
# mode. Both are rewritten on every run, so they always match this script.
GUIDE_DIR="$ACTUAL_HOME/.local/share/macbook-postinstall"
mkdir -p "$GUIDE_DIR" "$ACTUAL_HOME/.local/share/applications"

cat > "$GUIDE_DIR/KEYBOARD SHORTCUTS.txt" << 'SHORTCUTS'
═══════════════════════════════════════════════════════
  KEYBOARD SHORTCUTS — debian-intel-macbook-post-install
  Intel MacBooks · Debian 13 Trixie · XFCE
═══════════════════════════════════════════════════════

Keys work as on macOS Monterey, with one exception:
Cmd+Tab moves to the next tab and Option+Tab switches
apps. Any shortcut an app lists as Ctrl+<key> also
works as Cmd+<key>. Right Option is plain Alt.

───────────────────────────────────────────────────────
  GENERAL (works in most apps)
───────────────────────────────────────────────────────
  Cmd+C / Cmd+V      Copy / Paste
  Cmd+X              Cut
  Cmd+Z              Undo
  Cmd+A              Select all
  Cmd+S              Save
  Cmd+F              Find
  Cmd+W              Close tab or window
  Cmd+Q              Quit app
  Cmd+Tab            Next tab (Cmd+Shift+Tab: previous)
  Option+Tab         Switch apps (hold Option, tap Tab)
  Cmd+`              Switch windows of the same app
  Cmd+Shift+[ / ]    Previous / next tab
  Cmd+Option+Left / Right   Previous / next tab
  Cmd+[ / ]          Back / forward (browser, Files)
  Cmd+M              Minimize window
  Cmd+Space          Spotlight (app finder)
  Cmd+Option+T       New terminal window

───────────────────────────────────────────────────────
  TEXT EDITING
───────────────────────────────────────────────────────
  Cmd+Left / Right   Start / end of line
  Cmd+Up / Down      Start / end of document
  Option+Left/Right  Jump one word
  Cmd+Backspace      Delete to start of line
  Option+Backspace   Delete one word
  Cmd+Option+F       Find and replace
  Add Shift to any move to select as you go.
  The control key works as in macOS text fields:
  Ctrl+A / E line start / end, Ctrl+K cut to end of
  line, Ctrl+F / B / N / P move, Ctrl+H / D delete.

───────────────────────────────────────────────────────
  IN FILES (like Finder)
───────────────────────────────────────────────────────
  Cmd+Backspace      Move to Trash
  Cmd+Up / Down      Enclosing folder / open
  Cmd+I              Properties (Get Info)
  Cmd+D              Duplicate
  Cmd+Shift+D / H    Desktop / Home folder
  Cmd+Shift+G        Go to Folder
  Cmd+Shift+Delete   Empty Trash (asks first)
  Cmd+Shift+.        Show / hide hidden files

───────────────────────────────────────────────────────
  IN THE TERMINAL
───────────────────────────────────────────────────────
  Cmd+C / Cmd+V      Copy / Paste
  Ctrl+C             Stop the running program
  Cmd+T / Cmd+N      New tab / new window
  Cmd+W / Cmd+Q      Close tab / close window
  Option+Left/Right  Jump one word; Option+Backspace
                     deletes one, Cmd+Backspace the line
  (Takes effect after you log out and back in once.)

───────────────────────────────────────────────────────
  DESKTOP AND WINDOWS
───────────────────────────────────────────────────────
  Ctrl+Up or F3      Mission Control (all windows)
  Ctrl+Down          All windows of the front app
  Ctrl+Left / Right  Previous / next desktop
  Cmd+F3 or Fn+H     Show the desktop
  Cmd+H              Hide the front app
  Cmd+Option+H       Hide every other app
  Ctrl+Cmd+F         Full screen
  Drag to an edge    Snap the window to that half

───────────────────────────────────────────────────────
  MAC-STYLE FUNCTION KEYS
───────────────────────────────────────────────────────
  The top row works like on macOS. Hold Fn to get plain
  F1-F12 instead.

  F1 / F2            Screen brightness down / up
  F3                 Mission Control (Cmd+F3: show desktop)
  F4                 Open app finder (like Launchpad)
  F5 / F6            Keyboard backlight down / up
  F7 / F8 / F9       Previous track / Play-Pause / Next track
  F10                Mute / Unmute
  F11 / F12          Volume down / up

───────────────────────────────────────────────────────
  SCREENSHOTS
───────────────────────────────────────────────────────
  Cmd+Shift+3        Whole screen, saved to Pictures and
                     copied to the clipboard
  Cmd+Shift+4 or 5   Pick an area, annotate (Flameshot)
  Cmd+Option+S       The same (the key earlier versions used)

───────────────────────────────────────────────────────
  SYSTEM
───────────────────────────────────────────────────────
  Cmd+Option+Esc     Force quit (click the window)
  Ctrl+Cmd+Space     Emoji picker (also Fn+E)
  Cmd+Option+D       Dock auto-hide on / off
  Ctrl+Cmd+Q         Lock screen
  Shift+Cmd+Q        Log out (asks to confirm)

───────────────────────────────────────────────────────
  DESKTOP ICONS (first time only)
───────────────────────────────────────────────────────
  When clicking a desktop icon for the first time,
  XFCE will ask "Untrusted application launcher" —
  click Launch to confirm. It won't ask again.

═══════════════════════════════════════════════════════
SHORTCUTS

cat > "$GUIDE_DIR/GETTING STARTED.txt" << 'GUIDE'
═══════════════════════════════════════════════════════
  GETTING STARTED — debian-intel-macbook-post-install
  Intel MacBooks · Debian 13 Trixie · XFCE
═══════════════════════════════════════════════════════

  This file and KEYBOARD SHORTCUTS.txt are on your
  Desktop and in the app menu (Cmd+Space, then type
  "Getting Started" or "Keyboard Shortcuts").

───────────────────────────────────────────────────────
  FIRST THINGS TO CHECK
───────────────────────────────────────────────────────
  1. If the script said a reboot is needed, reboot.
  2. WiFi connects, and the webcam works (open Cheese).
  3. Keys work as on a Mac: Cmd+C / Cmd+V copy and
     paste, Cmd+Q quits an app. Cmd+Tab is next tab,
     Option+Tab switches apps.
  4. First click on a Desktop icon asks "Untrusted
     application launcher" -- click Launch, once.

───────────────────────────────────────────────────────
  EVERYDAY THINGS
───────────────────────────────────────────────────────
  Find an app        Cmd+Space or F4, then type its name
  Light or dark      Settings > Appearance (Style and
                     Icons) and Settings > Window Manager
  Default apps       Settings > Default Applications
                     (text opens in Mousepad, images in
                     Ristretto unless you chose otherwise)
  Remove an app      sudo apt remove <package>
  Updates            Security updates install themselves.
                     For everything else:
                     sudo apt update && sudo apt full-upgrade

───────────────────────────────────────────────────────
  RUNNING THE SCRIPTS AGAIN
───────────────────────────────────────────────────────
  Both scripts are safe to re-run: they skip what is
  already done and only redo what changed. Re-running
  the theming script resets the dock settings and the
  wallpaper colour; your own Desktop launchers and the
  apps you pinned to the dock stay.

───────────────────────────────────────────────────────
  IF SOMETHING GOES WRONG
───────────────────────────────────────────────────────
  Undo the whole setup run (snapshot taken before it
  changed anything):
      sudo timeshift --restore

  The full log of the last run:
      ~/.local/state/macbook-postinstall/latest.log

  Everything else, including known problems and fixes:
      github.com/willardcsoriano/debian-intel-macbook-post-install

═══════════════════════════════════════════════════════
GUIDE

# Menu entries open the master copies with the default text editor.
make_guide_entry() {
    local id=$1 name=$2 file=$3
    cat > "$ACTUAL_HOME/.local/share/applications/${id}.desktop" << GUIDE_ENTRY
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Comment=debian-intel-macbook-post-install guide
Exec=xdg-open "$GUIDE_DIR/$file"
Icon=help-contents
Terminal=false
Categories=Utility;Documentation;
GUIDE_ENTRY
}
make_guide_entry "macbook-postinstall-getting-started" "Getting Started" "GETTING STARTED.txt"
make_guide_entry "macbook-postinstall-keyboard-shortcuts" "Keyboard Shortcuts" "KEYBOARD SHORTCUTS.txt"

cp "$GUIDE_DIR/GETTING STARTED.txt" "$GUIDE_DIR/KEYBOARD SHORTCUTS.txt" "$ACTUAL_HOME/Desktop/"
print_ok "Getting Started guide and keyboard shortcuts saved to Desktop and the app menu"

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
if is_installed xfce4-docklike-plugin; then
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
if [ "$LOG_DIR" != "/tmp" ]; then
    echo -e "${CYAN}  Latest run always at: $LOG_DIR/latest.log${NC}"
fi

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
echo -e "  ${CYAN}All your desktop shortcuts are ready on the Desktop.${NC}"
echo -e "  ${CYAN}If anything looks wrong, undo this entire run with: sudo timeshift --restore${NC}\n"

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
