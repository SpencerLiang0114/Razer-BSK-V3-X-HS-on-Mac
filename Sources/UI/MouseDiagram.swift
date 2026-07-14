import SwiftUI
import AppKit

// Uses the shipped photo (Resources/mouse.png) as the diagram base.
// Anchor points sit on the mouse; callouts sit at fixed vertical positions
// on either flank so they never overlap even when anchors are close.
// The MouseButton enum used throughout the diagram lives in Sources/MouseButton.swift.

// Anchor on the mouse (0..1 in the image's box) and the callout label's
// resting position (also in image-normalized coords — may exceed 0..1
// because callouts naturally sit outside the image bounds).
private struct AnchorLayout {
    let anchor: CGPoint            // blue-dot position on the mouse
    let callout: CGPoint           // label position (can be < 0 or > 1)
    let onLeft: Bool
}

struct MouseDiagram: View {
    let selection: Binding<MouseButton?>
    /// Default-layer actions per button — used by the callout to render
    /// mapping as SF Symbol key badges (for keyStroke actions) or text.
    let actions: [MouseButton: ButtonAction]
    /// User-overridden hotspot dot positions (normalized on the image bounds).
    var hotspots: [String: NormalizedPoint] = [:]
    /// User-overridden callout-label positions (also normalized).
    var callouts: [String: NormalizedPoint] = [:]
    /// When true, hotspots and callouts become independently draggable.
    var editing: Bool = false
    var onMoveHotspot: ((MouseButton, NormalizedPoint) -> Void)? = nil
    var onMoveCallout: ((MouseButton, NormalizedPoint) -> Void)? = nil

    // Anchors captured at the moment a drag begins — we use translation +
    // start to avoid the "click makes it jump under the cursor" jitter.
    @State private var dragStartHotspot: [String: CGPoint] = [:]
    @State private var dragStartCallout: [String: CGPoint] = [:]

    // Layouts were dialed in against this specific mouse.png crop by dragging
    // each button in the app's own hotspot editor. Anchors (blue dots) sit on
    // the physical button; callouts sit outside the image bounds at a fixed
    // flank column so the leader lines read cleanly. If you swap the photo,
    // re-enter Edit hotspots and re-tune.
    private let layouts: [MouseButton: AnchorLayout] = [
        //           ── LEFT flank ──
        .leftClick:   AnchorLayout(anchor: CGPoint(x: 0.4150, y: 0.1340),
                                   callout: CGPoint(x: -0.1961, y: 0.05), onLeft: true),
        .scrollClick: AnchorLayout(anchor: CGPoint(x: 0.5433, y: 0.2642),
                                   callout: CGPoint(x: -0.1961, y: 0.28),  onLeft: true),
        .mouseButton5:AnchorLayout(anchor: CGPoint(x: 0.2892, y: 0.4541),
                                   callout: CGPoint(x: -0.1961, y: 0.55),  onLeft: true),
        .mouseButton4:AnchorLayout(anchor: CGPoint(x: 0.3224, y: 0.6212),
                                   callout: CGPoint(x: -0.1961, y: 0.85),  onLeft: true),
        //           ── RIGHT flank ──
        .rightClick:  AnchorLayout(anchor: CGPoint(x: 0.6746, y: 0.1193),
                                   callout: CGPoint(x: 1.2126, y: -0.0493), onLeft: false),
        .scrollUp:    AnchorLayout(anchor: CGPoint(x: 0.5365, y: 0.1796),
                                   callout: CGPoint(x: 1.2126, y: 0.2470),  onLeft: false),
        .scrollDown:  AnchorLayout(anchor: CGPoint(x: 0.5476, y: 0.3484),
                                   callout: CGPoint(x: 1.2126, y: 0.5746),  onLeft: false),
        .dpiCycle:    AnchorLayout(anchor: CGPoint(x: 0.5483, y: 0.4655),
                                   callout: CGPoint(x: 1.2126, y: 0.8674),  onLeft: false),
    ]

