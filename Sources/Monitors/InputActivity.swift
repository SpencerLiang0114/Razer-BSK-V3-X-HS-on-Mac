import Foundation
import AppKit
import IOKit
import IOKit.hid
import Carbon.HIToolbox

/// Fires `onActivity` whenever the user is interacting with a mouse.
///
/// Uses two independent signal sources so a permission gap on one doesn't
/// blind us to the other:
///
/// 1. **`IOHIDManager` value callbacks** (primary) — matches any Razer or
///    "Basilisk V3 X" HID device and fires on every input value change
///    (movement, buttons, wheel). Precise: we know it was our device.
///    Requires *Input Monitoring* TCC — silently no-ops without it, which
///    is exactly what happens after every rebuild of a self-signed app.
///
/// 2. **`NSEvent` global monitor** (backup) — fires on mouse clicks and
///    discrete-wheel events system-wide. Does NOT require any TCC
///    permission for mouse events. Can't tell which physical device
///    generated the event, but if a Basilisk is currently paired and
///    someone is clicking, it's overwhelmingly likely them. This is the
///    signal that keeps the tray icon honest over Bluetooth after a
///    rebuild has reset Input Monitoring trust.
///
/// The two signals both call `onActivity`; `DeviceController.markAlive()`
/// is idempotent so double-firing is free. The NSEvent path is
/// throttled to 500 ms to avoid a mouseMoved firehose (we don't listen
/// for mouseMoved but future changes here shouldn't accidentally let it
/// through).
/// Records that the Basilisk itself just emitted a keyboard-page HID event.
///
/// A CGEventTap cannot tell which physical device produced a `keyDown` /
/// `flagsChanged` — a Control press from the mouse's firmware-remapped side
/// button and one from the user's real keyboard are byte-identical at that
/// layer. Matching a KeyTrigger on keycode alone therefore fires on BOTH,
/// which turns "button 4 switches Space" into "pressing Control anywhere
/// switches Space".
///
/// `InputActivity`'s IOHIDManager is matched to the Basilisk's VID/PID, so it
/// *does* know the source. It stamps the time here; the tap then only honors a
/// trigger when the mouse produced a matching HID event microseconds earlier.
/// Observed latency between the HID callback and the tap callback is under
/// 2 ms, so the window below is ~25× the real figure — generous enough to
/// never drop a genuine press, far too tight for an unrelated keystroke to
/// slip through.
@MainActor
enum MouseKeyboardEcho {
    /// How recently the mouse must have emitted a key for the tap to trust it.
    static let window: TimeInterval = 0.05

    private static var lastAt: Date = .distantPast
    private static var lastUsage: UInt32 = 0

    static func record(usage: UInt32) {
        lastAt = Date()
        lastUsage = usage
    }

    /// True when the mouse emitted a keyboard HID event within `window`.
    /// `expectedUsage` narrows it further when the trigger's keycode maps to a
    /// known HID usage; pass nil to accept any recent key from the mouse.
    static func sawRecently(expectedUsage: UInt32?) -> Bool {
        guard Date().timeIntervalSince(lastAt) <= window else { return false }
        guard let want = expectedUsage else { return true }
        return lastUsage == want
    }

    /// HID keyboard usage for a macOS virtual keycode, for the keys a Synapse
    /// remap actually produces (modifiers + function row). Returns nil for
    /// anything not in the table so matching falls back to "any recent key
    /// from the mouse" rather than silently refusing to match.
    static func hidUsage(forKeyCode code: UInt16) -> UInt32? {
        switch Int(code) {
        case kVK_Control:      return 0xE0
        case kVK_Shift:        return 0xE1
        case kVK_Option:       return 0xE2
        case kVK_Command:      return 0xE3
        case kVK_RightControl: return 0xE4
        case kVK_RightShift:   return 0xE5
        case kVK_RightOption:  return 0xE6
        case kVK_RightCommand: return 0xE7
        case kVK_F1:  return 0x3A;  case kVK_F2:  return 0x3B
        case kVK_F3:  return 0x3C;  case kVK_F4:  return 0x3D
        case kVK_F5:  return 0x3E;  case kVK_F6:  return 0x3F
        case kVK_F7:  return 0x40;  case kVK_F8:  return 0x41
        case kVK_F9:  return 0x42;  case kVK_F10: return 0x43
        case kVK_F11: return 0x44;  case kVK_F12: return 0x45
        case kVK_F13: return 0x68;  case kVK_F14: return 0x69
        case kVK_F15: return 0x6A;  case kVK_F16: return 0x6B
        case kVK_F17: return 0x6C;  case kVK_F18: return 0x6D
        case kVK_F19: return 0x6E;  case kVK_F20: return 0x6F
        default: return nil
        }
    }
}

