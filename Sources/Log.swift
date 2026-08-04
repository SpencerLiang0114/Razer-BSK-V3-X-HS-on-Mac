import Foundation

/// Unbuffered logger — writes to stderr AND `/tmp/bskv3xhs.log`.
///
/// Format: `[HH:mm:ss.SSS] [LVL ][cat] message`
///
/// Levels are advisory. `.debug` is gated: nothing is written unless the
/// `BSKV3XHS_DEBUG` env var is set to a non-zero/non-empty value, or the
/// `BSKDebugLog` UserDefaults key is `YES`. This lets hot-path logging
/// (every scroll tick, every button press, every GATT state change) stay
/// out of the file by default without deleting the diagnostic value —
/// flip the switch when you're debugging a specific problem.
///
/// Categories tag which sub-system emitted a line so a `grep '\[button\]'`
/// gets you every button-map / event-tap message and nothing else. Old
/// call sites that predate the tagged API get `.misc` automatically.
///
/// The log file is rotated to `.1` when it crosses `maxBytes` (~1 MB),
/// keeping one generation of history — enough for the last few sessions
/// without stealing MB of `/tmp` on a machine that runs for months. File
/// mode is 0600 so `ButtonMappings` labels / typed-text contents / device
/// serials don't leak to other users on shared machines.
enum Log {

    // ─── Public API ──────────────────────────────────────────────────

    enum Level: Int, Comparable {
        case debug = 0, info, warn, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        fileprivate var tag: String {
            switch self {
            case .debug: return "DBG "
            case .info:  return "info"
            case .warn:  return "WARN"
            case .error: return "ERR "
            }
        }
    }

    /// Sub-system that emitted the line. Kept as short-stable strings —
    /// they land in the log verbatim so users can `grep '\[gatt\]'` etc.
    /// Add new cases as the code grows. `.misc` is the fallback for
    /// legacy call sites that pre-date the tagged API.
    enum Category: String {
        case lifecycle      // app start / quit / wake / sleep
        case hid            // Razer vendor protocol / IOHID transport
        case button         // ButtonMap / CGEventTap
        case scroll         // ScrollTransformer
        case battery        // Battery smoothing / low-battery / LED dim
        case gatt           // GATTBattery (Bluetooth LE)
        case hotplug        // Hotplug transport detection
        case input          // InputActivity
        case profile        // profile switch / auto-switch
        case ui             // PanelController / TrayController / HUD
        case settings       // SettingsStore load / save / migrations
        case misc
    }

    static let fileURL     = URL(fileURLWithPath: "/tmp/bskv3xhs.log")
    private static let rotatedURL = URL(fileURLWithPath: "/tmp/bskv3xhs.log.1")

    /// UserDefaults key backing the in-app debug toggle. Exposed so the
    /// Device pane can bind to it via `@AppStorage(Log.debugPrefKey)`
    /// — that keeps SwiftUI's cached copy in sync with what
    /// `Log.debug(...)` reads on every call.
    static let debugPrefKey = "BSKDebugLog"

    /// Snapshot of the env-var override at process start. Env vars are
    /// immutable for the lifetime of the process, so caching this
    /// avoids a `ProcessInfo.environment` dictionary copy on every
    /// hot-path `Log.debug(...)` call.
    private static let debugEnvOverride: Bool? = {
        guard let raw = ProcessInfo.processInfo.environment["BSKV3XHS_DEBUG"]
        else { return nil }
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !v.isEmpty && v != "0" && v != "false" && v != "no"
    }()

    /// True when `BSKV3XHS_DEBUG` was set at launch. The Device pane
    /// uses this to grey out its Debug toggle — flipping UserDefaults
    /// wouldn't change behaviour until the app relaunches without the
    /// override, and showing a live-looking switch that doesn't take
    /// effect would be worse than showing a disabled one.
    static var debugOverriddenByEnv: Bool { debugEnvOverride != nil }

    /// True when `.debug` lines are being written. Reads UserDefaults
    /// on every call so a toggle in the settings pane takes effect
    /// immediately — no relaunch required. Env var (if set) takes
    /// precedence over UserDefaults; it's the dev/CI override.
    static var debugEnabled: Bool {
        if let env = debugEnvOverride { return env }
        return UserDefaults.standard.bool(forKey: debugPrefKey)
    }

    // ─── Tagged API (preferred for new code) ─────────────────────────

    /// `.debug` message with an explicit category. The message closure
    /// only runs when `debugEnabled` is true — free when disabled, so
    /// call sites don't need their own if-checks around expensive
    /// interpolations.
    static func debug(_ cat: Category, _ msg: @autoclosure () -> String) {
        guard debugEnabled else { return }
        emit(.debug, cat, msg())
    }

