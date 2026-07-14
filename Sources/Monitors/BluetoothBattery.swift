import Foundation
import IOKit
import IOKit.hid
import IOKit.ps

/// Read the battery percentage macOS has cached for a Bluetooth HID mouse.
///
/// Over the 2.4 GHz dongle we go through Razer's vendor protocol — over
/// Bluetooth that protocol isn't exposed, so we lean on the value macOS
/// itself already publishes for the paired device. Which registry entry
/// holds the value depends on the driver stack and the macOS version:
/// sometimes on the `AppleDeviceManagementHIDEventService`, sometimes on an
/// `IOBluetoothHIDDriver`, sometimes on the `IOBluetoothDevice` parent, and
/// on newer builds only via the public PowerSources subsystem.
///
/// Strategies are tried in stability order — IOPowerSources first because
/// it's the public API Apple itself uses to render the Bluetooth mouse
/// battery pill in System Settings, and it stays populated across macOS
/// updates that shuffle private IORegistry keys around. IORegistry key
/// spelunking is the fallback for older builds. When every strategy misses,
/// a one-shot diagnostic dump to the log names every battery-flavoured key
/// visible in the registry so the miss can be closed without a rebuild
/// blindfolded.
enum BluetoothBattery {
    /// Known property keys used across macOS versions / driver stacks to
    /// expose a parsed battery percentage. Kept broad so a new macOS
    /// release that renames the key doesn't silently blank the pill.
    private static let batteryKeys: [String] = [
        "BatteryPercent",
        "BatteryPercentSingle",
        "BatteryPercentCombined",
        "BatteryPercentUnified",
        "BatteryPercentCase",
        "IOBatteryPercent",
        "kIOPSCurrentCapacity",
        "kHIDBatteryStrengthKey",
        "HIDBatteryCurrentCapacity",
        "SelfBatteryPercent",
        "BatteryLevel",
    ]

    static func read() -> Int? {
        // Strategy 1: public IOPowerSources API. Same data source macOS
        // uses for the battery pill in System Settings → Bluetooth. Most
        // stable across macOS versions.
        if let v = readFromIOPowerSources() { return v }
        // Strategy 2: query the IOHIDDevice for battery-flavoured props
        // directly. Some BT HID drivers expose the parsed percentage right
        // on the HID device itself.
        if let v = readFromHIDDeviceDirect() { return v }
        // Strategy 3: walk the IORegistry parent chain from any Basilisk
        // HID device — the BT HID driver / IOBluetoothDevice entries live
        // upstream of the HID interface.
        if let v = readFromHIDDeviceParents() { return v }
        // Strategy 4: enumerate every IOBluetoothDevice / HID driver
        // service in the registry, match by name, read battery.
        if let v = readFromBluetoothServices() { return v }
        // All strategies missed. Dump ONCE so future debug rounds don't
        // guess — actual property keys / paths appear in the log.
        dumpDiagnosticsOnce()
        return nil
    }

    // MARK: - Strategy 1: IOPowerSources (public API)

    /// Ask macOS's PowerSources subsystem for a Basilisk-named source and
    /// read its `Current Capacity`. This is what `System Settings > Bluetooth`
    /// uses to render its own battery pill for HID mice, so it's the most
    /// reliable path across macOS versions and driver stacks.
    private static func readFromIOPowerSources() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for src in sources {
            guard let dict = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            let name = (dict[kIOPSNameKey] as? String) ?? ""
            let lower = name.lowercased()
            guard lower.contains("basilisk") || lower.contains("bsk v3 x") || lower.contains("bsk-v3-x")
            else { continue }
            // Current Capacity here is already 0..100 for HID accessories.
            if let cap = dict[kIOPSCurrentCapacityKey] as? Int { return clamp(cap) }
            if let cap = (dict[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue { return clamp(cap) }
        }
        return nil
    }

    // MARK: - Strategy 2: IOHIDDevice's own properties

    private static func readFromHIDDeviceDirect() -> Int? {
        forEachBasiliskHIDDevice { dev in
            for key in batteryKeys {
                if let val = IOHIDDeviceGetProperty(dev, key as CFString) {
                    if let n = (val as? Int) ?? (val as? NSNumber)?.intValue {
                        return clamp(n)
                    }
                }
            }
            return nil as Int?
        }
    }

    // MARK: - Strategy 3: walk parents from a Basilisk HID

    private static func readFromHIDDeviceParents() -> Int? {
        forEachBasiliskHIDDevice { dev in
            walkParentsForBattery(hidDevice: dev)
        }
    }

    private static func walkParentsForBattery(hidDevice: IOHIDDevice) -> Int? {
        var service: io_service_t = IOHIDDeviceGetService(hidDevice)
        guard service != IO_OBJECT_NULL else { return nil }
        IOObjectRetain(service)
        for _ in 0..<32 {
            for key in batteryKeys {
                if let v = readIntProperty(service, key) { IOObjectRelease(service); return clamp(v) }
            }
            var parent: io_service_t = 0
            let rc = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
            IOObjectRelease(service)
            guard rc == KERN_SUCCESS, parent != IO_OBJECT_NULL else { return nil }
            service = parent
        }
        IOObjectRelease(service)
        return nil
    }

    // MARK: - Strategy 4: enumerate BT / HID-driver services

    /// Registry classes that macOS uses for the driver-side entries where
    /// a paired BT HID device's battery lands. IOKit matches on class name
    /// (case-sensitive) — enumerating each and filtering by device name
    /// covers most of the plausible driver stacks.
    private static let btServiceClasses: [String] = [
        "IOBluetoothDevice",
        "AppleDeviceManagementHIDEventService",
        "IOBluetoothHIDDriver",
        "AppleBluetoothHIDGenericDevice",
        "AppleBluetoothHIDDevice",
        "BluetoothHCIControllerUSBTransport",  // last resort — walk from here
    ]

    /// String keys used across drivers to store the human-visible device
    /// name. We match "Basilisk" or "BSK V3 X" in any of these.
    private static let nameKeys: [String] = [
        "DeviceName", "Product", "kIOHIDProductKey", "Name", "LocalName",
    ]

    private static func readFromBluetoothServices() -> Int? {
        for cls in btServiceClasses {
            if let v = readFromServiceClass(cls) { return v }
        }
        return nil
    }

    private static func readFromServiceClass(_ className: String) -> Int? {
        guard let matching = IOServiceMatching(className) else { return nil }
        var iter: io_iterator_t = 0
        let rc = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard rc == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let entry = IOIteratorNext(iter), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            if !entryMentionsBasilisk(entry) { continue }
            for key in batteryKeys {
                if let v = readIntProperty(entry, key) { return clamp(v) }
            }
            // Battery might be on a child of this service (e.g.
            // IOBluetoothHIDDriver → IOHIDInterface). Descend a few levels.
            if let v = walkChildrenForBattery(entry, depth: 3) { return v }
        }
        return nil
    }

