import Foundation
import AppKit
import Carbon.HIToolbox

// ─── Remap actions ───────────────────────────────────────────────────

/// What a physical mouse button should do when pressed. `passthrough` is the
/// button's default OS behavior; other cases swallow the original event and
/// synthesize a substitute.
enum ButtonAction: Codable, Equatable {
    case passthrough
    case disabled
    case keyStroke(KeyCombo)
    case mouseClick(SynthMouseButton)
    case syntheticMouse(SyntheticMouse)   // Double click, scroll left/right, boss key
    case multimedia(MediaKey)
    case sensitivity(SensitivityAction)
    case launch(LaunchTarget)
    case typeText(String)
    /// Hold one or more modifier keys while the mouse button is held. On
    /// press we post the virtual keyDown for each modifier (⌃ = 0x3B, ⌥ =
    /// 0x3A, ⇧ = 0x38, ⌘ = 0x37); on release we post the matching keyUp.
    /// Unlike `.keyStroke`, this action honors the button lifecycle so
    /// hold-and-drag patterns (⌘-drag to move a window etc.) work.
    case modifier(NSEvent.ModifierFlags)

    var label: String {
        switch self {
        case .passthrough:            return "Default"
        case .disabled:               return "Disabled"
        case .keyStroke(let k):       return k.label
        case .mouseClick(let m):      return m.label
        case .syntheticMouse(let s):  return s.label
        case .multimedia(let m):      return m.label
        case .sensitivity(let s):     return s.label
        case .launch(let t):          return "Launch: \(t.displayName)"
        case .typeText(let s):        return "Type: \"\(s.prefix(24))\(s.count > 24 ? "…" : "")\""
        case .modifier(let m):        return "Hold \(modifierGlyphs(m))"
        }
    }
}

/// Return the SF-Symbol-style compact glyph string for a modifier set —
/// e.g. `.control` → "⌃", `[.control, .shift]` → "⌃⇧". Order is fixed
/// (⌃⌥⇧⌘) so labels stay stable.
private func modifierGlyphs(_ m: NSEvent.ModifierFlags) -> String {
    var s = ""
    if m.contains(.control) { s += "⌃" }
    if m.contains(.option)  { s += "⌥" }
    if m.contains(.shift)   { s += "⇧" }
    if m.contains(.command) { s += "⌘" }
    return s
}

enum SynthMouseButton: String, Codable, CaseIterable {
    case left, right, middle
    var label: String {
        switch self {
        case .left:   return "Left click"
        case .right:  return "Right click"
        case .middle: return "Middle click"
        }
    }
}

struct KeyCombo: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let mods: NSEvent.ModifierFlags
    let label: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(mods.rawValue)
        hasher.combine(label)
    }
    static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.mods == rhs.mods && lhs.label == rhs.label
    }

    enum CodingKeys: String, CodingKey { case keyCode, mods, label }
    init(keyCode: UInt16, mods: NSEvent.ModifierFlags, label: String) {
        self.keyCode = keyCode; self.mods = mods; self.label = label
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        mods    = NSEvent.ModifierFlags(rawValue: try c.decode(UInt.self, forKey: .mods))
        label   = try c.decode(String.self, forKey: .label)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(mods.rawValue, forKey: .mods)
        try c.encode(label, forKey: .label)
    }

}

// ─── Persistence-friendly bag ────────────────────────────────────────

/// A keyboard-event signature that a physical mouse button currently emits
/// (because the mouse's firmware was configured by a prior app to remap the
/// button to a key). If we know the trigger, we can intercept that keyDown
/// and run the user's chosen action.
struct KeyTrigger: Codable, Equatable {
    let keyCode: UInt16
    let modsRaw: UInt64                // raw bits of CGEventFlags
    var flags: CGEventFlags { CGEventFlags(rawValue: modsRaw) }
    func matches(_ eventFlags: CGEventFlags) -> Bool {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        return (eventFlags.intersection(mask)) == (self.flags.intersection(mask))
    }
}

struct ButtonMappings: Codable, Equatable {
    var leftClick:    ButtonAction = .passthrough
    var rightClick:   ButtonAction = .passthrough
    var scrollClick:  ButtonAction = .passthrough
    var scrollUp:     ButtonAction = .passthrough
    var scrollDown:   ButtonAction = .passthrough
    var mouseButton4: ButtonAction = .passthrough
    var mouseButton5: ButtonAction = .passthrough

    /// Keyboard triggers used when a button's HID output has been firmware-
    /// remapped to a key (e.g. Synapse set button 4 → fn+F5). Keyed by the
    /// MouseButton rawValue.
    var triggers: [String: KeyTrigger] = [:]

