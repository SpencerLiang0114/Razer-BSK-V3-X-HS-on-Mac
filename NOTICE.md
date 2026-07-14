# Notices

## Trademarks

**Razer™, Basilisk™, HyperSpeed™, and Synapse™** are trademarks or registered
trademarks of Razer USA Ltd. in the United States and other countries.

This project is a personal, independent, third-party interoperability utility.
It is **not affiliated with, endorsed by, sponsored by, or associated with
Razer USA Ltd.** in any way. Product names appear only where necessary to
identify the specific device this software supports (nominative fair use).

The name "BSK V3 X HS" is the internal product string that the mouse's own
firmware broadcasts over USB and Bluetooth — this project uses it factually.

## Third-party sources

The Razer HID protocol constants and command shapes used to talk to the
mouse (frame layout, command classes, effect IDs, wave direction encoding,
etc.) were derived from prior published reverse-engineering work:

- **[OpenRazer](https://github.com/openrazer/openrazer)** — GPL-2.0
  Linux driver project. The 90-byte transaction frame layout, CRC
  computation, class/command-id numbering, and Basilisk-family
  extended-matrix lighting command shapes were confirmed against
  OpenRazer's public source. All code in this repository was written
  independently from those factual protocol constants; no source was
  copied.

Protocol facts (byte layouts, magic numbers, opcodes) are not
copyrightable subject matter under the *interoperability* doctrine
(17 U.S.C. § 1201(f) / EU Software Directive Art. 6). This project
distributes only the interoperability implementation, not any code from
OpenRazer.

## macOS system frameworks

This app links against Apple's system frameworks (AppKit, SwiftUI, IOKit,
Combine, CoreBluetooth, UserNotifications, ServiceManagement, Carbon).
Those frameworks are © Apple Inc. and used under the standard macOS SDK
license terms.

## Fonts, icons

The tray-bar mouse icon and the SF Symbols used throughout the UI are
Apple SF Symbols (system-provided) — usage governed by the SF Symbols
license.

The `Resources/mouse.png` diagram image is a product photograph — provided
solely to render an accurate diagram of the physical button layout for the
remap UI. If Razer would prefer this asset not be redistributed, please
file an issue and the maintainer will replace it with a hand-drawn
diagram.