final class InputActivity {
    var onActivity: (() -> Void)?

    private let hidManager: IOHIDManager
    /// Last time we forwarded activity — coalesces the HID callback burst
    /// (a single click can fire multiple element callbacks) so we don't
    /// queue a pile of main-actor tasks in the controller.
    private var lastForwarded: Date = .distantPast
    private let minInterval: TimeInterval = 0.4

    init() {
        // ── IOHIDManager (permission-gated, precise) ──────────────────
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Narrow the match to Basilisk VID/PID pairs (both dongle and BT
        // endpoints). System-wide, this eliminates the per-keystroke and
        // per-trackpad-tick callback fan-in that a wide-open matching
        // dictionary would incur — we were doing 3-4 IOHIDDeviceGetProperty
        // lookups per keyboard press just to reject the event. Firmware
        // variants with a different PID would silently drop from this HID
        // signal, but they're rare and the NSEvent global monitor below
        // still catches user clicks over Bluetooth without any TCC gate.
        let match: [[String: Any]] = [
            [kIOHIDVendorIDKey: Int(Razer.vendorID),
             kIOHIDProductIDKey: Int(Razer.productID)],
            [kIOHIDVendorIDKey: Int(Razer.bluetoothVendorID),
             kIOHIDProductIDKey: Int(Razer.bluetoothProductID)],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(hidManager, match as CFArray)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(hidManager, { ctx, _, _, value in
            // The IOHIDManager matching dictionary above already narrows
            // callbacks to Basilisk VID/PIDs, so per-event re-verification
            // is pure overhead. If a matching-dict change ever broadens the
            // filter, restore the isBasilisk() check here.
            guard let ctx else { return }
            let this = Unmanaged<InputActivity>.fromOpaque(ctx).takeUnretainedValue()
            this.recordEchoIfKeyboard(value)
            this.logButtonIfDebug(value)
            this.forwardOnMain()
        }, opaque)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))

        // (No NSEvent fallback.) The old design used a system-wide
        // `NSEvent.addGlobalMonitorForEvents` alongside the HID manager to
        // stay useful without Input Monitoring — but that fired on ANY
        // mouse-down event system-wide, including trackpad clicks. Effect:
        // if the user woke the Mac with the trackpad while the Basilisk
        // was physically OFF, the tray would still flip to "awake" and
        // show a stale battery. IOHIDManager above is now the sole source,
        // filtered strictly to Basilisk VID/PID pairs, so awake/asleep
        // tracks the actual mouse's radio traffic. Vendor commands need
        // Input Monitoring anyway; if it's denied, awake detection is
        // broken alongside everything else and the user gets a clear
        // permissions error, not silent lies from the tray.
    }