    /// Per-button turbo (rate-fire). Keyed by MouseButton.rawValue.
    /// Absent key = turbo disabled.
    var turbo: [String: TurboSettings] = [:]

    func action(for b: MouseButton) -> ButtonAction {
        switch b {
        case .rightClick:   return rightClick
        case .scrollClick:  return scrollClick
        case .scrollUp:     return scrollUp
        case .scrollDown:   return scrollDown
        case .mouseButton4: return mouseButton4
        case .mouseButton5: return mouseButton5
        case .leftClick, .dpiCycle: return .passthrough
        }
    }
    mutating func set(_ a: ButtonAction, for b: MouseButton) {
        switch b {
        case .leftClick, .dpiCycle: break     // locked
        case .rightClick:   rightClick = a
        case .scrollClick:  scrollClick = a
        case .scrollUp:     scrollUp = a
        case .scrollDown:   scrollDown = a
        case .mouseButton4: mouseButton4 = a
        case .mouseButton5: mouseButton5 = a
        }
    }

    func turbo(for b: MouseButton) -> TurboSettings {
        turbo[b.rawValue] ?? .disabled
    }
    mutating func setTurbo(_ t: TurboSettings, for b: MouseButton) {
        if !t.enabled {
            turbo.removeValue(forKey: b.rawValue)
        } else {
            turbo[b.rawValue] = t
        }
    }
    func virtualTrigger(for b: MouseButton) -> KeyTrigger? { triggers[b.rawValue] }
    mutating func setTrigger(_ t: KeyTrigger?, for b: MouseButton) {
        if let t { triggers[b.rawValue] = t } else { triggers.removeValue(forKey: b.rawValue) }
    }
}

extension ButtonAction {
    private enum Kind: String, Codable { case passthrough, disabled, keyStroke, mouseClick, syntheticMouse, multimedia, sensitivity, launch, typeText, modifier }
    private enum CodingKeys: String, CodingKey { case kind, key, click, synth, media, sens, launch, text, mods }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let k = try c.decode(Kind.self, forKey: .kind)
        switch k {
        case .passthrough:    self = .passthrough
        case .disabled:       self = .disabled
        case .keyStroke:      self = .keyStroke(try c.decode(KeyCombo.self, forKey: .key))
        case .mouseClick:     self = .mouseClick(try c.decode(SynthMouseButton.self, forKey: .click))
        case .syntheticMouse: self = .syntheticMouse(try c.decode(SyntheticMouse.self, forKey: .synth))
        case .multimedia:     self = .multimedia(try c.decode(MediaKey.self, forKey: .media))
        case .sensitivity:    self = .sensitivity(try c.decode(SensitivityAction.self, forKey: .sens))
        case .launch:         self = .launch(try c.decode(LaunchTarget.self, forKey: .launch))
        case .typeText:       self = .typeText(try c.decode(String.self, forKey: .text))
        case .modifier:
            let raw = try c.decode(UInt.self, forKey: .mods)
            self = .modifier(NSEvent.ModifierFlags(rawValue: raw))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passthrough:            try c.encode(Kind.passthrough, forKey: .kind)
        case .disabled:               try c.encode(Kind.disabled, forKey: .kind)
        case .keyStroke(let k):       try c.encode(Kind.keyStroke, forKey: .kind); try c.encode(k, forKey: .key)
        case .mouseClick(let m):      try c.encode(Kind.mouseClick, forKey: .kind); try c.encode(m, forKey: .click)
        case .syntheticMouse(let s):  try c.encode(Kind.syntheticMouse, forKey: .kind); try c.encode(s, forKey: .synth)
        case .multimedia(let m):      try c.encode(Kind.multimedia, forKey: .kind); try c.encode(m, forKey: .media)
        case .sensitivity(let s):     try c.encode(Kind.sensitivity, forKey: .kind); try c.encode(s, forKey: .sens)
        case .launch(let t):          try c.encode(Kind.launch, forKey: .kind); try c.encode(t, forKey: .launch)
        case .typeText(let s):        try c.encode(Kind.typeText, forKey: .kind); try c.encode(s, forKey: .text)
        case .modifier(let m):        try c.encode(Kind.modifier, forKey: .kind); try c.encode(m.rawValue, forKey: .mods)
        }
    }
}

// ─── CGEventTap engine ────────────────────────────────────────────────
// Listens for buttonNumber 3 (side back) and 4 (side forward) globally.
// If mapping is not `.passthrough`, swallows the mouse event and synthesizes
// the mapped key stroke. Requires Accessibility permission.

