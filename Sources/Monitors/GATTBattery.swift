import Foundation
@preconcurrency import CoreBluetooth

/// Read battery via the standard Bluetooth Low Energy GATT Battery
/// Service (0x180F / characteristic 0x2A19). This is Apple's own path for
/// rendering the Bluetooth battery pill in System Settings for HID
/// accessories — it works on any Mac where the BT stack advertises the
/// service, regardless of whether macOS's HID driver bothered to
/// republish the value into IORegistry.
///
/// The four IORegistry / IOPowerSources strategies in `BluetoothBattery`
/// depend on Apple's HID driver copying the GATT value into the OS-level
/// power-source subsystem. On some macOS builds that copy never happens,
/// or gets stripped by newer driver revisions — the mouse pairs, works
/// fine as a HID device, but battery-level look-ups return nothing.
///
/// This class opens the mouse directly through CoreBluetooth, discovers
/// the Battery Service, subscribes to the Battery Level characteristic,
/// and calls `onBattery` on the main actor whenever a fresh value lands.
/// Requires `NSBluetoothAlwaysUsageDescription` in Info.plist — macOS
/// prompts for Bluetooth permission on first use.
@MainActor
final class GATTBattery: NSObject {
    /// Fired with 0-100 whenever the peripheral pushes a fresh reading.
    var onBattery: ((Int) -> Void)?
    /// Fired with the Firmware Revision String from the standard Device
    /// Information Service. Populated once per successful discovery —
    /// value is stable across sessions so no need to re-read.
    var onFirmware: ((String) -> Void)?
    /// Fired with the Serial Number String from the DIS. Same one-shot
    /// semantics as `onFirmware`.
    var onSerial: ((String) -> Void)?

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel   = CBUUID(string: "2A19")
    /// Device Information Service — standard BLE service that exposes
    /// firmware version, serial number, manufacturer etc as read-only
    /// characteristics. Over the Razer dongle we get these via the
    /// vendor protocol; over BT we lean on this instead.
    private let deviceInfoService = CBUUID(string: "180A")
    private let firmwareRevision  = CBUUID(string: "2A26")
    private let serialNumber      = CBUUID(string: "2A25")

    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?

    /// Reconnect attempt count for exponential backoff on didDisconnect.
    /// Reset on any successful discovery or on radio poweredOn transition.
    fileprivate var reconnectAttempts: Int = 0

    override init() {
        super.init()
        // queue: nil → delegate callbacks arrive on main. We still stamp
        // each callback body with @MainActor so the compiler tracks it.
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    deinit {
        // manager.stopScan() and letting CoreBluetooth tear down the
        // peripheral connection on release is safe from any thread —
        // CBCentralManager retains internally until the queue drains.
    }

    /// Kick off a refresh. Fast path first (`retrieveConnectedPeripherals`)
    /// so we don't hit the radio when the mouse's Battery Service is
    /// already live; if that misses we fall through to an active scan.
    /// A HID-over-BLE device won't always show up as GATT-connected even
    /// though it's paired at the HID profile level, so the scan path
    /// tends to be the one that actually delivers on this mouse.
    func refresh() {
        let s = manager.state
        Log.info("gatt refresh: state=\(stateName(s))")
        guard s == .poweredOn else { return }
        // If we already have a live peripheral with the characteristic
        // subscribed, do nothing — notifications will push new values.
        if peripheral?.state == .connected { return }
        connectBasilisk()
        if peripheral == nil { startScan() }
    }

    /// Explicit re-read of the battery-level characteristic on the
    /// connected peripheral. Subscribe stays live across radio sleep, but
    /// some firmwares stop pushing after a nap — an explicit read
    /// guarantees UI freshness. Called from the DeviceController pump so
    /// all periodic reads live in one place. No-op when no peripheral is
    /// connected (the pump also triggers `refresh()` in that case).
    func rereadBatteryLevel() {
        guard manager.state == .poweredOn,
              let p = peripheral, p.state == .connected,
              let services = p.services else { return }
        for svc in services where svc.uuid == batteryService {
            for c in (svc.characteristics ?? []) where c.uuid == batteryLevel {
                p.readValue(for: c)
            }
        }
    }

    /// Actively scan for any advertiser broadcasting the Battery Service
    /// or a name matching this mouse. `scanForPeripherals(withServices:)`
    /// with `nil` catches devices that don't advertise the service in
    /// their scan response — we filter by name in `didDiscover`. Stopped
    /// after `scanDuration` seconds to keep the radio quiet.
    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        // nil service list = scan-everything; the mouse might not include
        // the Battery Service UUID in its BLE advertisement even though
        // the service is exposed post-connect. Filtering by name in the
        // callback is safer than pre-filtering by service UUID here.
        manager.scanForPeripherals(withServices: nil, options: nil)
        Log.info("gatt: started scan (name-filter, no service pre-filter)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.scanDuration * 1_000_000_000))
            guard let self, self.isScanning else { return }
            self.manager.stopScan()
            self.isScanning = false
            Log.info("gatt: scan window expired")
        }
    }

