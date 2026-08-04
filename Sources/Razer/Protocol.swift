import Foundation

// ─── Razer HID protocol — pure logic, no I/O ─────────────────────────
// 90-byte razer_report frame. CRC = XOR of bytes 2..87. Transaction id 0x1F
// is the HyperSpeed dongle protocol used by the Basilisk V3 X HyperSpeed.
// VARSTORE = 0x01 writes to onboard memory so changes survive sleep/replug.

enum Razer {
    // ─── Dongle (2.4 GHz HyperSpeed, wired) ──────────────────────────
    static let vendorID:  UInt16 = 0x1532
    static let productID: UInt16 = 0x00B9      // Basilisk V3 X HyperSpeed
    static let transactionID: UInt8 = 0x1F
    static let reportLen = 90

    // ─── Bluetooth Low Energy ────────────────────────────────────────
    // On BLE the mouse enumerates with a NON-Razer VID (0x068E) and a
    // different PID from the dongle. Confirmed against a live device via
    // /tmp/bskv3xhs.log dump:
    //   "BSK V3 X HS" (manu=Razer, VID 0x068E, PID 0x00BA, transport=BLE)
    // The product-string uses Razer's internal abbreviation "BSK", not
    // the marketing name "Basilisk", so substring-matching alone was the
    // reason the app misclassified BT-only sessions as disconnected.
    static let bluetoothVendorID:  UInt16 = 0x068E
    static let bluetoothProductID: UInt16 = 0x00BA

    enum Storage: UInt8 { case ram = 0x00, onboard = 0x01 }

    enum ResponseStatus: UInt8 {
        case busy = 0x01
        case success = 0x02
        case failure = 0x03
        case timeout = 0x04
        case notSupported = 0x05
    }

    /// Build a 90-byte razer_report frame from a command class + id + args.
    static func frame(class cls: UInt8, id: UInt8, args: [UInt8] = []) -> [UInt8] {
        precondition(args.count <= 80)
        var r = [UInt8](repeating: 0, count: reportLen)
        r[1] = transactionID
        r[5] = UInt8(args.count)
        r[6] = cls
        r[7] = id
        for (i, b) in args.enumerated() { r[8 + i] = b }
        r[88] = crc(r)
        return r
    }

    static func crc(_ report: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for i in 2..<88 { c ^= report[i] }
        return c
    }

    struct Parsed {
        let status: UInt8
        let cls: UInt8
        let id: UInt8
        let args: [UInt8]                      // 80 bytes
        let crcOK: Bool
    }

    static func parse(_ buf: [UInt8]) -> Parsed? {
        // Some HID stacks prepend a report ID byte — accept 90 or 91.
        let offset = (buf.count == reportLen + 1) ? 1 : 0
        guard buf.count >= reportLen + offset else { return nil }
        let r = Array(buf[offset..<(offset + reportLen)])
        return Parsed(
            status: r[0], cls: r[6], id: r[7],
            args: Array(r[8..<88]),
            crcOK: r[88] == crc(r)
        )
    }

    // ─── Command builders ─────────────────────────────────────────────

    static func firmwareRead() -> [UInt8] { frame(class: 0x00, id: 0x81, args: [0, 0]) }
    static func serialRead() -> [UInt8]   { frame(class: 0x00, id: 0x82, args: Array(repeating: 0, count: 22)) }
    static func batteryRead() -> [UInt8]  { frame(class: 0x07, id: 0x80, args: [0, 0]) }

    // ─── Device mode (the Synapse "driver mode" latch) ────────────────
    //
    // Razer mice have a global mode byte that decides HOW button presses
    // leave the device:
    //
    //   0x00 — Normal / hardware mode. The mouse emits standard HID mouse
    //          reports. macOS turns side-button presses into
    //          `otherMouseDown` with buttonNumber 3 / 4, which is the only
    //          thing our CGEventTap can see.
    //   0x03 — Driver mode. The mouse stops emitting standard HID reports
    //          for the extra buttons and instead ships raw button state
    //          over the *vendor* interface, expecting a driver (Synapse)
    //          to read it and decide what to do. With no Synapse running,
    //          those presses go nowhere: macOS never generates an event,
    //          so no event tap — ours or anyone's — can observe them.
    //   0x02 — Undocumented factory-test mode. OpenRazer explicitly blocks
    //          writing it and so do we.
    //
    // Synapse sets 0x03 when it takes over a device. The latch lives in the
    // mouse, not the host, so a mouse that was last used with Synapse on
    // Windows arrives on macOS still in driver mode — side buttons dead,
    // left/right/wheel fine (those stay on the boot-protocol path). That is
    // exactly the "I used real Synapse before and now buttons 4/5 do
    // nothing" failure, and it survives re-pairing and reboots because it's
    // stored on the device.
    //
    // Wire format matches OpenRazer's razer_chroma_standard_set_device_mode
    // / _get_device_mode: class 0x00, id 0x04 (write) / 0x84 (read),
    // data_size 0x02, args = [mode, param]. `param` is always 0x00.
    enum DeviceMode: UInt8 {
        case normal = 0x00
        case factoryTest = 0x02
        case driver = 0x03

