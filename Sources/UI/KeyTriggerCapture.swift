import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Renders a `KeyTrigger` as something a human can check against what they
/// pressed — "⌃ Control", "F5", "⌃⇧ F13".
enum KeyTriggerFormatter {
    static func describe(_ t: KeyTrigger) -> String {
        var out = ""
        let f = t.flags
        if f.contains(.maskControl)   { out += "⌃" }
        if f.contains(.maskAlternate) { out += "⌥" }
        if f.contains(.maskShift)     { out += "⇧" }
        if f.contains(.maskCommand)   { out += "⌘" }
        if !out.isEmpty { out += " " }
        return out + keyName(t.keyCode)
    }

    /// Name for the keycodes a firmware remap can plausibly produce. Anything
    /// unrecognized falls back to the raw hex so the user still sees something
    /// they can report, rather than a blank.
    static func keyName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Control, kVK_RightControl: return "Control"
        case kVK_Shift, kVK_RightShift:     return "Shift"
        case kVK_Option, kVK_RightOption:   return "Option"
        case kVK_Command, kVK_RightCommand: return "Command"
        case kVK_Function:                  return "Fn"
        case kVK_CapsLock:                  return "Caps Lock"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_F13: return "F13"; case kVK_F14: return "F14"
        case kVK_F15: return "F15"; case kVK_F16: return "F16"
        case kVK_F17: return "F17"; case kVK_F18: return "F18"
        case kVK_F19: return "F19"; case kVK_F20: return "F20"
        case kVK_LeftArrow:  return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"; case kVK_DownArrow:  return "↓"
        case kVK_PageUp:     return "Page Up"
        case kVK_PageDown:   return "Page Down"
        case kVK_Home:       return "Home"
        case kVK_End:        return "End"
        case kVK_Escape:     return "Esc"
        default: return "key 0x" + String(code, radix: 16)
        }
    }
}

/// Captures the keystroke a firmware-remapped mouse button emits.
///
/// Listens with `NSEvent.addGlobalMonitorForEvents` rather than the app's
/// CGEventTap: the tap consumes matched triggers, and reusing it here would
/// mean an already-configured button couldn't be re-learned. A global monitor
/// observes without consuming, so re-learning always works.
///
/// Watches both `.keyDown` and `.flagsChanged` — Synapse's "Hold Ctrl"-style
/// assignments emit a bare modifier, which never produces `keyDown`. Missing
/// that case is what made this whole feature unreachable for modifier remaps.
@MainActor
final class KeyTriggerCapture: ObservableObject {
    @Published private(set) var isListening = false

    private var monitor: Any?
    private var timeout: Timer?
    private var onCapture: ((KeyTrigger) -> Void)?

    /// Listen for one keystroke, hand back a trigger, and stop. Auto-cancels
    /// after 6 s so a user who clicks Learn and walks away doesn't leave a
    /// global monitor armed for the rest of the session.
    func start(_ handler: @escaping (KeyTrigger) -> Void) {
        stop()
        onCapture = handler
        isListening = true
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            MainActor.assumeIsolated { self?.handle(ev) }
        }
        timeout = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        timeout?.invalidate()
        timeout = nil
        isListening = false
        onCapture = nil
    }

    private func handle(_ ev: NSEvent) {
        let code = UInt16(ev.keyCode)
        let cg = CGEventFlags(rawValue: UInt64(ev.modifierFlags.rawValue))
        if ev.type == .flagsChanged {
            // flagsChanged fires on press AND release. Only the press edge is
            // the signal; without this check the release (flags already
            // cleared) would be recorded as a trigger with no modifier at all,
            // which then matches nothing.
            guard ButtonMap.isModifierKeyCode(code),
                  ButtonMap.modifierBitIsSet(keyCode: code, in: cg) else { return }
        }
        // Keep only the modifier bits the matcher compares, so incidental
        // state (numeric pad, caps) can't make a recorded trigger unmatchable.
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl,
                                  .maskShift, .maskSecondaryFn]
        let trigger = KeyTrigger(keyCode: code,
                                 modsRaw: cg.intersection(mask).rawValue)
        Log.info(.button, "learned firmware trigger: \(KeyTriggerFormatter.describe(trigger))")
        let cb = onCapture
        stop()
        cb?(trigger)
    }
}
