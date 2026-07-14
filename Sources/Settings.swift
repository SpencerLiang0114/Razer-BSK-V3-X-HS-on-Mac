import Foundation
import Combine

// ─── DPI + AppSettings (per profile) ─────────────────────────────────

struct DPIStageValue: Codable, Equatable { var x: Int; var y: Int }
struct DPIConfig: Codable, Equatable {
    var activeStage: Int
    var stages: [DPIStageValue]
    /// When false (default), UI mirrors X = Y on every edit and the axis
    /// value shown is X. When true, each stage exposes independent X and Y
    /// sliders, matching Synapse 4's "Enable X-Y Sensitivity" checkbox.
    /// Firmware always accepts (x, y); this flag is purely UI-side.
    var xyIndependent: Bool = false

    private enum CodingKeys: String, CodingKey {
        case activeStage, stages, xyIndependent
    }
    init(activeStage: Int, stages: [DPIStageValue], xyIndependent: Bool = false) {
        self.activeStage = activeStage
        self.stages = stages
        self.xyIndependent = xyIndependent
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeStage = try c.decode(Int.self, forKey: .activeStage)
        stages = try c.decode([DPIStageValue].self, forKey: .stages)
        xyIndependent = try c.decodeIfPresent(Bool.self, forKey: .xyIndependent) ?? false
    }
}

// ─── Lighting (scroll wheel LED) ─────────────────────────────────────

/// Persistable RGB triple. UI code converts to `Color` when rendering.
struct RGB: Codable, Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    static let razerGreen = RGB(r: 68, g: 217, b: 34)
}

/// One of the effects the Basilisk V3 X HyperSpeed's scroll-wheel LED can
/// play. Mirrors OpenRazer's supported set for USB PID 0x00B9. `.reactive`
/// speed is 1 (slow) to 4 (fast); `.wave` direction is left→right or reverse.
enum LightingEffect: Codable, Equatable, Hashable {
    case off
    case `static`(RGB)
    case breath(RGB)
    case spectrum
    case wave(direction: WaveDir)
    case reactive(RGB, speed: Int)

    enum WaveDir: String, Codable, CaseIterable, Hashable {
        case leftToRight, rightToLeft
        var label: String {
            switch self {
            case .leftToRight: return "Left → Right"
            case .rightToLeft: return "Right → Left"
            }
        }
    }

    /// Case tag used by the mode picker so we can render the UI without
    /// depending on payload equality.
    var mode: Mode {
        switch self {
        case .off: return .off
        case .static: return .static
        case .breath: return .breath
        case .spectrum: return .spectrum
        case .wave: return .wave
        case .reactive: return .reactive
        }
    }
    enum Mode: String, CaseIterable, Identifiable, Hashable {
        case off, `static`, breath, spectrum, wave, reactive
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off:      return "Off"
            case .static:   return "Static"
            case .breath:   return "Breath"
            case .spectrum: return "Spectrum"
            case .wave:     return "Wave"
            case .reactive: return "Reactive"
            }
        }
    }
}

struct LightingSettings: Codable, Equatable {
    var effect: LightingEffect = .spectrum
    /// User-facing brightness (0-100). Mapped to 0-255 at write time.
    var brightness: Int = 100
}

// ─── Scroll (system-side transform, transport-agnostic) ──────────────
//
// Runs at the CGEventTap layer so it works over dongle AND Bluetooth. Applies
// only to discrete line-based wheel events (physical mice) — trackpad's
// continuous scroll passes through untouched. Modelled after Mos:
//   • reverse direction (per-axis) so macOS's global "natural" can stay on
//     for the trackpad while the wheel behaves like Windows;
//   • speed multiplier — pixels emitted per line-tick;
//   • smoothing — accumulator + 120 Hz drain with exponential decay, so each
//     click becomes a short glide instead of a jump.
struct ScrollSettings: Codable, Equatable {
    /// Master toggle. When false the transformer is bypassed entirely and
    /// scrollWheel events pass through unchanged (macOS defaults win).
    var enabled: Bool = false
    var reverseVertical: Bool = false
    var reverseHorizontal: Bool = false
    /// Multiplier on pixels-per-tick. 1.0 ≈ 100 px/tick — matches Mos's
    /// out-of-the-box feel on a standard clicky wheel.
    var speed: Double = 1.0
    /// Convert discrete line ticks to interpolated pixel scroll. Off → only
    /// direction/speed apply, wheel still feels stepped.
    var smoothingEnabled: Bool = true
    /// 0.0 = snappy (~100 ms tail), 1.0 = long glide (~400 ms tail).
    var smoothness: Double = 0.5
}