@MainActor
final class ButtonMap: ObservableObject {
    static let shared = ButtonMap()

    @Published var mappings: ButtonMappings = .init()
    @Published var accessibilityTrusted: Bool = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var trustTimer: Timer?
    private init() {
        refreshTrust()
        // No tap yet — reconfigureTap() runs on apply() and on trust change.
        // With default all-passthrough mappings we don't want any tap.
        // Watch for the user granting Accessibility so we can install the
        // tap without needing an app restart. Only arm the poll while trust
        // is still missing — refreshTrust() stops it the moment it flips, so
        // long-running sessions don't burn an XPC every 2 s forever.
        if !accessibilityTrusted { armTrustTimer() }
    }

    private func armTrustTimer() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            // scheduledTimer fires on the current runloop; since init runs on
            // main (ButtonMap is @MainActor) that runloop is main. The
            // compiler can't see that on its own, so assume isolation
            // explicitly — the alternative is a Task hop per tick.
            MainActor.assumeIsolated { self?.refreshTrust() }
        }
    }

    func refreshTrust() {
        let now = AXIsProcessTrusted()
        let changed = accessibilityTrusted != now
        accessibilityTrusted = now
        // Whenever trust flips, re-evaluate the tap: on grant, install if the
        // current mappings need it; on revoke, tear the old (now-dead) one down.
        if changed { reconfigureTap() }
        // Trust is one-way in practice — once granted for this bundle, macOS
        // does not silently revoke. Kill the poll to stop the every-2-s XPC.
        // If the user revokes via System Settings and toggles it back later,
        // the tap will fail on next event (macOS also posts .tapDisabled...
        // which we handle) and requestTrust() re-arms the poll on demand.
        if now, trustTimer != nil {
            trustTimer?.invalidate()
            trustTimer = nil
        }
    }

    /// Prompt the user (once) — pops the standard macOS "would like to
    /// control your computer" dialog + jumps them to System Settings if
    /// permission isn't granted.
    func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        refreshTrust()
        // If the user hasn't granted yet (they'll do it in System Settings
        // asynchronously), make sure the 2 s poll is running so we notice
        // the grant without needing a relaunch. refreshTrust() will stop it
        // again the moment `trusted` flips true.
        if !accessibilityTrusted { armTrustTimer() }
    }

    func apply(_ new: ButtonMappings) {
        mappings = new
        Log.info("button map applied — left=\(new.leftClick.label) right=\(new.rightClick.label) mid=\(new.scrollClick.label) btn4=\(new.mouseButton4.label) btn5=\(new.mouseButton5.label) scrollUp=\(new.scrollUp.label) scrollDown=\(new.scrollDown.label)")
        // In-flight Turbo timers captured the OLD action at button-down time.
        // If the user changed the mapping (or the tap mask shrinks below the
        // button's UP events), the timer would keep firing the stale action
        // forever with no way to stop it. Kill everything now — the next
        // physical press restarts turbo with the new settings.
        stopAllTurbo()
        // Same reasoning applies to suppression tracking — the newly-installed
        // tap may not include the up-mask for a button that's still held, so
        // its release event might never reach us. Start clean.
        suppressedButtons.removeAll()
        // Rebuilds the tap with the minimum event mask the new mappings need;
        // if nothing is remapped, tears the tap down entirely.
        reconfigureTap()
    }

    /// The scroll transformer runs through this tap too. When the user
    /// toggles scroll on/off we need to expand or shrink the event mask so
    /// scrollWheel events either reach us or bypass us entirely.
    func scrollSettingsChanged() {
        reconfigureTap()
    }

    // ─── Tap install ─────────────────────────────────────────────────

    /// Bitmask of the CGEventTypes the currently-installed tap is listening
    /// for. Used to detect no-op reconfigure calls.
    private var currentMask: UInt64 = 0

    /// Raw CG button numbers whose mouseDown we've consumed (non-passthrough
    /// action) and whose mouseUp is still pending. macOS's HID layer still
    /// treats the physical button as held, so mouse movement gets classified
    /// as .rightMouseDragged / .otherMouseDragged with this button number
    /// attached — games whose input tap only listens for .mouseMoved (GLFW's
    /// captured-cursor path, used by Minecraft) drop those samples on the
    /// floor. While a button number is in this set, the tap rewrites its
    /// drag events back into .mouseMoved so mouse-look keeps working.
    private var suppressedButtons: Set<Int64> = []

    /// Bring the tap in line with the current mappings. When nothing is
    /// remapped, the tap is torn down entirely so we don't wake on every
    /// system-wide click or keystroke. Called from apply(), refreshTrust(),
    /// and (indirectly) on macOS-triggered tap timeouts. Idempotent.
    func reconfigureTap() {
        var mask: UInt64 = 0
        for t in neededEventTypes() { mask |= (1 << t.rawValue) }

        // Nothing to intercept → tear down whatever's live.
        if mask == 0 {
            uninstallTap()
            return
        }
        // Already configured correctly.
        if let existing = tap, CGEvent.tapIsEnabled(tap: existing), currentMask == mask {
            return
        }
        // Rebuild — CGEventTap's mask is fixed at creation.
        uninstallTap()
        installTap(mask: mask)
    }

    /// Minimum CGEventTypes required by the current mappings. Buttons whose
    /// action is `.passthrough` don't need their event types in the mask —
    /// leaving them out means macOS never wakes us for those events at all.
    private func neededEventTypes() -> Set<CGEventType> {
        var types = Set<CGEventType>()
        let buttons: [(MouseButton, [CGEventType])] = [
            (.rightClick,   [.rightMouseDown, .rightMouseUp]),
            (.scrollClick,  [.otherMouseDown, .otherMouseUp]),
            (.scrollUp,     [.scrollWheel]),
            (.scrollDown,   [.scrollWheel]),
            (.mouseButton4, [.otherMouseDown, .otherMouseUp]),
            (.mouseButton5, [.otherMouseDown, .otherMouseUp]),
        ]
        var anyRemap = false
        for (btn, evts) in buttons {
            if mappings.action(for: btn) != .passthrough {
                types.formUnion(evts)
                anyRemap = true
            }
        }
        // When we swallow a mouseDown, the physical button stays "held" at
        // the HID layer, so motion events arrive as rightMouseDragged /
        // otherMouseDragged instead of mouseMoved. Intercept those so the
        // callback can rewrite them (see tapCallback). Left drags are always
        // legitimate (left is locked to passthrough), so we leave them out.
        if anyRemap {
            types.insert(.rightMouseDragged)
            types.insert(.otherMouseDragged)
        }
        // Firmware-remapped side buttons emit keys instead of mouse events.
        // Only listen for keyDown when we actually have a trigger to match —
        // otherwise typing anywhere would wake this app on every keystroke.
        if !mappings.triggers.isEmpty {
            types.insert(.keyDown)
        }
        // Scroll transform also lives on this tap. When it's on we need
        // scrollWheel events even if no scrollUp/scrollDown button remap
        // is set.
        if ScrollTransformer.shared.settings.enabled {
            types.insert(.scrollWheel)
        }
        return types
    }

    private func installTap(mask: UInt64) {
        guard AXIsProcessTrusted() else {
            Log.warn("skip event tap install — Accessibility not granted")
            return
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: ButtonMap.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.warn("CGEventTap create failed")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = src
        self.currentMask = mask
        Log.info("event tap installed mask=0x\(String(mask, radix: 16))")
    }

    private func uninstallTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            self.runLoopSource = nil
        }
        if let existing = tap {
            CGEvent.tapEnable(tap: existing, enable: false)
            // Explicit invalidate so the port sheds its runloop retain now;
            // ARC releasing the CFMachPort alone leaves the port drifting
            // until the last source retain drains.
            CFMachPortInvalidate(existing)
            self.tap = nil
            Log.info("event tap uninstalled")
        }
        self.currentMask = 0
    }

    /// Map a raw CG event's button + type into (MouseButton, isDown).
    /// Scroll-wheel events are handled earlier in tapCallback so they never
    /// reach this classifier.
    private static func classify(type: CGEventType, event: CGEvent) -> (MouseButton, Bool)? {
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        let isDown = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)
        switch (type, btn) {
        case (.leftMouseDown, _), (.leftMouseUp, _):   return (.leftClick,    isDown)
        case (.rightMouseDown, _), (.rightMouseUp, _): return (.rightClick,   isDown)
        case (.otherMouseDown, 2), (.otherMouseUp, 2): return (.scrollClick,  isDown)
        case (.otherMouseDown, 3), (.otherMouseUp, 3): return (.mouseButton4, isDown)
        case (.otherMouseDown, 4), (.otherMouseUp, 4): return (.mouseButton5, isDown)
        default: return nil
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let this = Unmanaged<ButtonMap>.fromOpaque(refcon).takeUnretainedValue()

        // Fast-path our own synthesized events. Mapping a physical button
        // to `.mouseClick(.middle)` or `.typeText(…)` produces events whose
        // types are in our own mask — without this early-return we'd re-enter
        // the tap forever. The marker is stamped by stampedSource(); the
        // scroll transformer uses its own separate marker below.
        let mark = event.getIntegerValueField(.eventSourceUserData)
        if mark == ButtonMap.ownEventMarker || mark == ScrollTransformer.ownEventMarker {
            return Unmanaged.passUnretained(event)
        }

        // Re-enable the tap if macOS ever times it out on us. Also drop any
        // in-flight Turbo timers — during the disabled window the physical
        // button's UP event never reached us, so we don't know if it's
        // still held. Best case scenario, the timer would keep auto-firing
        // whatever action was mapped forever, until the user opens the app
        // and changes the mapping.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            this.stopAllTurbo()
            // We missed however many up events during the disabled window;
            // don't try to guess which physical buttons are still held.
            this.suppressedButtons.removeAll()
            if let tap = this.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Physical buttons whose down we consumed still register as held at
        // the HID layer, so the corresponding movement events arrive here as
        // drag types. Rewrite them into mouseMoved so downstream taps (e.g.
        // GLFW's raw-motion tap in Minecraft) still see cursor deltas while
        // the button is held.
        if type == .rightMouseDragged || type == .otherMouseDragged {
            let btnNum = event.getIntegerValueField(.mouseEventButtonNumber)
            if this.suppressedButtons.contains(btnNum) {
                let dx = event.getIntegerValueField(.mouseEventDeltaX)
                let dy = event.getIntegerValueField(.mouseEventDeltaY)
                let loc = event.location
                let src = this.stampedSource()
                if let moved = CGEvent(mouseEventSource: src,
                                       mouseType: .mouseMoved,
                                       mouseCursorPosition: loc,
                                       mouseButton: .left) {
                    moved.setIntegerValueField(.mouseEventDeltaX, value: dx)
                    moved.setIntegerValueField(.mouseEventDeltaY, value: dy)
                    moved.post(tap: .cghidEventTap)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // keyDown is only in the tap mask when we actually have a virtual
        // trigger to match (see reconfigureTap). Match silently — do NOT
        // log the raw keycode/modifiers here: /tmp/bskv3xhs.log is world-
        // readable and we don't want a plaintext record of every keystroke
        // the user makes while a trigger is configured.
        if type == .keyDown {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if let (btn, action) = this.matchKeyTrigger(keyCode: UInt16(kc), flags: flags) {
                Log.info("matched virtual trigger for \(btn.rawValue) → \(action.label)")
                if action != .passthrough {
                    this.fire(action)
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Scroll goes through its own path: a direction-based button remap
        // (scrollUp / scrollDown → action) wins over the transformer; if
        // no such remap is set, run the event through ScrollTransformer
        // (reverse + smoothing). Handling scroll here means the transformer
        // never runs on events we've already consumed for a button action.
        if type == .scrollWheel {
            let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let mappedBtn: MouseButton? = {
                if dy > 0 { return .scrollUp }
                if dy < 0 { return .scrollDown }
                return nil
            }()
            if let btn = mappedBtn {
                let action = this.mappings.action(for: btn)
                if action != .passthrough {
                    let turbo = this.mappings.turbo(for: btn)
                    Log.info("tap saw \(btn.rawValue) → action=\(action.label)\(turbo.enabled ? " [turbo \(turbo.rate)Hz]" : "")")
                    if turbo.enabled {
                        this.startTurbo(btn: btn, action: action, rate: turbo.rate)
                    } else {
                        this.fire(action)
                    }
                    return nil
                }
            }
            switch ScrollTransformer.shared.handle(event) {
            case .passthrough, .modified: return Unmanaged.passUnretained(event)
            case .consumed:               return nil
            }
        }

        guard let (btn, isDown) = classify(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        // Always terminate any in-flight turbo for this button on UP —
        // before the passthrough guard. If the mapping was changed to
        // passthrough while the button was still held down, the guard
        // below would return early and the timer would never be stopped.
        if !isDown { this.stopTurbo(btn: btn) }

        let action = this.mappings.action(for: btn)
        let turbo = this.mappings.turbo(for: btn)
        if isDown {
            Log.info("tap saw button=\(btn.rawValue) down → action=\(action.label)\(turbo.enabled ? " [turbo \(turbo.rate)Hz]" : "")")
        }
        guard action != .passthrough else {
            return Unmanaged.passUnretained(event)
        }
        // Remember (or forget) that this physical button's down was consumed
        // so drag→moved rewriting above can gate on it.
        let rawBtnNum = event.getIntegerValueField(.mouseEventButtonNumber)
        if isDown {
            this.suppressedButtons.insert(rawBtnNum)
        } else {
            this.suppressedButtons.remove(rawBtnNum)
        }
        // .modifier honors the whole press/release lifecycle — post keyDown
        // on button-down and keyUp on button-up so hold-drag (⌘-drag etc.)
        // works. Turbo is meaningless here so it's ignored.
        if case .modifier(let mods) = action {
            this.applyModifierHold(mods, for: btn, down: isDown)
            return nil
        }
        // Safety net: if the mapping just changed away from .modifier while
        // the button was still held, we still need to release whatever
        // keys we had down for it.
        if !isDown { this.releaseHeldModifier(for: btn) }
        if isDown {
            if turbo.enabled {
                this.startTurbo(btn: btn, action: action, rate: turbo.rate)
            } else {
                this.fire(action)
            }
        }
        return nil
    }

    // MARK: - Turbo scheduling
    private var turboTimers: [String: DispatchSourceTimer] = [:]
    // Dedicated high-priority background queue so timer ticks aren't dropped
    // when the main thread is busy with SwiftUI redraws.
    private let turboQueue = DispatchQueue(label: "bskv3xhs.turbo", qos: .userInteractive)

    private func startTurbo(btn: MouseButton, action: ButtonAction, rate: Int) {
        stopTurbo(btn: btn)
        // Nanosecond precision + tight leeway so schedule is accurate.
        let ns = UInt64(1_000_000_000 / max(1, rate))
        let timer = DispatchSource.makeTimerSource(queue: turboQueue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(ns)),
                       repeating: .nanoseconds(Int(ns)),
                       leeway: .nanoseconds(500_000))    // 0.5 ms
        timer.setEventHandler { [weak self] in
            // fire() reaches AppKit APIs that are documented main-only
            // (NSWorkspace.open, NSEvent.mouseLocation, NSScreen.main) and
            // ButtonMap itself is @MainActor — so hop back to main. If main
            // is genuinely swamped, Turbo ticks queue up rather than
            // crashing on a background AppKit access.
            DispatchQueue.main.async { self?.fire(action) }
        }
        timer.resume()
        turboTimers[btn.rawValue] = timer
    }
    private func stopTurbo(btn: MouseButton) {
        if let t = turboTimers.removeValue(forKey: btn.rawValue) { t.cancel() }
    }

    private func stopAllTurbo() {
        for (_, t) in turboTimers { t.cancel() }
        turboTimers.removeAll()
    }

    /// Which MouseButton (if any) is bound to a specific keyboard-event
    /// trigger. Used for firmware-remapped side buttons that emit keys.
    private func matchKeyTrigger(keyCode: UInt16, flags: CGEventFlags) -> (MouseButton, ButtonAction)? {
        for b in MouseButton.allCases {
            switch mappings.virtualTrigger(for: b) {
            case .some(let t) where t.keyCode == keyCode && t.matches(flags):
                return (b, mappings.action(for: b))
            default: continue
            }
        }
        return nil
    }

    /// DeviceController installs a handler here so a Sensitivity action can
    /// reach the mouse. Kept as a closure so ButtonMap doesn't need to know
    /// about the controller directly.
    var onSensitivity: ((SensitivityAction) -> Void)?

    private func fire(_ action: ButtonAction) {
        switch action {
        case .passthrough:
            return
        case .disabled:
            return                              // event was already consumed
        case .keyStroke(let k):
            var flags = translate(k.mods)
            if isFunctionLayerKey(UInt16(k.keyCode)) { flags.insert(.maskSecondaryFn) }
            postKeyStroke(CGKeyCode(k.keyCode), flags: flags)
        case .mouseClick(let m):
            let button: CGMouseButton = {
                switch m {
                case .left:   return .left
                case .right:  return .right
                case .middle: return .center
                }
            }()
            postMouseClickPair(button, at: currentMouseLocation())
        case .multimedia(let m):
            MediaKeyPoster.post(m)
        case .sensitivity(let s):
            onSensitivity?(s)
        case .launch(let target):
            if target.runInTerminal {
                launchInTerminal(command: target.url)
            } else {
                guard let url = URL(string: target.url) else { return }
                NSWorkspace.shared.open(url)
            }
        case .syntheticMouse(let s):
            fireSynthetic(s)
        case .typeText(let text):
            typeText(text)
        case .modifier:
            // Handled in the tap callback with proper down/up lifecycle.
            // Reaching here would mean fire() was called for a modifier
            // action outside the tap path — treat as no-op.
            return
        }
    }

    // ─── Modifier-hold ───────────────────────────────────────────────
    // Per-button record of which modifier virtual keys we currently have
    // "held down" via SetReport. Keyed by MouseButton.rawValue. On the
    // matching button-up we post keyUp for each; on a stray up (mapping
    // changed mid-hold) `releaseHeldModifier` fires the cleanup.
    private var heldModifiers: [String: NSEvent.ModifierFlags] = [:]

    private func applyModifierHold(_ mods: NSEvent.ModifierFlags, for btn: MouseButton, down: Bool) {
        if down {
            // If somehow already recorded (rapid re-press with a stale up
            // never delivered), tear the previous set down first so the
            // OS's flag state stays consistent.
            releaseHeldModifier(for: btn)
            postModifierEvents(mods, down: true)
            heldModifiers[btn.rawValue] = mods
        } else {
            releaseHeldModifier(for: btn)
        }
    }

    private func releaseHeldModifier(for btn: MouseButton) {
        guard let mods = heldModifiers.removeValue(forKey: btn.rawValue) else { return }
        postModifierEvents(mods, down: false)
    }

    /// Post keyDown or keyUp for each modifier bit in `mods`. Uses the
    /// left-side virtual keycodes (⌃=0x3B, ⌥=0x3A, ⇧=0x38, ⌘=0x37) —
    /// macOS treats "any of the pair as pressed" as the modifier being
    /// active, so left-only is fine and keeps the label unambiguous.
    private func postModifierEvents(_ mods: NSEvent.ModifierFlags, down: Bool) {
        let src = stampedSource()
        // Post them in a fixed order (⌃⌥⇧⌘) so ordering artefacts in
        // event coalescing don't produce different behavior between two
        // "identical" modifier sets. Each event carries the CUMULATIVE
        // set of modifiers so the OS ends up in the right state whether
        // we're pressing or releasing.
        struct M { let flag: NSEvent.ModifierFlags; let key: CGKeyCode; let cgFlag: CGEventFlags }
        let all: [M] = [
            .init(flag: .control, key: 0x3B, cgFlag: .maskControl),
            .init(flag: .option,  key: 0x3A, cgFlag: .maskAlternate),
            .init(flag: .shift,   key: 0x38, cgFlag: .maskShift),
            .init(flag: .command, key: 0x37, cgFlag: .maskCommand),
        ]
        var cumulativeFlags: CGEventFlags = []
        // On down: post in ⌃⌥⇧⌘ order, each event carrying the flags
        // accumulated so far. On up: reverse order, each event carrying
        // the flags still remaining after this one goes up.
        let order: [M] = down ? all.filter { mods.contains($0.flag) }
                              : all.filter { mods.contains($0.flag) }.reversed()
        if down {
            for m in order {
                cumulativeFlags.insert(m.cgFlag)
                let ev = CGEvent(keyboardEventSource: src, virtualKey: m.key, keyDown: true)
                ev?.flags = cumulativeFlags
                ev?.post(tap: .cghidEventTap)
            }
        } else {
            cumulativeFlags = []
            for m in all where mods.contains(m.flag) { cumulativeFlags.insert(m.cgFlag) }
            for m in order {
                cumulativeFlags.remove(m.cgFlag)
                let ev = CGEvent(keyboardEventSource: src, virtualKey: m.key, keyDown: false)
                ev?.flags = cumulativeFlags
                ev?.post(tap: .cghidEventTap)
            }
        }
    }

    private func fireSynthetic(_ s: SyntheticMouse) {
        switch s {
        case .doubleClick:
            let pt = currentMouseLocation()
            // Two left clicks with clickState 2 on the second for macOS to
            // register a proper double-click.
            postMouseClickPair(.left, at: pt, clickState: 1)
            postMouseClickPair(.left, at: pt, clickState: 2)
        case .scrollUp, .scrollDown:
            let dy: Int32 = (s == .scrollUp) ? 3 : -3
            postScroll(axis: .vertical, delta: dy)
        case .scrollLeft, .scrollRight:
            let dx: Int32 = (s == .scrollRight) ? 3 : -3
            postScroll(axis: .horizontal, delta: dx)
        case .bossKey:
            // "Hide app" — ⌘H on the frontmost app.
            postKeyStroke(CGKeyCode(kVK_ANSI_H), flags: .maskCommand)
        }
    }

    // MARK: - Event synthesis helpers

    /// Post a key-down followed by a delayed key-up. The 2 ms gap gives
    /// target apps' text input pipelines a beat to register each event
    // ─── Own-event marker ────────────────────────────────────────────
    // Every event we synthesize below gets stamped with this magic value
    // on its `CGEventSource.userData`. The tap callback checks the field
    // FIRST and passes through anything that carries the marker — without
    // this, mapping a button to `.mouseClick(.middle)` or `.typeText(…)`
    // would re-enter the tap and loop forever (the very same otherMouseDown
    // / keyDown types are in our mask).
    static let ownEventMarker: Int64 = 0x4253_4B53_5459_5000  // "BSKSTYP\0"

    /// Build a stamped event source. Callers pass the result into
    /// `CGEvent(...Source:)` factories, and every event derived from it
    /// carries the marker in `.eventSourceUserData`.
    private func stampedSource() -> CGEventSource? {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.userData = ButtonMap.ownEventMarker
        return src
    }

    /// instead of coalescing them at high Turbo rates. asyncAfter (not
    /// usleep) so we don't stall the runloop the tap callback runs on.
    private func postKeyStroke(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = stampedSource()
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2)) {
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Post a paired mouse down/up at the given point. Optional
    /// `clickState` is used for double-click sequences (macOS keys off it
    /// to decide whether two clicks fuse into one double-click).
    private func postMouseClickPair(_ button: CGMouseButton, at point: CGPoint, clickState: Int64? = nil) {
        let src = stampedSource()
        let (downType, upType): (CGEventType, CGEventType) = {
            switch button {
            case .left:  return (.leftMouseDown, .leftMouseUp)
            case .right: return (.rightMouseDown, .rightMouseUp)
            default:     return (.otherMouseDown, .otherMouseUp)
            }
        }()
        let down = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: point, mouseButton: button)
        let up   = CGEvent(mouseEventSource: src, mouseType: upType,   mouseCursorPosition: point, mouseButton: button)
        if let state = clickState {
            down?.setIntegerValueField(.mouseEventClickState, value: state)
            up?.setIntegerValueField(.mouseEventClickState, value: state)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private enum ScrollAxis { case vertical, horizontal }
    private func postScroll(axis: ScrollAxis, delta: Int32) {
        let src = stampedSource()
        let event: CGEvent? = {
            switch axis {
            case .vertical:
                return CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
            case .horizontal:
                return CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0)
            }
        }()
        event?.post(tap: .cghidEventTap)
    }

    /// Current cursor position translated into CGEvent's flipped-Y coord
    /// space. AppKit reports mouseLocation with y growing upward from the
    /// primary display's bottom-left; CGEvent expects y growing downward
    /// from top-left.
    private func currentMouseLocation() -> CGPoint {
        let loc = NSEvent.mouseLocation
        return CGPoint(x: loc.x, y: (NSScreen.main?.frame.height ?? 0) - loc.y)
    }

    /// Types a string at the current keyboard focus using
    /// `CGEventKeyboardSetUnicodeString`. Works with any Unicode text and any
    /// keyboard layout because we're passing the resolved characters, not
    /// virtual key codes.
    private func typeText(_ text: String) {
        let src = stampedSource()
        for scalar in text.unicodeScalars {
            var chars: [UniChar] = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Open Terminal and run `command` in a fresh window. Uses AppleScript
    /// because Terminal has no `x-command:` URL scheme, and a stray temp
    /// `.command` file left in /tmp reads as junk on the user's disk. First
    /// invocation triggers a one-time Automation permission prompt for
    /// Terminal — that's a fair price for launching a CLI from a mouse
    /// button. `command` is expected to already be shell-quoted (the CLI
    /// preset resolves the absolute binary path with quotes).
    private func launchInTerminal(command: String) {
        // Escape backslashes and double-quotes so the AppleScript literal
        // survives command paths with spaces / unusual characters.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                Log.warn("Terminal launch failed: \(error)")
            }
        }
    }

    private func isFunctionLayerKey(_ code: UInt16) -> Bool {
        // These are the keys that the Mac keyboard reports with `.function`
        // set on physical press.
        let ids: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                             kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End,
                             kVK_ForwardDelete]
        return ids.contains(Int(code))
    }

    private func translate(_ m: NSEvent.ModifierFlags) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.shift)   { f.insert(.maskShift) }
        if m.contains(.option)  { f.insert(.maskAlternate) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.function){ f.insert(.maskSecondaryFn) }
        return f
    }
}