        var label: String {
            switch self {
            case .normal:      return "normal"
            case .factoryTest: return "factory-test"
            case .driver:      return "driver (Synapse)"
            }
        }
    }

    static func deviceModeRead() -> [UInt8] { frame(class: 0x00, id: 0x84, args: [0, 0]) }

    /// Write the device mode. `.factoryTest` is coerced to `.normal` — it
    /// makes the buttons emit keystrokes and OpenRazer blocks it too.
    static func deviceModeWrite(_ mode: DeviceMode) -> [UInt8] {
        let m: UInt8 = (mode == .factoryTest) ? DeviceMode.normal.rawValue : mode.rawValue
        return frame(class: 0x00, id: 0x04, args: [m, 0x00])
    }

    // Idle sleep timer — how many minutes of no input before the mouse
    // powers down its radio. OpenRazer: cls=0x07 id=0x03, 2-byte value in
    // minutes (big-endian). Read: cls=0x07 id=0x83.
    static func idleTimeRead() -> [UInt8] { frame(class: 0x07, id: 0x83, args: [0, 0]) }
    static func idleTimeWrite(minutes: Int) -> [UInt8] {
        let m = UInt16(max(1, min(15, minutes)) * 60)          // seconds
        return frame(class: 0x07, id: 0x03, args: [UInt8((m >> 8) & 0xFF), UInt8(m & 0xFF)])
    }

    static func pollRateRead() -> [UInt8] { frame(class: 0x00, id: 0x85, args: [0]) }
    static func pollRateWrite(_ hz: Int) -> [UInt8] {
        let byte: UInt8 = { switch hz { case 1000: return 0x01; case 500: return 0x02; case 125: return 0x08; default: return 0x01 } }()
        return frame(class: 0x00, id: 0x05, args: [byte])
    }
    static func pollRateFromByte(_ b: UInt8) -> Int? {
        switch b { case 0x01: return 1000; case 0x02: return 500; case 0x08: return 125; default: return nil }
    }

    static func dpiRead(storage: Storage = .onboard) -> [UInt8] {
        frame(class: 0x04, id: 0x85, args: [storage.rawValue, 0, 0, 0, 0, 0, 0])
    }
    static func dpiWrite(_ x: Int, _ y: Int, storage: Storage = .onboard) -> [UInt8] {
        let cx = UInt16(max(100, min(45000, x))), cy = UInt16(max(100, min(45000, y)))
        return frame(class: 0x04, id: 0x05, args: [storage.rawValue,
            UInt8((cx >> 8) & 0xFF), UInt8(cx & 0xFF),
            UInt8((cy >> 8) & 0xFF), UInt8(cy & 0xFF), 0, 0])
    }

    static func dpiStagesRead(storage: Storage = .onboard) -> [UInt8] {
        var args: [UInt8] = [storage.rawValue]; while args.count < 0x26 { args.append(0) }
        return frame(class: 0x04, id: 0x86, args: args)
    }
    static func dpiStagesWrite(active: Int, stages: [(x: Int, y: Int)], storage: Storage = .onboard) -> [UInt8] {
        precondition(!stages.isEmpty && stages.count <= 5)
        // Clamp `active` into 1...stages.count here, at the protocol boundary,
        // the same way `dpiWrite` / `idleTimeWrite` / `lightingReactive` clamp
        // their own inputs. A bare `UInt8(active)` traps the process on a
        // negative or >255 value, and a value inside UInt8 but past the end of
        // the stage list is silently NAKed by the firmware — dropping the
        // whole DPI apply. Callers do clamp today; this makes the frame
        // builder correct on its own terms rather than by convention.
        let activeByte = UInt8(max(1, min(stages.count, active)))
        var args: [UInt8] = [storage.rawValue, activeByte, UInt8(stages.count)]
        for (i, s) in stages.enumerated() {
            let cx = UInt16(max(100, min(45000, s.x))), cy = UInt16(max(100, min(45000, s.y)))
            args += [UInt8(i + 1),
                UInt8((cx >> 8) & 0xFF), UInt8(cx & 0xFF),
                UInt8((cy >> 8) & 0xFF), UInt8(cy & 0xFF), 0, 0]
        }
        while args.count < 0x26 { args.append(0) }
        return frame(class: 0x04, id: 0x06, args: args)
    }

