import Foundation
import AppKit
import Carbon.HIToolbox

// ─── Media keys ──────────────────────────────────────────────────────

enum MediaKey: String, Codable, CaseIterable, Identifiable {
    case volumeUp, volumeDown, mute
    case play, next, previous
    case brightnessUp, brightnessDown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .play: return "Play / Pause"
        case .next: return "Next track"
        case .previous: return "Previous track"
        case .brightnessUp: return "Brightness up"
        case .brightnessDown: return "Brightness down"
        }
    }
    /// NX_KEYTYPE_* constants from IOKit/hidsystem/ev_keymap.h.
    var nxKey: Int32 {
        switch self {
        case .volumeUp:       return 0
        case .volumeDown:     return 1
        case .brightnessUp:   return 2
        case .brightnessDown: return 3
        case .mute:           return 7
        case .play:           return 16
        case .next:           return 17
        case .previous:       return 18
        }
    }
}

enum MediaKeyPoster {
    static func post(_ key: MediaKey) {
        for isDown in [true, false] {
            let flags: UInt = isDown ? 0xa00 : 0xb00
            let data1 = (Int(key.nxKey) << 16) | ((isDown ? 0xa : 0xb) << 8)
            if let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1
            ), let cg = ev.cgEvent {
                cg.post(tap: .cghidEventTap)
            }
        }
    }
}

// ─── Sensitivity ─────────────────────────────────────────────────────

enum SensitivityAction: Codable, Equatable, Hashable {
    case nextStage
    case previousStage
    case specificStage(Int)          // 1-based

    var label: String {
        switch self {
        case .nextStage:            return "Cycle to next DPI stage"
        case .previousStage:        return "Cycle to previous DPI stage"
        case .specificStage(let i): return "Go to DPI stage \(i)"
        }
    }
}

// ─── Extended synthetic mouse actions ────────────────────────────────

// ─── Turbo (rate-fire) ────────────────────────────────────────────────
// When Turbo is enabled on a button, holding it fires its mapped action
// at `rate` times per second until released. Useful for gaming keybinds
// or clicking through repetitive UI.

struct TurboSettings: Codable, Equatable {
    var enabled: Bool
    /// Repetitions per second. Real Razer Synapse allows 1-30. Higher is
    /// possible but macOS caps event injection somewhere around 60 Hz.
    var rate: Int

    static let disabled = TurboSettings(enabled: false, rate: 15)
}

enum SyntheticMouse: String, Codable, CaseIterable {
    case doubleClick, scrollUp, scrollDown, scrollLeft, scrollRight, bossKey
    var label: String {
        switch self {
        case .doubleClick: return "Double Click"
        case .scrollUp:    return "Scroll Up"
        case .scrollDown:  return "Scroll Down"
        case .scrollLeft:  return "Scroll Left"
        case .scrollRight: return "Scroll Right"
        case .bossKey:     return "Boss Key (hide app)"
        }
    }
}

// ─── Launch target ───────────────────────────────────────────────────

/// A stored launch target. `runInTerminal` is optional in the JSON — legacy
/// profiles decode with it defaulting to `false` (open the URL directly),
/// so existing on-disk state keeps working. When true, `url` is treated as a
/// shell command string; ButtonMap opens Terminal and runs it.
struct LaunchTarget: Codable, Equatable, Hashable {
    var displayName: String
    var url: String                  // http(s):// or file://, OR a shell command when `runInTerminal` is true
    var runInTerminal: Bool

    init(displayName: String, url: String, runInTerminal: Bool = false) {
        self.displayName = displayName
        self.url = url
        self.runInTerminal = runInTerminal
    }

    private enum CodingKeys: String, CodingKey { case displayName, url, runInTerminal }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        url = try c.decode(String.self, forKey: .url)
        runInTerminal = try c.decodeIfPresent(Bool.self, forKey: .runInTerminal) ?? false
    }
}