/// A normalized (0-1) position within the mouse image. Codable so it lands
/// in `settings.json` when the user drags a hotspot in the diagram editor.
struct NormalizedPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

// ─── Low-battery behavior ────────────────────────────────────────────
//
// Two independent knobs that share a threshold, mirroring Synapse's
// "Notify me when battery is low" and "Turn off lighting when battery is
// low" toggles. Kept in one struct so users can flip both from a single
// card without hunting through separate panes.

struct LowBatterySettings: Codable, Equatable {
    /// Post a macOS notification when battery first crosses under
    /// `threshold`, and again on every further drop (e.g., 20% → 15%
    /// → 10% posts three banners). Repeat suppression rides on
    /// `pct < lastNotified` so a smoothed reading that oscillates near
    /// the boundary doesn't spam. Recovery above `threshold + hysteresis`
    /// resets the state so a re-drop starts the cadence over.
    var alertEnabled: Bool = true
    /// Cut the LED brightness in half at low battery — LED is the
    /// biggest single power draw on this mouse, so dimming meaningfully
    /// extends AA life during the last stretch before replacement.
    /// Dimming rides on `.ram` writes so it never touches onboard flash.
    var dimLEDEnabled: Bool = true
    /// Percentage below which alert + dim engage. Default 15 matches
    /// Synapse's low-battery threshold for this mouse. Slider range in
    /// the UI is 5–30; the decoder below clamps stored values into that
    /// window so profiles from earlier builds (when the range extended
    /// to 100) load with a sensible position instead of a slider that
    /// visually caps below the stored number.
    var threshold: Int = 15

    private enum CodingKeys: String, CodingKey { case alertEnabled, dimLEDEnabled, threshold }
    init(alertEnabled: Bool = true, dimLEDEnabled: Bool = true, threshold: Int = 15) {
        self.alertEnabled = alertEnabled
        self.dimLEDEnabled = dimLEDEnabled
        self.threshold = threshold
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alertEnabled = try c.decodeIfPresent(Bool.self, forKey: .alertEnabled) ?? true
        dimLEDEnabled = try c.decodeIfPresent(Bool.self, forKey: .dimLEDEnabled) ?? true
        let raw = try c.decodeIfPresent(Int.self, forKey: .threshold) ?? 15
        threshold = min(30, max(5, raw))
    }
}

/// One profile's worth of configuration. Everything about how the mouse
/// behaves lives in here so switching profiles is a self-contained swap.
struct AppSettings: Codable, Equatable {
    var dpi: DPIConfig
    var pollRateHz: Int
    var idleMinutes: Int
    var buttons: ButtonMappings = .init()
    var lighting: LightingSettings = .init()
    var scroll: ScrollSettings = .init()
    var lowBattery: LowBatterySettings = .init()
    var hotspotOverrides: [String: NormalizedPoint] = [:]
    var calloutOverrides: [String: NormalizedPoint] = [:]

    private enum CodingKeys: String, CodingKey {
        case dpi, pollRateHz, idleMinutes, buttons, lighting, scroll,
             lowBattery, hotspotOverrides, calloutOverrides
    }

