import Foundation
import IOKit
import IOKit.hid

// ─── Transport error ──────────────────────────────────────────────────

enum DeviceError: Error, CustomStringConvertible {
    case notPresent
    case notPermitted              // macOS Input Monitoring likely blocked
    case ioReturn(kern_return_t)
    case notSupported
    case failure
    case noResponse

    var description: String {
        switch self {
        case .notPresent:      return "mouse not present (dongle unplugged)"
        case .notPermitted:    return "IOKit access denied — grant Input Monitoring in System Settings"
        case .ioReturn(let k): return "IOKit error 0x\(String(UInt32(bitPattern: k), radix: 16))"
        case .notSupported:    return "command not supported by device"
        case .failure:         return "device reported failure"
        case .noResponse:      return "mouse asleep or unreachable"
        }
    }
}

// ─── Retry profile ────────────────────────────────────────────────────

struct RetryProfile {
    let attempts: Int
    let firstWaitMs: Int
    let retryWaitMs: Int
    /// Extra wait after the mouse reported busy (status 0x01). Onboard-flash
    /// writes on class 0x04 lock the mouse's HID processor for 300–800 ms;
    /// hitting it with the normal `retryWaitMs` inside that window keeps it
    /// busy forever. Also applied after ambiguous `.timeout` responses.
    let busyBackoffMs: Int
    /// After this many consecutive busy responses in one transact, give up
    /// even if attempts remain — the mouse is either locked or won't answer
    /// this command right now, and further pounding just wakes the radio.
    let maxConsecutiveBusy: Int
    /// User-initiated action (Apply, manual refresh) — wait long enough for a
    /// deeply-sleeping mouse to wake and respond.
    static let full  = RetryProfile(attempts: 40, firstWaitMs: 60, retryWaitMs: 120,
                                    busyBackoffMs: 400, maxConsecutiveBusy: 20)
    /// Background probe — bail out quickly if the mouse isn't answering.
    /// Bumped from 8 attempts / 4 busy tolerance after users reported
    /// "mouse asleep" errors during active use: HID input reports
    /// saturating the endpoint would eat the first several feature-
    /// report attempts, and 8 wasn't enough headroom. 20 attempts with
    /// 10 busy backoff keeps the same wall-clock ceiling for a truly
    /// asleep mouse (still tens of ms) while surviving normal
    /// mouse-in-use HID contention.
    static let short = RetryProfile(attempts: 20, firstWaitMs: 60, retryWaitMs: 150,
                                    busyBackoffMs: 350, maxConsecutiveBusy: 10)
}

// ─── HID transport ────────────────────────────────────────────────────
//
// Open-per-transaction: opens the HID device only for the duration of a single
// SetReport/GetReport round-trip, then closes. Holding the mouse HID open on
// macOS long-term can interfere with the OS pointer subsystem, so we don't.
//
// Everything is serialized on a private queue — the mouse can't handle
// concurrent feature-report exchanges, and we don't want interleaved probes.

/// Thread-safe one-shot cancellation flag. Used to plumb Task cancellation
/// through the sync DispatchQueue-based retry loop, which can't otherwise
/// observe the enclosing Task's state.
private final class CancelToken: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return flag
    }
    func trip() { lock.lock(); flag = true; lock.unlock() }
}

