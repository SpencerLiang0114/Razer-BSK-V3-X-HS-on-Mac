import SwiftUI
import Carbon.HIToolbox

/// Renders a `KeyCombo` as a pill of key badges, the way macOS System
/// Settings and Xcode display shortcuts — modifier icons then the key.
struct KeyComboChip: View {
    let combo: KeyCombo
    var body: some View {
        HStack(spacing: 4) {
            ForEach(modifierIcons(combo.mods), id: \.self) { icon in
                KeyBadge(text: icon.text, symbol: icon.symbol)
            }
            KeyBadge(text: keyBadgeLabel(combo.keyCode).text,
                     symbol: keyBadgeLabel(combo.keyCode).symbol)
        }
    }
}

private struct KeyBadge: View {
    let text: String?
    let symbol: String?
    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            } else if let text {
                Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
            } else { EmptyView() }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(DS.border, lineWidth: 0.5)
        )
    }
}

private struct BadgeGlyph: Hashable {
    let text: String?
    let symbol: String?
}

private func modifierIcons(_ mods: NSEvent.ModifierFlags) -> [BadgeGlyph] {
    var out: [BadgeGlyph] = []
    if mods.contains(.control) { out.append(BadgeGlyph(text: nil, symbol: "control")) }
    if mods.contains(.option)  { out.append(BadgeGlyph(text: nil, symbol: "option")) }
    if mods.contains(.shift)   { out.append(BadgeGlyph(text: nil, symbol: "shift")) }
    if mods.contains(.command) { out.append(BadgeGlyph(text: nil, symbol: "command")) }
    return out
}

private func keyBadgeLabel(_ code: UInt16) -> BadgeGlyph {
    switch Int(code) {
    case kVK_Space:         return BadgeGlyph(text: nil, symbol: "space")
    case kVK_Return:        return BadgeGlyph(text: nil, symbol: "return")
    case kVK_Tab:           return BadgeGlyph(text: nil, symbol: "arrow.right.to.line")
    case kVK_Escape:        return BadgeGlyph(text: nil, symbol: "escape")
    case kVK_Delete:        return BadgeGlyph(text: nil, symbol: "delete.left")
    case kVK_ForwardDelete: return BadgeGlyph(text: nil, symbol: "delete.right")
    case kVK_LeftArrow:     return BadgeGlyph(text: nil, symbol: "arrow.left")
    case kVK_RightArrow:    return BadgeGlyph(text: nil, symbol: "arrow.right")
    case kVK_UpArrow:       return BadgeGlyph(text: nil, symbol: "arrow.up")
    case kVK_DownArrow:     return BadgeGlyph(text: nil, symbol: "arrow.down")
    case kVK_PageUp:        return BadgeGlyph(text: nil, symbol: "arrow.up.to.line")
    case kVK_PageDown:      return BadgeGlyph(text: nil, symbol: "arrow.down.to.line")
    // "Home" / "End" go through String(localized:) so the badge picks
    // up the user's locale — zh-Hans users saw literal English inside
    // an otherwise fully-translated shortcut chip.
    case kVK_Home:          return BadgeGlyph(text: String(localized: "Home"), symbol: nil)
    case kVK_End:           return BadgeGlyph(text: String(localized: "End"),  symbol: nil)
    default:
        return BadgeGlyph(text: keyDisplayString(code), symbol: nil)
    }
}

/// Human-readable label for a full key combo (used in the manual builder's
/// live preview + persisted KeyCombo.label).
func renderCombo(keyCode: UInt16, mods: NSEvent.ModifierFlags) -> String {
    var s = ""
    if mods.contains(.control) { s += "⌃" }
    if mods.contains(.option)  { s += "⌥" }
    if mods.contains(.shift)   { s += "⇧" }
    if mods.contains(.command) { s += "⌘" }
    s += keyDisplayString(keyCode)
    return s
}

/// Compact modifier-glyph string ("⌃⌥") for modifier-only bindings. Same
/// order as `renderCombo` so labels stay consistent across the app.
func modifierGlyphString(_ mods: NSEvent.ModifierFlags) -> String {
    var s = ""
    if mods.contains(.control) { s += "⌃" }
    if mods.contains(.option)  { s += "⌥" }
    if mods.contains(.shift)   { s += "⇧" }
    if mods.contains(.command) { s += "⌘" }
    return s
}

