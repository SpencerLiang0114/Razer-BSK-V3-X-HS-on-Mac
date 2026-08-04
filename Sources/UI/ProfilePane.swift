import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ─── Profiles pane ───────────────────────────────────────────────────
//
// The one place where profile management lives: switch/add/rename/delete,
// bind apps to a profile so it auto-activates on focus, and pick the
// default profile that auto-switch falls back to when no rule matches.
//
// Kept out of DetailPanes.swift because ProfilePane is a full mini-screen
// on its own (three cards, a picker sheet, a delete confirmation) —
// crowding it into the shared file made both harder to navigate.

struct ProfilePane: View {
    @ObservedObject private var store = SettingsStore.shared
    /// Profile currently being renamed. UUID? so `.sheet(item:)` binds.
    @State private var renamingID: UUID? = nil
    @State private var renameDraft: String = ""
    /// Profile pending deletion — shown via `.confirmationDialog` so a
    /// misclick doesn't wipe a carefully-tuned profile.
    @State private var pendingDelete: Profile? = nil

    private var activeProfile: Profile? {
        store.file.profiles.first { $0.id == store.file.activeID }
    }

    var body: some View {
        Card(title: "Profiles") { profilesCardBody }
        Card(title: "Auto-switch") { autoSwitchCardBody }
    }

    // MARK: - Profiles list card