    // Custom decoder so profiles saved before ScrollSettings existed still
    // load — the missing field falls back to `.init()` defaults instead of
    // aborting decode and quarantining the file. Also clamps activeStage
    // into range: a legacy `activeStage = 0` (pre-1-based era) would
    // otherwise reach `Razer.dpiStagesWrite(active: 0)` and the firmware
    // silently NAKs, dropping the entire DPI-stages apply on the floor.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var loadedDpi = try c.decode(DPIConfig.self, forKey: .dpi)
        if !loadedDpi.stages.isEmpty {
            loadedDpi.activeStage = max(1, min(loadedDpi.stages.count, loadedDpi.activeStage))
        } else {
            loadedDpi.activeStage = 1
        }
        dpi = loadedDpi
        pollRateHz = try c.decode(Int.self, forKey: .pollRateHz)
        idleMinutes = try c.decode(Int.self, forKey: .idleMinutes)
        buttons = try c.decodeIfPresent(ButtonMappings.self, forKey: .buttons) ?? .init()
        lighting = try c.decodeIfPresent(LightingSettings.self, forKey: .lighting) ?? .init()
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? .init()
        lowBattery = try c.decodeIfPresent(LowBatterySettings.self, forKey: .lowBattery) ?? .init()
        hotspotOverrides = try c.decodeIfPresent([String: NormalizedPoint].self, forKey: .hotspotOverrides) ?? [:]
        calloutOverrides = try c.decodeIfPresent([String: NormalizedPoint].self, forKey: .calloutOverrides) ?? [:]
    }

    init(dpi: DPIConfig, pollRateHz: Int, idleMinutes: Int,
         buttons: ButtonMappings = .init(), lighting: LightingSettings = .init(),
         scroll: ScrollSettings = .init(),
         lowBattery: LowBatterySettings = .init(),
         hotspotOverrides: [String: NormalizedPoint] = [:],
         calloutOverrides: [String: NormalizedPoint] = [:]) {
        self.dpi = dpi
        self.pollRateHz = pollRateHz
        self.idleMinutes = idleMinutes
        self.buttons = buttons
        self.lighting = lighting
        self.scroll = scroll
        self.lowBattery = lowBattery
        self.hotspotOverrides = hotspotOverrides
        self.calloutOverrides = calloutOverrides
    }

    static let defaults = AppSettings(
        dpi: DPIConfig(activeStage: 1, stages: [
            .init(x: 800,  y: 800),
            .init(x: 1600, y: 1600),
            .init(x: 2400, y: 2400),
            .init(x: 3200, y: 3200),
        ]),
        pollRateHz: 1000,
        idleMinutes: 3,
        buttons: ButtonMappings(),
        lighting: LightingSettings(),
        scroll: ScrollSettings(),
        lowBattery: LowBatterySettings(),
        hotspotOverrides: [:],
        calloutOverrides: [:]
    )
}

// ─── Profiles ────────────────────────────────────────────────────────

/// The on-disk shape. `profiles` is ordered so the sidebar picker can list
/// them consistently; `activeID` names which one is live. `defaultID` names
/// the profile the auto-switch watcher falls back to when the focused app
/// doesn't match any profile's trigger list — legacy files that predate the
/// auto-switch feature decode with `defaultID == nil`, which the watcher
/// treats as "don't revert automatically."
struct SettingsFile: Codable, Equatable {
    var profiles: [Profile]
    var activeID: UUID
    var defaultID: UUID? = nil

    private enum CodingKeys: String, CodingKey { case profiles, activeID, defaultID }
    init(profiles: [Profile], activeID: UUID, defaultID: UUID? = nil) {
        self.profiles = profiles
        self.activeID = activeID
        self.defaultID = defaultID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        activeID = try c.decode(UUID.self, forKey: .activeID)
        defaultID = try c.decodeIfPresent(UUID.self, forKey: .defaultID)
    }
}