/// Best-effort human-readable label for a virtual key code — uses the user's
/// current keyboard layout so QWERTY / Dvorak / AZERTY all show the right key.
func keyDisplayString(_ code: UInt16) -> String {
    switch Int(code) {
    // Non-printing keys that UCKeyTranslate returns as invisible control
    // chars — resolve them ourselves so `renderCombo` produces "⌃←" and not
    // "⌃\u{1c}".
    case kVK_LeftArrow:     return "←"
    case kVK_RightArrow:    return "→"
    case kVK_UpArrow:       return "↑"
    case kVK_DownArrow:     return "↓"
    case kVK_PageUp:        return "⇞"
    case kVK_PageDown:      return "⇟"
    // See `keyBadgeLabel` above — same localization reasoning.
    case kVK_Home:          return String(localized: "Home")
    case kVK_End:           return String(localized: "End")
    case kVK_Space:         return "Space"
    case kVK_Return:        return "Return"
    case kVK_Tab:           return "Tab"
    case kVK_Escape:        return "Esc"
    case kVK_Delete:        return "⌫"
    case kVK_ForwardDelete: return "⌦"
    case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
    case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
    case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
    case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
    case kVK_F13: return "F13"; case kVK_F14: return "F14"; case kVK_F15: return "F15"
    case kVK_F16: return "F16"; case kVK_F17: return "F17"; case kVK_F18: return "F18"
    case kVK_F19: return "F19"
    default: break
    }
    let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
    if let layoutData = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        if status == noErr, length > 0 {
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
    return "Key \(code)"
}

// ─── Manual shortcut builder ─────────────────────────────────────────

/// Groups of virtual key codes for the keyboard pane's key grid.
enum KeyGroup: String, CaseIterable, Identifiable {
    case letters, numbers, function, navigation, special
    var id: String { rawValue }
    var label: String {
        switch self {
        case .letters:    return "Letters"
        case .numbers:    return "Numbers"
        case .function:   return "Function"
        case .navigation: return "Navigation"
        case .special:    return "Special"
        }
    }
    var codes: [UInt16] {
        switch self {
        case .letters:
            return [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
                    kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                    kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                    kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                    kVK_ANSI_Y, kVK_ANSI_Z].map(UInt16.init)
        case .numbers:
            return [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                    kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map(UInt16.init)
        case .function:
            // F-key virtual codes on macOS are NOT contiguous (kVK_F1=122,
            // kVK_F2=120, kVK_F3=99, …), so we can't use a Range. List each.
            return [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
                    kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13,
                    kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19].map(UInt16.init)
        case .navigation:
            return [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                    kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End].map(UInt16.init)
        case .special:
            return [kVK_Space, kVK_Return, kVK_Tab, kVK_Escape,
                    kVK_Delete, kVK_ForwardDelete].map(UInt16.init)
        }
    }
}

/// A key button rendered like a physical keycap — square-ish, subtle border,
/// tint highlight when selected. Renders SF Symbols for navigation / special
/// keys (arrows, return, delete, space) and text for everything else.
struct KeyBadgeSquare: View {
    let code: UInt16
    let selected: Bool

    var body: some View {
        Group {
            if let symbol = symbolName(for: code) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            } else {
                Text(keyDisplayString(code))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
        .frame(minWidth: 36, minHeight: 30)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.15) : Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }

    private func symbolName(for code: UInt16) -> String? {
        switch Int(code) {
        case kVK_LeftArrow:     return "arrow.left"
        case kVK_RightArrow:    return "arrow.right"
        case kVK_UpArrow:       return "arrow.up"
        case kVK_DownArrow:     return "arrow.down"
        case kVK_PageUp:        return "arrow.up.to.line"
        case kVK_PageDown:      return "arrow.down.to.line"
        case kVK_Return:        return "return"
        case kVK_Tab:           return "arrow.right.to.line"
        case kVK_Space:         return "space"
        case kVK_Escape:        return "escape"
        case kVK_Delete:        return "delete.left"
        case kVK_ForwardDelete: return "delete.right"
        default: return nil
        }
    }
}
