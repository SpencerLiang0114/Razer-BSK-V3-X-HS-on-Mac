import SwiftUI
import AppKit
import Carbon.HIToolbox

// ─── Remap picker sheet — Synapse-style two-pane categorized nav ─────

private enum PickerCategory: String, CaseIterable, Identifiable {
    case defaultAction, aiLauncher, keyboard, mouse, sensitivity
    case multimedia, launch, macShortcuts, textFunction, disable
    var id: String { rawValue }
    var label: String {
        switch self {
        case .defaultAction: return "Default"
        case .aiLauncher:    return "AI Launcher"
        case .keyboard:      return "Keyboard"
        case .mouse:         return "Mouse"
        case .sensitivity:   return "Sensitivity"
        case .multimedia:    return "Multimedia"
        case .launch:        return "Launch"
        case .macShortcuts:  return "macOS Shortcuts"
        case .textFunction:  return "Text Function"
        case .disable:       return "Disable"
        }
    }
    var symbol: String {
        switch self {
        case .defaultAction: return "arrow.uturn.backward"
        case .aiLauncher:    return "sparkles"
        case .keyboard:      return "keyboard"
        case .mouse:         return "computermouse"
        case .sensitivity:   return "cursorarrow.motionlines"
        case .multimedia:    return "speaker.wave.2"
        case .launch:        return "square.and.arrow.up.on.square"
        case .macShortcuts:  return "command"
        case .textFunction:  return "text.cursor"
        case .disable:       return "nosign"
        }
    }
    var subtitle: String {
        switch self {
        case .defaultAction: return "Restore original behavior."
        case .aiLauncher:    return "ChatGPT, Claude, Gemini, or another AI chat."
        case .keyboard:      return "Keyboard shortcut or common action."
        case .mouse:         return "Emit another mouse action."
        case .sensitivity:   return "Switch DPI stage."
        case .multimedia:    return "Volume, playback, brightness."
        case .launch:        return "Open a URL, file, or app."
        case .macShortcuts:  return "Common macOS shortcuts."
        case .textFunction:  return "Type text at the cursor."
        case .disable:       return "Swallow the press — do nothing."
        }
    }
}

struct RemapPicker: View {
    let button: MouseButton
    @Binding var draft: AppSettings
    let onClose: () -> Void

    @State private var selectedCategory: PickerCategory = .defaultAction
    @State private var launchName = ""
    @State private var launchURL  = ""
    @State private var textDraft  = ""
    /// Local buffer for the Turbo rate slider — writes disk / re-applies
    /// ButtonMap only on drag-end so mid-scrub values don't hammer save.
    @State private var turboScrub: Int? = nil
    /// Drives the "Learn" button for firmware-remapped side buttons.
    @StateObject private var triggerCapture = KeyTriggerCapture()