    // ─── Scroll-wheel LED (Basilisk V3 X HyperSpeed's only addressable LED) ───
    // Protocol matches OpenRazer's extended-matrix effect handlers for this
    // device (razer_chroma_extended_matrix_effect_*):
    //   class = 0x0F, cmd = 0x02 (effect) or 0x04/0x84 (brightness rw)
    //   args[0] = VARSTORE (0x01)
    //   args[1] = SCROLL_WHEEL_LED (0x01)
    //   args[2] = effect_id
    private static let scrollLED: UInt8 = 0x01

    /// Effect_id constants — used on the wire for the scroll wheel LED.
    enum LEDEffectID: UInt8 { case none = 0x00, `static` = 0x01, breath = 0x02, spectrum = 0x03, wave = 0x04, reactive = 0x05 }

    /// Wave direction. `0x02` = left→right, `0x01` = right→left, matching the
    /// OpenRazer clamp (0..2).
    enum WaveDirection: UInt8 { case leftToRight = 0x02, rightToLeft = 0x01 }

    // Every lighting write accepts a `storage` argument. `.ram` applies the
    // effect immediately but does NOT touch the mouse's onboard flash — safe
    // to spam during a ColorPicker drag. `.onboard` commits the state so it
    // survives sleep / re-plug — one flash write per drag settle is enough.
    static func lightingOff(storage: Storage = .onboard) -> [UInt8] {
        // data_size = 0x06: [store, led, effect, 0, 0, 0]
        return frame(class: 0x0F, id: 0x02, args: [storage.rawValue, scrollLED, LEDEffectID.none.rawValue, 0, 0, 0])
    }
    static func lightingStatic(r: UInt8, g: UInt8, b: UInt8, storage: Storage = .onboard) -> [UInt8] {
        // data_size = 0x09: [store, led, effect, 0, 0, 0x01, r, g, b]
        return frame(class: 0x0F, id: 0x02, args: [storage.rawValue, scrollLED, LEDEffectID.static.rawValue, 0, 0, 0x01, r, g, b])
    }
    static func lightingBreath(r: UInt8, g: UInt8, b: UInt8, storage: Storage = .onboard) -> [UInt8] {
        // data_size = 0x09 (single-color breath): [store, led, effect, 0x01, 0, 0x01, r, g, b]
        return frame(class: 0x0F, id: 0x02, args: [storage.rawValue, scrollLED, LEDEffectID.breath.rawValue, 0x01, 0, 0x01, r, g, b])
    }
    static func lightingSpectrum(storage: Storage = .onboard) -> [UInt8] {
        // data_size = 0x06
        return frame(class: 0x0F, id: 0x02, args: [storage.rawValue, scrollLED, LEDEffectID.spectrum.rawValue, 0, 0, 0])
    }
    static func lightingWave(direction: WaveDirection, storage: Storage = .onboard) -> [UInt8] {
        // data_size = 0x06: args[3]=direction, args[4]=0x28 (speed; lower = faster per driver)
        return frame(class: 0x0F, id: 0x02, args: [storage.rawValue, scrollLED, LEDEffectID.wave.rawValue, direction.rawValue, 0x28, 0])
    }
    static func lightingReactive(r: UInt8, g: UInt8, b: UInt8, speed: UInt8, storage: Storage = .onboard) -> [UInt8] {
        // data_size = 0x09: args[4]=speed (1..4), args[5]=0x01, args[6..8]=rgb
        let sp = max(1, min(4, speed))
        return frame(class: 0x0F, id: 0x02, args: [storage.rawValue, scrollLED, LEDEffectID.reactive.rawValue, 0, sp, 0x01, r, g, b])
    }

    /// Brightness on 0..255 (the wire scale).
    static func brightnessWrite(_ level: UInt8, storage: Storage = .onboard) -> [UInt8] {
        // class=0x0F cmd=0x04, data_size=0x03: [store, led, level]
        return frame(class: 0x0F, id: 0x04, args: [storage.rawValue, scrollLED, level])
    }
    static func brightnessRead() -> [UInt8] {
        // class=0x0F cmd=0x84, data_size=0x03: [store, led, 0]
        return frame(class: 0x0F, id: 0x84, args: [Storage.onboard.rawValue, scrollLED, 0])
    }
}
