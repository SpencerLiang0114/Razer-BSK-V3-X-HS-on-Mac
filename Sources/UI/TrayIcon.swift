import AppKit

/// Renders the mouse-shaped tray icon in three visual states. Template image
/// for "awake" so macOS auto-tints; fixed grays for the other two so users
/// can tell at a glance that data is stale / offline.
enum TrayIconState { case awake, asleep, unplugged }

enum TrayIcon {
    private static let size = NSSize(width: 12, height: 18)
    private static let stroke: CGFloat = 1.15
    private static let corner: CGFloat = 4

    static func image(for state: TrayIconState) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let color: NSColor
            switch state {
            case .awake:     color = .black                        // template — macOS tints
            case .asleep:    color = NSColor(white: 0.55, alpha: 1)
            case .unplugged: color = NSColor(white: 0.45, alpha: 1)
            }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(stroke)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            let body = rect.insetBy(dx: 1, dy: 1)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.strokePath()

            // Scroll-wheel notch
            let cx = rect.midX
            ctx.move(to: CGPoint(x: cx, y: rect.height - 3))
            ctx.addLine(to: CGPoint(x: cx, y: rect.height - 7))
            ctx.strokePath()

            if state == .unplugged {
                ctx.move(to: CGPoint(x: 1.5, y: 1.5))
                ctx.addLine(to: CGPoint(x: rect.width - 1.5, y: rect.height - 1.5))
                ctx.strokePath()
            }
            return true
        }
        if state == .awake { img.isTemplate = true }
        return img
    }
}
