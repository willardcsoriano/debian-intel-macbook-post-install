# Debian Linux Post-Installation Setup for Intel MacBooks

## Overview

A one-command post-installation setup for Intel MacBooks (2012–2019 models)
running Debian GNU/Linux 13 (Trixie). It picks up where the Broadcom offline
WiFi install leaves off — a bare terminal — and turns the machine into a
daily-usable laptop: an XFCE desktop, automatic security updates, a hardened
Broadcom WiFi rebuild chain, NetworkManager, macOS-style keyboard remapping via
keyd, working suspend/resume (s2idle plus lid suspend-then-hibernate), a bcm5974
touchpad resume fix, the reverse-engineered FaceTime HD webcam and microphone
drivers, and a curated set of everyday applications. An optional theming script
gives XFCE a macOS-style look — the WhiteSur dark theme and a Plank dock — with
Classic, Dock, and Revert modes. Both scripts are idempotent and safe to re-run.
Apple Silicon Macs are not supported; use the Asahi Linux project instead.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [⚠️ Compatibility Notice](#-compatibility-notice)
- [The Story So Far](#the-story-so-far)
- [Why Debian on an Intel MacBook](#why-debian-on-an-intel-macbook)
- [Who This Is For](#who-this-is-for)
- [What This Script Installs and Configures](#what-this-script-installs-and-configures)
  - [Automatic Security Updates](#automatic-security-updates)
  - [System Upgrade (optional)](#system-upgrade-optional)
  - [Desktop Environment](#desktop-environment)
  - [Terminal](#terminal)
  - [Browser and Core Apps](#browser-and-core-apps)
  - [Code Editor](#code-editor)
  - [Media and Utilities](#media-and-utilities)
  - [WiFi Management](#wifi-management)
  - [MacBook Keyboard Fixes](#macbook-keyboard-fixes)
  - [MacBook Touchpad Resume Fix](#macbook-touchpad-resume-fix)
  - [Webcam and Microphone](#webcam-and-microphone)
  - [Battery and Power](#battery-and-power)
  - [System Monitoring](#system-monitoring)
  - [Fonts](#fonts)
  - [App Finder Launcher Fix](#app-finder-launcher-fix)
  - [Desktop Shortcuts](#desktop-shortcuts)
  - [Keyboard Shortcuts Cheat Sheet](#keyboard-shortcuts-cheat-sheet)
- [Prerequisites](#prerequisites)
  - [1. Working internet connection](#1-working-internet-connection)
  - [2. Set up sudo for your user](#2-set-up-sudo-for-your-user)
- [Installation](#installation)
- [Theming (optional)](#theming-optional)
- [Microsoft Teams (optional)](#microsoft-teams-optional)
- [Verified Test Environment](#verified-test-environment)
- [Known Limitations](#known-limitations)
- [Related](#related)
- [Version History](#version-history)
- [Contributing](#contributing)
- [License](#license)

## Quick Start

> Make sure you have read [Prerequisites](#prerequisites) first — sudo
> must be configured and you need a working internet connection.

**Setup script** (required):

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.7.7/setup.sh)

**Theming script** (optional, run after first reboot):

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.7.7/themes.sh)

**Microsoft Teams script** (optional, for users who need Teams):

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.8.0/teams.sh)

---

## ⚠️ Compatibility Notice

**This script is for Intel MacBooks only.**

Apple Silicon Macs (M1, M2, M3, M4 — released 2020 onwards) use ARM
architecture and are not supported. Apple Silicon Linux support is handled
by the separate Asahi Linux project.

**This script targets Debian GNU/Linux 13 (Trixie) only.**

Ubuntu and Linux Mint are not tested and not officially supported. Most
apt-based steps will likely work, but keyd availability varies by Ubuntu
version and may require a PPA. The facetimehd driver is built from upstream
source via DKMS and generally tracks current kernels, but kernel API changes
have broken it before (notably Trixie's 6.12 kernel, which dropped the
`videobuf-dma-sg.h` header) — it relies on the latest upstream master carrying
the fix, which it currently does.
If you test this on Ubuntu or Mint, open an issue with your results.

Tested on MacBook Air 7,2 (2015, 13-inch). Should work on most Intel
MacBooks from 2012–2019 running Debian 13 Trixie.

---

## The Story So Far

If you just came from the [Broadcom offline repo](https://github.com/willardcsoriano/debian-intel-macbook-broadcom-offline), you have accomplished something genuinely difficult — you installed Linux on a MacBook with no internet access and got WiFi working entirely from a USB stick. That is not a beginner task and you should feel good about it.

But right now you are staring at a terminal. No desktop, no browser, no
way to adjust brightness, no GUI tools, no keyboard shortcuts that feel
familiar coming from macOS. The Cmd key does nothing useful. The function
keys do nothing. The FaceTime camera does not work. The mic may not work.

This script fixes all of that in one command.

---

## Why Debian on an Intel MacBook

macOS Monterey — the last macOS version supporting most Intel MacBooks —
reached end of life on September 16, 2024 when Apple released Sequoia.
Security updates have stopped. On top of that, Monterey consumes roughly
4GB of RAM at idle on 8GB hardware, leaving almost nothing available for
actual work.

Debian Trixie at idle uses under 500MB. After running this post-install script, idle RAM rises to approximately 1GB — XFCE, NetworkManager, Bluetooth, and the FaceTime driver all add overhead that a terminal-only install does not have. That is still well under a quarter of what Monterey uses on the same hardware, and you now have a fully functional desktop.

---

## Who This Is For

This script is for users who have:

1. An Intel MacBook with no usable macOS (end of life, or removed)
2. Debian GNU/Linux 13 (Trixie) installed — minimal, no desktop
3. Broadcom WiFi working via the offline repo below
4. Internet connected via wpa_supplicant and dhcpcd
5. A terminal and nothing else

If you have not yet gotten WiFi working, start [here](https://github.com/willardcsoriano/debian-intel-macbook-broadcom-offline) first.

---

## What This Script Installs and Configures

### Automatic Security Updates
- linux-image-amd64 — kernel meta-package, ensures the kernel actually updates
  automatically rather than staying pinned to the version installed at setup
- intel-microcode — CPU microcode updates for Spectre/Meltdown-class mitigations
- unattended-upgrades — daily auto-install of Debian security patches and kernel
  updates. Extended to also cover the stable -updates pocket and the VS Code
  Microsoft repo (third-party origins are excluded by default)
- needrestart — notifies you when a kernel or library update requires a reboot
  to take effect. No auto-reboot; you decide when to restart.
- fwupd + fwupd-refresh.timer — UEFI and firmware updates via LVFS, refreshed
  automatically on a timer
- AppArmor verified active (ships enabled on Debian 13, warns if disabled)

### System Upgrade (optional)
Near the end, the script offers to run a full `apt full-upgrade` to bring every
package up to the latest Debian 13 point release. It first simulates the upgrade
and, when nothing is pending, reports the system as up to date and skips the
prompt entirely. When updates are available it is still **off by default** —
security updates already install automatically via unattended-upgrades, so
skipping it is safe, and pressing Enter (or a non-interactive run) skips it. If
you accept and a new kernel is installed, the Broadcom and FaceTime HD DKMS
drivers rebuild for it automatically and the script flags a reboot — verify WiFi
and the webcam after rebooting. The summary closes with a **System status** line
reporting one of: fully up to date, upgraded, or — if you declined pending
updates — a warning with the `sudo apt full-upgrade` command to catch up later.

### Desktop Environment
- xorg — display server
- xfce4 + xfce4-goodies — lightweight desktop, chosen specifically because
  it is fast and low on RAM — consistent with the reason you switched to
  Linux in the first place

### Terminal
- gnome-terminal — modern terminal with proper copy-paste, right-click menu,
  and mouse support. The default xterm that ships with Debian minimal is
  essentially unusable for everyday work.
- Bracketed paste mode disabled system-wide so pasting commands into the
  terminal works without escape code artifacts

### Browser and Core Apps
- firefox-esr — Mozilla Firefox
- gedit — simple text editor, similar feel to TextEdit on macOS
- cups — printing system, works with most USB and network printers

### Code Editor
- code (Visual Studio Code) — installed from Microsoft's official apt
  repository so it stays current via normal apt updates
- tomoki1207.pdf extension + libgtk-3-0t64 — renders PDFs natively inside
  VS Code tabs

### Media and Utilities
- flameshot — screenshot tool with annotation support. Shortcut: Ctrl+Alt+S
- xfce4-screenshooter — basic screenshot tool bound to the Print key
- file-roller — archive manager for zip, tar, and other formats
- vlc — media player for video and audio
- blueman — Bluetooth manager with GUI tray applet
- fastfetch — system info tool. Run with: fastfetch
- sane-utils + simple-scan — scanner support for USB and all-in-one printers
- xfce4-clipman-plugin — clipboard history manager
- xfce4-pulseaudio-plugin — volume control in taskbar with scroll-wheel adjustment
- libreoffice — full office suite (Writer, Calc, Impress). Large download ~300MB.
- mtpaint — simple image editor similar to Microsoft Paint
- gdebi — GUI installer for standalone .deb packages
- poppler-utils — command-line PDF tools (pdftotext, pdfinfo, pdfimages)
- speech-dispatcher — text-to-speech backend for accessibility tools

### WiFi Management
- network-manager + network-manager-gnome — replaces the manual
  wpa_supplicant + dhcpcd workflow permanently. After this you will never
  type ip link or wpa_passphrase again. WiFi connects automatically on boot
  and a tray icon lets you switch networks from the desktop.

### MacBook Keyboard Fixes
This is one of the most important parts of the script. Out of the box on
Linux, the Mac keyboard feels completely wrong — the Cmd key does nothing,
F keys behave unexpectedly, and text navigation shortcuts from macOS do not
work. This script fixes all of it.

- keyd — kernel-level key remapping, works before the desktop even loads
- brightness-udev — backlight write permissions without sudo
- rofi — window switcher used as an F3 Mission Control equivalent

Full key mapping applied:

| Key | Action |
|-----|--------|
| Cmd | Ctrl (preserves Mac muscle memory) |
| Cmd+Space / F4 | App finder (like Spotlight / Launchpad) |
| F1 / F2 | Brightness down / up |
| F3 | Window switcher (like Mission Control) |
| F5 / F6 | Keyboard backlight down / up |
| F7 / F8 / F9 | Previous / Play-Pause / Next track |
| F10 / F11 / F12 | Mute / Volume down / Volume up |
| Fn+F1–F12 | Standard F1–F12 keys |
| Cmd+Left / Right | Jump to start / end of line |
| Cmd+Up / Down | Jump to start / end of document |
| Cmd+Shift+Left / Right | Select to start / end of line |
| Cmd+Shift+Up / Down | Select to start / end of document |
| Cmd+Backspace | Delete entire line left of cursor |

### MacBook Touchpad Resume Fix
The bcm5974 trackpad re-enumerates as a USB device every time the lid opens
after suspend. When it reconnects, XFCE's settings daemon (xfsettingsd) replays
its stored input properties — and if it has a stale `Device_Enabled=0`, it
disables the trackpad before anything can turn it back on, leaving a dead pad
until reboot. This script clears that stored state and installs a systemd sleep
hook that force-enables the trackpad after each resume.

This covers only re-enabling the trackpad. For personal touchpad *preferences*
(tap-to-click, natural scrolling, cursor acceleration), see the
[dotfiles](https://github.com/willardcsoriano/dotfiles) repo below.

### Webcam and Microphone
The FaceTime HD camera in Intel MacBooks connects via PCIe, not USB. It
requires a reverse-engineered driver that is not included in the Linux
kernel. This script builds and installs it automatically via DKMS, which
means it survives kernel updates without any manual intervention.

- facetimehd — FaceTime HD webcam driver (compiled from source, DKMS managed)
- Microphone configured for MacBook Air hardware via ALSA

### Battery and Power
- xfce4-battery-plugin — battery level and charging status in taskbar
- xfce4-power-manager — lid close triggers suspend and screen lock.
  Password required on wake.

### System Monitoring
- xfce4-taskmanager — GUI task manager, similar to Activity Monitor
- htop — terminal process viewer

### Fonts
- fonts-liberation — Arial, Times New Roman, Courier New replacements
- fonts-noto — broad Unicode coverage

### App Finder Launcher Fix
Some installed `.desktop` files declare `Exec=...%F` or `%U`, telling the
launcher to pass a file argument. When you launch those apps from the XFCE
App Finder with no file selected they silently fail. This step writes
cleaned copies of affected launchers into `~/.local/share/applications`
(per-user overrides — system files are left untouched) so every app starts
cleanly from the App Finder.

### Desktop Shortcuts
Shortcuts for every installed app are placed on your Desktop so you can
find everything without memorizing commands. First time you click a
shortcut XFCE will show "Untrusted application launcher" — click Launch
to confirm. It will not ask again.

### Keyboard Shortcuts Cheat Sheet
A plain text file called KEYBOARD SHORTCUTS.txt is placed on your Desktop
with a complete reference of every shortcut configured by this script.

---

## Prerequisites

### 1. Working internet connection

Confirm with:

    ping -c 3 google.com

### 2. Set up sudo for your user

Debian does not configure sudo for regular users by default. This must be
done once before running the script. Do it while you are still in the
terminal from the Broadcom install.

Switch to root:

    su -

Add your user to the sudo group (replace yourusername with your actual
username, for example willard):

    usermod -aG sudo yourusername

Exit root and log out:

    exit
    logout

Log back in as your regular user. Confirm sudo works:

    sudo echo "sudo is working"

If you see "sudo is working" you are ready.

---

## Installation

Run this single command as your regular user, not as root:

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.7.7/setup.sh)

The script prints progress for every step. Estimated time: 20–40 minutes
depending on internet speed. LibreOffice alone is ~300MB.

When finished it will tell you whether a reboot is required and prompt you.

---

## Theming (optional)

Vanilla XFCE is functional but plain. If you want a macOS-style look — the
WhiteSur dark GTK theme, macOS-style window controls on the left, and a
Plank dock at the bottom — run this after the setup script completes and
you have rebooted into the desktop:

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.7.7/themes.sh)

You will be prompted to choose a mode:

- **Classic** — desktop icons visible, Plank shows open apps only
- **Dock** — clean empty desktop, all apps pinned in Plank
- **Revert** — removes all themes and restores vanilla XFCE

If you change your mind later, just run the script again and pick a
different mode or choose Revert.

---

## Microsoft Teams (optional)

If you need Teams, run this any time after setup completes:

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.8.0/teams.sh)

This installs [`teams-for-linux`](https://github.com/IsmaelMartinez/teams-for-linux), the unofficial Electron client, since Microsoft ships no native Debian package. It adds its own apt repository (`repo.teamsforlinux.de`) so it stays current via normal apt updates, and creates a Desktop shortcut. Safe to skip if you don't use Teams.

If first sign-in shows "Your account is temporarily locked to prevent unauthorized use", that's Microsoft Entra ID's Smart Lockout — a server-side account protection triggered by repeated failed sign-in attempts, unrelated to this script or the client. It clears itself after a short cooldown; if it persists, it's a Conditional Access block or disabled account that only your org's admin can lift.

---

## Verified Test Environment

| Component | Details |
|---|---|
| **Machine** | Apple MacBookAir7,2 (Mid-2015, 13-inch) |
| **OS** | Debian GNU/Linux 13 (Trixie) 13.5 |
| **Kernel** | 6.12.73+deb13-amd64 |
| **CPU** | Intel Core i5-5350U @ 1.80GHz (2 cores, 4 threads, up to 2.9GHz) |
| **RAM** | 8GB |
| **Storage** | 221GB SSD |
| **Architecture** | amd64 (64-bit) |

---

## Known Limitations

- F3 (Mission Control) uses rofi as an approximation. It shows open windows
  with icons and supports arrow key navigation. A closer equivalent
  (skippy-xd) is not currently in Debian Trixie repos.
- The FaceTime HD webcam driver is a community reverse-engineered driver.
  It works well but is not officially supported by Apple or the Linux kernel.
- Ctrl+Alt+S screenshot shortcut requires XFCE session to be running. It
  will not work from a pure terminal before first boot into the desktop.

---

## Related

Step 1 — get WiFi working before running this script:
https://github.com/willardcsoriano/debian-intel-macbook-broadcom-offline

Optional — personal touchpad preferences (tap-to-click, natural scrolling,
cursor acceleration) on top of the resume fix this script installs:
https://github.com/willardcsoriano/dotfiles

---

## Version History

- **v1.8.0** — Add optional `teams.sh` (unofficial `teams-for-linux` client, installed from its own apt repository) as a standalone opt-in script, kept out of `setup.sh` since not everyone needs Teams; add the `tomoki1207.pdf` VS Code extension to `setup.sh` for native PDF viewing
- **v1.7.7** — Remove the Google Antigravity CLI (`agy`) install: it was personal tooling rather than MacBook/Debian enablement, and dropping it also removes a third-party `curl | bash` installer from the run
- **v1.7.6** — Add the Google Antigravity CLI (`agy`), installed user-space via the official upstream installer (no root, checksum-verified, idempotent); render the optional system upgrade as its own three-state **System status** line (fully up to date / upgraded / declined) instead of a mislabeled package skip, warning with a catch-up command when pending updates are declined
- **v1.7.5** — Fix the contradictory closing message (the final banner no longer says "just reboot when ready" on a run that also reports "no reboot needed"); skip the optional system-upgrade prompt entirely when every package is already current, instead of always asking then doing nothing
- **v1.7.4** — Add an optional, off-by-default `apt full-upgrade` step (runs last so a new kernel triggers automatic DKMS driver rebuilds; flags a reboot when the running kernel is superseded)
- **v1.7.3** — Correct the stale post-install repo name in `setup.sh` branding and comments; restore the README intro as an Overview and drop the duplicate contents list; document the facetimehd kernel 6.12 build caveat; bump the verified environment to Debian 13.5
- **v1.7.2** — Fix suspend/resume on Intel MacBooks: force `s2idle` (deep/S3 never resumes on this hardware, leaving the machine dead on lid-open until a hard power-off) via the `mem_sleep_default=s2idle` kernel parameter and `MemorySleepMode=s2idle`; delegate the lid to logind for `suspend-then-hibernate` so a long/overnight close hibernates instead of draining the battery flat
- **v1.7.1** — Fix App Finder launches for apps whose `.desktop` files declare `Exec=...%F/%U` file-argument placeholders; writes cleaned per-user copies to `~/.local/share/applications`
- **v1.7.0** — Add automatic security updates section: linux-image-amd64, intel-microcode, unattended-upgrades (extended to -updates pocket and VS Code repo), needrestart, fwupd with timer, AppArmor check
- **v1.6.3** — Align window title to the left for macOS style in themes.sh
- **v1.6.2** — Fix FaceTime HD webcam driver re-installing on every run; replace unreliable modinfo check with direct find on module path
- **v1.6.1** — Fix conflicting VS Code apt sources (vscode.sources vs vscode.list breaks all apt installs); use full path for swapon
- **v1.6.0** — Harden themes.sh: fix plugin ID collision, unconditional panel restart after plugin changes, --force-array for wallpaper rgba1, poll-based plank seed replacing fixed sleep, explicit Sort= ordering for dock items, Mode 3 confirmation prompt, curl-based connectivity check, dual metadata::trusted+checksum for XFCE compat; harden setup.sh connectivity check
- **v1.5.0** — Automate panel setup (battery, volume, WiFi icons added on first login — no manual steps); fix themes.sh plugin ID collision
- **v1.4.0** — Add optional theming script (WhiteSur dark theme, Plank dock, macOS-style layout)
- **v1.3.0** — Add VS Code, poppler-utils, and speech-dispatcher; drop rhythmbox
- **v1.2.0** — Harden Broadcom WiFi rebuild chain, add swap warning, refactor for readability
- **v1.1.0** — Add gdebi package installer utility
- **v1.0** — Initial release

For full release details and downloads, see [GitHub Releases](https://github.com/willardcsoriano/debian-intel-macbook-post-install/releases).

---

## Contributing

Pull requests welcome. If you test this on a different Intel MacBook model
please open an issue with your model (run: sudo dmidecode -s
system-product-name) and whether it worked, so the tested hardware list
can be updated.

---

## License

MIT
