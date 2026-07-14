import Foundation
import AppKit

/// User-selected UI language, independent of the macOS system locale.
///
/// Bundle localizations are resolved once per process from `AppleLanguages`
/// in UserDefaults — SwiftUI, NSMenu, NSAlert etc. all cache their
/// resolved strings at load time, so a runtime toggle can't retroactively
/// re-localize the existing UI. The pattern is therefore:
///
///   1. `applyEarly()` reads the persisted choice on `main()` before AppKit
///      starts loading anything and mirrors it into `AppleLanguages`.
///   2. UI picker writes the choice through `set(_:)` and prompts the user
///      to relaunch — `relaunch()` re-execs the app bundle via `open` and
///      terminates the current process.
enum LanguagePreference {
    /// Persistence key for our own preference. Kept distinct from
    /// `AppleLanguages` so a user who picks "Follow system" can clear our
    /// key and let the OS-provided default win again.
    static let key = "bskv3xhs.language"

    enum Choice: String, CaseIterable, Identifiable {
        case system, en, zhHans
        var id: String { rawValue }
        /// Non-localized label — the picker deliberately shows each
        /// option in its own language so users can find their language
        /// even from a locale they can't read.
        var label: String {
            switch self {
            case .system: return "Follow system"
            case .en:     return "English"
            case .zhHans: return "简体中文"
            }
        }
        /// The value we write into `AppleLanguages`. `nil` means "clear
        /// the override" so system defaulting kicks back in.
        var appleLanguagesValue: String? {
            switch self {
            case .system: return nil
            case .en:     return "en"
            case .zhHans: return "zh-Hans"
            }
        }
    }

    static var current: Choice {
        switch UserDefaults.standard.string(forKey: key) {
        case "en":      return .en
        case "zh-Hans": return .zhHans
        default:        return .system
        }
    }

    /// The Locale identifier we align with each `Choice`. Without this,
    /// `Locale.current` / `Date.FormatStyle` / `NumberFormatter` all keep
    /// following the system locale even when the UI language is forced —
    /// so e.g. a zh-Hans UI would still format dates with the user's
    /// system region rules. Aligning the locale keeps everything in sync.
    private static func localeIdentifier(for choice: Choice) -> String? {
        switch choice {
        case .system: return nil
        case .en:     return "en_US"
        case .zhHans: return "zh_Hans_CN"
        }
    }

    static func set(_ choice: Choice) {
        let d = UserDefaults.standard
        if let v = choice.appleLanguagesValue {
            d.set(v, forKey: key)
            d.set([v], forKey: "AppleLanguages")
            if let loc = localeIdentifier(for: choice) { d.set(loc, forKey: "AppleLocale") }
        } else {
            d.removeObject(forKey: key)
            d.removeObject(forKey: "AppleLanguages")
            d.removeObject(forKey: "AppleLocale")
        }
    }

    /// Call this from `main()` before AppKit initialises. Reads the
    /// persisted choice and mirrors it into `AppleLanguages` so
    /// Bundle-lookup picks up the override for this launch.
    static func applyEarly() {
        guard let stored = UserDefaults.standard.string(forKey: key) else { return }
        UserDefaults.standard.set([stored], forKey: "AppleLanguages")
        // Also mirror AppleLocale early so formatters pick up the right
        // region on this launch's very first log line, not on the next.
        let choice: Choice = stored == "en" ? .en : (stored == "zh-Hans" ? .zhHans : .system)
        if let loc = localeIdentifier(for: choice) {
            UserDefaults.standard.set(loc, forKey: "AppleLocale")
        }
    }

    /// Terminate the current process and re-open the app bundle. Used
    /// after a language change so the fresh process picks up the new
    /// `AppleLanguages`. Only terminates on a successful re-launch —
    /// otherwise the user loses the app until they open it themselves.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            Log.warn("language relaunch failed: \(error)")
        }
    }
}