    private static func walkChildrenForBattery(_ entry: io_service_t, depth: Int) -> Int? {
        guard depth > 0 else { return nil }
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(childIter) }
        while case let child = IOIteratorNext(childIter), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            for key in batteryKeys {
                if let v = readIntProperty(child, key) { return clamp(v) }
            }
            if let v = walkChildrenForBattery(child, depth: depth - 1) { return v }
        }
        return nil
    }

    // MARK: - Diagnostics

    private static var didDumpDiagnostics = false
    private static func dumpDiagnosticsOnce() {
        if didDumpDiagnostics { return }
        didDumpDiagnostics = true
        var lines: [String] = ["BluetoothBattery: no strategy found a value. Registry dump for adjustment:"]
        // Log IOPS power-source names too — this tells us if the mouse is
        // even visible to the PowerSources subsystem (Strategy 1 preflight).
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            lines.append("IOPowerSources snapshot: \(sources.count) source(s)")
            for src in sources {
                if let dict = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] {
                    let name = (dict[kIOPSNameKey] as? String) ?? "?"
                    let cap = dict[kIOPSCurrentCapacityKey].map { "\($0)" } ?? "-"
                    lines.append("  IOPS: name=\"\(name)\" capacity=\(cap)")
                }
            }
        }
        forEachBasiliskHIDDevice { dev in
            let name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "?"
            lines.append("HID device: \(name)")
            var service: io_service_t = IOHIDDeviceGetService(dev)
            guard service != IO_OBJECT_NULL else { return nil as Int? }
            IOObjectRetain(service)
            for level in 0..<8 {
                var nameBuf = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(service, &nameBuf)
                let clsName = String(cString: nameBuf)
                lines.append("  L\(level): class=\(clsName)")
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    for (k, v) in dict where isBatteryish(k) {
                        lines.append("    \(k) = \(v)")
                    }
                }
                var parent: io_service_t = 0
                let rc = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
                IOObjectRelease(service)
                if rc != KERN_SUCCESS || parent == IO_OBJECT_NULL {
                    // Owning reference already released — clear the local
                    // so the post-loop release below doesn't double-release.
                    service = IO_OBJECT_NULL
                    break
                }
                service = parent
            }
            if service != IO_OBJECT_NULL { IOObjectRelease(service) }
            return nil as Int?
        }
        Log.warn(lines.joined(separator: "\n"))
    }

    private static func isBatteryish(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("batter") || lower.contains("power") || lower.contains("capac")
    }

    // MARK: - Helpers

    /// Enumerate every BT-side Basilisk HID (skipping the wired dongle —
    /// its battery is read via the Razer vendor protocol elsewhere).
    /// Body returns nil to continue, non-nil to short-circuit.
    @discardableResult
    private static func forEachBasiliskHIDDevice(_ body: (IOHIDDevice) -> Int?) -> Int? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [:] as CFDictionary)
        guard let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !devs.isEmpty else { return nil }
        for d in devs {
            guard Hotplug.isBluetoothBasilisk(d) else { continue }
            if let hit = body(d) { return hit }
        }
        return nil
    }

    private static func entryMentionsBasilisk(_ entry: io_service_t) -> Bool {
        for k in nameKeys {
            if let name = IORegistryEntryCreateCFProperty(entry, k as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                let lower = name.lowercased()
                if lower.contains("basilisk") || lower.contains("bsk v3 x") { return true }
            }
        }
        return false
    }

    private static func readIntProperty(_ entry: io_service_t, _ key: String) -> Int? {
        guard let val = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        else { return nil }
        if let n = val as? Int { return n }
        if let n = val as? NSNumber { return n.intValue }
        return nil
    }

    private static func clamp(_ n: Int) -> Int? {
        // IORegistry sometimes reports the raw byte (0..255) instead of a
        // percent — if the number is > 100 assume 0..255 scale and rescale.
        if n < 0 { return nil }
        if n <= 100 { return n }
        if n <= 255 { return Int((Double(n) / 255.0 * 100.0).rounded()) }
        return nil
    }
}
