import SwiftUI
import AppKit

// Synapse-style floating HUD framework. Originally just for the DPI-cycle
// stage indicator; extended to cover other transient events the user
// asked to be surfaced (auto-profile switch, connection change, battery
// milestones). One shared NSPanel that swaps content — only ever one
// HUD visible at a time.
//
// Rendering notes:
//   • NSPanel shadow is disabled so SwiftUI can draw its own rounded
//     shadow around the glass shape — the default AppKit shadow is
//     rectangular and betrays the pill outline.
//   • The panel background is fully transparent; the visible surface
//     is `.glassEffect()` (macOS 26 Liquid Glass) or `.regularMaterial`
//     on older systems, both applied inside SwiftUI so the shape and
//     corner radius match the shadow.
//   • Positioned top-right of the pointer's screen, flush with the
//     visible frame — matches where macOS 26 puts most transient HUDs
//     and where the main settings panel also opens.

@MainActor
final class SystemHUD {
    static let shared = SystemHUD()

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var dismissWork: DispatchWorkItem?

    private let visibleDuration: TimeInterval = 1.8
    private let fadeInDuration: TimeInterval = 0.22
    private let fadeOutDuration: TimeInterval = 0.28

    private init() {}

    /// Present (or refresh) the HUD with the given content view. Safe to
    /// call repeatedly — a second call re-renders content and restarts
    /// the auto-dismiss timer without a hide/show flicker.
    func show<Content: View>(_ content: Content, duration: TimeInterval? = nil) {
        let erased = AnyView(content)
        let panel = ensurePanel()
        hosting?.rootView = erased

        // Re-measure — HUD content is variable-size (DPI text width,
        // profile name length, etc.), so the panel frame must track
        // the SwiftUI content's fitting size on every show.
        if let hosting {
            hosting.setFrameSize(hosting.fittingSize)
            panel.setContentSize(hosting.fittingSize)
        }
        positionPanel(panel)

        dismissWork?.cancel()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeInDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            // A second show during an in-flight fade should snap back to
            // fully visible; otherwise the user sees a mid-opacity flash.
            panel.animator().alphaValue = 1
        }

        let hold = duration ?? visibleDuration
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            // A show() that landed during the fade-out will have set
            // alphaValue back to 1 (mid-flight cancel); if we still
            // orderOut here the panel disappears out from under the user.
            // Only hide when the fade actually completed to zero.
            guard let panel, panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }

        // Start with an empty placeholder — `show()` sets the real content
        // via `hosting.rootView =` immediately after this returns. Doing
        // both here and there was harmless but redundant.
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        // Panel is created with a small placeholder size; `show()` resizes
        // it to the real content's fitting size immediately, before the
        // panel is ordered front, so nothing at a "wrong" size is ever
        // painted on-screen.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // `.screenSaver` sits above menu bar and full-screen apps so
        // the HUD still surfaces during a game or presentation.
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting

        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
        guard let screen else { return }

        let size = panel.frame.size
        let frame = screen.visibleFrame
        // Content-flush positioning: the panel's SwiftUI content includes a
        // gutter around the pill so the shadow blur can complete without
        // clipping. Offset the panel origin by that gutter in both axes so
        // the visible pill — not the panel bounds — lines up flush with the
        // top-right corner of the visible frame. The shadow gutter extends
        // above vis.maxY into the menu-bar strip, which is fine at
        // `.screenSaver` level (nothing to obscure there).
        let x = frame.maxX - size.width + HUDCardView.gutter
        let y = frame.maxY - size.height + HUDCardView.gutter
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

// ─── Public presenters ────────────────────────────────────────────────

extension SystemHUD {
    func showDPIStage(stage: Int, total: Int, dpi: DPIStageValue) {
        show(DPIStageHUDView(stage: stage, total: total, dpi: dpi))
    }

    func showProfileSwitch(name: String) {
        show(HUDCardView(icon: "person.crop.circle.fill",
                         tint: .accentColor,
                         title: name))
    }

    func showConnectionChange(kind: ConnectionKind) {
        let (icon, tint, title): (String, Color, String)
        switch kind {
        case .dongle:
            // Filled variant so the plug reads at a glance instead of
            // looking like an empty outline.
            icon = "cable.connector"
            tint = .blue
            title = String(localized: "Connected")
        case .bluetooth:
            // `dot.radiowaves.left.and.right` is the canonical wireless
            // pairing glyph in macOS Control Center and always renders
            // (the plain `bluetooth` symbol is unreliable on some
            // macOS releases — used to show as a placeholder box).
            icon = "dot.radiowaves.left.and.right"
            tint = .blue
            title = String(localized: "Bluetooth")
        case .none:
            icon = "cable.connector.slash"
            tint = .red
            title = String(localized: "Disconnected")
        }
        show(HUDCardView(icon: icon, tint: tint, title: title))
    }

