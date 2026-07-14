import Foundation
import IOKit
import IOKit.hid

/// Instant plug/unplug + Bluetooth reachability detection via IOHIDManager.
///
/// Two important behaviours beyond the basic add/remove callbacks:
///
/// 1. **BT-first classification.** When a user switches the mouse from
///    dongle to Bluetooth mode, the physical dongle often stays enumerated
///    with a phantom mouse endpoint (Razer's dongle firmware doesn't drop
///    its HID interface on mode-switch). Blindly preferring dongle would
///    show "Idle" — vendor probes silently fail because the mouse isn't
///    actually listening on that radio, and `awake` never sets because
///    input events flow over BT. We prefer BT when both are present, which
///    reflects the mode the user actually selected on the mouse.
///
/// 2. **Sticky-BT hysteresis.** Bluetooth HID devices intermittently drop
///    from `IOHIDManagerCopyDevices` when the radio enters low-power. A
///    raw enumeration would flap the UI between "Bluetooth" and
///    "Disconnected". A BT→none transition needs the device to stay
///    absent for `btDisconnectSettle` seconds before we downgrade.
///
/// Matching is deliberately **broad**: we match every HID device the
/// system enumerates and filter down in code by product-name substring.
/// The Basilisk over Bluetooth may enumerate under a variety of primary
/// usage pages (mouse / consumer / keyboard) depending on macOS build and
/// how the BT stack chose to categorise the multi-collection descriptor,
/// so restricting the match ahead of time is how we silently lose the BT
/// device and end up misclassifying as `.dongle`. Cost of the broad
/// match: one callback per USB device plug/unplug system-wide. Trivial.
final class Hotplug {
    /// Fires when the debounced connection state changes.
    var onChange: ((ConnectionKind) -> Void)?
    private(set) var kind: ConnectionKind = .none
    /// Convenience for callers that only care "is anything reachable."
    var present: Bool { kind != .none }