    var body: some View {
        GeometryReader { geo in
            // Available area: 130pt callout column on each side + gap.
            let calloutW: CGFloat = 130
            let gap: CGFloat = 22
            let sideSpace: CGFloat = calloutW + gap
            // Reserve vertical headroom for the extreme callouts. The
            // top-right callout (`rightClick`) sits at normalized y =
            // -0.05 (above the image) so with a naive `height - 24`
            // budget its label draws above the diagram's own frame and
            // spills onto neighbouring Card headers. Budget = extreme
            // top offset + callout half-height + a little breathing.
            let calloutHeadroom: CGFloat = 64
            let imgMax = min(geo.size.width - sideSpace * 2,
                             geo.size.height - calloutHeadroom)
            let imgSize = max(280, min(440, imgMax))
            let rect = CGRect(
                x: (geo.size.width - imgSize) / 2,
                y: (geo.size.height - imgSize) / 2,
                width: imgSize, height: imgSize
            )

            ZStack(alignment: .topLeading) {
                // Photo — with a subtle rounded rect white "canvas" behind it
                // so the transparent PNG reads cleanly on any window bg.
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
                    .frame(width: imgSize, height: imgSize)
                    .position(x: rect.midX, y: rect.midY)

                if let img = mouseImage() {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imgSize, height: imgSize)
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
                }

                // Leader lines + hotspots + callouts (independent drag).
                ForEach(MouseButton.allCases) { btn in
                    if let lay = layouts[btn] {
                        let hotN = normalizedHotspot(for: btn, default: lay.anchor)
                        let calN = normalizedCallout(for: btn, layout: lay)
                        let hotspot = CGPoint(
                            x: rect.minX + hotN.x * rect.width,
                            y: rect.minY + hotN.y * rect.height
                        )
                        let calloutCenter = CGPoint(
                            x: rect.minX + calN.x * rect.width,
                            y: rect.minY + calN.y * rect.height
                        )

                        // Diagonal straight line — hotspot to callout center.
                        Path { p in
                            p.move(to: hotspot)
                            p.addLine(to: calloutCenter)
                        }
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7),
                                style: StrokeStyle(lineWidth: 1, lineCap: .round))

                        // Hotspot: draggable independently.
                        HotspotDot(button: btn, editing: editing)
                            .contentShape(Rectangle().inset(by: -8))
                            .position(hotspot)
                            .gesture(hotspotDragGesture(for: btn, in: rect), including: editing ? .all : .subviews)

                        // Callout: draggable independently.
                        Callout(button: btn,
                                action: actions[btn],
                                onLeft: lay.onLeft,
                                editing: editing) {
                            if btn.remappable && !editing { selection.wrappedValue = btn }
                        }
                        .frame(width: calloutW, alignment: .center)
                        .position(calloutCenter)
                        .gesture(calloutDragGesture(for: btn, in: rect), including: editing ? .all : .subviews)
                    }
                }
            }
        }
        .frame(minHeight: 380)
    }

    private func mouseImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "mouse", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    private func normalizedHotspot(for btn: MouseButton, default fallback: CGPoint) -> CGPoint {
        if let o = hotspots[btn.rawValue] { return CGPoint(x: o.x, y: o.y) }
        return fallback
    }

    /// Where the callout label sits, in normalized image coords. Falls back
    /// to the layout's built-in position when the user hasn't dragged it.
    private func normalizedCallout(for btn: MouseButton, layout lay: AnchorLayout) -> CGPoint {
        if let o = callouts[btn.rawValue] { return CGPoint(x: o.x, y: o.y) }
        return lay.callout
    }

    private func hotspotDragGesture(for btn: MouseButton, in rect: CGRect) -> some Gesture {
        // Use translation instead of location so the dot doesn't jump under
        // the cursor on mouse-down (user may click near the edge of the dot
        // and expect it to stay where it was until they actually move).
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                guard editing else { return }
                let start = normalizedHotspot(for: btn, default: layouts[btn]?.anchor ?? CGPoint(x: 0.5, y: 0.5))
                let dxN = g.translation.width / rect.width
                let dyN = g.translation.height / rect.height
                let nx = clampNorm(start.x + dxN)
                let ny = clampNorm(start.y + dyN)
                dragStartHotspot[btn.rawValue] = start
                onMoveHotspot?(btn, NormalizedPoint(x: Double(nx), y: Double(ny)))
            }
            .onEnded { _ in dragStartHotspot[btn.rawValue] = nil }
    }

    private func calloutDragGesture(for btn: MouseButton, in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                guard editing else { return }
                // Callout uses translation + start position, same reason as
                // the hotspot: no jump on click.
                let start = dragStartCallout[btn.rawValue]
                    ?? normalizedCallout(for: btn, layout: layouts[btn]!)
                if dragStartCallout[btn.rawValue] == nil {
                    dragStartCallout[btn.rawValue] = start
                }
                let dxN = g.translation.width / rect.width
                let dyN = g.translation.height / rect.height
                let nx = clampWide(start.x + dxN)
                let ny = clampWide(start.y + dyN)
                onMoveCallout?(btn, NormalizedPoint(x: Double(nx), y: Double(ny)))
            }
            .onEnded { _ in dragStartCallout[btn.rawValue] = nil }
    }

    private func clampNorm(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
    private func clampWide(_ v: CGFloat) -> CGFloat { max(-0.5, min(1.5, v)) }
}