    @ViewBuilder
    private var profilesCardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.file.profiles) { p in
                profileRow(p)
                if p.id != store.file.profiles.last?.id {
                    Divider().opacity(0.35).padding(.leading, 28)
                }
            }
        }
        HStack(spacing: 8) {
            Button {
                let name = suggestNewProfileName()
                store.addProfile(name: name)
            } label: { Label("New profile", systemImage: "plus") }
            .buttonStyle(.bordered)

            Button {
                store.duplicateActive()
            } label: { Label("Duplicate active", systemImage: "plus.square.on.square") }
            .buttonStyle(.bordered)

            Button {
                if let a = activeProfile {
                    renameDraft = a.name
                    renamingID = a.id
                }
            } label: { Label("Rename", systemImage: "pencil") }
            .buttonStyle(.bordered)
            .disabled(activeProfile == nil)

            Spacer()

            Button(role: .destructive) {
                pendingDelete = activeProfile
            } label: { Label("Delete active", systemImage: "trash") }
            .buttonStyle(.bordered)
            .disabled(store.file.profiles.count <= 1)
        }
        .padding(.top, 6)
        .sheet(item: $renamingID) { id in
            RenameProfileSheet(name: $renameDraft) { newName in
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { store.renameProfile(id, to: trimmed) }
                renamingID = nil
            } onCancel: { renamingID = nil }
        }
        .confirmationDialog(
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

    /// One profile row. Click activates. Row background flips to a
    /// subtle accent wash when active so the state reads instantly
    /// without hunting for the radio dot. Default chip on the right,
    /// trigger-app count as a small footnote.
    @ViewBuilder
    private func profileRow(_ p: Profile) -> some View {
        let isActive = (p.id == store.file.activeID)
        let isDefault = (p.id == store.file.defaultID)
        Button {
            store.setActive(p.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.6))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name)
                            .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                            .foregroundStyle(.primary)
                        if isDefault {
                            Text("Default")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }
                    if !p.triggerBundleIDs.isEmpty {
                        Text(p.triggerBundleIDs.count == 1
                             ? "1 linked app"
                             : "\(p.triggerBundleIDs.count) linked apps")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .hoverHighlight(cornerRadius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }

    private func suggestNewProfileName() -> String {
        // Match Synapse: "Profile 2", "Profile 3", … avoiding collisions.
        var n = store.file.profiles.count + 1
        var candidate = "Profile \(n)"
        while store.file.profiles.contains(where: { $0.name == candidate }) {
            n += 1
            candidate = "Profile \(n)"
        }
        return candidate
    }

    // MARK: - Auto-switch card

    @ViewBuilder
    private var autoSwitchCardBody: some View {
        Text("Bring an app to the front and this profile activates. Move to any app that's not linked, and the default profile takes over.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider().opacity(0.4).padding(.vertical, 2)

        // Trigger apps for the CURRENTLY-ACTIVE profile. Users switch profile
        // via the list above (or the sidebar picker) and edit its triggers
        // here. Beats a per-row expander — one focus at a time is enough.
        if let active = activeProfile {
            HStack(spacing: 6) {
                Text("Trigger apps for")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(active.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            triggerAppsList(for: active)
            HStack {
                Menu {
                    Button {
                        pickAppToAdd(profileID: active.id)
                    } label: {
                        Label("Choose from Applications…", systemImage: "folder")
                    }
                    // Running-apps submenu — for cases where the trigger
                    // isn't the visible /Applications binary (Minecraft
                    // launched via a Java runtime, an Electron app whose
                    // binary lives inside a package, a Steam game). The
                    // user picks whichever process is actually frontmost
                    // during gameplay so auto-switch picks it up.
                    let running = runningAppsForPicker()
                    if !running.isEmpty {
                        Menu("Choose from running…") {
                            ForEach(running, id: \.key) { entry in
                                Button {
                                    store.addTriggerBundleID(entry.key, to: active.id)
                                } label: {
                                    // Menu items don't render NSImages from
                                    // Label automatically, so just show the
                                    // localized name — icon shows up in the
                                    // trigger list once linked.
                                    Text(entry.name)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add app…", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(.top, 4)
        }

        Divider().opacity(0.4).padding(.vertical, 6)

        // Default-profile toggle. Reads cleanly as a single Toggle bound to
        // "is the active profile the default?" — flipping on makes it so,
        // flipping off clears the default entirely.
        Toggle(isOn: Binding(
            get: { store.file.defaultID != nil && store.file.defaultID == store.file.activeID },
            set: { on in
                if on { store.setDefaultProfile(store.file.activeID) }
                else  { store.setDefaultProfile(nil) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use this profile as the default")
                    .font(.system(size: 13, weight: .medium))
                Text(defaultToggleSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    private var defaultToggleSubtitle: LocalizedStringKey {
        if let did = store.file.defaultID,
           let d = store.file.profiles.first(where: { $0.id == did }),
           did != store.file.activeID {
            return "Currently defaulting to \(d.name)."
        }
        return "Fallback when the focused app doesn't match any trigger list."
    }

    /// List of trigger-app rows for `profile`. Each row resolves the bundle
    /// ID to an installed app when possible so users see the icon + real
    /// name; a stale bundle ID (app uninstalled since binding) still shows
    /// with an "unknown" glyph and remains removable.
    @ViewBuilder
    private func triggerAppsList(for profile: Profile) -> some View {
        if profile.triggerBundleIDs.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("No apps linked yet. Add one below to make this profile activate on focus.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        } else {
            VStack(spacing: 4) {
                ForEach(profile.triggerBundleIDs, id: \.self) { bid in
                    triggerAppRow(bundleID: bid, profileID: profile.id)
                }
            }
        }
    }

    /// One trigger-app row. Big icon + name, faint bundle-ID underneath
    /// (helps users notice when two apps share a name), remove button on
    /// the right. Uses `.thinMaterial` so it blends with the Card's own
    /// material instead of sitting on top of it as an opaque slab.
    @ViewBuilder
    private func triggerAppRow(bundleID: String, profileID: UUID) -> some View {
        let resolved = resolveApp(bundleID)
        HStack(spacing: 12) {
            appIcon(resolved: resolved)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(resolved?.name ?? bundleID)
                    .font(.system(size: 13, weight: .medium))
                Text(bundleID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                store.removeTriggerBundleID(bundleID, from: profileID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("Remove this app from the trigger list")
            .hoverPointer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .selectableCard(selected: false, stroke: .always)
    }

    /// Resolve a trigger key (bundle ID or `exe:<name>`) to a display
    /// location + name.
    ///
    ///  • Bundle-ID keys: look up in NSWorkspace's bundle registry.
    ///    Returns nil when the app is uninstalled but still linked.
    ///  • `exe:<name>` keys: look for a currently-running process with
    ///    a matching executable name and use its icon + localized name.
    ///    Falls back to a nil resolution if no such process is running
    ///    — the row still renders (with the neutral glyph) and stays
    ///    removable.
    private func resolveApp(_ triggerKey: String) -> (url: URL, name: String)? {
        if triggerKey.hasPrefix("exe:") {
            let exe = String(triggerKey.dropFirst(4))
            guard let match = NSWorkspace.shared.runningApplications.first(where: {
                $0.executableURL?.lastPathComponent == exe
            }), let url = match.executableURL else { return nil }
            let name = match.localizedName ?? exe
            return (url, name)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: triggerKey),
              let bundle = Bundle(url: url) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        return (url, name)
    }

    /// AppKit icon for the row. Falls back to a neutral glyph when the
    /// bundle isn't resolvable.
    @ViewBuilder
    private func appIcon(resolved: (url: URL, name: String)?) -> some View {
        if let url = resolved?.url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
        }
    }

    /// Snapshot the currently-running apps for the "Choose from running…"
    /// submenu. Each entry's `key` is what we'll store in the trigger
    /// list — either the bundle identifier (preferred) or an
    /// `exe:<executable-name>` fallback when the process has no bundle
    /// (Java-based games opened by Prism/MultiMC, Electron dev builds,
    /// Steam-launched binaries — Activity Monitor still shows them but
    /// they never register a proper Info.plist). Deduped by key so
    /// multiple Chrome helpers don't spam the menu.
    private func runningAppsForPicker() -> [(key: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> (key: String, name: String)? in
                let key: String
                if let bid = app.bundleIdentifier, !bid.isEmpty {
                    key = bid
                } else if let exe = app.executableURL?.lastPathComponent, !exe.isEmpty {
                    key = "exe:\(exe)"
                } else {
                    return nil
                }
                let name = app.localizedName ?? key
                guard !name.isEmpty, !seen.contains(key) else { return nil }
                seen.insert(key)
                return (key: key, name: name)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Open NSOpenPanel scoped to /Applications so users pick apps
    /// visually rather than typing a bundle ID. We then read the app's
    /// Info.plist to extract the real bundle ID — matching whatever
    /// NSWorkspace's activation notifications will emit.
    private func pickAppToAdd(profileID: UUID) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an app to link")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Link")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url),
              let bid = bundle.bundleIdentifier else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't read that app's bundle ID")
            alert.informativeText = String(localized: "The picked app is missing a valid Info.plist. Pick a different app.")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        store.addTriggerBundleID(bid, to: profileID)
    }
}

// ─── Rename sheet (Profile pane's own copy) ─────────────────────────
//
// The one in MainView.swift is `private` so we can't reach it. Duplicate
// here — it's ~15 lines and giving the two panes their own sheets keeps
// scoping simple (no cross-file `internal` leak on a tiny detail).

private struct RenameProfileSheet: View {
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
