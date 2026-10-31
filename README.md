# Debian Linux Post-Installation Setup for Intel MacBooks

## Overview

A one-command post-installation setup for Intel MacBooks (2012–2019 models)
running Debian GNU/Linux 13 (Trixie). It picks up where the Broadcom offline
WiFi install leaves off — a bare terminal — and turns the machine into a
daily-usable laptop: a mandatory pre-change snapshot via Timeshift (so the
whole run can be undone), an XFCE desktop, automatic security updates that
actually run on battery power, a hardened Broadcom WiFi rebuild chain,
NetworkManager, macOS-style keyboard remapping via keyd, working
suspend/resume (s2idle plus lid suspend-then-hibernate), a bcm5974 touchpad
resume fix, the reverse-engineered FaceTime HD webcam and microphone
drivers, and a curated set of everyday applications. An optional theming
script gives XFCE a macOS-style look — the WhiteSur theme in light and dark
and a Plank dock — with Classic, Dock, and Revert modes. Both scripts are idempotent and
safe to re-run. Apple Silicon Macs are not supported; use the Asahi Linux
project instead.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Is This for You?](#is-this-for-you)
  - [Why Debian on an Intel MacBook](#why-debian-on-an-intel-macbook)
  - [⚠️ Compatibility Notice](#️-compatibility-notice)
- [Before You Start](#before-you-start)
  - [1. Working internet connection](#1-working-internet-connection)
  - [2. Set up sudo for your user](#2-set-up-sudo-for-your-user)
  - [The safety snapshot](#the-safety-snapshot)
- [What to Expect While It Runs](#what-to-expect-while-it-runs)
  - [What the symbols mean](#what-the-symbols-mean)
  - [Questions it may ask](#questions-it-may-ask)
  - [The log file](#the-log-file)
  - [The summary at the end](#the-summary-at-the-end)
  - [Running it again](#running-it-again)
- [After It Finishes](#after-it-finishes)
- [Making It Yours](#making-it-yours)
  - [Theming (optional)](#theming-optional)
  - [Default apps](#default-apps)
  - [Removing apps you don't want](#removing-apps-you-dont-want)
  - [Keeping it up to date](#keeping-it-up-to-date)
- [When Something Goes Wrong](#when-something-goes-wrong)
  - [Microsoft Teams](#microsoft-teams)
- [What This Script Installs and Configures](#what-this-script-installs-and-configures)
  - [Pre-Change Safety Snapshot](#pre-change-safety-snapshot)
  - [Swap / Memory Safety Net](#swap--memory-safety-net)
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
  - [Getting Started Guide](#getting-started-guide)
  - [Keyboard Shortcuts Cheat Sheet](#keyboard-shortcuts-cheat-sheet)
- [Verified Test Environment](#verified-test-environment)
- [Known Limitations](#known-limitations)
- [The Story So Far](#the-story-so-far)
- [Related](#related)
- [Version History](#version-history)
- [Contributing](#contributing)
- [License](#license)

## Quick Start

> Make sure you have read [Before You Start](#before-you-start) first — sudo
> must be configured and you need a working internet connection.

**Setup script** (required):

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.12.0/setup.sh)

**Theming script** (optional, run after first reboot):

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.12.0/themes.sh)

---

**Part 1 — Using it.** Everything you need to install, run and live with
the setup, in plain language. The technical detail is in Part 2 further down.

## Is This for You?

This script is for users who have:

1. An Intel MacBook with no usable macOS (end of life, or removed)
2. Debian GNU/Linux 13 (Trixie) installed — minimal, no desktop
3. Broadcom WiFi working via the offline repo below
4. Internet connected via wpa_supplicant and dhcpcd
5. A terminal and nothing else

If you have not yet gotten WiFi working, start [here](https://github.com/willardcsoriano/debian-intel-macbook-wifi-offline) first.

### Why Debian on an Intel MacBook

macOS Monterey — the last macOS version supporting most Intel MacBooks —
reached end of life on September 16, 2024 when Apple released Sequoia.
Security updates have stopped. On top of that, Monterey consumes roughly
4GB of RAM at idle on 8GB hardware, leaving almost nothing available for
actual work.

Debian Trixie at idle uses under 500MB. After running this post-install script, idle RAM rises to approximately 1GB — XFCE, NetworkManager, Bluetooth, and the FaceTime driver all add overhead that a terminal-only install does not have. That is still well under a quarter of what Monterey uses on the same hardware, and you now have a fully functional desktop.

### ⚠️ Compatibility Notice

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

## Before You Start

You need two things in place, and it helps to know about the safety net.

**If you haven't installed Debian yet:** choose *Guided — use entire disk and
set up encrypted LVM* in the installer's partitioning step. A laptop gets lost
and stolen, and without disk encryption anyone holding it can read your files.
It can only be chosen at install time; this script can't add it afterwards.

### 1. Working internet connection

Confirm with:

    ping -c 3 google.com

The script checks this itself and stops with a message if it finds no
connection.

### 2. Set up sudo for your user

`sudo` is how a regular user runs a command with administrator rights — the
Linux equivalent of typing your password into a macOS admin prompt.

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

Run the script as your regular user, not as root — it refuses to start as
root, and stops with the fix if sudo is not set up yet.

### The safety snapshot

Before it changes anything, the script installs Timeshift (a system restore
tool, similar in spirit to Time Machine) and takes a snapshot of the system.
There is no question to answer. It takes a few minutes, because Timeshift
checks every system file each time. If the run leaves your Mac in a bad state,
you can roll the whole thing back with:

    sudo timeshift --restore

This is a snapshot of the system (not your home folder) taken before the
script changes anything, not a recurring backup of your files. See [Pre-Change Safety Snapshot](#pre-change-safety-snapshot)
for the detail.

---

## What to Expect While It Runs

The script works through one section at a time — each starts with a blue
banner naming it — and prints a line for every step.

### What the symbols mean

| Symbol | Colour | Meaning |
|---|---|---|
| ✔ | green | Done — installed or configured just now |
| ⊘ | yellow | Already done on an earlier run, so skipped |
| → | cyan | Working on it (for example "Installing VLC...") |
| ⚠ | yellow | Worth knowing, but the run carries on |
| ✘ | red | That step failed — the run carries on and lists it at the end |

### Questions it may ask

Most runs ask very little. Depending on your machine you may see:

- **Your password**, once near the start, so it can make system changes.
- **"Continue anyway? [y/N]"** if the system does not look like Debian 13.
  Pressing Enter means no and stops the script.
- **"Continue anyway? [y/N]"** if you are not inside a desktop session — for
  example on a first run from the bare terminal. It warns that XFCE settings
  (shortcuts, power, tiling) will not be saved. Answer `y` to carry on; you
  can run the script again later from a terminal inside the desktop to apply
  them.
- **"Run a full system upgrade now? [y/N]"** near the end, only when Debian
  has updates waiting. Pressing Enter skips it, which is safe — see
  [System Upgrade (optional)](#system-upgrade-optional).
- **"Reboot now? [Y/n]"** at the very end, only when a reboot is needed.
  Here Enter means yes and restarts the Mac straight away; type `n` to
  reboot later yourself.

### The log file

Everything the script does, including the full output it hides from the
screen, goes into a log file. Its path is printed at the start and again at
the end. It lives at:

    ~/.local/state/macbook-postinstall/setup-<date>-<time>.log

`~` means your home folder. `latest.log` in the same folder always points at
the most recent run, and only the five most recent runs are kept. If that
folder can't be written, the log goes to
`/tmp/macbook-postinstall-<date>-<time>.log` instead.

### The summary at the end

When it finishes, the script prints an **Installation Summary**: what it
installed, what was already there and skipped, and — only if something went
wrong — what failed, with a pointer to the log. A **System status** line
then says whether Debian is fully up to date, was upgraded, or has updates
you chose not to apply. Last comes a reminder that `sudo timeshift --restore`
undoes the whole run, and the reboot question if a reboot is needed.

### Running it again

Re-running is safe. The script checks each step first and skips what is
already done (the ⊘ lines), so a second run only finishes what was missing.
A re-run of the same version of the script doesn't take another safety
snapshot: the one from its first run still covers everything it changes. To
skip the snapshot on purpose, run the script with `--no-snapshot`.

---

## After It Finishes

A short checklist for your first session on the new desktop:

1. **Reboot if it asked you to.** The desktop, WiFi manager, keyboard
   remapping and webcam driver only take effect after a restart.
2. **Check WiFi.** Your saved WiFi password is picked up automatically, and a
   WiFi icon in the panel lets you switch networks. See
   [WiFi Management](#wifi-management).
3. **Check the webcam and microphone.** Open **Cheese** from the app menu —
   it is installed for exactly this quick test. See
   [Webcam and Microphone](#webcam-and-microphone).
4. **Click Launch once per desktop icon.** The first time you open a desktop
   shortcut, XFCE shows "Untrusted application launcher". Click **Launch**;
   it will not ask again for that icon.
5. **Use the keys as you would on a Mac.** Cmd+C, Cmd+V, Cmd+Q, Option+arrows
   and the rest behave as on macOS, and Cmd+Space opens the App Finder, much
   like Spotlight. One difference: Cmd+Tab moves to the next tab and
   Option+Tab switches apps.
6. **Read the two help files.** `GETTING STARTED.txt` and
   `KEYBOARD SHORTCUTS.txt` are on your Desktop, and also in the app menu
   (Cmd+Space / App Finder) as **Getting Started** and **Keyboard
   Shortcuts**.

---

## Making It Yours

### Theming (optional)

Vanilla XFCE is functional but plain. If you want a macOS-style look — the
WhiteSur GTK theme, macOS-style window controls on the left, and a
Plank dock at the bottom — run this after the setup script completes and
you have rebooted into the desktop:

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.12.0/themes.sh)

You will be prompted to choose a mode:

- **Classic** — desktop icons visible (the shortcuts the setup script made),
  Plank shows open apps only
- **Dock** — clean empty desktop, everyday apps pinned in Plank, laid out like
  the Mac's default Dock: Files, App Finder, Chromium, Text Editor, Writer,
  Calc, Impress, Images, VLC, Calculator, Settings and the Trash. Developer and
  system tools (Terminal, VS Code, Task Manager) stay in the App Finder
- **Revert** — removes all themes and restores vanilla XFCE

Both the light and dark variants of WhiteSur are installed, and dark is
applied. To switch at any time, with no re-run and no logout:

| Setting | Dark | Light |
|---|---|---|
| Settings → Appearance → Style | WhiteSur-Dark | WhiteSur-Light |
| Settings → Appearance → Icons | WhiteSur-dark | WhiteSur-light |
| Settings → Window Manager → Style | WhiteSur-Dark | WhiteSur-Light |

The `-solid` variants drop the translucency. The terminal follows the theme.

If you change your mind later, just run the script again and pick a
different mode or choose Revert. Re-running replaces only the desktop
launchers and dock items the script placed itself; anything you pinned to the
dock or put on the Desktop by hand stays. Re-running does reset the Plank
dock settings and the solid wallpaper colour to the script's defaults.

The dock's icons are locked, so an icon dragged off by accident stays put. To
pin or remove one on purpose, turn the lock off in Plank's Preferences (hold
Ctrl and right-click the dock), make the change, and turn it back on. The same
switch from a terminal:

    gsettings set net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/ lock-items false

(`true` locks it again).

On a Mac the bar at the bottom is the Dock and the one at the top the menu
bar. Here the Dock is drawn by Plank, and the top bar is the XFCE panel.

### Default apps

Plain text files open in **Mousepad** (a simple editor, like TextEdit) and
images open in **Ristretto** (a light image viewer). The script sets these
only where you hadn't already chosen a default, so a choice you made
yourself wins — including on a re-run.

### Removing apps you don't want

Anything the script installed can be removed with:

    sudo apt remove <package-name>

The package names are listed in
[What This Script Installs and Configures](#what-this-script-installs-and-configures).
Earlier versions of this script installed gnome-terminal and the gedit text
editor; if your machine has them, `sudo apt remove gnome-terminal gedit`
clears them out.

### Keeping it up to date

Security updates install themselves daily, on battery as well as on mains
power, and you are told when one needs a reboot — nothing restarts on its
own. To bring every package up to the latest Debian 13 point release
yourself, run:

    sudo apt update && sudo apt full-upgrade

See [Automatic Security Updates](#automatic-security-updates) and
[System Upgrade (optional)](#system-upgrade-optional) for the detail.

---

## When Something Goes Wrong

- **A step shows ✘ or appears under "Failed" in the summary.** Open the log
  (`~/.local/state/macbook-postinstall/latest.log`) for the details, then run
  the script again — it skips everything already done and retries the rest.
- **The Ctrl+Alt+S screenshot shortcut, lid/power behaviour or window
  snapping isn't set.**
  The script was probably run outside the desktop (it warned you). Run it
  again from a terminal inside the desktop.
- **"Snapshot creation failed: …".** The run carried on without one. The
  message shows Timeshift's own error; the full output is in the log.
- **The whole run left things worse.** Roll back with
  `sudo timeshift --restore`.
- **WiFi or the webcam stopped working after a system upgrade.** A new
  kernel needs a reboot before the drivers run on it; reboot, then check
  both again.
- **The webcam is flaky.** The FaceTime HD driver is a community
  reverse-engineered driver, not officially supported — see
  [Known Limitations](#known-limitations).
- **The trackpad is dead after opening the lid.** The script installs a fix
  for this; see [MacBook Touchpad Resume Fix](#macbook-touchpad-resume-fix).
- **F3 doesn't look quite like Mission Control, or Ctrl+Alt+S does nothing
  in a plain terminal.** Both are known limitations — see
  [Known Limitations](#known-limitations).
- **The camera or sign-in fails in Microsoft Teams.** See below.

### Microsoft Teams

Microsoft ships no native Teams client for Debian. Use the web app at
`teams.microsoft.com` in **Chromium**, which `setup.sh` installs. Nothing
else to install, and it updates itself.

Why Chromium rather than a desktop client: when a call starts, Teams asks
the camera for a specific resolution, and the reverse-engineered
`facetimehd` driver only supports a narrow, fixed set of resolutions. In the
unofficial `teams-for-linux` Electron client that mismatch makes the camera
fail at call start even though it works in Cheese and Zoom; Chromium
negotiates the camera more permissively and the camera works. Full writeup:
[docs/teams-for-linux-camera.md](docs/teams-for-linux-camera.md).

If first sign-in shows "Your account is temporarily locked to prevent unauthorized use", that's Microsoft Entra ID's Smart Lockout — a server-side account protection triggered by repeated failed sign-in attempts, unrelated to this script or the browser. It clears itself after a short cooldown; if it persists, it's a Conditional Access block or disabled account that only your org's admin can lift.

**If you installed `teams-for-linux` with the `teams.sh` script from v1.9.x**,
remove the client, its apt repository and its signing key, since that
repository is not covered by automatic updates:

    sudo apt purge -y teams-for-linux
    sudo rm -f /etc/apt/sources.list.d/teams-for-linux-packages.sources /etc/apt/keyrings/teams-for-linux.asc
    sudo apt update
    rm -rf ~/.config/teams-for-linux "$HOME/Desktop/Microsoft Teams.desktop"

---

**Part 2 — Technical reference.** The detail behind Part 1: exactly what the
script installs and changes, and why.

## What This Script Installs and Configures

### Pre-Change Safety Snapshot
- timeshift — creates an on-demand system snapshot before any other step
  runs, with no prompt. This script rewrites GRUB, kernel parameters, logind,
  polkit, and the network stack — if anything goes wrong on your specific
  hardware, the run can be undone with `sudo timeshift --restore`. Configured
  for on-demand snapshots only; it does not set up recurring scheduled
  backups.
- One snapshot per version of the script. Each snapshot records a hash of
  `setup.sh`; when the newest one already belongs to this version, the run
  says so and doesn't take another, because re-running the same version
  changes nothing new. Run from a pipe (`bash <(curl …)`, as in the Quick
  Start) the script can't read itself to hash, so every run snapshots.
- Two kept. After a new snapshot, the script deletes its own snapshots
  except the oldest (the closest to before it first ran) and the newest.
  Snapshots you take yourself are never touched: the script finds its own by
  their description.
- `--no-snapshot` skips it, for a quick re-run when you don't need an undo
  point.

### Swap / Memory Safety Net
- zram-tools — compressed RAM swap, enabled automatically whenever no swap
  is already configured. 8GB of RAM with no swap at all will hard-freeze
  the machine on out-of-memory pressure with no warning; zram avoids that
  with near-zero disk wear since it never touches the SSD. Skipped if you
  already have swap set up some other way.

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
- ufw firewall — blocks incoming connections and allows everything outgoing,
  with mDNS left open so printers and other devices are still found. A laptop
  joins networks it doesn't control, and anything listening on all interfaces
  is otherwise reachable by everyone on them. Open a port with
  `sudo ufw allow <port>`. It is turned on only by the run that installs it; if
  ufw is already installed but off, the script leaves it off. **Docker
  caveat:** Docker writes its own firewall rules that bypass ufw, so a
  container published with `-p 8080:80` is still reachable from the network.
  Publish to localhost instead (`-p 127.0.0.1:8080:80`) unless you mean to share
  it.
- A systemd drop-in clearing `apt-daily-upgrade.service`'s shipped
  `ConditionACPower=true` — without this, the daily security-update check
  silently skips every time the laptop is running on battery, which for a
  MacBook is not an edge case

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
- xfce4-terminal — XFCE's own terminal, with copy-paste, a right-click menu
  and mouse support. It comes with xfce4-goodies, so nothing extra is
  installed; the script makes it the default for Ctrl+Alt+T, Thunar's "Open
  Terminal Here" and the system-wide `x-terminal-emulator`. Earlier versions
  installed gnome-terminal before XFCE was in place; a machine that has it can
  remove it with `sudo apt remove gnome-terminal`.
- Bracketed paste mode disabled system-wide so pasting commands into the
  terminal works without escape code artifacts

### Browser and Core Apps
- chromium — the default browser, because it is the browser the FaceTime HD
  camera works with in Microsoft Teams (`teams.microsoft.com`, see
  [Microsoft Teams](#microsoft-teams) above). It becomes the default only if
  you haven't chosen one yet.
- firefox-esr — Mozilla Firefox, still installed
- galculator — a light calculator (Debian's XFCE install has none)
- cups — printing system, works with most USB and network printers

### Code Editor
- code (Visual Studio Code) — installed from Microsoft's official apt
  repository so it stays current via normal apt updates
- tomoki1207.pdf extension + libgtk-3-0t64 — renders PDFs natively inside
  VS Code tabs

### Media and Utilities
- flameshot — screenshot tool with annotation support. Shortcut: Ctrl+Alt+S
- xfce4-screenshooter — basic screenshot tool bound to the Print key
- mousepad — XFCE's text editor, similar feel to TextEdit on macOS, and the
  default for plain text files (which otherwise open in LibreOffice Writer)
- ristretto — XFCE's image viewer, and the default for images (which
  otherwise open in ImageMagick's bare viewer). Defaults are set only where
  you haven't chosen one yourself.
- file-roller — archive manager for zip, tar, and other formats
- vlc — media player for video and audio
- blueman — Bluetooth manager with GUI tray applet
- fastfetch — system info tool. Run with: fastfetch
- sane-utils + simple-scan — scanner support for USB and all-in-one printers
- xfce4-clipman-plugin — clipboard history manager
- xfce4-pulseaudio-plugin — volume control in taskbar with scroll-wheel adjustment
- playerctl — MPRIS media-control backend the F7/F8/F9 previous/play-pause/next
  keys need to actually control whatever's playing, rather than doing nothing
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
- polkit rule refusing network changes from a locked screen — Debian lets
  you change network settings without a password while you're at the
  desktop, but once the screen locks that permission lapses and a
  background process can pop up an admin password dialog you never asked
  for. The rule refuses those requests instead, so an unexpected password
  prompt about network settings never appears. Nothing changes while
  you're using the desktop.

### MacBook Keyboard Fixes
This is one of the most important parts of the script. Out of the box on
Linux, the Mac keyboard feels completely wrong — the Cmd key does nothing,
F keys behave unexpectedly, and text navigation shortcuts from macOS do not
work. This script fixes all of it.

- keyd — kernel-level key remapping, works before the desktop even loads
- mac-app-keys (`/usr/local/bin/mac-app-keys`, started at login) — gives the
  terminal, Files and a few other apps their own Mac keys by switching keyd's
  bindings when another app comes to the front. It replaces keyd's own
  keyd-application-mapper, which rescanned every window on each title change:
  on a busy desktop it fell minutes behind (the terminal got the wrong keys)
  while using a whole CPU core. mac-app-keys reacts only to the window
  manager's "active window changed" notice, so it is idle the rest of the
  time. Re-running the script removes the old mapper and its leftover log.
  It runs as a systemd user service (`systemctl --user status mac-app-keys`),
  started at login, so a crash is restarted within seconds instead of leaving
  Cmd+C sending Ctrl+C in the terminal until you log in again.
  It talks to keyd through the `keyd` group's socket, so your user is added to
  that group. Treat that group like sudo; you already are a sudoer.
- python3-xlib — lets the mapper see which window is focused
- brightness-udev — backlight write permissions without sudo
- rofi — window switcher used as an F3 Mission Control equivalent

**The rule:** keys do what they do on macOS Monterey (sources: Apple's
[Mac keyboard shortcuts](https://support.apple.com/en-us/102650); the
shortcuts on that page are unchanged since Monterey, compared against its 2022
version). The one deliberate exception is Tab: **Cmd+Tab moves to the next tab
and Option+Tab switches apps**, matching how Mac users reach for Cmd as their
main modifier on Linux. Any shortcut an app lists as Ctrl+key also works as
Cmd+key.

**How it works.** Cmd is a held keyd *layer* that behaves as Ctrl, with
macOS-specific overrides on top. Left Option is a layer that never sends Alt
by itself: its keys (word jump, word delete, the app switcher) are explicit,
because a layer that holds Alt lets apps see the Alt press, and Option+Right
opened the File menu. Right Option stays plain Alt (Alt+F4, Alt+drag, AltGr
layouts). The control key does what it does on macOS, and stays Ctrl for
everything else, so Ctrl+C stops a terminal program. keyd only sends keys:
anything that starts a program (F3, Cmd+Shift+3) is a shortcut XFCE runs as
you, never as root. Versions before this one wrote the Cmd combinations as keyd
*chords*, which only fire when both keys go down within 50 ms, so Cmd+Space and
Cmd+arrows never worked.

**Audited against Apple's list.** [docs/apple-shortcuts.tsv](docs/apple-shortcuts.tsv)
goes through every shortcut on Apple's
[Mac keyboard shortcuts](https://support.apple.com/en-us/102650) page (as
published September 14, 2026) and says how each one behaves here: mapped,
the same Ctrl key Linux already uses, a Files action given Finder's key,
different on purpose, or not possible and why. The tests check it against
the config setup.sh writes, so a row can't claim a key that isn't bound.

| Key | Action |
|-----|--------|
| Cmd+C / V / X / Z / S / F / W / Q … | Copy, paste, … (any Ctrl+key shortcut works as Cmd+key) |
| Cmd+Space / F4 | App finder (like Spotlight / Launchpad) |
| Cmd+Tab / Cmd+Shift+Tab | Next / previous tab (not the macOS key: see above) |
| Option+Tab | Switch apps, hold Option and tap Tab (not the macOS key: see above) |
| Cmd+` | Switch windows of the same app |
| Cmd+Shift+[ / ] | Previous / next tab |
| Cmd+Option+Left / Right | Previous / next tab |
| Cmd+[ / ] | Back / forward (browsers, Files) |
| Cmd+H | Hide the front app (minimizes all its windows on this desktop) |
| Cmd+Option+H | Hide every other app |
| Cmd+M / Cmd+Option+M | Minimize the window / all windows of the front app |
| Cmd+Left / Right | Start / end of line |
| Cmd+Up / Down | Start / end of document |
| Cmd+Backspace | Delete to start of line |
| Option+Left / Right | Jump one word |
| Option+Backspace / Option+Fn+Backspace | Delete the word before / after the cursor |
| Option+Up / Down | Start / end of the paragraph |
| + Shift | Select while moving (Cmd+Shift+Left, Option+Shift+Right, …) |
| Cmd+Shift+3 | Whole-screen screenshot to `~/Pictures` and the clipboard |
| Cmd+Shift+4 / 5, Cmd+Option+S | Area screenshot with annotation (Flameshot) |
| Cmd+Option+T | New terminal window, from anywhere |
| Ctrl+Cmd+Q | Lock screen |
| Shift+Cmd+Q | Log out (asks to confirm) |
| Cmd+Option+F | Find and replace |
| Cmd+Option+Shift+V | Paste as plain text (Paste and Match Style) |
| Cmd+Option+I | Developer tools / inspector |
| Cmd+? (Cmd+Shift+/) | Help (F1) |
| Ctrl+Up / F3 | Mission Control (all windows) |
| Ctrl+Down | All windows of the front app |
| Ctrl+Left / Right | Previous / next desktop |
| Cmd+F3 / Fn+F11 / Fn+H | Show the desktop (Fn+F11 replaces plain F11, as on a Mac) |
| Fn+Shift+A | App finder (like Apps / Launchpad) |
| Ctrl+Cmd+Space / Fn+E | Emoji picker: type to search, Enter types it (and copies it) |
| Cmd+Option+D / Fn+A | Dock auto-hide on / off |
| Option+Brightness / Volume / Keyboard light / F3 | Open Display / Sound / Keyboard / window manager settings |
| Option+Shift+Brightness / Volume / Keyboard light | Smaller steps |
| Ctrl+Cmd+Option+8 | Invert colors |
| Ctrl+Power / Ctrl+Shift+Power | Restart-sleep-shut-down dialog / display sleep (not yet confirmed on hardware) |
| Ctrl+A / E / F / B / N / P / H / D / K / O | macOS text-field keys: line start / end, move, delete, cut to end of line, open a line |
| Ctrl+Cmd+F | Full screen |
| Cmd+Option+Esc | Force quit (click a window) |
| In Files: Cmd+D, Cmd+Shift+D / H / G / F / K / C / O, Cmd+Option+L, Cmd+Shift+Delete, Cmd+/, Ctrl+Cmd+T, Cmd+Shift+. | Duplicate; Desktop, Home, Go to Folder, Recents, Network, Computer, Documents, Downloads; Empty Trash; status bar; add to sidebar; show hidden files |
| In LibreOffice: Cmd+{ / } / \|, Cmd+; | Align left / right / center, Spelling |
| F1 / F2 | Brightness down / up |
| F3 | Window switcher (like Mission Control) |
| F5 / F6 | Keyboard backlight down / up |
| F7 / F8 / F9 | Previous / Play-Pause / Next track |
| F10 / F11 / F12 | Mute / Volume down / Volume up |
| Fn+F1–F12 | Standard F1–F12 keys (except Fn+F11: show the desktop) |

**In Files (Thunar)** the keys follow Finder: Cmd+Backspace moves the
selection to the Trash, Cmd+Up / Down go to the enclosing folder / open the
selection, Cmd+I shows Properties. This also keeps the text-editing
Cmd+Backspace (Shift+Home, Delete) out of the file manager, where it would
select every file up to the first one and trash them.

**In the terminal** (xfce4-terminal), mac-app-keys
switches a few keys to what a terminal needs: Cmd+C / Cmd+V copy and paste,
Cmd+T / N / W / Q open and close tabs and windows, Cmd+F finds,
Cmd+Backspace deletes to the start of the line (Ctrl+U), and Option+Backspace is
the shell's word delete. Option+arrows need no terminal override: they send
Ctrl+arrows, which Debian's shell setup already treats as word moves. The control key reaches the
shell unchanged (Ctrl+C, Ctrl+A, Ctrl+K, …), as in macOS Terminal. This needs one log-out and
log-in after the first run. The bindings live in `~/.config/keyd/app.conf`;
if you write your own file there, the script leaves it alone. Cmd+Tab /
Cmd+Shift+Tab move between xfce4-terminal's tabs without any of this: the
terminal's own next / previous tab keys are set to Ctrl+Tab / Ctrl+Shift+Tab,
which Cmd+Tab sends everywhere (in effect once every terminal window has been
closed). GNOME Terminal, which earlier versions installed, gets no Mac keys:
remove it (see above).

### MacBook Touchpad Resume Fix
The bcm5974 trackpad re-enumerates as a USB device every time the lid opens
after suspend. When it reconnects, XFCE's settings daemon (xfsettingsd) replays
its stored input properties — and if it has a stale `Device_Enabled=0`, it
disables the trackpad before anything can turn it back on, leaving a dead pad
until reboot. This script clears that stored state and installs a systemd sleep
hook that force-enables the trackpad after each resume.

It also sets the trackpad to feel like a Mac's: natural scrolling, two-finger
click for a right click, and no stray clicks while typing, plus tap-to-click
(off by default on macOS, on here). These are written as defaults in
`/etc/X11/xorg.conf.d/30-macbook-postinstall-touchpad.conf`, so Settings →
Mouse and Touchpad still changes them per user, and a later-numbered file of
your own overrides any of them.

### Webcam and Microphone
The FaceTime HD camera in Intel MacBooks connects via PCIe, not USB. It
requires a reverse-engineered driver that is not included in the Linux
kernel. This script builds and installs it automatically via DKMS, which
means it survives kernel updates without any manual intervention.

- facetimehd — FaceTime HD webcam driver (compiled from source, DKMS managed)
- Microphone configured for MacBook Air hardware via ALSA
- cheese — a reverse-engineered driver is worth verifying immediately
  rather than discovering it's broken mid-call; gives a one-click way to
  confirm the camera and mic actually work

### Battery and Power
- xfce4-battery-plugin — battery level and charging status in taskbar
- xfce4-power-manager — lid close triggers suspend and screen lock.
  Password required on wake.
- Keyboard backlight follows the display, as on a Mac. A sleep hook turns it
  off during suspend, and a small watcher started at login
  (`/usr/local/bin/kbd-backlight-follow-display`) turns it off while the
  display is powered off, then restores your level when it wakes. If you
  change the level while the display was off, yours wins. The watcher reads
  the panel's power state from the kernel, so it sees the lock screen too, and
  switches the light through UPower, so it needs no root or extra groups.
- The lock screen powers the display off after a minute without input, as a
  Mac does. LightDM's greeter only blanks the screen (black, but the panel
  stays lit and drawing power); a `greeter-setup-script`
  (`/etc/lightdm/lightdm.conf.d/50-macbook-postinstall.conf`) sets display
  power saving on each lock and login screen. It applies from the next boot.

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

It also lists xfce4-terminal as **Terminal** (the package calls it "Xfce
Terminal"), through a per-user copy of the package's launcher that each run
regenerates. If you made your own `xfce4-terminal.desktop` there, it is left
alone.

### Desktop Shortcuts
Shortcuts for the everyday apps are placed on your Desktop so you can
find everything without memorizing commands: Files, App Finder, Chromium,
Text Editor, Writer, Calc, Impress, Images, VLC, Calculator and System
Settings, the same apps the Dock holds (see themes.sh). Developer and system
tools (Terminal, VS Code, Task Manager, Bluetooth, System Info) are in the App
Finder. Re-running the script updates these shortcuts and removes ones older
versions placed (such as Firefox, Terminal and htop), but never touches a
shortcut you made or edited yourself. The shortcuts are marked trusted, so
XFCE shouldn't ask "Untrusted application launcher"; if it does, click Launch
and it won't ask again.

### Getting Started Guide
A plain text file called GETTING STARTED.txt is placed on your Desktop, and
is also in the app menu as **Getting Started**, with a short first-steps
guide to the new desktop.

### Keyboard Shortcuts Cheat Sheet
A plain text file called KEYBOARD SHORTCUTS.txt is placed on your Desktop
with a complete reference of every shortcut configured by this script. It is
also in the app menu as **Keyboard Shortcuts**.

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
- The screenshot shortcuts (Cmd+Shift+3 / 4 / 5) need the XFCE session to be
  running. They won't work from a pure terminal before first boot into the
  desktop.

---

## The Story So Far

If you just came from the [offline WiFi kit](https://github.com/willardcsoriano/debian-intel-macbook-wifi-offline), you have accomplished something genuinely difficult — you installed Linux on a MacBook with no internet access and got WiFi working entirely from a USB stick. That is not a beginner task and you should feel good about it.

But right now you are staring at a terminal. No desktop, no browser, no
way to adjust brightness, no GUI tools, no keyboard shortcuts that feel
familiar coming from macOS. The Cmd key does nothing useful. The function
keys do nothing. The FaceTime camera does not work. The mic may not work.

This script fixes all of that in one command.

---

## Related

Step 1 — get WiFi working before running this script:
https://github.com/willardcsoriano/debian-intel-macbook-wifi-offline

---

## Version History

- **v1.12.0** — Mac shortcuts, not just Mac keys: Cmd+H hides the front app and Cmd+Option+H every other app; Fn is a layer (Fn+H / Fn+F11 show the desktop, Fn+E emoji, Fn+A the Dock); an emoji picker on Ctrl+Cmd+Space; Dock auto-hide on Cmd+Option+D; Option and Option+Shift with the top-row keys open their settings or take small steps; invert colors, paragraph moves, Paste and Match Style, Help and developer tools; Finder's keys in Files (Desktop, Home, Go to Folder, Downloads, Documents, Recents, Duplicate, Empty Trash) and alignment and spelling in LibreOffice. `docs/apple-shortcuts.tsv` audits every shortcut on Apple's list and says how each behaves here. The keyboard light now goes dark whenever the display is off, and the lock screen powers the display off after a minute. Tests check the generated keyd config against keyd's grammar and run the helpers against stub tools on every pull request.
- **v1.11.0** — Make the Mac keyboard work: Cmd is a held keyd layer (the old chord bindings never fired), keys follow macOS Monterey with Cmd+Tab for the next tab and Option+Tab to switch apps, Left Option never sends a bare Alt (Option+Right opened the File menu), the control key does what it does on macOS, and keyd's per-app mapper gives the terminal, Files and browsers their own keys; F3 and screenshots no longer run as root. Take the safety snapshot for the first time (Timeshift 24.06 rejected `--tags O`), keep one per script version and only two in total, and add `--no-snapshot`. Turn on a ufw firewall. Report service and keyd results by what actually happened, and stop reinstalling multiarch packages. Curate the apps (xfce4-terminal, Mousepad, galculator; GNOME Terminal and gedit dropped), converge Desktop and dock launchers on re-run without deleting the user's own, and default text to Mousepad and images to Ristretto. Install both WhiteSur variants. Mac trackpad defaults. Restructure the README into a user guide and a reference, and add Getting Started and Keyboard Shortcuts guides to the app menu. Keep install logs in `~/.local/state`.
- **v1.10.0** — Refuse NetworkManager changes from locked or background sessions with a polkit rule. With the screen locked, Debian's no-password network rule stops applying, and a background process could raise an admin password dialog nobody asked for. Stop versioned kernel headers from pinning the install-time kernel, so `apt autoremove` can clear superseded kernels. Drop the optional `teams.sh` (`teams-for-linux`) in favor of Teams on the web in Chromium, which is the path where the FaceTime HD camera works; the README gives removal steps for existing installs. Update links for the renamed offline WiFi kit repo, regenerate the TOC with GitHub-accurate anchors, and add the issue labeler, issue forms and PR template.
- **v1.9.1** — Fix the `touchpad-resume` sleep hook's trigger condition: it guarded on `[ "$1" = "post" ] && [ "$2" = "resume" ]`, but systemd's sleep-hook contract never actually passes the literal string `"resume"` as the second argument (it's always the sleep action — `suspend`, `hibernate`, etc.) — so the condition could never be true and the hook has been dead code since it was written. The touchpad re-enable behavior users actually observed was coming entirely from the `xfconf` `Device_Enabled` correction earlier in the script, not from this hook. Fixed to guard on `[ "$1" = "post" ]` alone, matching the equivalent fix already applied in the `dotfiles` repo's copy of this hook.
- **v1.9.0** — `v1.8.0` was never actually tagged despite being documented as released, leaving the Quick Start commands 404ing against a nonexistent tag; this release folds in everything that was pending plus new additions rather than retroactively fixing the broken tag. Add a mandatory, silent pre-change snapshot via Timeshift (on-demand only, no recurring schedule) before any other step runs; add Chromium alongside Firefox so the documented Teams camera-bug fallback actually works without an extra install; add zram compressed swap whenever no swap is already configured, replacing a warning that previously did nothing; clear `apt-daily-upgrade.service`'s shipped `ConditionACPower=true` so daily security updates actually run on battery, not just AC power; add Cheese for an immediate webcam/mic verification right after the driver installs; add playerctl as the media-key control backend for F7/F8/F9. Also includes what was pending from the untagged v1.8.0: optional `teams.sh` (unofficial `teams-for-linux` client, installed from its own apt repository) as a standalone opt-in script kept out of `setup.sh`; the `tomoki1207.pdf` VS Code extension for native PDF viewing; turning off the keyboard backlight during suspend (s2idle doesn't power it down on its own).
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

Pull requests welcome. `python3 -m unittest discover -s tests` runs the
tests (standard library only): they check that the keyd config and
`app.conf` that `setup.sh` writes are valid keyd 2.5.0, since keyd skips a
line it can't parse instead of failing, and they test the keyboard-backlight
watcher. GitHub runs them on every pull request.

If you test this on a different Intel MacBook model
please open an issue with your model (run: sudo dmidecode -s
system-product-name) and whether it worked, so the tested hardware list
can be updated.

---

## License

MIT
