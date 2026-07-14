import Foundation

/// Unbuffered logger — writes to stderr AND /tmp/bskv3xhs.log.
///
/// Levels are advisory; production would probably respect an env var but for
/// a personal-use utility we always log everything. The file is truncated and
/// rotated when it crosses `maxBytes` so the log doesn't grow without bound —
/// a driver-flavoured background app can produce a lot of hotplug / apply
/// noise over a week of use.
enum Log {
    static let fileURL = URL(fileURLWithPath: "/tmp/bskv3xhs.log")
    private static let rotatedURL = URL(fileURLWithPath: "/tmp/bskv3xhs.log.1")
    private static let queue = DispatchQueue(label: "bskv3xhs.log")
    /// Cap the live log at ~1 MB. When crossed we roll it over to `.1`,
    /// keeping one generation of history — enough for the last few sessions
    /// without stealing MB of `/tmp` on a machine that runs for months.
    private static let maxBytes: UInt64 = 1_000_000
    private static var writtenBytes: UInt64 = 0
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
        // Append if the file already exists (this session's fresh log), else
        // create it. Preserving cross-launch context is worth the extra byte.
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: fileURL)
        _ = try? h?.seekToEnd()
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64 {
            writtenBytes = size
        }
        return h
    }()

    static func info(_ msg: String)  { emit("info", msg) }
    static func warn(_ msg: String)  { emit("WARN", msg) }
    static func error(_ msg: String) { emit("ERR ", msg) }

    private static func emit(_ level: String, _ msg: String) {
        let line = "[\(level)] \(msg)\n"
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

    /// Called on `queue`. Move the current file aside as `.1` and reopen a
    /// fresh empty log. If the reopen fails we keep the previous handle so
    /// subsequent writes still land on disk — better a bloated log than
    /// silently dropping messages, which the old code did.
    private static func rotate() {
        let fm = FileManager.default
        let previous = handle
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
        fm.createFile(atPath: fileURL.path, contents: nil)
        if let fresh = try? FileHandle(forWritingTo: fileURL) {
            try? previous?.close()
            handle = fresh
            writtenBytes = 0
        }
        // else: keep `previous` (already assigned to `handle`) — no drop.
    }
}