    private var current: ButtonAction {
        draft.buttons.action(for: button)
    }
    private func commit(_ a: ButtonAction) {
        draft.buttons.set(a, for: button)
        ButtonMap.shared.apply(draft.buttons)
        SettingsStore.shared.updateActive { $0 = draft }
        onClose()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                CategoryList(selection: $selectedCategory)
                    .frame(width: 180)
                Divider().opacity(0.35)
                ScrollView {
                    contentPane
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Turbo footer only shows once the button has a real action —
            // Default / Disable modes don't emit anything to repeat.
            // Also hidden for scroll-wheel direction buttons: wheel events
            // are one-shot (no "up" event to stop a repeating timer), so
            // a turbo timer would run forever. ButtonMap ignores turbo on
            // scroll actions too; hiding the toggle keeps the UI honest.
            if current != .passthrough && current != .disabled
               && button != .scrollUp && button != .scrollDown {
                Divider()
                turboFooter
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            // Firmware-remap footer. Only meaningful for the two side
            // buttons — they're the ones Synapse remaps to keystrokes.
            if button == .mouseButton4 || button == .mouseButton5 {
                Divider()
                firmwareTriggerFooter
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .frame(width: 760, height: 540)
        // Sheets on macOS ship with their own opaque presentation
        // background — `.liquidGlassPanel()` alone can't override it.
        // `.liquidGlassSheet()` swaps that default material out for our
        // Liquid Glass surface so the whole sheet reads as one continuous
        // glass panel, matching the main window.
        .liquidGlassSheet()
        .onAppear { selectedCategory = initialCategory() }
    }

    // MARK: - Firmware-remap trigger footer

    /// A mouse whose onboard profile was configured by Razer Synapse can have
    /// its side buttons emit *keystrokes* instead of mouse buttons. macOS then
    /// never generates `otherMouseDown` for them, so the event tap has nothing
    /// to intercept and the button silently does nothing no matter what action
    /// is assigned here.
    ///
    /// `ButtonMappings.triggers` is the escape hatch: record the keystroke the
    /// button actually emits and the tap matches on that instead. The model and
    /// tap sides shipped, but nothing could ever populate the dictionary — this
    /// footer is that missing piece.
    private var firmwareTriggerFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Firmware-remapped button")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .help("If this button was remapped by Razer Synapse it sends a keyboard key, not a mouse button — so macOS never reports it as a mouse click and the action above never runs. Click Learn, then press the button once to capture what it actually sends.")
                Spacer()
                if draft.buttons.virtualTrigger(for: button) != nil {
                    Button("Clear") {
                        draft.buttons.setTrigger(nil, for: button)
                        persistTrigger()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button(triggerCapture.isListening ? "Press the button now…" : "Learn") {
                    triggerCapture.start { captured in
                        draft.buttons.setTrigger(captured, for: button)
                        persistTrigger()
                    }
                }
                .disabled(triggerCapture.isListening)
                Text(triggerDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(triggerCapture.isListening ? .primary : .secondary)
            }
        }
    }

    private var triggerDescription: String {
        if triggerCapture.isListening {
            return String(localized: "Listening — press the mouse button once.")
        }
        guard let t = draft.buttons.virtualTrigger(for: button) else {
            return String(localized: "Not set. Use this only if the button does nothing.")
        }
        return String(localized: "Triggered by") + " " + KeyTriggerFormatter.describe(t)
    }

    private func persistTrigger() {
        ButtonMap.shared.apply(draft.buttons)
        SettingsStore.shared.updateActive { $0 = draft }
    }

    // MARK: - Turbo footer

    private var turbo: TurboSettings {
        draft.buttons.turbo(for: button)
    }

    private var turboFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { turbo.enabled },
                    set: { setTurbo(TurboSettings(enabled: $0, rate: turbo.rate)) }
                )) {
                    Text("Enable Turbo")
                        .font(.system(size: 12, weight: .medium))
                }.toggleStyle(.checkbox)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .help("Repeats the action while held. Speed is presses per second.")
                Spacer()
            }

            if turbo.enabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speed (press/sec)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        // Editable text field + up/down stepper, matching
                        // Synapse's Speed input. Both read `turboScrub ??
                        // turbo.rate` so mid-Slider-drag values show
                        // consistently everywhere; both commit through
                        // `setTurbo(...)` and clear `turboScrub` so any
                        // pending scrub value doesn't shadow the just-
                        // committed rate on the next read.
                        HStack(spacing: 0) {
                            TextField("", value: Binding(
                                get: { turboScrub ?? turbo.rate },
                                set: {
                                    setTurbo(TurboSettings(enabled: true, rate: min(20, max(1, $0))))
                                    turboScrub = nil
                                }
                            ), format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .monospacedDigit()
                                .multilineTextAlignment(.center)
                                .frame(width: 36)
                            Stepper("", value: Binding(
                                get: { turboScrub ?? turbo.rate },
                                set: {
                                    setTurbo(TurboSettings(enabled: true, rate: min(20, max(1, $0))))
                                    turboScrub = nil
                                }
                            ), in: 1...20)
                            .labelsHidden()
                        }
                        .padding(.vertical, 3).padding(.leading, 6).padding(.trailing, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))

