import SwiftUI
import AppKit

// ─── Sidebar sections ─────────────────────────────────────────────────

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case sensitivity, reporting, scroll, buttons, lighting, power, profile, device
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sensitivity: return "Sensitivity"
        case .reporting:   return "Report rate"
        case .scroll:      return "Scroll"
        case .buttons:     return "Buttons"
        case .lighting:    return "Lighting"
        case .power:       return "Power"
        case .profile:     return "Profiles"
        case .device:      return "Device"
        }
    }
    var symbol: String {
        switch self {
        case .sensitivity: return "cursorarrow.motionlines"
        case .reporting:   return "waveform.path"
        case .scroll:      return "arrow.up.arrow.down"
        case .buttons:     return "hand.point.up.left"
        case .lighting:    return "lightbulb"
        case .power:       return "battery.100"
        case .profile:     return "person.crop.circle.badge.checkmark"
        case .device:      return "info.circle"
        }
    }
    /// Concise pane-header subtitle. Kept short — Synapse never explains
    /// *why*, just names what's on the pane. See Localizable.strings for
    /// the localized values (zh-Hans).
    var subtitle: String {
        switch self {
        case .sensitivity: return "DPI stages"
        case .reporting:   return "Polling rate"
        case .scroll:      return "Wheel direction and smoothing"
        case .buttons:     return "Button remap and turbo"
        case .lighting:    return "Scroll wheel LED"
        case .power:       return "Battery and idle sleep"
        case .profile:     return "Auto-switch by focused app"
        case .device:      return "Hardware and utilities"
        }
    }

    /// True when this pane's writes require the 2.4 GHz dongle transport.
    /// Over Bluetooth these panes are shown but locked out — the Razer
    /// transaction protocol isn't reachable so the writes have no effect.
    var requiresDongle: Bool {
        switch self {
        case .sensitivity, .reporting, .lighting: return true
        // Power reads battery from macOS's IORegistry over BT, so the
        // pane is partially usable — the idle-sleep card locks itself
        // internally when we're not on the dongle.
        case .power, .scroll, .buttons, .profile, .device: return false
        }
    }
}

// ─── Root ────────────────────────────────────────────────────────────

struct MainView: View {
    @EnvironmentObject var status: Status
    @EnvironmentObject var controller: DeviceController
    @State private var selection: AppSection? = .sensitivity
    @State private var draft: AppSettings = SettingsStore.shared.current
    @State private var footer: FooterState = .idle
    /// When the user last mutated `draft`. Guards the external-update paths
    /// below: while the user is actively dragging a slider, incoming
    /// publishes (from `apply()` completing, `syncFromHardware`, etc.)
    /// would snap the slider backward under their finger. Skipping the
    /// reset for a short window after each edit lets the user's edits win.
    @State private var draftLastEdit: Date = .distantPast
    private let draftHoldWindow: TimeInterval = 0.6
    /// Slider-drag state coordinator — MainView listens so it can defer
    /// autoApply until every active slider drag has ended (users read
    /// "still holding the slider" as "don't save yet"). See
    /// SliderCommitCoordinator for the contract.
    @ObservedObject private var sliderCoord = SliderCommitCoordinator.shared

    enum FooterState {
        case idle, working(String), ok(String), error(String)
        var showsAny: Bool {
            if case .idle = self { return false }; return true
        }
    }