/// Where a preset falls on the spectrum "opens a window ↔ runs a command".
/// GUI presets launch a native `.app` (or fall back to the web version);
/// CLI presets always open a new Terminal window running the command.
enum AIPresetKind: Codable, Hashable {
    case gui                            // native `.app` (or fallback web)
    case cli(command: String)           // Terminal + shell command
}

/// AI-chat entries in the picker. GUI presets prefer the installed `.app`
/// (falling back to the web URL when the toggle is off or nothing's
/// installed). CLI presets don't have a window — they always run their
/// command in a new Terminal window; the row is greyed out when the
/// command isn't on PATH.
struct AIPreset: Identifiable, Hashable {
    let name: String
    let kind: AIPresetKind
    /// Used only for GUI presets. Empty string when `kind == .cli`.
    let webURL: String
    /// Bundle IDs to probe when `kind == .gui`. Empty for CLI.
    let bundleIDs: [String]

    var id: String { name }

    /// Resolved LaunchTarget for the user's current state, or nil when the
    /// preset isn't usable (a CLI preset whose command isn't installed).
    func resolvedTarget(preferApp: Bool) -> LaunchTarget? {
        switch kind {
        case .gui:
            if preferApp, let installed = installedAppURL() {
                return LaunchTarget(displayName: name, url: installed.absoluteString)
            }
            // Even without an installed app, a GUI preset can always fall
            // back to the web URL — better than a dead click.
            return LaunchTarget(displayName: name, url: webURL)
        case .cli(let command):
            guard let path = Self.findCLI(command) else { return nil }
            // Prefer the resolved absolute path so `open`ing Terminal from
            // a launchd context (which has a minimal PATH) still finds the
            // binary. Quoting handles paths with spaces.
            return LaunchTarget(displayName: name, url: "\"\(path)\"", runInTerminal: true)
        }
    }

    /// Returns the file:// URL of the installed native app, if any is found.
    func installedAppURL() -> URL? {
        for bid in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        return nil
    }

    /// Whether this preset is usable right now: GUI presets are always
    /// usable (web fallback), CLI presets require the command on PATH.
    var isAvailable: Bool {
        switch kind {
        case .gui: return true
        case .cli(let command): return Self.findCLI(command) != nil
        }
    }

    /// True when the GUI variant of this preset has a native app installed.
    /// Meaningless for CLIs — returns false in that case.
    var isAppInstalled: Bool {
        switch kind {
        case .gui: return installedAppURL() != nil
        case .cli: return false
        }
    }