/// One saved profile. `triggerBundleIDs` opts the profile into auto-switch:
/// when any of these app bundle IDs becomes frontmost, this profile
/// activates. Legacy profiles predating this feature decode with an empty
/// list — auto-switch just skips them. Order isn't meaningful.
struct Profile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var settings: AppSettings
    var triggerBundleIDs: [String] = []

    private enum CodingKeys: String, CodingKey { case id, name, settings, triggerBundleIDs }
    init(id: UUID, name: String, settings: AppSettings, triggerBundleIDs: [String] = []) {
        self.id = id
        self.name = name
        self.settings = settings
        self.triggerBundleIDs = triggerBundleIDs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        settings = try c.decode(AppSettings.self, forKey: .settings)
        triggerBundleIDs = try c.decodeIfPresent([String].self, forKey: .triggerBundleIDs) ?? []
    }
}

// ─── Store ───────────────────────────────────────────────────────────

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    let fileURL: URL
    @Published private(set) var file: SettingsFile
    /// Background queue for the disk write. Encoding still runs on main
    /// (needs to snapshot the actor-isolated `file`) but the actual atomic
    /// write no longer blocks main during slider drags — Turbo / DPI slider
    /// motion fires save() many times a second and prior behaviour did a
    /// full JSON write on the main thread per frame.
    private let saveQueue = DispatchQueue(label: "bskv3xhs.settings.save", qos: .utility)

    /// The currently-active profile's config. Legacy call sites still expect
    /// `.current` as an `AppSettings`, so we keep this accessor.
    var current: AppSettings {
        get { file.profiles.first(where: { $0.id == file.activeID })?.settings ?? .defaults }
        set { updateActive { $0 = newValue } }
    }

    init() {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let base = support.appendingPathComponent("BSKV3XHS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("settings.json")

        // One-shot migration: earlier builds stored under "BasiliskMac". If
        // the new location is empty but the old one has a settings.json,
        // move it in so existing users don't lose their profiles on rename.
        let legacy = support.appendingPathComponent("BasiliskMac", isDirectory: true)
            .appendingPathComponent("settings.json")
        if !FileManager.default.fileExists(atPath: fileURL.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            do {
                try FileManager.default.moveItem(at: legacy, to: fileURL)
                Log.info("migrated settings.json from BasiliskMac/ → BSKV3XHS/")
            } catch {
                // Copy as a fallback so a permissions quirk on move doesn't
                // strand the user's data — worst case they end up with two
                // copies, which is better than zero.
                try? FileManager.default.copyItem(at: legacy, to: fileURL)
                Log.warn("copied settings.json from BasiliskMac/ → BSKV3XHS/ (move failed: \(error))")
            }
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL) {
                // Try the current (profiled) format first.
                if let parsed = try? JSONDecoder().decode(SettingsFile.self, from: data) {
                    self.file = parsed
                    return
                }
                // Legacy: an old settings.json that stored a flat AppSettings.
                // Wrap it into a single "Default" profile so the user's
                // existing config survives the upgrade.
                if let legacy = try? JSONDecoder().decode(AppSettings.self, from: data) {
                    let id = UUID()
                    self.file = SettingsFile(
                        profiles: [Profile(id: id, name: "Default", settings: legacy)],
                        activeID: id
                    )
                    self.save()   // migrate legacy → profiled format
                    return
                }
            }
            // File exists but is unreadable / unparseable. This almost
            // always means a previous run was interrupted mid-write — DO
            // NOT overwrite with defaults; move the corrupt file aside so
            // the user can recover their profiles by hand if they need to.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            Log.warn("settings.json unparseable — quarantined to \(backup.lastPathComponent), starting fresh")
        }
        // Fresh install (or corrupt file just quarantined). Skip the eager
        // save — if the user never edits anything we don't want an empty
        // defaults file on disk, and the first real mutation will save.
        let id = UUID()
        self.file = SettingsFile(
            profiles: [Profile(id: id, name: "Default", settings: .defaults)],
            activeID: id
        )
    }

    // ─── Mutations ────────────────────────────────────────────────────

    /// Mutate the currently-active profile's settings.
    func updateActive(_ mutate: (inout AppSettings) -> Void) {
        guard let idx = file.profiles.firstIndex(where: { $0.id == file.activeID }) else { return }
        mutate(&file.profiles[idx].settings)
        save()
    }

    func setActive(_ id: UUID) {
        guard file.profiles.contains(where: { $0.id == id }) else { return }
        file.activeID = id
        save()
    }

    /// Add a new profile cloned from the active one (Synapse's default new
    /// profile behavior). Returns the new profile's id.
    @discardableResult
    func addProfile(name: String) -> UUID {
        let seed = current
        let new = Profile(id: UUID(), name: name, settings: seed)
        file.profiles.append(new)
        file.activeID = new.id
        save()
        return new.id
    }

    /// Duplicate the active profile with an auto-suggested name. This is the
    /// Synapse workflow — "I like this setup but want a variant for gaming"
    /// — where cloning DPI/buttons/lighting/scroll all at once beats
    /// clicking through every pane on a fresh profile.
    @discardableResult
    func duplicateActive() -> UUID? {
        guard let source = file.profiles.first(where: { $0.id == file.activeID }) else { return nil }
        // Suggest "<name> copy" then " copy 2", " copy 3" — matching Finder's
        // duplicate-naming convention so users read it as familiar.
        let baseName = source.name + " copy"
        var candidate = baseName
        var n = 2
        while file.profiles.contains(where: { $0.name == candidate }) {
            candidate = "\(baseName) \(n)"
            n += 1
        }
        let new = Profile(id: UUID(), name: candidate, settings: source.settings)
        file.profiles.append(new)
        file.activeID = new.id
        save()
        return new.id
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let idx = file.profiles.firstIndex(where: { $0.id == id }) else { return }
        file.profiles[idx].name = name
        save()
    }

    /// Remove a profile. Refuses to remove the last remaining one — an app
    /// with zero profiles has no state to load.
    func deleteProfile(_ id: UUID) {
        guard file.profiles.count > 1 else { return }
        file.profiles.removeAll { $0.id == id }
        if file.activeID == id, let first = file.profiles.first {
            file.activeID = first.id
        }
        // Deleting the default nulls out the pointer — the watcher then
        // treats "no rule matched" as "don't revert" rather than pinning to
        // a profile that no longer exists.
        if file.defaultID == id { file.defaultID = nil }
        save()
    }

    // ─── Auto-switch (per-profile trigger apps + fallback default) ──────
    // These knobs feed the AppSwitchWatcher: when the focused app matches
    // some profile's `triggerBundleIDs`, that profile activates; otherwise
    // the watcher falls back to `defaultID` (if set).

    /// Replace the trigger-app bundle-ID list for one profile.
    func setTriggerBundleIDs(_ ids: [String], for profileID: UUID) {
        guard let idx = file.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        // Dedupe + drop empties. Trigger lists are order-independent — the
        // watcher matches by membership.
        var seen = Set<String>()
        let cleaned = ids.compactMap { bid -> String? in
            let trimmed = bid.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        guard file.profiles[idx].triggerBundleIDs != cleaned else { return }
        file.profiles[idx].triggerBundleIDs = cleaned
        save()
    }

    /// Add one bundle ID to a profile's trigger list (no-op if already there).
    func addTriggerBundleID(_ bundleID: String, to profileID: UUID) {
        guard let idx = file.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !file.profiles[idx].triggerBundleIDs.contains(trimmed) else { return }
        file.profiles[idx].triggerBundleIDs.append(trimmed)
        save()
    }

    /// Remove one bundle ID from a profile's trigger list.
    func removeTriggerBundleID(_ bundleID: String, from profileID: UUID) {
        guard let idx = file.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let before = file.profiles[idx].triggerBundleIDs.count
        file.profiles[idx].triggerBundleIDs.removeAll { $0 == bundleID }
        if file.profiles[idx].triggerBundleIDs.count != before { save() }
    }

    /// Mark a profile as the default (returned to when no auto-switch rule
    /// matches the focused app). Pass `nil` to clear the default entirely.
    func setDefaultProfile(_ id: UUID?) {
        if let id { guard file.profiles.contains(where: { $0.id == id }) else { return } }
        guard file.defaultID != id else { return }
        file.defaultID = id
        save()
    }

    // ─── Import / Export ────────────────────────────────────────────

    /// Portable one-profile file. Wrapped so `.bskprofile` files carry
    /// enough metadata to reject nonsense inputs (wrong app, incompatible
    /// version) instead of silently importing garbage as a profile.
    struct ProfileExport: Codable, Equatable {
        static let currentApp = "BSK V3 X HS"
        static let currentVersion = 1
        var app: String
        var version: Int
        var profile: Profile
    }

    /// Encode the currently-active profile for export. Returns raw JSON —
    /// callers decide where to write it (NSSavePanel, clipboard, etc).
    func exportActive() throws -> Data {
        guard let source = file.profiles.first(where: { $0.id == file.activeID }) else {
            throw ImportExportError.noActiveProfile
        }
        let wrapper = ProfileExport(
            app: ProfileExport.currentApp,
            version: ProfileExport.currentVersion,
            profile: source
        )
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        return try enc.encode(wrapper)
    }

    /// Add a decoded profile from an export file as a NEW profile — never
    /// overwrites existing state. Renames on collision so a duplicate name
    /// doesn't confuse the picker. Returns the new profile's id.
    @discardableResult
    func importProfile(from data: Data) throws -> UUID {
        let wrapper = try JSONDecoder().decode(ProfileExport.self, from: data)
        // Version gate: newer files may carry fields we don't understand.
        // Rejecting up front beats silently dropping the unknown bits.
        guard wrapper.version <= ProfileExport.currentVersion else {
            throw ImportExportError.unsupportedVersion(wrapper.version)
        }
        // Reject exports from other products even if their JSON shape
        // happens to match — a Razer .synapse won't have compatible field
        // semantics and we don't want to load it into the mouse.
        guard wrapper.app == ProfileExport.currentApp else {
            throw ImportExportError.wrongApp(wrapper.app)
        }
        var new = wrapper.profile
        new.id = UUID()                                // never reuse — collision is a bug
        // Trigger bundle IDs are machine-local — the exporter's list of
        // "apps I want this profile bound to" isn't likely to match the
        // importer's installed set, and quietly re-arming auto-switch for
        // apps the importer might not even own is a surprising side effect.
        // Clear on import; the user can re-add on their own machine.
        new.triggerBundleIDs = []
        // Rename on collision: Finder-style " (2)" suffix, incremented.
        var candidate = new.name
        var n = 2
        while file.profiles.contains(where: { $0.name == candidate }) {
            candidate = "\(new.name) (\(n))"
            n += 1
        }
        new.name = candidate
        file.profiles.append(new)
        file.activeID = new.id
        save()
        return new.id
    }

    enum ImportExportError: Error, LocalizedError {
        case noActiveProfile
        case unsupportedVersion(Int)
        case wrongApp(String)

        var errorDescription: String? {
            switch self {
            case .noActiveProfile:
                return String(localized: "No active profile to export.")
            case .unsupportedVersion(let v):
                return String(format: NSLocalizedString(
                    "This file uses profile format v%lld, newer than what this app understands.",
                    comment: "import error, unknown version"), v)
            case .wrongApp(let name):
                return String(format: NSLocalizedString(
                    "This file was exported by \"%@\", not by BSK V3 X HS.",
                    comment: "import error, wrong app"), name)
            }
        }
    }

    // ─── Persistence ─────────────────────────────────────────────────

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        guard let data = try? enc.encode(file) else {
            Log.error("settings encode failed")
            return
        }
        let url = fileURL
        // .atomic writes to a hidden temp file and renames on close, so a
        // crash mid-write leaves the previous file intact — no more
        // truncated JSON turning into a "fresh install" on next launch.
        // Dispatched off main so slider frames don't stutter on the disk I/O.
        saveQueue.async {
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                Log.error("settings save failed: \(error)")
            }
        }
    }
}
