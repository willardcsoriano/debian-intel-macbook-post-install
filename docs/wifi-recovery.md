# Wifi Recovery: fix-wifi and wifi-watchdog

## Overview

The Broadcom wifi in these MacBooks fails in a few distinct ways, and a reboot "fixes" most of them only because it forces one fresh start. `setup.sh` installs two tools that do the same without restarting. `fix-wifi` reconnects, power-cycles the radio (`--radio`) or power-cycles Bluetooth (`--bluetooth`). `wifi-watchdog` is a background service that spots the one failure you can't fix by reconnecting, a wedged driver that refuses every network, and power-cycles the radio for you. This page lists each failure mode, how to tell them apart from the logs, which tool fixes which, and how the watchdog decides when to act and when to leave the radio alone.

## Table of Contents

- [Overview](#overview)
- [Which one is it?](#which-one-is-it)
- [Reading the logs](#reading-the-logs)
- [fix-wifi](#fix-wifi)
- [How the watchdog decides](#how-the-watchdog-decides)
- [Turning it off](#turning-it-off)

## Which one is it?

| What you see | What's happening | Fix |
|---|---|---|
| Connected, but drops every minute or so; worse on a mesh network | **Roaming storm:** the laptop keeps hopping between access points of the same network | `fix-wifi` |
| Won't connect to anything, not even a phone hotspot that works for other devices | **Driver lockup:** the driver refuses every association before anything goes out over the air | `fix-wifi --radio` (the watchdog does this by itself after about a minute) |
| Wifi is off after a reboot and stays off | **Radio blocked at boot:** the hardware switch (rfkill) came up blocked | `nmcli radio wifi on`, or the network icon |
| Wifi is off after waking from sleep | Look at the watchdog's log first (below). If it ran a reset that failed, turning the radio back on was refused. | `nmcli radio wifi on` |
| Phone tethering over Bluetooth fails with "Input/output error" | The Bluetooth stack is stuck | `fix-wifi --bluetooth` |

## Reading the logs

- **Driver lockup:** `journalctl -b -u wpa_supplicant` shows `Association request to the driver failed` on every attempt, against every network. NetworkManager (`journalctl -b -u NetworkManager`) keeps auto-activating and failing with `association took too long`. A failure against one network only points at that network or its access point, not at the driver.
- **Roaming storm:** NetworkManager reconnects repeatedly to the same network name on different access points (different BSSIDs), every 30 to 90 seconds. Each hop is a short real outage. The connection works between hops.
- **Radio blocked at boot:** NetworkManager logs `disabled by radio killswitch`. The watchdog's log is silent, because the radio was off before it started.
- **The watchdog's own log:** `journalctl --user -u wifi-watchdog`. Every reset it runs, or defers, is logged there. If wifi is off and this log shows a reset just before, the reset is what turned it off.

## fix-wifi

```sh
fix-wifi               # disconnect and reconnect the wifi device
fix-wifi --radio       # power-cycle the wifi radio (nmcli radio wifi off/on)
fix-wifi --bluetooth   # power-cycle Bluetooth
```

None of these need `sudo`. Turning the radio on and off is a NetworkManager permission the user at the active session already has.

`--radio` checks that the radio actually came back on, and retries up to three times. If it still reads off, it says so and exits with an error instead of leaving wifi off silently. A plain `fix-wifi` works one layer above the driver, which is why it can't clear a lockup. NetworkManager keeps retrying that same reconnect on its own during one anyway.

## How the watchdog decides

It is a systemd user service (`systemctl --user status wifi-watchdog`) that checks wifi every 10 seconds:

- **It acts** when NetworkManager has been trying to connect and failing for about a minute: six polls in an attempt or failed state, with no successful connection in between. Then it runs `fix-wifi --radio` and shows a notification.
- **Idle doesn't count.** A disconnected device that isn't trying to connect is never treated as a lockup, for example when no saved network is in range or you're on a cable. A short idle moment between two failed attempts doesn't reset the count, but a full minute of idle does.
- **Sleep doesn't count.** NetworkManager takes wifi down on purpose before every sleep. While the system is suspending or asleep, and right after it wakes, the count starts again. If a suspend keeps failing and retrying, the watchdog stays out of it.
- **A locked screen defers the reset.** Turning the radio on and off is allowed only for the active session. A reset started while the screen is locked could turn the radio off and then be refused when turning it back on. So the watchdog asks NetworkManager first, logs that it is waiting, and runs the reset on the first check after you unlock, if wifi is still failing.
- **It doesn't fight.** After a reset it waits at least five minutes before the next one. It never escalates to reloading the driver or rebooting. If the notification keeps coming back, the problem is something a radio reset can't fix: read the logs above.

## Turning it off

```sh
systemctl --user mask --now wifi-watchdog     # stop it and keep it off
systemctl --user unmask wifi-watchdog         # allow it again (starts at next login)
```

`setup.sh` turns it on for every account with `systemctl --global enable`. A per-user `disable` can't undo that, but a per-user `mask` can, and later runs of `setup.sh` leave a masked watchdog off. `fix-wifi` stays available either way.
