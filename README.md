<h1 align="center">Razer BSK V3 X HS on Mac</h1>

<p align="center">
  Open source native macOS app for configuring Razer Basilisk V3 X
  HyperSpeed on Mac.<br/>
  DPI, polling rate, button remap, lighting, scroll smoothing, battery,
  and per-app profile auto-switch — no Synapse needed.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#permissions">Permissions</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="README.zh-Hans.md">中文</a>
</p>

---

## Overview

Razer's Synapse app doesn't ship a macOS build for the Basilisk V3 X
HyperSpeed. This app fills that gap. Everything writes to the mouse's
**onboard memory**, so settings survive sleep, unplug, and switching to
a Windows machine.

<p align="center">
  <img src="screenshots/tray.png" width="280" alt="Tray menu" />
</p>

---

## Screenshots

| Sensitivity | Report rate |
|:---:|:---:|
| ![Sensitivity](screenshots/sensitivity.png) | ![Report rate](screenshots/report-rate.png) |

| Scroll | Buttons |
|:---:|:---:|
| ![Scroll](screenshots/scroll.png) | ![Buttons](screenshots/buttons.png) |

| Lighting | Power |
|:---:|:---:|
| ![Lighting](screenshots/lighting.png) | ![Power](screenshots/power.png) |

| Profiles | Device |
|:---:|:---:|
| ![Profiles](screenshots/profiles.png) | ![Device](screenshots/device.png) |

---

## Features

- **Sensitivity** — up to 5 DPI stages (100–18000 dpi), per-stage X/Y
  split, physical DPI-cycle button reflected in the UI
- **Report rate** — 125 / 500 / 1000 Hz on the 2.4 GHz dongle (Bluetooth
  is capped at ~125 Hz by macOS)
- **Scroll** — reverse direction per axis, speed multiplier, ~100–400 ms
  smoothing glide. Works over Bluetooth. Trackpad untouched.
- **Buttons** — remap right / scroll / side buttons to keystrokes, mouse
  clicks, media keys, DPI cycle, launch URL / app / CLI, type text, hold
  modifiers, boss key. Turbo (rate-fire) 1–60 Hz per button.
- **Lighting** — scroll-wheel LED effects (Static, Breath, Spectrum,
  Wave, Reactive), full RGB, wave direction, reactive speed. Interactive
  edits go to RAM so flash wear stays bounded.
- **Power** — battery smoothed over 30 min (hides AA voltage recovery),
  idle-sleep timer with read-back verification, configurable low-battery
  threshold with system notification + auto-dim LED.
- **Profiles** — auto-switch by focused app (bind bundle IDs to a
  profile), fallback default profile. Import / export `.bskprofile.json`.
- **Device** — firmware, serial, VID/PID, launch at login, language
  (Follow system / English / 简体中文), refresh from mouse, show
  settings.json, export/import profile.
- **Menu bar** — icon dims when the mouse idles, brightens on input.
  Battery pill next to the icon updates from three sources (Razer vendor
  protocol, BLE GATT, Apple IOPowerSources).

---

## Install

1. Download the latest `Razer-BSK-V3-X-HS-<ver>.app.zip` or
   `.dmg` from the
   [Releases](https://github.com/AaronKhoolb/Razer-BSK-V3-X-HS-on-Mac/releases)
   page.
2. Unzip or open the DMG and drag to `/Applications`.
3. First launch: right-click the app → **Open** to bypass Gatekeeper's
   unsigned-app warning. Or run once:
   ```
   xattr -dr com.apple.quarantine "/Applications/BSK V3 X HS.app"
   ```
4. Grant *Input Monitoring* and *Accessibility* (see below) so vendor
   commands and button remap can reach the mouse.

Requires macOS 14 (Sonoma) or newer, Apple Silicon.

---

## Permissions

- **Input Monitoring** — required to send HID feature reports over the
  dongle (DPI, poll rate, lighting, idle timer, battery).
- **Accessibility** — required for button remap and scroll smoothing
  (both use a CGEventTap).
- **Bluetooth** (optional) — for reading battery over BLE when the
  dongle isn't plugged in.
- **Notifications** (optional) — for the low-battery alert.

Panels that need a missing permission show an in-app card with a
"Grant" button that jumps to the right System Settings screen.

If you build from source with `setup-cert.sh`, the code-signing
identity stays stable across rebuilds and macOS keeps the permission
grants. Ad-hoc-signed downloads get a new signing hash on each build,
so you'd need to re-grant after re-signing.

---

## Build from Source

```bash
git clone https://github.com/AaronKhoolb/Razer-BSK-V3-X-HS-on-Mac.git
cd Razer-BSK-V3-X-HS-on-Mac

# One-time: create a stable self-signed cert so TCC permissions stick
# across rebuilds. No Apple Developer account needed.
bash setup-cert.sh

# Build
bash build.sh

# Run
open "build/BSK V3 X HS.app"
```

---

## Trademarks

**Razer™, Basilisk™, and HyperSpeed™** are trademarks of Razer USA
Ltd. This project is not affiliated with, endorsed by, or sponsored by
Razer. Product names appear only to identify the specific device this
software supports. See [NOTICE.md](NOTICE.md) for full attributions.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Contributors

<a href="https://github.com/AaronKhoolb/Razer-BSK-V3-X-HS-on-Mac/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=AaronKhoolb/Razer-BSK-V3-X-HS-on-Mac&v=1" alt="Contributors" />
</a>