    static func info(_  cat: Category, _ msg: String) { emit(.info,  cat, msg) }
    static func warn(_  cat: Category, _ msg: String) { emit(.warn,  cat, msg) }
    static func error(_ cat: Category, _ msg: String) { emit(.error, cat, msg) }

    // ─── Legacy API ──────────────────────────────────────────────────
    //
    // Older call sites don't specify a category. They land under `.misc`
    // in the output — grepping `[misc]` still catches them. Kept as
    // regular overloads (not deprecated) because there are ~90 usages
    // across the codebase and migrating them is opportunistic, not
    // urgent — the timestamp / rotation / mode-0600 improvements land
    // for free on both APIs.

    static func info(_  msg: String) { emit(.info,  .misc, msg) }
    static func warn(_  msg: String) { emit(.warn,  .misc, msg) }
    static func error(_ msg: String) { emit(.error, .misc, msg) }

    /// Wipe the live log and the rotated `.1` history in one shot,
    /// then re-open a fresh empty file with mode 0600. Runs on the
    /// log queue so it doesn't race with in-flight writes — if a
    /// write is queued behind this call, it lands in the new file.
    /// Used from the Device pane's "Clear log" button so a fresh
    /// debug reproduction doesn't get mixed with pre-existing noise.
    static func clear() {
        queue.async {
            let fm = FileManager.default
            let previous = handle
            try? previous?.close()
            try? fm.removeItem(at: fileURL)
            try? fm.removeItem(at: rotatedURL)
            fm.createFile(atPath: fileURL.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
            handle = try? FileHandle(forWritingTo: fileURL)
            writtenBytes = 0
            // Leave a breadcrumb so the reader knows they're looking
            // at a freshly-cleared log rather than one that was empty
            // for other reasons (permissions, disk full, …).
            let ts = tsFormatter.string(from: Date())
            let line = "[\(ts)] [info][misc] log cleared by user\n"
            if let data = line.data(using: .utf8) {
                FileHandle.standardError.write(data)
                handle?.write(data)
                writtenBytes = UInt64(data.count)
            }
        }
    }

    // ─── Internals ───────────────────────────────────────────────────

    private static let queue = DispatchQueue(label: "bskv3xhs.log")
    /// Cap the live log at ~1 MB. When crossed we roll it over to `.1`,
    /// keeping one generation of history — enough for the last few sessions
    /// without stealing MB of `/tmp` on a machine that runs for months.
    private static let maxBytes: UInt64 = 1_000_000
    private static var writtenBytes: UInt64 = 0

    /// One shared handle for the lifetime of the process. `queue`
    /// serializes writes so we can freely mutate `writtenBytes` and
    /// rotate the file without extra locking.
    private static var handle: FileHandle? = {
        let fm = FileManager.default
        // If a previous session's log exists and is over budget, rotate
        // BEFORE opening — otherwise the first write of the new session
        // would still push it past the cap before we noticed.
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64, size > maxBytes {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: fileURL, to: rotatedURL)
        }
        // Create with mode 0600 on first launch. Prior versions of this
        // logger created the file with default 0644, so ALSO tighten an
        // existing file's mode on every launch — this migrates
        // long-running installs without deleting their history.
        // /tmp is world-readable; button-map labels, typed-text strings
        // and device serials should not be readable by other users.
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o600],
                                   ofItemAtPath: fileURL.path)
        }
        let h = try? FileHandle(forWritingTo: fileURL)
        _ = try? h?.seekToEnd()
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64 {
            writtenBytes = size
        }
        return h
    }()

    /// Millisecond timestamp for log lines. Locale-independent so the
    /// format is stable regardless of the user's locale.
    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func emit(_ level: Level, _ cat: Category, _ msg: String) {
        let ts = tsFormatter.string(from: Date())
        let line = "[\(ts)] [\(level.tag)][\(cat.rawValue)] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            // stderr in the same serial block so line ordering matches
            // the file — a `Console.app` tail against stderr and a
            // `tail -f` against the log won't diverge under load.
            FileHandle.standardError.write(data)
            handle?.write(data)
            writtenBytes &+= UInt64(data.count)
            if writtenBytes > maxBytes { rotate() }
        }
    }

    /// Called on `queue`. Move the current file aside as `.1` and reopen
    /// a fresh empty log. If the reopen fails we keep the previous
    /// handle so subsequent writes still land on disk — better a bloated
    /// log than silently dropping messages, which the old code did.
    private static func rotate() {
        let fm = FileManager.default
        let previous = handle
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
        fm.createFile(atPath: fileURL.path, contents: nil,
                      attributes: [.posixPermissions: 0o600])
        if let fresh = try? FileHandle(forWritingTo: fileURL) {
            try? previous?.close()
            handle = fresh
            writtenBytes = 0
        }
        // else: keep `previous` (already assigned to `handle`) — no drop.
    }
}
