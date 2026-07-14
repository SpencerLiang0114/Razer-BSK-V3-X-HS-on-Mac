import Foundation

// High-level API on top of Device. All setters use onboard storage so changes
// survive mouse sleep and dongle replug.

struct FirmwareVersion { let major: UInt8; let minor: UInt8; var string: String { "\(major).\(minor)" } }
struct DPIRead         { let x: Int; let y: Int }
struct DPIStagesRead   { let active: Int; let stages: [(index: Int, x: Int, y: Int)] }

final class Service {
    let device: Device
    init(device: Device) { self.device = device }

    func firmware(profile: RetryProfile = .full) async throws -> FirmwareVersion {
        let r = try await device.transact(Razer.firmwareRead(), profile: profile)
        return FirmwareVersion(major: r.args[0], minor: r.args[1])
    }

    func serial(profile: RetryProfile = .full) async throws -> String {
        let r = try await device.transact(Razer.serialRead(), profile: profile)
        // Stop at the first non-printable byte, not just NUL: some firmwares
        // pad the serial with 0xFF, spaces, or garbage after the string ends,
        // which the original NUL-only scan would fold into the returned
        // value. Serial numbers are always printable ASCII in Razer's kits.
        var end = 0
        while end < 22 {
            let b = r.args[end]
            if b < 0x20 || b > 0x7E { break }
            end += 1
        }
        return String(bytes: r.args.prefix(end), encoding: .ascii) ?? ""
    }

    /// Returns 0-100 percentage.
    func batteryPercent(profile: RetryProfile = .full) async throws -> Int {
        let r = try await device.transact(Razer.batteryRead(), profile: profile)
        return Int(round(Double(r.args[1]) / 255.0 * 100.0))
    }

    /// Read idle-sleep timer, expressed as minutes.
    func idleMinutes(profile: RetryProfile = .full) async throws -> Int {
        let r = try await device.transact(Razer.idleTimeRead(), profile: profile)
        let secs = (Int(r.args[0]) << 8) | Int(r.args[1])
        return max(1, secs / 60)
    }
    // Setters default to `.short` — the UI's debounced auto-apply is what
    // drives these, and a sleeping mouse should just retry on the next
    // slider settle rather than blocking the device queue for 5 s each.
    // Passing `.full` explicitly is still available for user-initiated
    // "Apply Now"-style paths that must ride out a deeply-asleep mouse.
    func setIdleMinutes(_ minutes: Int, profile: RetryProfile = .short) async throws {
        _ = try await device.transact(Razer.idleTimeWrite(minutes: minutes), profile: profile)
    }

    func pollRate(profile: RetryProfile = .full) async throws -> Int {
        let r = try await device.transact(Razer.pollRateRead(), profile: profile)
        return Razer.pollRateFromByte(r.args[0]) ?? 1000
    }
    func setPollRate(_ hz: Int, profile: RetryProfile = .short) async throws {
        _ = try await device.transact(Razer.pollRateWrite(hz), profile: profile)
    }

    func dpi(profile: RetryProfile = .full) async throws -> DPIRead {
        let r = try await device.transact(Razer.dpiRead(), profile: profile)
        return DPIRead(
            x: (Int(r.args[1]) << 8) | Int(r.args[2]),
            y: (Int(r.args[3]) << 8) | Int(r.args[4])
        )
    }

    func dpiStages(profile: RetryProfile = .full) async throws -> DPIStagesRead {
        let r = try await device.transact(Razer.dpiStagesRead(), profile: profile)
        var out: [(Int, Int, Int)] = []
        // Clamp to the protocol max (5 stages × 7 bytes each = 35 bytes after
        // active byte, fits inside args[80]). Without this, a garbage
        // count byte from a stale-cached response would run us off the end
        // of `args` at `args[o+4]` and trap the process.
        let count = max(0, min(5, Int(r.args[2])))
        for i in 0..<count {
            let o = 3 + i * 7
            out.append((Int(r.args[o]),
                        (Int(r.args[o+1]) << 8) | Int(r.args[o+2]),
                        (Int(r.args[o+3]) << 8) | Int(r.args[o+4])))
        }
        return DPIStagesRead(active: Int(r.args[1]), stages: out)
    }
    func setDPIStages(active: Int, stages: [(x: Int, y: Int)], profile: RetryProfile = .short) async throws {
        _ = try await device.transact(Razer.dpiStagesWrite(active: active, stages: stages), profile: profile)
    }

    // ─── Lighting (scroll wheel LED) ────────────────────────────────

    /// Storage governs flash-wear: pass `.ram` for interactive drags (LED
    /// updates immediately, no onboard-memory write) and `.onboard` for the
    /// final commit when the user has settled on a value.
    func setLightingEffect(_ effect: LightingEffect,
                           storage: Razer.Storage = .onboard,
                           profile: RetryProfile = .short) async throws {
        let bytes: [UInt8]
        switch effect {
        case .off:
            bytes = Razer.lightingOff(storage: storage)
        case .static(let c):
            bytes = Razer.lightingStatic(r: c.r, g: c.g, b: c.b, storage: storage)
        case .breath(let c):
            bytes = Razer.lightingBreath(r: c.r, g: c.g, b: c.b, storage: storage)
        case .spectrum:
            bytes = Razer.lightingSpectrum(storage: storage)
        case .wave(let dir):
            let d: Razer.WaveDirection = (dir == .leftToRight) ? .leftToRight : .rightToLeft
            bytes = Razer.lightingWave(direction: d, storage: storage)
        case .reactive(let c, let speed):
            bytes = Razer.lightingReactive(r: c.r, g: c.g, b: c.b, speed: UInt8(max(1, min(4, speed))), storage: storage)
        }
        _ = try await device.transact(bytes, profile: profile)
    }

    /// `percent` is 0-100. Mapped to the wire's 0-255 range. Same storage
    /// semantics as `setLightingEffect`.
    func setBrightnessPercent(_ percent: Int,
                              storage: Razer.Storage = .onboard,
                              profile: RetryProfile = .short) async throws {
        let clamped = max(0, min(100, percent))
        let level = UInt8(clamped * 255 / 100)
        _ = try await device.transact(Razer.brightnessWrite(level, storage: storage), profile: profile)
    }

    /// Read current brightness on 0-100.
    func brightnessPercent(profile: RetryProfile = .full) async throws -> Int {
        let r = try await device.transact(Razer.brightnessRead(), profile: profile)
        // Response arg[2] is the level (mirror of the write byte).
        let level = Int(r.args[2])
        return (level * 100) / 255
    }
}