    deinit {
        IOHIDManagerRegisterInputValueCallback(hidManager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - HID-layer button diagnostics

    /// Log physical button presses as the *hardware* reports them, below
    /// CGEventTap.
    ///
    /// This exists because "button 4 does nothing" has two very different
    /// causes that look identical from the event-tap side:
    ///
    ///   1. The mouse never sent anything (onboard profile disabled the
    ///      button, or remapped it to something that emits no HID button) —
    ///      nothing downstream can possibly fix that.
    ///   2. The mouse sent it fine, but another process's event tap
    ///      consumed the event before ours ran, or macOS assigned it a
    ///      button number we don't classify.
    ///
    /// The event tap only ever sees case 2, so with tap logging alone both
    /// cases produce an empty log. Reading the HID element here settles it:
    /// if the line below appears but no matching `tap saw button=` line
    /// does, the mouse is fine and the event is being lost above us.
    ///
    /// Debug-gated and button-only. Movement and wheel deltas fire this
    /// callback constantly, so we filter to usage page 0x09 (Button) before
    /// doing any string work, and never log coordinates.
    private func logButtonIfDebug(_ value: IOHIDValue?) {
        guard Log.debugEnabled, let value else { return }
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let v = IOHIDValueGetIntegerValue(value)

        // Movement and wheel deltas fire this callback constantly. Drop the
        // axes (X/Y/Wheel/AC-Pan) so the log stays readable, and drop the
        // release edge of everything else's zero value only for axes.
        //
        // Deliberately NOT filtered to the Button page (0x09). A Razer mouse
        // whose onboard profile was remapped by Synapse emits the affected
        // side buttons as *keystrokes* on one of its two Keyboard-usage HID
        // interfaces (page 0x07), or as consumer keys (page 0x0C) — not as
        // buttons. Filtering to 0x09 made that case look byte-for-byte
        // identical to "the mouse sent nothing at all", which are opposite
        // diagnoses with opposite fixes. Log every page and let the reader
        // tell them apart.
        if page == 0x01 {
            // Generic Desktop: 0x30=X, 0x31=Y, 0x38=Wheel. Axes only.
            if usage == 0x30 || usage == 0x31 || usage == 0x38 { return }
        }
        if page == 0x0C && usage == 0x0238 { return }   // AC Pan (h-scroll)

        let pageName: String
        switch page {
        case 0x01: pageName = "GenericDesktop"
        case 0x07: pageName = "Keyboard"
        case 0x09: pageName = "Button"
        case 0x0C: pageName = "Consumer"
        default:   pageName = "0x" + String(page, radix: 16)
        }
        if page == 0x09 {
            // HID button usage N maps to macOS buttonNumber N-1, which is
            // what ButtonMap.classify() switches on — print both so the two
            // logs line up directly.
            Log.debug(.hid, "HID button usage=\(usage) (macOS buttonNumber=\(Int(usage) - 1)) \(v != 0 ? "DOWN" : "up")")
        } else {
            // A non-Button page from the *mouse's* own HID interfaces. This
            // is the firmware-remap signature. Note this cannot capture the
            // user's real typing: the IOHIDManager match is restricted to
            // the Basilisk's VID/PID, so these only fire for input the mouse
            // itself generated.
            Log.debug(.hid, "HID non-button: page=\(pageName)(0x\(String(page, radix: 16))) usage=0x\(String(usage, radix: 16)) value=\(v) — firmware-remapped button?")
        }
    }

    /// Stamp keyboard-page presses from the mouse so the event tap can tell a
    /// firmware-remapped side button apart from the user's real keyboard.
    /// Press edge only — a release carries no information the tap needs, and
    /// stamping it would leave the window open past the button's lifetime.
    private func recordEchoIfKeyboard(_ value: IOHIDValue?) {
        guard let value else { return }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == 0x07 else { return }
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }
        let usage = IOHIDElementGetUsage(element)
        // The keyboard report's array elements surface a 0xffffffff sentinel
        // alongside the real usage; ignore it so it can't overwrite the stamp.
        guard usage != 0xffffffff else { return }
        // Record SYNCHRONOUSLY. This callback is already on the main runloop
        // (see `IOHIDManagerScheduleWithRunLoop(…, CFRunLoopGetMain())` in
        // init), and so is ButtonMap's CGEventTap callback. Hopping through
        // `DispatchQueue.main.async` here deferred the stamp to the *next*
        // runloop turn, so the tap's keyDown/flagsChanged handler could run
        // first, find no echo, and discard a genuine firmware-remapped side
        // button press as "real keyboard" — the exact case KeyTrigger exists
        // to catch. The doc comment above measures tap latency at under 2 ms,
        // which is comfortably inside one runloop turn, so the race was live
        // and would surface as an intermittently dead side button.
        //
        // `assumeIsolated` rather than a Task hop: MouseKeyboardEcho is
        // @MainActor and this C callback is nonisolated, but the runloop
        // scheduling above makes main-thread execution a structural
        // guarantee, not a hope. Same pattern as ButtonMap.armTrustTimer.
        MainActor.assumeIsolated { MouseKeyboardEcho.record(usage: usage) }
    }

    // MARK: - Private

    /// Coalesce fire-again bursts and hop to main. Both signal sources
    /// go through here.
    private func forwardOnMain() {
        let now = Date()
        if now.timeIntervalSince(lastForwarded) < minInterval { return }
        lastForwarded = now
        DispatchQueue.main.async { [weak self] in self?.onActivity?() }
    }
}
