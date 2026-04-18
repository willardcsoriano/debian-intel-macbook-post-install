# Debian Linux Post-Installation Setup for Intel MacBooks

A single-command post-installation setup script for Intel MacBooks running
Debian GNU/Linux 13 (Trixie). This picks up exactly where the Broadcom
offline repo leaves off — WiFi is working, you have a terminal, and now
it is time to turn this machine into something you can actually use every
day.

---

## ⚠️ Compatibility Notice

**This script is for Intel MacBooks only.**

Apple Silicon Macs (M1, M2, M3, M4 — released 2020 onwards) use ARM
architecture and are not supported. Apple Silicon Linux support is handled
by the separate Asahi Linux project.

**This script targets Debian GNU/Linux 13 (Trixie) only.**

Ubuntu and Linux Mint are not tested and not officially supported. Most
apt-based steps will likely work, but keyd availability varies by Ubuntu
version and may require a PPA. The facetimehd driver builds from source
via DKMS and should work on any kernel as long as headers are installed.
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

If you have not yet gotten WiFi working, start [here](https://github.com/willardcsoriano/debian-trixie-intel-macbook-broadcom-offline) first.

---

## What This Script Installs and Configures

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

### Media and Utilities
- flameshot — screenshot tool with annotation support. Shortcut: Ctrl+Alt+S
- xfce4-screenshooter — basic screenshot tool bound to the Print key
- file-roller — archive manager for zip, tar, and other formats
- vlc — media player for video and audio
- blueman — Bluetooth manager with GUI tray applet
- fastfetch — system info tool. Run with: fastfetch
- sane-utils + simple-scan — scanner support for USB and all-in-one printers
- xfce4-clipman-plugin — clipboard history manager
- libreoffice — full office suite (Writer, Calc, Impress). Large download ~300MB.
- mtpaint — simple image editor similar to Microsoft Paint
- rhythmbox — music player for local libraries

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

    bash <(curl -s https://raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.0/setup.sh)

The script prints progress for every step. Estimated time: 20–40 minutes
depending on internet speed. LibreOffice alone is ~300MB.

When finished it will tell you whether a reboot is required and prompt you.

---

## After Reboot

Two things need to be added to your taskbar manually after the first boot
into XFCE:

### Add WiFi icon to taskbar
Right-click taskbar → Panel → Add New Items → Network Manager → Add

### Add battery indicator to taskbar
Right-click taskbar → Panel → Add New Items → Battery Monitor → Add

These are one-time steps. After this everything is automatic.

---

## Verified Test Environment

| | |
|---|---|
| **Machine** | Apple MacBookAir7,2 (Mid-2015, 13-inch) |
| **OS** | Debian GNU/Linux 13 (Trixie) 13.4 |
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
https://github.com/willardcsoriano/debian-trixie-intel-macbook-broadcom-offline

---

## Contributing

Pull requests welcome. If you test this on a different Intel MacBook model
please open an issue with your model (run: sudo dmidecode -s
system-product-name) and whether it worked, so the tested hardware list
can be updated.

---

## License

MIT
