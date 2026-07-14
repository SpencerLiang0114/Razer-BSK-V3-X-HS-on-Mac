import Foundation
import AppKit
import IOKit
import IOKit.hid

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
        IOHIDManagerRegisterInputValueCallback(hidManager, { ctx, _, _, _ in
            // The IOHIDManager matching dictionary above already narrows
            // callbacks to Basilisk VID/PIDs, so per-event re-verification
            // is pure overhead. If a matching-dict change ever broadens the
            // filter, restore the isBasilisk() check here.
            guard let ctx else { return }
            Unmanaged<InputActivity>.fromOpaque(ctx).takeUnretainedValue().forwardOnMain()
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

    // MARK: - Private

    /// Coalesce fire-again bursts and hop to main. Both signal sources
    /// go through here.
    private func forwardOnMain() {
        let now = Date()
        if now.timeIntervalSince(lastForwarded) < minInterval { return }
        lastForwarded = now
        DispatchQueue.main.async { [weak self] in self?.onActivity?() }
    }

    /// Cheap check inside the input-value callback hot path. Delegates to
    /// `Hotplug.isDongle` / `isBluetoothBasilisk` so both monitors match
    /// the same devices — otherwise BT input can fire without our
    /// classify seeing the same device (or vice versa) and the two
    /// signals drift out of sync.
    private static func isBasilisk(_ dev: IOHIDDevice) -> Bool {
        Hotplug.isDongle(dev) || Hotplug.isBluetoothBasilisk(dev)
    }
}