    /// Search a curated list of standard bin paths for an executable. Apps
    /// launched by launchd (Dock, login-item) inherit a minimal PATH that
    /// doesn't include Homebrew or user-local bins, so `which` from
    /// ProcessInfo would come up empty — we probe the disk directly.
    static func findCLI(_ command: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin",            // Apple Silicon Homebrew
            "/usr/local/bin",               // Intel Homebrew + npm globals
            "\(home)/.local/bin",           // pipx, user pip
            "\(home)/.claude/local",        // Anthropic's install helper
            "\(home)/.claude/bin",
            "\(home)/.cargo/bin",           // Rust
            "\(home)/.deno/bin",            // Deno
            "\(home)/.bun/bin",             // Bun
            "\(home)/.npm-global/bin",      // Explicit npm prefix
            "/usr/bin",
            "/bin",
        ]
        for dir in candidates {
            let full = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    static let all: [AIPreset] = [
        // ── Consumer chat apps ─────────────────────────────────────────
        AIPreset(name: "Claude", kind: .gui,
                 webURL: "https://claude.ai",
                 bundleIDs: ["com.anthropic.claudefordesktop"]),
        // ChatGPT.app ships with bundle ID `com.openai.codex` on macOS
        // (OpenAI reused their old Codex bundle when they shipped the
        // desktop client). Both IDs listed so any future rename lands.
        AIPreset(name: "ChatGPT", kind: .gui,
                 webURL: "https://chatgpt.com",
                 bundleIDs: ["com.openai.codex", "com.openai.ChatGPT"]),
        AIPreset(name: "ChatGPT Atlas", kind: .gui,
                 webURL: "https://openai.com/index/introducing-chatgpt-atlas",
                 bundleIDs: ["com.openai.atlas"]),
        AIPreset(name: "Gemini", kind: .gui,
                 webURL: "https://gemini.google.com",
                 bundleIDs: []),
        AIPreset(name: "Perplexity", kind: .gui,
                 webURL: "https://perplexity.ai",
                 bundleIDs: ["ai.perplexity.mac", "ai.perplexity.comet"]),
        AIPreset(name: "Copilot", kind: .gui,
                 webURL: "https://copilot.microsoft.com",
                 bundleIDs: ["com.microsoft.copilot"]),

        // ── Coding-focused IDEs / clients ──────────────────────────────
        AIPreset(name: "Antigravity IDE", kind: .gui,
                 webURL: "https://antigravity.google",
                 bundleIDs: ["com.google.antigravity-ide"]),
        AIPreset(name: "Antigravity Tools", kind: .gui,
                 webURL: "https://antigravity.google",
                 bundleIDs: ["com.lbjlaq.antigravity-tools"]),
        AIPreset(name: "Kiro", kind: .gui,
                 webURL: "https://kiro.dev",
                 bundleIDs: ["dev.kiro.desktop"]),

        // ── CLIs — Terminal launch only, greyed out when not on PATH ───
        AIPreset(name: "Claude Code CLI", kind: .cli(command: "claude"),
                 webURL: "", bundleIDs: []),
        AIPreset(name: "Codex CLI", kind: .cli(command: "codex"),
                 webURL: "", bundleIDs: []),
        AIPreset(name: "Gemini CLI", kind: .cli(command: "gemini"),
                 webURL: "", bundleIDs: []),
        AIPreset(name: "Kiro CLI", kind: .cli(command: "kiro"),
                 webURL: "", bundleIDs: []),
    ]
}

// ─── macOS shortcut presets ──────────────────────────────────────────
// These are curated KeyCombo presets grouped for easy discovery — they
// correspond to what Synapse calls "Windows Shortcuts", rewired for macOS.

extension KeyCombo {
    static let macShortcuts: [KeyCombo] = [
        KeyCombo(keyCode: UInt16(kVK_F11),         mods: [.function],       label: "Show Desktop"),
        KeyCombo(keyCode: UInt16(kVK_UpArrow),     mods: [.control],        label: "Mission Control"),
        KeyCombo(keyCode: UInt16(kVK_DownArrow),   mods: [.control],        label: "App windows"),
        KeyCombo(keyCode: UInt16(kVK_Tab),         mods: [.command],        label: "Cycle apps (⌘⇥)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Grave),  mods: [.command],        label: "Cycle windows (⌘`)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_W),      mods: [.command],        label: "Close window (⌘W)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Q),      mods: [.command],        label: "Quit app (⌘Q)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_H),      mods: [.command],        label: "Hide app (⌘H)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_M),      mods: [.command],        label: "Minimize (⌘M)"),
        KeyCombo(keyCode: UInt16(kVK_Space),       mods: [.command],        label: "Spotlight (⌘Space)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Q),      mods: [.command, .control], label: "Lock screen (⌃⌘Q)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_3),      mods: [.command, .shift],   label: "Screenshot (⇧⌘3)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_4),      mods: [.command, .shift],   label: "Area screenshot (⇧⌘4)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_5),      mods: [.command, .shift],   label: "Screenshot tools (⇧⌘5)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Equal),  mods: [.command],           label: "Zoom in (⌘=)"),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Minus),  mods: [.command],           label: "Zoom out (⌘-)"),
    ]
}
