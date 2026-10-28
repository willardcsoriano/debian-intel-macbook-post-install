# Teams for Linux — Camera Fails Only During a Call (Zoom/Cheese Work Fine)

## Overview

On a MacBook running the reverse-engineered `facetimehd` webcam driver (installed by this toolkit's `setup.sh`), `teams-for-linux` can fail to connect the camera specifically once a call starts — even though the camera works fine everywhere else (Zoom, Cheese, `ffplay`, etc.) and the driver itself is confirmed healthy. This is not a driver, permissions, or network problem. Microsoft Teams' web app requests a specific camera resolution/frame-rate via `getUserMedia` once a call begins negotiating media, and `facetimehd` — unlike a real webcam — only supports a narrow, fixed set of resolutions. When Teams' requested constraints don't match what the driver can actually deliver, the camera fails right there, which is why it looks like "camera works everywhere except during an actual Teams call." The fix is a one-line `teams-for-linux` config addition; a browser fallback (`teams.microsoft.com` in Chromium) works immediately without needing this fix at all, since the browser negotiates its own constraints more permissively. **If the browser fallback still shows a blank camera, check which browser you used** — the fallback needs to be Chromium-based specifically; Firefox has its own, unrelated Teams video bug (a blank video grid even with a working camera), so use Chromium for the fallback.

## Table of Contents

- [Overview](#overview)
- [How to confirm this is the cause](#how-to-confirm-this-is-the-cause)
- [Fix 1 — teams-for-linux config (persistent)](#fix-1-teams-for-linux-config-persistent)
- [Fix 2 — browser fallback (immediate, no config needed)](#fix-2-browser-fallback-immediate-no-config-needed)
- [What this rules out](#what-this-rules-out)

## How to confirm this is the cause

Before assuming this is the cause, rule out the more obvious things first — all of these were checked directly and came back clean in the case this note documents:

- Camera works in another app (Zoom, Cheese, or `ffplay -f v4l2 -i /dev/video0`) — if it doesn't, this note doesn't apply; the problem is upstream of Teams entirely (driver/permissions/hardware).
- `lsmod | grep facetimehd` shows the module loaded, and `modinfo facetimehd | grep vermagic` matches `uname -r` exactly — confirms the DKMS-built driver actually matches the running kernel.
- Your user is in the `video` group (`groups | grep video`) and nothing else has the device open (`fuser /dev/video0`, `lsof /dev/video0` — both should be empty when idle).

If all of the above check out and the camera still only fails specifically once a Teams call starts (not on device detection, not in Teams' own settings preview), this is very likely it.

## Fix 1 — teams-for-linux config (persistent)

Create or edit `~/.config/teams-for-linux/config.json`:

```json
{
  "media": {
    "camera": {
      "resolution": {
        "enabled": true,
        "mode": "remove"
      }
    }
  }
}
```

`mode: "remove"` strips the resolution/frame-rate constraints Teams normally sends with its `getUserMedia` request, letting the camera stream at whatever native resolution it actually supports instead of failing to match an unsupported one. Fully quit `teams-for-linux` (not just close the window — confirm no `teams-for-linux` process is still running) before retesting, since the config is only read at startup.

Documented upstream: [`teams-for-linux` configuration docs](https://ismaelmartinez.github.io/teams-for-linux/docs/configuration), `media.camera.resolution.*`.

## Fix 2 — browser fallback (immediate, no config needed)

Open `teams.microsoft.com` in a Chromium-based browser and sign in with the work account. Chromium generally has more complete/reliable Teams WebRTC support than Firefox (Microsoft optimizes Teams web primarily for Chromium-based browsers), and the browser's own `getUserMedia` negotiation is more permissive than `teams-for-linux`'s Electron wrapper — so this can work immediately even before applying Fix 1.

## What this rules out

Investigated and confirmed *not* the cause, in case any of this needs re-checking later — don't re-litigate these without new evidence:

- **Driver/kernel mismatch** — `facetimehd`'s DKMS build vermagic matched the running kernel exactly, and DKMS had already correctly rebuilt it across two prior kernel upgrades.
- **`video` group / device permissions** — correct.
- **Device held open by another process** — nothing had `/dev/video0` open at the time of investigation.
- **System-wide network/firewall blocking WebRTC** — ruled out by Zoom working normally on the same machine at the same time.