                        Text("1").font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(turboScrub ?? turbo.rate) },
                            set: { turboScrub = min(20, max(1, Int($0.rounded()))) }
                        ), in: 1...20,
                        onEditingChanged: { editing in
                            if !editing, let r = turboScrub {
                                setTurbo(TurboSettings(enabled: true, rate: r))
                                turboScrub = nil
                            }
                        })
                            .tint(.green)
                        Text("20").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("Presses per second while the button is held.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 2)
                }
            }
        }
    }

    private func setTurbo(_ t: TurboSettings) {
        draft.buttons.setTurbo(t, for: button)
        ButtonMap.shared.apply(draft.buttons)
        SettingsStore.shared.updateActive { $0 = draft }
    }

    private func initialCategory() -> PickerCategory {
        switch current {
        case .passthrough:     return .defaultAction
        case .disabled:        return .disable
        case .keyStroke:       return .keyboard
        case .modifier:        return .keyboard
        case .mouseClick, .syntheticMouse: return .mouse
        case .sensitivity:     return .sensitivity
        case .multimedia:      return .multimedia
        case .launch:          return .launch
        case .typeText:        return .textFunction
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Format-string interpolation via LocalizedStringKey — the
                // "Remap %@" / "Currently: %@" keys map to zh-Hans in
                // Localizable.strings with the same positional argument.
                Text("Remap \(button.label)")
                    .font(.system(size: 15, weight: .semibold))
                Text("Currently: \(current.label)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Right pane

    @ViewBuilder private var contentPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(selectedCategory.label))
                .font(.system(size: 16, weight: .semibold))
            Text(LocalizedStringKey(selectedCategory.subtitle))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)

            switch selectedCategory {
            case .defaultAction:
                bigRow("Default", desc: "Passes the click through as-is.", isSelected: current == .passthrough) {
                    commit(.passthrough)
                }
            case .disable:
                bigRow("Disable", desc: "Swallows the button press.", isSelected: current == .disabled) {
                    commit(.disabled)
                }
            case .aiLauncher:   aiLauncherPane
            case .keyboard:     keyboardPane
            case .mouse:        mousePane
            case .sensitivity:  sensitivityPane
            case .multimedia:   multimediaPane
            case .launch:       launchPane
            case .macShortcuts: macShortcutsPane
            case .textFunction: textPane
            }
        }
    }

    // Persist across sheet reopens and sessions — sheet-local @State reset
    // to `true` every time the user tapped a different button, forcing them
    // to re-pick "Always use web" over and over.
    @AppStorage("remap.aiPreferApp") private var aiPreferApp = true

    private var aiLauncherPane: some View {
        let guiPresets = AIPreset.all.filter { if case .gui = $0.kind { return true } else { return false } }
        let cliPresets = AIPreset.all.filter { if case .cli = $0.kind { return true } else { return false } }
        return VStack(alignment: .leading, spacing: 12) {
            // GUI-preset toggle: only relevant for the chat apps section.
            // CLI presets always run in Terminal, so we hide the toggle
            // when only CLI rows would be shown.
            Picker("", selection: $aiPreferApp) {
                Text("Prefer installed app").tag(true)
                Text("Always use web").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 6)
            .help("Applies to chat apps below. CLI shortcuts always open in Terminal.")

            ForEach(guiPresets) { p in aiRow(preset: p) }

            // Divider + CLI section — greys out items whose command isn't
            // on PATH so users see them but can't click them.
            Divider().padding(.vertical, 4)
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Command-line tools")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Opens a Terminal window and runs the command. Greyed rows aren't installed on this Mac.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            ForEach(cliPresets) { p in aiRow(preset: p) }
        }
    }

    /// One row in the AI Launcher list. GUI presets show the installed-app
    /// or browser icon; CLI presets show the terminal icon and are dimmed
    /// when their command isn't on PATH.
    @ViewBuilder
    private func aiRow(preset p: AIPreset) -> some View {
        let target = p.resolvedTarget(preferApp: aiPreferApp)
        let available = p.isAvailable
        let isSelected: Bool = {
            guard let target else { return false }
            return current == .launch(target)
        }()
        Button {
            guard let target else { return }
            commit(.launch(target))
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: iconName(for: p))
                    .font(.system(size: 15))
                    .foregroundStyle(iconColor(for: p))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 13, weight: .medium))
                    Text(subtitle(for: p))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        .font(.system(size: 16))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectableCard(selected: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1.0 : 0.45)
        .help(available ? "" : "Command not found on PATH. Install it, then reopen this picker.")
        .hoverPointer()
    }

    private func iconName(for p: AIPreset) -> String {
        switch p.kind {
        case .gui:
            return (p.isAppInstalled && aiPreferApp) ? "app.badge.checkmark" : "safari"
        case .cli:
            return "terminal"
        }
    }
    private func iconColor(for p: AIPreset) -> Color {
        switch p.kind {
        case .gui:
            return (p.isAppInstalled && aiPreferApp) ? Color.accentColor : Color.secondary
        case .cli:
            return p.isAvailable ? Color.accentColor : Color.secondary
        }
    }
    private func subtitle(for p: AIPreset) -> LocalizedStringKey {
        switch p.kind {
        case .gui:
            if p.isAppInstalled && aiPreferApp {
                return "Launches installed app"
            } else {
                return "Opens \(p.webURL) in your browser"
            }
        case .cli(let command):
            if p.isAvailable {
                return "Runs `\(command)` in a new Terminal window"
            } else {
                return "`\(command)` not installed"
            }
        }
    }

    private var macShortcutsPane: some View {
        let cols = [GridItem(.adaptive(minimum: 200), spacing: 8)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(KeyCombo.macShortcuts, id: \.self) { k in
                shortcutRow(name: shortcutTitle(k), combo: k)
            }
        }
    }

    /// Two-line card for a macOS shortcut: title on top, SF-Symbol chip on
    /// bottom, matching how System Settings shows Keyboard shortcuts.
    private func shortcutRow(name: String, combo k: KeyCombo) -> some View {
        let selected = current == .keyStroke(k)
        return Button {
            commit(.keyStroke(k))
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(name)).font(.system(size: 12, weight: .medium))
                    KeyComboChip(combo: k)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        .font(.system(size: 14))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectableCard(selected: selected, stroke: .always)
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }

    /// Strips the `(⌘C)`-style suffix out of the preset label so the two-line
    /// row can show a clean title with the SF-Symbol chip below it.
    private func shortcutTitle(_ k: KeyCombo) -> String {
        if let paren = k.label.firstIndex(of: "(") {
            return String(k.label[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return k.label
    }

    private var textPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text to type").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: $textDraft)
                .font(.system(size: 12))
                .frame(minHeight: 80, maxHeight: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            HStack {
                Button {
                    commit(.typeText(textDraft))
                } label: {
                    Text("Save").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(textDraft.isEmpty)
                Text("Types text at the cursor.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        // Seed the editor from the current mapping so reopening the sheet
        // on a button already bound to `.typeText("foo")` shows "foo"
        // rather than an empty field. Mirrors `seedManualFromCurrent()`
        // in the keyboard pane.
        .onAppear {
            if case .typeText(let s) = current { textDraft = s }
        }
    }

    @State private var manualMods: NSEvent.ModifierFlags = []
    @State private var manualKey: UInt16? = nil
    @State private var keyGroup: KeyGroup = .letters

    private var keyboardPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Live preview with Save + Clear
            HStack(spacing: 10) {
                Text("Shortcut").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                if let k = builtCombo {
                    KeyComboChip(combo: k)
                } else if let m = builtModifier {
                    Text("Hold \(modifierGlyphString(m))")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Pick modifiers, or modifiers + a key")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { manualMods = []; manualKey = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .disabled(manualMods.isEmpty && manualKey == nil)
                Button {
                    if let k = builtCombo {
                        commit(.keyStroke(k))
                    } else if let m = builtModifier {
                        commit(.modifier(m))
                    }
                } label: {
                    Text("Save").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            Divider()

            Text("Modifiers").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                modChip("control", flag: .control)
                modChip("option",  flag: .option)
                modChip("shift",   flag: .shift)
                modChip("command", flag: .command)
                Spacer()
            }

            Text("Key").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
            Picker("", selection: $keyGroup) {
                ForEach(KeyGroup.allCases) { g in Text(LocalizedStringKey(g.label)).tag(g) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let cols = [GridItem(.adaptive(minimum: 44), spacing: 6)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                ForEach(keyGroup.codes, id: \.self) { c in
                    keyPickChip(code: c)
                }
            }
        }
        .onAppear { seedManualFromCurrent() }
    }

    private var builtCombo: KeyCombo? {
        guard let key = manualKey else { return nil }
        let label = renderCombo(keyCode: key, mods: manualMods)
        return KeyCombo(keyCode: key, mods: manualMods, label: label)
    }

    /// When the user has picked modifiers but no key, we emit
    /// `.modifier(mods)` (hold-while-pressed) instead of `.keyStroke(...)`.
    private var builtModifier: NSEvent.ModifierFlags? {
        (manualKey == nil && !manualMods.isEmpty) ? manualMods : nil
    }

    private var canSave: Bool { builtCombo != nil || builtModifier != nil }

    private func seedManualFromCurrent() {
        if case .keyStroke(let k) = current {
            manualMods = k.mods; manualKey = k.keyCode
            for g in KeyGroup.allCases where g.codes.contains(k.keyCode) { keyGroup = g }
        } else if case .modifier(let m) = current {
            manualMods = m; manualKey = nil
        }
    }

    private func modChip(_ symbol: String, flag: NSEvent.ModifierFlags) -> some View {
        let on = manualMods.contains(flag)
        return Button {
            if on { manualMods.remove(flag) } else { manualMods.insert(flag) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(labelFor(flag)).font(.system(size: 11))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : Color(nsColor: .quaternarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.accentColor.opacity(0.5) : DS.border, lineWidth: 0.5))
            .foregroundStyle(on ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func labelFor(_ flag: NSEvent.ModifierFlags) -> String {
        switch flag {
        case .control: return "Control"
        case .option:  return "Option"
        case .shift:   return "Shift"
        case .command: return "Command"
        default:       return ""
        }
    }

    private func keyPickChip(code: UInt16) -> some View {
        let selected = manualKey == code
        return Button {
            manualKey = code
        } label: {
            KeyBadgeSquare(code: code, selected: selected)
        }
        .buttonStyle(.plain)
    }

    private var mousePane: some View {
        let cols = [GridItem(.adaptive(minimum: 150), spacing: 6)]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Mouse buttons").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                ForEach(SynthMouseButton.allCases, id: \.self) { m in
                    chip(LocalizedStringKey(m.label), selected: current == .mouseClick(m)) { commit(.mouseClick(m)) }
                }
            }
            Text("Extended actions").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                ForEach(SyntheticMouse.allCases, id: \.self) { s in
                    chip(LocalizedStringKey(s.label), selected: current == .syntheticMouse(s)) { commit(.syntheticMouse(s)) }
                }
            }
        }
    }

    private var sensitivityPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            bigRow("Cycle to next DPI stage",
                   desc: "Move to the next stage in the DPI list.",
                   isSelected: current == .sensitivity(.nextStage)) {
                commit(.sensitivity(.nextStage))
            }
            bigRow("Cycle to previous DPI stage",
                   desc: "Move to the previous stage in the DPI list.",
                   isSelected: current == .sensitivity(.previousStage)) {
                commit(.sensitivity(.previousStage))
            }
            Text("Go to a specific stage").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).padding(.top, 6)
            // Range follows the profile's actual DPI stage count so a
            // user with 3 stages can't bind `.specificStage(5)` and end
            // up commanding the mouse to a stage that doesn't exist.
            let stageCount = max(1, draft.dpi.stages.count)
            let cols = [GridItem(.adaptive(minimum: 100), spacing: 6)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                ForEach(1...stageCount, id: \.self) { i in
                    chip("Stage \(i)", selected: current == .sensitivity(.specificStage(i))) {
                        commit(.sensitivity(.specificStage(i)))
                    }
                }
            }
        }
    }

    private var multimediaPane: some View {
        let cols = [GridItem(.adaptive(minimum: 150), spacing: 6)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            ForEach(MediaKey.allCases) { m in
                chip(LocalizedStringKey(m.label), selected: current == .multimedia(m)) { commit(.multimedia(m)) }
            }
        }
    }

    private var launchPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose Application…") { pickApp() }
                    .buttonStyle(.bordered)
                Text("…or type a URL below").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Text("Display name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("ChatGPT", text: $launchName).textFieldStyle(.roundedBorder).font(.system(size: 13))
            Text("URL or file:// path").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 6)
            TextField("https://chatgpt.com  or  file:///Applications/Safari.app", text: $launchURL)
                .textFieldStyle(.roundedBorder).font(.system(size: 13))

            HStack(spacing: 8) {
                Button {
                    guard !launchURL.isEmpty else { return }
                    let name = launchName.isEmpty ? URL(string: launchURL)?.host ?? launchURL : launchName
                    commit(.launch(LaunchTarget(displayName: name, url: launchURL)))
                } label: {
                    Text("Save").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(launchURL.isEmpty)
            }.padding(.top, 6)

            if case .launch(let t) = current {
                Divider().padding(.vertical, 6)
                Text("Currently launches").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(t.displayName) — \(t.url)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            launchName = url.deletingPathExtension().lastPathComponent
            launchURL = url.absoluteString
        }
    }

    // MARK: - Small helpers

    @ViewBuilder
    private func bigRow(_ title: LocalizedStringKey, desc: LocalizedStringKey, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        .font(.system(size: 16))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectableCard(selected: isSelected)
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }

    @ViewBuilder
    private func chip(_ text: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).font(.system(size: 12))
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint).font(.system(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .selectableCard(selected: selected,
                            cornerRadius: 6,
                            accentWashOpacity: 0.18,
                            stroke: .selectedOnly)
        }
        .buttonStyle(.plain)
    }
}

private struct CategoryList: View {
    @Binding var selection: PickerCategory
    var body: some View {
        List(PickerCategory.allCases, selection: $selection) { c in
            Label(c.label, systemImage: c.symbol)
                .font(.system(size: 13))
                .tag(c)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // No solid background — the parent RemapPicker container carries
        // the Liquid Glass surface, and stacking a second material on top
        // muddies the effect on Tahoe. List keeps its own selection tint.
    }
}