    var body: some View {
        // Manual HStack layout instead of NavigationSplitView. Tahoe's
        // NavigationSplitView applied a floating-sidebar treatment we
        // couldn't opt out of — it vertically re-centered the sidebar
        // column against the detail column when the two had different
        // content heights, producing the "sidebar sits 120 pt below
        // detail hero when on dongle" bug the user reported. HStack
        // gives us a hard predictable top alignment: both columns
        // start at y=0 of the window.
        HStack(spacing: 0) {
            // Floating-capsule sidebar — Tahoe Finder style. The sidebar
            // is inset from the window edges with rounded corners and
            // its own translucent material, so it reads as a distinct
            // pane hovering over the window's Liquid Glass instead of
            // fusing with the detail column. `.regularMaterial` auto-
            // upgrades to Liquid Glass on macOS 26; pre-26 users get the
            // same translucent look System Settings has always used.
            Sidebar(selection: $selection)
                .frame(width: 210)
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(DS.border, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                )
                .padding(.leading, 10)
                .padding(.vertical, 10)
                .padding(.trailing, 4)
            VStack(spacing: 0) {
                DetailHero(section: selection)
                Divider().opacity(0.3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Banner only appears on the Power pane over BT so
                        // users understand *why* the Idle-sleep card is
                        // locked. Every other visible pane on BT works
                        // fully — the banner would be noise.
                        if status.connection == .bluetooth && selection == .power {
                            BluetoothBanner()
                        }
                        switch selection {
                        case .sensitivity: SensitivityPane(dpi: $draft.dpi)
                        case .reporting:   ReportingPane(hz: $draft.pollRateHz)
                        case .scroll:      ScrollPane(draft: $draft)
                        case .power:       PowerPane(draft: $draft)
                        case .profile:     ProfilePane()
                        case .device:      DevicePane(draft: $draft)
                        case .buttons:     ButtonsPane(draft: $draft)
                        case .lighting:    LightingPane(draft: $draft)
                        case .none:        EmptyView()
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
            }
            .animation(.easeInOut(duration: 0.15), value: footer.showsAny)
        }
        // Floating status toast — overlays the top-right corner so it
        // doesn't push detail content up and cause a scroll bar to appear
        // like the old bottom footer did.
        .overlay(alignment: .topTrailing) {
            if footer.showsAny {
                StatusBar(footer: $footer)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Single translucent surface for the whole window. Using
        // `.regularMaterial` rather than `.glassEffect()` here: nested
        // glassEffect layers (window → sidebar → card) can't share a
        // GlassEffectContainer, so on macOS 26 the inner ones render
        // as opaque milky rectangles instead of refracting the layer
        // beneath. Material stacks cleanly, and macOS 26 auto-lifts
        // it to Liquid Glass characteristics anyway.
        .background(.regularMaterial)
        .frame(minWidth: 900, idealWidth: 900, minHeight: 580, idealHeight: 580)
        // Extend content behind the titlebar strip so the visible top of
        // the panel is the sidebar / detail content itself, not an empty
        // grey band left over by `.titled` styleMask. Titlebar is still
        // there for drag support (isMovableByWindowBackground), just no
        // longer showing its own chrome.
        .ignoresSafeArea(edges: .top)
        // When a profile switch happens (or on first sync from hardware),
        // re-seed the draft so the panes reflect the active profile.
        // Guarded by `draftHoldWindow` so a debounced apply landing right
        // after the user paused a drag doesn't yank the slider back to the
        // stale committed value.
        .onReceive(status.$settings) { s in
            guard Date().timeIntervalSince(draftLastEdit) > draftHoldWindow else { return }
            if s != draft { draft = s }
        }
        .onReceive(SettingsStore.shared.$file) { _ in
            guard Date().timeIntervalSince(draftLastEdit) > draftHoldWindow else { return }
            let cur = SettingsStore.shared.current
            if cur != draft { draft = cur }
        }
        // A profile switch (or a fresh "New Profile" that flips activeID)
        // must always re-seed the draft, even if the user was mid-edit —
        // otherwise the pre-switch draft rides across the switch, and the
        // next `draft.onChange` fires an apply() that writes the previous
        // profile's edits into whichever profile is now active. That was
        // reproducible as "created a new profile, edited it, went back to
        // the old one — old one had my new edits too".
        .onReceive(SettingsStore.shared.$file.map(\.activeID).removeDuplicates().dropFirst()) { _ in
            let cur = SettingsStore.shared.current
            if cur != draft { draft = cur }
            // Clear the edit window too: any pending debounce belongs to
            // the previous profile and shouldn't gate the new one.
            draftLastEdit = .distantPast
        }
        // First-launch-over-BT UX: if we land on a dongle-only pane while
        // the mouse is reachable only via Bluetooth, jump to the first
        // usable pane so users aren't looking at a dimmed disabled screen.
        // Also fires when the user unplugs the dongle while sitting on
        // one of the dongle-only panes.
        .onAppear { autoSelectUsablePane() }
        .onChange(of: status.connection) { _, _ in autoSelectUsablePane() }
        .onChange(of: draft) { old, next in
            draftLastEdit = Date()
            // Slider still under the user's finger — mid-drag values are
            // draft-only for now. The `.onChange(of: sliderCoord.activeDrags)`
            // handler below fires the commit once the last drag ends.
            guard sliderCoord.activeDrags == 0 else { return }
            // Lighting-only changes take a fast path — writing DPI/poll/idle
            // alongside a mode/color tweak visibly restarts the mouse's LED
            // effect timer (spectrum/wave stutter) and adds ~1.5s of latency.
            if old.lighting != next.lighting {
                var normalized = old
                normalized.lighting = next.lighting
                if normalized == next {
                    scheduleLightingApply(next.lighting)
                    return
                }
            }
            scheduleAutoApply(next)
        }
        .onChange(of: sliderCoord.activeDrags) { _, count in
            // Last slider release — commit whatever draft holds now.
            // Guarded against stray decrements when the count was already
            // zero so we don't fire an apply on cold start.
            guard count == 0 else { return }
            scheduleAutoApply(draft)
        }
    }

    /// Debounce hardware writes so dragging a slider doesn't spam the mouse:
    /// coalesces to ~150 ms — matches Synapse's near-instant feel while still
    /// batching mid-drag ticks into a single HID write. Held on the
    /// controller so device-lifecycle callbacks can cancel it if the dongle
    /// disappears mid-write.
    private func scheduleAutoApply(_ next: AppSettings) {
        controller.autoApplyTask?.cancel()
        controller.autoApplyTask = Task { [weak controller] in
            guard let controller else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            await MainActor.run { footer = .working(String(localized: "Applying…")) }
            do {
                try await controller.apply(next)
                await MainActor.run {
                    footer = .ok(String(localized: "Saved"))
                    Task { try? await Task.sleep(nanoseconds: 1_400_000_000)
                           await MainActor.run { if case .ok = footer { footer = .idle } } }
                }
            } catch is CancellationError {
                // Superseded by a newer edit; the follow-up task is already
                // running. Suppress the transient footer flash entirely.
                await MainActor.run { if case .working = footer { footer = .idle } }
            } catch {
                await MainActor.run { footer = .error(String(describing: error)) }
            }
        }
    }

    /// Steer users away from a dimmed disabled pane when the current pane
    /// requires the dongle but we're over Bluetooth. We only redirect —
    /// never lock the user out of clicking back to a dongle-only pane from
    /// the sidebar, so they can still preview settings that would apply
    /// once the dongle returns.
    private func autoSelectUsablePane() {
        guard status.connection == .bluetooth,
              let s = selection, s.requiresDongle else { return }
        // Prefer Scroll (input-side feature that just landed on this pane)
        // as the first stop; falls back to whatever the enum says.
        selection = AppSection.allCases.first { !$0.requiresDongle } ?? .device
    }

    /// Fast path for lighting-only changes. Split into two debounced tasks
    /// so flash wear stays bounded during a drag:
    ///
    ///  • **RAM task** (100 ms) — writes the effect / brightness to the
    ///    mouse's RAM so the LED updates near-instantly. Does NOT touch
    ///    onboard flash. Rebuilt on every drag frame.
    ///  • **Flash-commit task** (500 ms) — writes the settled state to
    ///    onboard flash. Cancelled and re-armed on every drag frame, so it
    ///    only fires once the user has stopped moving — a long slow
    ///    ColorPicker drag becomes exactly one flash write instead of one
    ///    per debounce interval.
    private func scheduleLightingApply(_ lighting: LightingSettings) {
        // RAM update — cheap, non-persistent, safe to fire often.
        controller.lightingRAMTask?.cancel()
        controller.lightingRAMTask = Task { [weak controller] in
            guard let controller else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            do {
                try await controller.applyLighting(lighting, commitToFlash: false)
            } catch {
                // Silent — RAM writes are best-effort feedback, not the
                // persistence path. Flash commit below is what has to land.
            }
        }
        // Flash commit — one write per drag session.
        controller.lightingFlashTask?.cancel()
        controller.lightingFlashTask = Task { [weak controller] in
            guard let controller else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            do {
                try await controller.applyLighting(lighting, commitToFlash: true)
            } catch is CancellationError {
                // Newer edit landed while this commit was in-flight; the
                // successor's own flash task is already queued. Swallow
                // silently — user isn't done editing yet, don't flash a
                // fake error into the footer.
            } catch {
                await MainActor.run { footer = .error(String(describing: error)) }
            }
        }
    }
}

// ─── Sidebar ─────────────────────────────────────────────────────────

private struct Sidebar: View {
    @Binding var selection: AppSection?
    @EnvironmentObject var status: Status
    @ObservedObject private var store = SettingsStore.shared

    /// Sections the current transport can actually configure. Over BT the
    /// vendor-protocol panes (Sensitivity/Reporting/Lighting) are hidden
    /// entirely rather than shown-and-dimmed — user asked for clean
    /// "if I can't use it, hide it" behaviour so the sidebar only lists
    /// things that will actually work when clicked. A footer note names
    /// what's hidden so discoverability isn't lost.
    private var visibleSections: [AppSection] {
        if status.connection == .bluetooth {
            return AppSection.allCases.filter { !$0.requiresDongle }
        }
        return AppSection.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Padding at top adds visual breathing room now that
            // .ignoresSafeArea has pulled the content up over the
            // titlebar strip — without this the mouse thumb touches
            // the panel's top edge.
            SidebarHeader()
                .padding(.horizontal, 12)
                .padding(.top, 40)
                .padding(.bottom, 14)

            sectionLabel("Profile")
            ProfilePicker()
                .padding(.horizontal, 8)
                .padding(.bottom, 12)

            sectionLabel("Configuration")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleSections) { s in
                    sectionRow(s)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            // Footnote when sections are hidden so users know they exist.
            if status.connection == .bluetooth {
                Divider().padding(.horizontal, 14).padding(.bottom, 6)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("Plug in the dongle for DPI, polling rate, and lighting.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }

    /// Small caps-style label between sidebar sections. Matches macOS
    /// System Settings' subtle group headers rather than the loud
    /// bordered dividers we had before.
    @ViewBuilder private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }

    @ViewBuilder private func sectionRow(_ s: AppSection) -> some View {
        let selected = (selection == s)
        Button {
            selection = s
        } label: {
            HStack(spacing: 10) {
                // Icon + text both take `.primary` when unselected so the
                // row reads as a solid black label on the material,
                // matching the selected row's solid-white contrast rather
                // than fading the icon out with `.secondary`.
                Image(systemName: s.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(LocalizedStringKey(s.title))
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            // Hover wash sits BEHIND the selected fill (background modifiers
            // stack inside-out), so selected rows still read as accent while
            // unselected rows pick up a soft primary tint under the pointer.
            .hoverHighlight(cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }
}

// ─── Profile picker ──────────────────────────────────────────────────

private struct ProfilePicker: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var renaming: UUID? = nil
    @State private var draftName: String = ""
    /// UUID pending deletion — presented via `.confirmationDialog`. Delete is
    /// irreversible (no undo, no trash) and profiles hold serious tuning, so
    /// a one-click destructive menu item was too dangerous.
    @State private var pendingDelete: Profile? = nil

    var body: some View {
        Menu {
            SwiftUI.Section("Switch profile") {
                ForEach(store.file.profiles) { p in
                    Button {
                        store.setActive(p.id)
                    } label: {
                        if p.id == store.file.activeID {
                            Label(p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name)
                        }
                    }
                }
            }
            Divider()
            Button {
                let name = "Profile \(store.file.profiles.count + 1)"
                store.addProfile(name: name)
            } label: { Label("New profile", systemImage: "plus") }
            Button {
                store.duplicateActive()
            } label: { Label("Duplicate active", systemImage: "plus.square.on.square") }
            if let active = store.file.profiles.first(where: { $0.id == store.file.activeID }) {
                Button {
                    draftName = active.name
                    renaming = active.id
                } label: { Label("Rename active", systemImage: "pencil") }
                if store.file.profiles.count > 1 {
                    Button(role: .destructive) {
                        pendingDelete = active
                    } label: { Label("Delete active", systemImage: "trash") }
                }
            }
        } label: {
            // Padding + background live OUTSIDE this label — the
            // `.borderlessButton` menu style adds its own implicit
            // internal inset that would misalign the icon by a few
            // points against the section rows and would also swallow
            // the custom rounded-pill background. Applying the visual
            // treatment on the Menu itself sidesteps both.
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .quaternarySystemFill).opacity(0.6))
        )
        .sheet(item: $renaming) { id in
            RenameSheet(name: $draftName) { newName in
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { store.renameProfile(id, to: trimmed) }
                renaming = nil
            } onCancel: { renaming = nil }
        }
        .confirmationDialog(
            // NB: `confirmationDialog(_:isPresented:...)` accepts a
            // LocalizedStringKey — passing "Delete profile \"%@\"?" would
            // be redundant since the profile name isn't itself localizable.
            // We localize the title by formatting via String(localized:).
            pendingDelete.map { String(localized: "Delete profile \"\($0.name)\"?") } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                store.deleteProfile(profile.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This can't be undone. All settings on this profile will be lost.")
        }
    }

    private var activeName: String {
        store.file.profiles.first { $0.id == store.file.activeID }?.name ?? "—"
    }
    private var subtitle: LocalizedStringKey {
        let n = store.file.profiles.count
        return n == 1 ? "1 profile" : "\(n) profiles"
    }
}

// Needed by `.sheet(item: $renaming)` where `renaming` is `UUID?`. Declared
// retroactive so a future Foundation-owned conformance doesn't collide.
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}


private struct RenameSheet: View {
    @Binding var name: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename profile").font(.system(size: 14, weight: .semibold))
            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") { onSave(name) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .liquidGlassSheet()
    }
}

private struct SidebarHeader: View {
    @EnvironmentObject var status: Status
    // Centred vertical layout — the sidebar is 210 pt wide with 12 pt
    // padding on either side, so there's ~186 pt to work with. A more
    // premium look than a cramped horizontal row: a rounded product
    // thumbnail on top, product name below it, then a small
    // connection-state chip that reads left-to-right.
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            mouseThumb()
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
            VStack(spacing: 4) {
                Text("BSK V3 X HS")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                statusChip
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Small pill under the product name: connection glyph + subtitle
    /// (battery % if we've got one, otherwise the transport name).
    /// Neutral, subtle — doesn't compete with the section list below.
    private var statusChip: some View {
        HStack(spacing: 4) {
            Image(systemName: dotIcon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(dotColor)
            Text(verbatim: subtitleText)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: .quaternarySystemFill).opacity(0.6)))
    }

    @ViewBuilder private func mouseThumb() -> some View {
        if let url = Bundle.main.url(forResource: "mouse", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .padding(4)
        } else {
            Image(systemName: "computermouse")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
    private var dotColor: Color {
        switch status.connection {
        case .none:      return .secondary.opacity(0.5)
        case .bluetooth: return .blue.opacity(0.85)
        case .dongle:    return status.awake ? .green : .secondary.opacity(0.6)
        }
    }
    private var dotIcon: String {
        switch status.connection {
        case .none:      return "xmark.circle.fill"
        case .bluetooth: return "wave.3.right.circle.fill"
        case .dongle:    return status.awake ? "circle.fill" : "moon.fill"
        }
    }
    /// Two-segment status label: transport name + battery percentage
    /// separated by a middle dot. Composed from `String(localized:)`
    /// pieces rather than a single interpolated literal — that way the
    /// individual words go through the .strings lookup even though the
    /// battery number itself is dynamic. The final composed string is
    /// then handed to `Text` verbatim (see `statusChip`) to avoid a
    /// second lookup on the composed value.
    private var subtitleText: String {
        switch status.connection {
        case .none:
            return String(localized: "Disconnected")
        case .bluetooth:
            let transport = String(localized: "Bluetooth")
            if let pct = status.battery { return "\(transport) · \(pct)%" }
            return transport
        case .dongle:
            let transport = status.awake
                ? String(localized: "Dongle")
                : String(localized: "Dongle · Idle")
            if let pct = status.battery { return "\(transport) · \(pct)%" }
            return transport
        }
    }
}

// ─── Detail hero (title + connection pill) ────────────────────────────

private struct DetailHero: View {
    let section: AppSection?
    var body: some View {
        // Connection state is now surfaced in the sidebar header (a
        // more permanent home) — no ConnectionPill here; that removes
        // the duplication and gives the hero row breathing room for a
        // longer subtitle without competing with a chip.
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(section?.title ?? ""))
                    .font(.system(size: 22, weight: .semibold))
                Text(LocalizedStringKey(section?.subtitle ?? ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 14)
    }
}

// ─── Bluetooth notice ────────────────────────────────────────────────

/// One-line notice shown only on the Power pane over BT, where the
/// Idle-sleep card is dimmed. Native `Label` + secondary text — the same
/// shape macOS System Settings uses for "this needs something else"
/// hints. No glass tile, no two-column feature matrix.
private struct BluetoothBanner: View {
    var body: some View {
        Label {
            Text("Connected over Bluetooth — idle-sleep needs the dongle.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .padding(.vertical, 4)
    }
}

// (DongleLockOverlay was removed — sidebar now filters out dongle-only
// panes over BT so the "locked pane" state is unreachable and its
// modifier was dead code.)