    private var isScanning = false
    private static let scanDuration: TimeInterval = 12

    private func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .unknown:      return "unknown"
        case .resetting:    return "resetting"
        case .unsupported:  return "unsupported"
        case .unauthorized: return "unauthorized (Info.plist / TCC?)"
        case .poweredOff:   return "poweredOff"
        case .poweredOn:    return "poweredOn"
        @unknown default:   return "?"
        }
    }

    // MARK: - Discovery

    private func connectBasilisk() {
        // Ask macOS for connected peripherals. Try three service UUIDs
        // in order — a HOGP mouse might not advertise Battery Service in
        // its scan-response even though it exposes the service post-
        // connect, and macOS's retrieveConnectedPeripherals only returns
        // peripherals whose advertisement matched one of the UUIDs.
        //   0x180F — Battery Service (what we ultimately want)
        //   0x1812 — Human Interface Device (mouse's primary profile)
        //   0x1800 — Generic Access (advertised by nearly all BLE devices)
        let probeServices: [CBUUID] = [
            batteryService,
            CBUUID(string: "1812"),
            CBUUID(string: "1800"),
        ]
        var found: CBPeripheral? = nil
        for svc in probeServices {
            let candidates = manager.retrieveConnectedPeripherals(withServices: [svc])
            Log.info("gatt: retrieveConnectedPeripherals(\(svc.uuidString)) returned \(candidates.count) candidate(s)")
            for p in candidates {
                Log.info("  · name=\"\(p.name ?? "?")\" id=\(p.identifier.uuidString) state=\(peripheralStateName(p.state))")
            }
            if let m = candidates.first(where: { p in
                let name = (p.name ?? "").lowercased()
                return name.contains("basilisk") || name.contains("bsk v3 x")
            }) {
                found = m
                break
            }
        }
        guard let p = found else {
            Log.info("gatt: no connected candidate matched — falling back to scan")
            return
        }
        Log.info("gatt: matched \"\(p.name ?? "?")\" state=\(peripheralStateName(p.state))")
        peripheral = p
        p.delegate = self
        if p.state == .connected {
            p.discoverServices([batteryService])
        } else {
            manager.connect(p, options: nil)
        }
    }

    private func peripheralStateName(_ s: CBPeripheralState) -> String {
        switch s {
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default:    return "?"
        }
    }

}

