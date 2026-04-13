# debian-macbook-post-install

A single-command post-installation setup script for Intel MacBooks running
Debian GNU/Linux 13 (Trixie). This script picks up where a fresh minimal
Debian install leaves off — no GUI, no quality-of-life tooling, just a
working terminal with internet access.

---

## Who this is for

This script is for users who have:

1. Installed Debian GNU/Linux 13 (Trixie) on an Intel MacBook (tested on
   MacBook Air 7,2 — 2015 13-inch)
2. Successfully set up Broadcom WiFi drivers (see prerequisite repo below)
3. Connected to the internet manually via wpa_supplicant and dhcpcd
4. Booted into a terminal with no graphical interface

If you have not yet gotten WiFi working, see this repo first:
https://github.com/willardcsoriano/debian-trixie-macbook-broadcom-offline

---

## What this script installs

### Graphical Interface
- xorg — display server
- xfce4 + xfce4-goodies — lightweight desktop environment

### Terminal
- gnome-terminal — a modern terminal with proper copy-paste, mouse support,
  and a menubar. Replaces the default xterm which lacks these features.

### Browser
- firefox — web browser

### Keyboard (Mac-specific fixes)
- keyd — kernel-level key remapping daemon
- Full keyd configuration covering:
  - Command key remapped to Ctrl (preserves Mac muscle memory)
  - Cmd+Left/Right jumps to start/end of line
  - Cmd+Up/Down jumps to start/end of document
  - Cmd+Shift+Left/Right/Up/Down selects to start/end of line/document
  - Cmd+Delete deletes entire line to the left of cursor
  - Cmd+Space opens the XFCE application finder
  - F1/F2 brightness down/up
  - F7/F8/F9 previous track/play-pause/next track
  - F10 mute toggle
  - F11/F12 volume down/up
  - Keyboard backlight up/down

### Brightness and Media
- brightnessctl — controls screen brightness and keyboard backlight
- playerctl — controls media playback (Spotify, VLC, browsers, etc.)
- pulseaudio-utils — controls system volume

### WiFi Management
- network-manager + network-manager-gnome — replaces the manual
  wpa_supplicant + dhcpcd workflow with a GUI tray applet that
  auto-connects to known networks on boot

### Battery
- xfce4-battery-plugin — shows battery level in the taskbar panel

### Power Management
- xfce4-power-manager — handles lid close, sleep, suspend, and
  screen dimming on idle

### Task Managers
- xfce4-taskmanager — GUI task manager similar to Activity Monitor on macOS,
  shows CPU and RAM usage per process
- htop — terminal-based process viewer, more detailed and beloved by
  Linux users

### Fonts
- fonts-liberation — metric-compatible replacements for Arial, Times New
  Roman, and Courier New
- fonts-noto — extensive Unicode font family covering most scripts
- fonts-dejavu — clean, readable fonts for UI and terminal use

---

## Prerequisites

### 1. Working internet connection

You should already have this if you followed the Broadcom offline repo.
Confirm with:

    ping -c 3 google.com

### 2. Set up sudo for your user

Debian does not configure sudo for regular users by default. You need to
do this once before running the script.

Switch to root:

    su -

Add your user to the sudo group (replace "yourusername" with your actual
username):

    usermod -aG sudo yourusername

Exit root:

    exit

Log out and log back in for the change to take effect. Confirm sudo works:

    sudo echo "sudo is working"

---

## Installation

Once prerequisites are complete, run this single command in your terminal:

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-macbook-post-install/main/setup.sh)

The script will print progress as it runs. Do not close the terminal.
When finished, it will prompt you to reboot.

---

## After reboot

Once you boot into XFCE, two things need to be added to your taskbar
panel manually:

### Add WiFi applet to panel
Right-click the taskbar > Panel > Add New Items > search for
"Network Manager" > Add

### Add battery indicator to panel
Right-click the taskbar > Panel > Add New Items > search for
"Battery Monitor" > Add

These are one-time steps. After this everything runs automatically.

---

## Tested on

- MacBook Air 7,2 (2015, 13-inch)
- Debian GNU/Linux 13 (Trixie) 13.4
- Fresh minimal install with no desktop environment

This script should work on most Intel MacBooks from 2012-2017 running
Debian Trixie. If you encounter issues on a different model, please open
an issue and include your MacBook model (run: sudo dmidecode -s
system-product-name) and the error output.

---

## Related

- Broadcom offline driver installer (run this first):
  https://github.com/willardcsoriano/debian-trixie-macbook-broadcom-offline

---

## Contributing

Pull requests welcome. If you have a different Intel MacBook model and
can confirm this works (or doesn't), please open an issue so the tested
hardware list can be updated.

---

## License

MIT