    private let manager: IOHIDManager
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.45
    /// Longer settle window for a BT→none downgrade specifically. The
    /// mouse's BLE radio takes long naps (up to ~10 s) even when
    /// perfectly reachable and paired, so anything shorter turns the
    /// tray icon into a strobe light. Only mark the mouse truly gone
    /// after 12 s of continuous absence — Hotplug.none is what tears
    /// down GATT + BT battery polling, so we want to be sure.
    private let btDisconnectSettle: TimeInterval = 12.0

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match EVERYTHING. Empty dict = "no restrictions" in IOHIDManager
        // semantics. See class-level note on why we don't pre-filter.
        IOHIDManagerSetDeviceMatching(manager, [:] as CFDictionary)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<Hotplug>.fromOpaque(ctx).takeUnretainedValue().schedulePresenceReconcile()
        }, opaque)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<Hotplug>.fromOpaque(ctx).takeUnretainedValue().schedulePresenceReconcile()
        }, opaque)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        let initial = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        kind = classify(devs: initial)
        logSnapshot(devs: initial, classifiedAs: kind, note: "initial", verbose: true)
    }

    deinit {
        debounceTimer?.invalidate()
        // Clear the C callbacks first so the manager can't call back into
        // a freed Hotplug during teardown. Passing nil context is the
        // documented way to unregister.
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Log Basilisk-like devices with full detail. On `verbose=true` (init +
    /// state change) we also log the top few non-Basilisk HIDs so debugging
    /// "why isn't my mouse detected" doesn't require me to look at raw
    /// `ioreg` output — the answer is usually right in `/tmp/bskv3xhs.log`.
    private func logSnapshot(devs: Set<IOHIDDevice>, classifiedAs k: ConnectionKind, note: String, verbose: Bool = false) {
        var lines: [String] = []
        var otherRazerLike: [String] = []
        for d in devs {
            let vid = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            let name = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "<unnamed>"
            let manu = (IOHIDDeviceGetProperty(d, kIOHIDManufacturerKey as CFString) as? String) ?? ""
            let usagePage = (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
            let usage = (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
            let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? "?"

            let lower = name.lowercased() + " " + manu.lowercased()
            if lower.contains("basilisk") || lower.contains("razer") || vid == Int(Razer.vendorID) {
                lines.append(String(
                    format: "  · \"%@\" (manu=%@, VID 0x%04X, PID 0x%04X, up 0x%02X us 0x%02X, transport=%@)",
                    name, manu, vid, pid, usagePage, usage, transport
                ))
            } else if verbose && otherRazerLike.count < 6 {
                otherRazerLike.append(String(
                    format: "  · (unrelated) \"%@\" transport=%@",
                    name, transport
                ))
            }
        }
        var msg = "hotplug \(note): devices=\(devs.count) classified=\(k.rawValue)"
        if !lines.isEmpty { msg += "\n" + lines.joined(separator: "\n") }
        else               { msg += " (no basilisk / razer devices matched)" }
        if verbose && !otherRazerLike.isEmpty {
            msg += "\n  (other HIDs sample):\n" + otherRazerLike.joined(separator: "\n")
        }
        Log.info(msg)
    }

    private func schedulePresenceReconcile() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let devs = (IOHIDManagerCopyDevices(self.manager) as? Set<IOHIDDevice>) ?? []
            let target = self.classify(devs: devs)
            // Only go verbose (include unrelated HID sample) when the target
            // differs from what we currently believe — the noisy "same as
            // before" reconciles don't need the wide snapshot. The debounce
            // timer restarted below is what actually collapses spurious
            // present→absent→present sequences into a single onChange.
            if target != self.kind {
                self.logSnapshot(devs: devs, classifiedAs: target, note: "reconcile", verbose: true)
            }
            self.armDebounce(target: target)
        }
    }

    /// Turn the current live device set into a single ConnectionKind.
    ///
    /// BT wins if a BT-flavoured Basilisk is present: the mouse is in BT
    /// mode, so even if the dongle also enumerates a phantom mouse
    /// endpoint the vendor protocol won't respond and treating it as
    /// dongle would just show a permanently-Idle tray.
    ///
    /// Matching philosophy — permissive by design:
    ///   • **Dongle**: exact VID+PID + `USB` transport. Prevents the BT
    ///     endpoint from being misread as dongle just because Razer happens
    ///     to reuse the VID number.
    ///   • **Bluetooth**: product name or manufacturer name mentions
    ///     "basilisk" (case-insensitive) AND transport isn't USB. Any
    ///     usage page is accepted so we catch consumer/keyboard/mouse
    ///     collections that the BT stack might expose primarily.
    private func classify(devs: Set<IOHIDDevice>) -> ConnectionKind {
        var sawDongle = false
        var sawBluetooth = false
        for d in devs {
            if Self.isDongle(d) { sawDongle = true; continue }
            if Self.isBluetoothBasilisk(d) { sawBluetooth = true }
        }
        if sawBluetooth { return .bluetooth }
        if sawDongle    { return .dongle }
        return .none
    }

    /// Wired dongle: exact VID+PID over a USB transport.
    static func isDongle(_ d: IOHIDDevice) -> Bool {
        let vid = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? ""
        return vid == Int(Razer.vendorID) && pid == Int(Razer.productID)
            && transport.uppercased().contains("USB")
    }

    /// Bluetooth Basilisk. Primary match is exact VID+PID over a Bluetooth
    /// transport — confirmed against the live device. Substring fallback
    /// on `basilisk` / `bsk v3 x` (case-insensitive) so a firmware variant
    /// with a different PID still gets caught, provided macOS labels it
    /// with a Basilisk-ish name.
    static func isBluetoothBasilisk(_ d: IOHIDDevice) -> Bool {
        let vid = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? ""
        let isBT = transport.uppercased().contains("BLUETOOTH")
        if vid == Int(Razer.bluetoothVendorID) && pid == Int(Razer.bluetoothProductID) && isBT {
            return true
        }
        guard isBT else { return false }
        let name = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? ""
        let manu = (IOHIDDeviceGetProperty(d, kIOHIDManufacturerKey as CFString) as? String) ?? ""
        let combined = (name + " " + manu).lowercased()
        return combined.contains("basilisk")
            || combined.contains("bsk v3 x")
    }

    private func armDebounce(target: ConnectionKind) {
        debounceTimer?.invalidate()
        let window: TimeInterval = (kind == .bluetooth && target == .none)
            ? btDisconnectSettle
            : debounceInterval
        debounceTimer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard target != self.kind else { return }
            Log.info("hotplug transition: \(self.kind.rawValue) → \(target.rawValue) (waited \(String(format: "%.2f", window))s)")
            self.kind = target
            self.onChange?(target)
        }
    }
}