extension GATTBattery: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.info("gatt centralManagerDidUpdateState: \(self.stateName(state))")
            if state == .poweredOn {
                self.reconnectAttempts = 0
                self.refresh()
            } else {
                // Radio went away (airplane mode, powered off, resetting…).
                // Stop the scan and drop the peripheral so the next
                // poweredOn transition can re-discover cleanly; otherwise
                // `isScanning` stays true and `refresh()` skips forever.
                if self.isScanning { self.manager.stopScan(); self.isScanning = false }
                self.peripheral = nil
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            let lower = name.lowercased()
            guard lower.contains("basilisk") || lower.contains("bsk v3 x") else { return }
            Log.info("gatt scan discovered \"\(name)\" rssi=\(RSSI)")
            self.manager.stopScan()
            self.isScanning = false
            self.peripheral = peripheral
            peripheral.delegate = self
            self.manager.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "?"
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.info("gatt didConnect: \(name)")
            self.reconnectAttempts = 0
            // Kick discovery for battery AND device info in one call — the
            // scan path did battery only, and DIS (firmware/serial) would
            // then never populate over BT without a follow-up refresh.
            peripheral.discoverServices([self.batteryService, self.deviceInfoService])
            // The 120 s safety-net re-read is driven by the
            // DeviceController pump — see `rereadBatteryLevel()`.
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let name = peripheral.name ?? "?"
        let errMsg = error.map { "\($0)" }
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.info("gatt didDisconnect: \(name)\(errMsg.map { " — \($0)" } ?? "")")
            // BT stack sometimes drops the peripheral during radio nap.
            // Reconnect with exponential backoff so an out-of-range or
            // unpaired mouse doesn't produce infinite reconnect churn on
            // the BT radio (each failed attempt wakes it briefly).
            // Attempts reset to zero on a successful poweredOn/refresh.
            let attempt = self.reconnectAttempts
            self.reconnectAttempts = min(attempt + 1, 6)
            let delayNs: UInt64 = UInt64(min(30_000, 500 * (1 << min(6, attempt)))) * 1_000_000
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayNs)
                guard let self, self.manager.state == .poweredOn else { return }
                self.manager.connect(peripheral, options: nil)
            }
        }
    }
}

extension GATTBattery: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let svcUUIDs = (peripheral.services ?? []).map { $0.uuid.uuidString }
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.info("gatt didDiscoverServices: \(svcUUIDs)")
            for s in (peripheral.services ?? []) {
                if s.uuid == self.batteryService {
                    peripheral.discoverCharacteristics([self.batteryLevel], for: s)
                } else if s.uuid == self.deviceInfoService {
                    // Firmware + serial live under the standard Device
                    // Information Service on well-behaved BLE devices.
                    // Nothing forces the mouse to expose them, but if it
                    // does we surface them so the Device pane doesn't
                    // have to show "Dongle only" over BT.
                    peripheral.discoverCharacteristics(
                        [self.firmwareRevision, self.serialNumber], for: s)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let charUUIDs = (service.characteristics ?? []).map { $0.uuid.uuidString }
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.info("gatt didDiscoverCharacteristicsFor \(service.uuid.uuidString): \(charUUIDs)")
            for c in (service.characteristics ?? []) {
                if c.uuid == self.batteryLevel {
                    peripheral.readValue(for: c)
                    peripheral.setNotifyValue(true, for: c)
                } else if c.uuid == self.firmwareRevision
                       || c.uuid == self.serialNumber {
                    // One-shot read; these strings don't change at runtime.
                    peripheral.readValue(for: c)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        // Extract on nonisolated context (Data is Sendable) then hop.
        let value: Data? = characteristic.value
        let uuid = characteristic.uuid
        Task { @MainActor [weak self] in
            guard let self, let data = value, !data.isEmpty else { return }
            if uuid == self.batteryLevel {
                let pct = Int(data[0])
                Log.info("gatt didUpdateValueFor \(uuid.uuidString): raw=\(pct)")
                guard pct >= 0, pct <= 100 else { return }
                self.onBattery?(pct)
            } else if uuid == self.firmwareRevision {
                if let s = String(data: data, encoding: .utf8) {
                    Log.info("gatt firmware revision: \"\(s)\"")
                    self.onFirmware?(s.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else if uuid == self.serialNumber {
                if let s = String(data: data, encoding: .utf8) {
                    Log.info("gatt serial number: \"\(s)\"")
                    self.onSerial?(s.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }
}