private struct HotspotDot: View {
    let button: MouseButton
    let editing: Bool
    var body: some View {
        Circle()
            .fill(button.remappable ? Color.accentColor : Color(nsColor: .quaternarySystemFill))
            .frame(width: editing ? 16 : 11, height: editing ? 16 : 11)
            .overlay {
                Circle().stroke(Color.white, lineWidth: editing ? 2.5 : 2)
            }
            .overlay {
                // Extra ring in edit mode so the user can see it's grabbable.
                if editing {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 6)
                        .frame(width: 26, height: 26)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 2)
    }
}

private struct Callout: View {
    let button: MouseButton
    let action: ButtonAction?
    let onLeft: Bool
    let editing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: onLeft ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if onLeft { Spacer(minLength: 0) }
                    Text(button.label)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(onLeft ? .trailing : .leading)
                    if !onLeft { Spacer(minLength: 0) }
                }
                mappingView
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: onLeft ? .trailing : .leading)
            .liquidGlass(cornerRadius: 8,
                         tint: editing ? Color.accentColor.opacity(0.10) : nil)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(strokeColor,
                            style: StrokeStyle(lineWidth: editing ? 1 : 0.5,
                                               dash: editing ? [3, 2] : []))
            )
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!button.remappable && !editing)
        .help(editing
              ? "Drag to move this label — click Done to finish"
              : (button.remappable ? "Click to remap" : "Handled by mouse firmware / OS"))
        .onHover { hovering in
            // Open-hand cursor when the label is grabbable — SwiftUI doesn't
            // otherwise cue that "click here" changed to "drag here."
            guard editing else { return }
            if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }

    private var strokeColor: Color {
        if editing { return Color.accentColor.opacity(0.6) }
        return button.remappable
            ? Color.accentColor.opacity(0.45)
            : Color(nsColor: .separatorColor).opacity(0.6)
    }

    /// Render the mapping as SF-Symbol key badges when it's a keyboard
    /// shortcut, plain text otherwise (mouse actions, launch, disable, …).
    @ViewBuilder private var mappingView: some View {
        switch action {
        case .keyStroke(let k):
            KeyComboChip(combo: k)
        default:
            Text(displayText)
                .font(.system(size: 10))
                .foregroundStyle(button.remappable ? .primary : .secondary)
                .lineLimit(1)
        }
    }

    private var displayText: String {
        if let action, action != .passthrough { return action.label }
        return button.remappable ? "Default" : "Fixed"
    }
}