    // (Removed `showBatteryMilestone(percent:kind:)` and its
    // `BatteryMilestone` enum — zero callers. `showBatteryPercent(_:)`
    // below replaced them: it derives icon and tint from the reading
    // itself across five bands instead of taking a caller-supplied
    // three-way classification, so the milestone variant had nothing
    // left to do.)

    /// Transient error toast — used when a physical-button action
    /// failed silently in a way the user needs to know about (e.g.
    /// Terminal Automation permission denied for a CLI action).
    /// Slightly wider than the standard HUDs and allows 3 wrapped
    /// lines so the actionable hint has room to breathe. Also
    /// stays visible longer since the user needs time to read it.
    func showActionError(_ title: String) {
        show(HUDCardView(icon: "exclamationmark.triangle.fill",
                         tint: .orange,
                         title: title,
                         lineLimit: 3,
                         maxWidth: 320),
             duration: 4.0)
    }

    /// Per-drop battery HUD — replaces the macOS notification path for
    /// the "Notify at threshold" toggle. macOS was silently coalescing /
    /// Focus-mode-suppressing the notifications; a HUD is 100% controlled
    /// by the app so it always surfaces. Icon and colour degrade with
    /// the reading so the user sees at a glance whether they've just
    /// dropped from full or crossed into red territory.
    func showBatteryPercent(_ pct: Int) {
        let (icon, tint): (String, Color)
        switch pct {
        case 76...:   (icon, tint) = ("battery.100", .green)
        case 51...75: (icon, tint) = ("battery.75",  .green)
        case 26...50: (icon, tint) = ("battery.50",  .yellow)
        case 11...25: (icon, tint) = ("battery.25",  .orange)
        default:      (icon, tint) = ("battery.0",   .red)
        }
        show(HUDCardView(icon: icon,
                         tint: tint,
                         title: String(format: String(localized: "Battery %lld%%"), pct)))
    }
}

// Backwards-compat alias — earlier call sites used `DPIStageHUD.shared.show(...)`.
typealias DPIStageHUD = SystemHUD

// ─── Content views ────────────────────────────────────────────────────

/// DPI stage indicator — capsule row + big DPI number.
struct DPIStageHUDView: View {
    let stage: Int
    let total: Int
    let dpi: DPIStageValue

    private var dpiText: String {
        dpi.x == dpi.y ? "\(dpi.x)" : "\(dpi.x) × \(dpi.y)"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<total, id: \.self) { i in
                    let active = (i + 1 == stage)
                    Capsule()
                        .fill(active ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: active ? 22 : 12, height: 4)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(dpiText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("DPI")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.4)
            }
            Text("STAGE \(stage) / \(total)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(1.2)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 20)
        .frame(minWidth: 280)
        .liquidGlass(cornerRadius: 20)
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
        .padding(HUDCardView.gutter)
        .fixedSize()
    }
}

/// Vertical HUD card: big semantically-tinted SF Symbol on top, short
/// title below. Same overall shape as the DPI-stage HUD so all HUDs
/// read as one language. `tint` carries the event's meaning (green /
/// blue / orange / red) — the text itself stays primary-colour so the
/// card doesn't look neon.
struct HUDCardView: View {
    let icon: String
    let tint: Color
    let title: String
    /// Max lines the title is allowed to wrap to. 1 for the short
    /// glyph+label HUDs ("Connected", "Bluetooth", "Battery 42%");
    /// higher for the error variant which carries actionable text
    /// like "Enable Terminal in Automation settings."
    var lineLimit: Int = 1
    /// Max width the pill is allowed to grow to before wrapping.
    /// Short labels center in the default minWidth; longer error
    /// messages get a wider box (still centered) so wrapping
    /// happens naturally instead of clipping.
    var maxWidth: CGFloat = 260

    /// Room around the pill for the shadow blur to complete before
    /// hitting the NSHostingView bounds. SwiftUI clips shadows to the
    /// view frame, so this needs to be ≥ the shadow radius or the
    /// clip line reads as a hard grey rectangle.
    static let gutter: CGFloat = 28

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .frame(minWidth: 200, maxWidth: maxWidth)
        .liquidGlass(cornerRadius: 20)
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
        .padding(HUDCardView.gutter)
        .fixedSize(horizontal: true, vertical: false)
    }
}