// All state on Device is either `let`-immutable (manager, queue, openStatus)
// or accessed only from inside `queue.async`, which serialises everything.
// Marking `@unchecked Sendable` lets us capture Device in the transact
// continuation without the compiler complaining, without introducing an
// actor wrapper that would require awaiting queue hops.
final class Device: @unchecked Sendable {
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "bskv3xhs.device")
    /// Result of `IOHIDManagerOpen` at init. When the manager fails to open
    /// (usually kIOReturnNotPermitted on modern macOS without Input
    /// Monitoring), `IOHIDManagerCopyDevices` silently returns empty and
    /// every transact looks like "no device present" to callers — making a
    /// permission problem indistinguishable from a truly unplugged dongle.
    /// We capture the code so we can surface the right error instead.
    private let openStatus: IOReturn

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Interface 0's Mouse collection is where the 90-byte vendor
        // feature report lives — the HID report descriptor for the
        // Basilisk V3 X HyperSpeed dongle declares the vendor Feature
        // (Usage Page 0xFF00, 90 bytes, no explicit Report ID) only on
        // the Mouse collection. Keyboard/Consumer collections have no
        // Feature reports at all, so opening them and issuing
        // SetReport/GetReport returns success with an all-zero buffer.
        let match: [String: Int] = [
            kIOHIDVendorIDKey:         Int(Razer.vendorID),
            kIOHIDProductIDKey:        Int(Razer.productID),
            kIOHIDPrimaryUsagePageKey: Int(kHIDPage_GenericDesktop),
            kIOHIDPrimaryUsageKey:     Int(kHIDUsage_GD_Mouse),
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        // Schedule the manager on the main run loop BEFORE opening. Without
        // this, `IOHIDManagerCopyDevices` returns stale IOHIDDevice refs
        // after any USB re-enumeration — every SetReport / GetReport then
        // fails with 0x10000003 (MACH_SEND_INVALID_DEST) because the
        // kernel ports on those old refs are already torn down. Symptom
        // was "unplug + replug the dongle stops the app dead until a full
        // app relaunch." Sibling managers in Hotplug and InputActivity
        // already schedule, and both survive replug fine.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Input Monitoring TCC is a separate permission from Accessibility.
        // Bundle-ID changes (like the Basilisk → BSK V3 X HS rename) don't
        // carry it over. IOHIDManagerOpen quietly returns success even
        // when TCC is denied — subsequent SetReport / GetReport calls
        // then silently return success with an untouched (all-zero)
        // buffer. Explicit check + request surfaces the ask up front.
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            Log.info("Input Monitoring access: granted")
        case kIOHIDAccessTypeDenied:
            Log.warn("Input Monitoring access: DENIED — vendor commands will silently fail. Ask the user to grant it in System Settings.")
        case kIOHIDAccessTypeUnknown:
            Log.info("Input Monitoring access: not determined — prompting")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        default:
            Log.info("Input Monitoring access: unrecognised state \(access.rawValue)")
        }
        openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let hex = String(UInt32(bitPattern: openStatus), radix: 16)
        if openStatus != kIOReturnSuccess {
            Log.warn("Device IOHIDManagerOpen failed: 0x\(hex) — grant Input Monitoring if the app can't see the dongle")
        } else {
            Log.info("Device IOHIDManagerOpen success (rc=0x\(hex))")
        }
    }

    var isPresent: Bool {
        (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.isEmpty == false
    }

    func transact(_ report: [UInt8], profile: RetryProfile) async throws -> Razer.Parsed {
        let token = CancelToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    do    { cont.resume(returning: try self.syncTransact(report, profile: profile, cancel: token)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: {
            // Runs on whatever task cancelled us. The sync loop reads this
            // flag between retries so a cancelled Task actually stops
            // hitting the mouse, instead of finishing its full 5 s ceiling.
            token.trip()
        }
    }

    // ─── Private ─────────────────────────────────────────────────────

    /// Cached usage-page/usage of the endpoint we last got a real
    /// response from — future calls prefer this pair before falling back
    /// to iterating all endpoints again. Cleared on every transact where
    /// the cached endpoint fails, so a dongle re-plug or firmware mode
    /// swap self-heals on the next call.
    private var preferredUsage: (page: Int, usage: Int)?

    private func syncTransact(_ report: [UInt8], profile: RetryProfile, cancel: CancelToken) throws -> Razer.Parsed {
        // When manager Open was denied, CopyDevices returns empty and
        // `notPresent` would be the wrong story — surface the permission
        // problem so the UI shows the fix (grant Input Monitoring), not
        // "dongle unplugged".
        if openStatus == kIOReturnNotPermitted { throw DeviceError.notPermitted }
        guard let devsSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !devsSet.isEmpty
        else { throw DeviceError.notPresent }

        // Sort endpoints: preferred one first (last-known-responsive),
        // then the rest by usage page + usage so ordering is deterministic
        // across runs. `preferredUsage` is nil on the first ever call.
        let devs = Array(devsSet).sorted { a, b in
            let (ap, au) = usageOf(a), (bp, bu) = usageOf(b)
            if let pref = preferredUsage {
                if (ap, au) == (pref.page, pref.usage) { return true }
                if (bp, bu) == (pref.page, pref.usage) { return false }
            }
            return ap == bp ? au < bu : ap < bp
        }

        // Iteration profile: when we already know which endpoint wins,
        // give the caller their requested budget on that endpoint. When
        // we're rediscovering, use a short profile per endpoint so the
        // total time to find a live one is bounded to ~2 s across 3
        // interfaces even in the worst case.
        let iterProfile: RetryProfile = (preferredUsage == nil && devs.count > 1) ? .short : profile
        var lastError: DeviceError?
        for dev in devs {
            let (page, usage) = usageOf(dev)
            let openRC = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openRC == kIOReturnSuccess else {
                lastError = openRC == kIOReturnNotPermitted ? .notPermitted : .ioReturn(openRC)
                continue
            }
            defer { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
            do {
                let parsed = try transactOnDevice(dev, report: report, profile: iterProfile, cancel: cancel)
                // Winning endpoint — remember it for next time so we
                // don't have to burn attempts on the wrong interface.
                if preferredUsage?.page != page || preferredUsage?.usage != usage {
                    Log.info("transact: endpoint winner usagePage=0x\(String(page, radix: 16)) usage=0x\(String(usage, radix: 16))")
                    preferredUsage = (page, usage)
                }
                return parsed
            } catch DeviceError.noResponse {
                // Try the next endpoint. Don't propagate noResponse until
                // we've exhausted them all — the dongle exposes multiple
                // and the "right" one for vendor cmds varies by device.
                lastError = .noResponse
                continue
            } catch let e as DeviceError {
                // Non-recoverable HID errors: surface immediately.
                throw e
            }
        }
        if preferredUsage != nil {
            // Cached endpoint just failed too — reset so the next call
            // re-probes ordering rather than sticking to a stale winner.
            preferredUsage = nil
        }
        throw lastError ?? .noResponse
    }

    private func usageOf(_ dev: IOHIDDevice) -> (page: Int, usage: Int) {
        let p = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let u = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
        return (p, u)
    }

    private func transactOnDevice(_ dev: IOHIDDevice,
                                  report: [UInt8],
                                  profile: RetryProfile,
                                  cancel: CancelToken) throws -> Razer.Parsed {

        // Diagnostic counters — one summary log per transact call so we
        // can see whether SetReport / GetReport are landing on the wire
        // or if we're spinning on short reads / bad CRC / class mismatch.
        var shortCount = 0
        var badCRCCount = 0
        var classMismatchCount = 0
        var busyCount = 0
        var invalidDestCount = 0
        var lastWasBusy = false
        var consecutiveBusy = 0
        /// Reset the busy streak. Both `lastWasBusy` (which picks the wait
        /// budget for the next attempt) and `consecutiveBusy` (which decides
        /// when to bail early) describe *the previous attempt*, so any
        /// non-busy outcome has to clear them. Without this they were
        /// write-once: one busy response early in the loop pinned every
        /// later attempt to `busyBackoffMs` (350 ms vs 150 ms — up to ~3.8 s
        /// of dead time on a `.short` probe) and turned `consecutiveBusy`
        /// into a total count, so a busy/short-read alternation bailed at
        /// `maxConsecutiveBusy` total busies instead of consecutive ones.
        func clearBusyStreak() {
            lastWasBusy = false
            consecutiveBusy = 0
        }
        let cls = report[6], cmd = report[7]
        attemptLoop: for attempt in 0..<profile.attempts {
            if cancel.cancelled { throw CancellationError() }
            let sendRC = report.withUnsafeBufferPointer { ptr -> IOReturn in
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0, ptr.baseAddress!, report.count)
            }
            // MACH_SEND_INVALID_DEST (0x1000_0003) happens when the HID
            // device's kernel port has been torn down mid-transaction —
            // typically a USB dongle flapping in/out of enumeration.
            // Retrying the SetReport on the SAME device object won't
            // help (the port is dead); the caller's outer loop will
            // re-copy devices on the next transact call.
            if sendRC == Int32(bitPattern: 0x1000_0003) {
                invalidDestCount += 1
                break
            }
            guard sendRC == kIOReturnSuccess else {
                // Permission errors need to surface — the fix is a TCC
                // prompt, not fallback. Everything else on this endpoint
                // becomes noResponse so the outer loop can try the next
                // one instead of bailing the whole transact on a wedged
                // interface.
                if sendRC == kIOReturnNotPermitted { throw DeviceError.notPermitted }
                throw DeviceError.noResponse
            }

            // Wait budget between SetReport and GetReport. On a busy status
            // from the previous attempt, use `busyBackoffMs` so we don't
            // hammer the mouse while it's still in a flash-write or
            // profile-switch window; otherwise use the standard cadence.
            let waitMs: Int
            if attempt == 0 { waitMs = profile.firstWaitMs }
            else if lastWasBusy { waitMs = profile.busyBackoffMs }
            else { waitMs = profile.retryWaitMs }
            usleep(useconds_t(waitMs * 1000))
            if cancel.cancelled { throw CancellationError() }

            // Buffer capacity MUST equal reportLen exactly. macOS 26's
            // AppleUserHIDDevice DEXT silently returns kIOReturnSuccess
            // with an untouched buffer if the request's (reportType,
            // reportID, capacity) triple doesn't match the descriptor —
            // and this device's vendor Feature report is declared with an
            // implicit report-ID of 0 and length 90, so a 91-byte buffer
            // (attempting to leave room for a leading report-ID byte) lands
            // in the DEXT's no-op path. Symptom was every vendor read
            // returning all-zero content that parsed as cls=0 id=0 status=0.
            var buf = [UInt8](repeating: 0, count: Razer.reportLen)
            var len = buf.count
            let getRC = buf.withUnsafeMutableBufferPointer { ptr -> IOReturn in
                IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0, ptr.baseAddress!, &len)
            }
            if getRC == Int32(bitPattern: 0x1000_0003) {
                invalidDestCount += 1
                break
            }
            guard getRC == kIOReturnSuccess else {
                if getRC == kIOReturnNotPermitted { throw DeviceError.notPermitted }
                throw DeviceError.noResponse
            }
            // Short response — treat as retry-worthy rather than parsing
            // zero-padded trailing bytes as valid frame content (CRC byte
            // would then read from padding and every response would fail
            // CRC → 40 wasted attempts on any short-response macOS quirk).
            guard len >= Razer.reportLen else {
                shortCount += 1; clearBusyStreak(); continue
            }
            let responseBytes = Array(buf.prefix(len))

            guard let parsed = Razer.parse(responseBytes) else {
                shortCount += 1; clearBusyStreak(); continue
            }
            // Sometimes macOS's HID stack hands back a stale cached response
            // from a different command — skip anything that doesn't echo our
            // class/id.
            guard parsed.cls == report[6] && parsed.id == report[7] else {
                if classMismatchCount < 3 {
                    Log.info("transact class mismatch: sent cls=0x\(String(cls, radix: 16)) id=0x\(String(cmd, radix: 16)) but got cls=0x\(String(parsed.cls, radix: 16)) id=0x\(String(parsed.id, radix: 16)) status=0x\(String(parsed.status, radix: 16))")
                }
                classMismatchCount += 1
                clearBusyStreak()
                continue
            }
            if !parsed.crcOK { badCRCCount += 1 }

            // Require crcOK on all terminal statuses. A CRC-bad response
            // with a coincidentally 0x03/0x05 status byte would otherwise
            // surface as a permanent notSupported/failure error even
            // though the frame is garbage.
            switch Razer.ResponseStatus(rawValue: parsed.status) {
            case .success where parsed.crcOK:
                return parsed
            case .notSupported where parsed.crcOK:
                throw DeviceError.notSupported
            case .failure where parsed.crcOK:
                throw DeviceError.failure
            default:
                busyCount += 1
                lastWasBusy = true
                consecutiveBusy += 1
                // Give up early on a run of busies — the mouse is either
                // locked in a flash-commit / profile-switch window, or won't
                // answer this specific command right now. `break attemptLoop`
                // is the *labeled* break so we escape the for-loop; a bare
                // `break` would only leave the switch and keep hammering.
                if consecutiveBusy >= profile.maxConsecutiveBusy { break attemptLoop }
                continue
            }
        }
        Log.info("transact noResponse cls=0x\(String(cls, radix: 16)) id=0x\(String(cmd, radix: 16)) attempts=\(profile.attempts) short=\(shortCount) badCRC=\(badCRCCount) classMismatch=\(classMismatchCount) busy=\(busyCount) invalidDest=\(invalidDestCount)")
        throw DeviceError.noResponse
    }
}
