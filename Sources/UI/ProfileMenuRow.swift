import AppKit

/// A menu-item view that renders the Profile row Tailscale-style: leading
/// avatar-sized icon (bigger than NSMenuItem.image would allow — AppKit
/// caps that at ~row-height), stacked "label / name" text, and a trailing
/// disclosure chevron. Handles its own mouse-hover highlight and, on click,
/// pops the attached submenu — a custom-view menu item does not get
/// AppKit's automatic hover-to-open behavior for `.submenu` on this macOS
/// release, so we drive it manually.
@MainActor
final class ProfileMenuRowView: NSView {
    private static let rowHeight: CGFloat = 44
    private static let iconSize: CGFloat = 30
    private static let padLeft: CGFloat = 14
    private static let padRight: CGFloat = 12
    private static let iconGap: CGFloat = 3

    private let avatarView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let nameField = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(labelText: String, nameText: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.rowHeight))
        autoresizingMask = [.width]
        wantsLayer = true
        setupAvatar()
        setupText(labelText: labelText, nameText: nameText)
        setupChevron()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Subview setup

    private func setupAvatar() {
        let base = NSImage(systemSymbolName: "person.crop.circle.fill",
                           accessibilityDescription: nil)
        let cfg = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular)
        let scaled = base?.withSymbolConfiguration(cfg)
        scaled?.size = NSSize(width: Self.iconSize, height: Self.iconSize)
        scaled?.isTemplate = true
        avatarView.image = scaled
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.frame = NSRect(x: Self.padLeft,
                                  y: (Self.rowHeight - Self.iconSize) / 2,
                                  width: Self.iconSize, height: Self.iconSize)
        addSubview(avatarView)
    }

    private func setupText(labelText: String, nameText: String) {
        let textX = Self.padLeft + Self.iconSize + Self.iconGap
        // Two lines stacked around the row's vertical center: caption on
        // top, name on bottom. Text field bounds are sized so the *baseline*
        // of the visible glyph line up cleanly with the avatar's midline.
        let center = Self.rowHeight / 2.0

        labelField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        labelField.textColor = NSColor.secondaryLabelColor
        labelField.isBordered = false
        labelField.drawsBackground = false
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.stringValue = labelText
        labelField.frame = NSRect(x: textX, y: center + 1, width: 160, height: 14)
        addSubview(labelField)

        nameField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameField.textColor = NSColor.labelColor
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.stringValue = nameText
        nameField.frame = NSRect(x: textX, y: center - 17, width: 160, height: 17)
        addSubview(nameField)
    }

    private func setupChevron() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let base = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        let scaled = base?.withSymbolConfiguration(cfg)
        scaled?.isTemplate = true
        chevronView.image = scaled
        chevronView.contentTintColor = NSColor.tertiaryLabelColor
        let size: CGFloat = 13
        chevronView.frame = NSRect(x: bounds.width - Self.padRight - size,
                                   y: (Self.rowHeight - size) / 2,
                                   width: size, height: size)
        chevronView.autoresizingMask = [.minXMargin]
        addSubview(chevronView)
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    // MARK: - Hover highlight

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyHighlight(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyHighlight(false)
    }

    private func applyHighlight(_ on: Bool) {
        needsDisplay = true
        // Tint every glyph in the row to match the selected-menu-item text
        // color so the whole row reads as "one hover target" — matches how
        // a normal NSMenuItem inverts its contents when highlighted.
        avatarView.contentTintColor = on ? .selectedMenuItemTextColor : nil
        labelField.textColor = on ? .selectedMenuItemTextColor : .secondaryLabelColor
        nameField.textColor = on ? .selectedMenuItemTextColor : .labelColor
        chevronView.contentTintColor = on ? .selectedMenuItemTextColor : .tertiaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovering else { return }
        // AppKit's default menu-item selection fill is a full-bleed accent
        // rectangle with rounded caps inset a few points from the menu
        // edges. `selectedContentBackgroundColor` is the modern token for
        // the exact hue macOS uses in menus.
        let bg = NSColor.selectedContentBackgroundColor
        let rect = bounds.insetBy(dx: 5, dy: 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        bg.setFill()
        path.fill()
    }

    // MARK: - Click → open the attached submenu

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let sub = item.submenu else { return }
        // The parent menu is actively tracking; cancelling it lets us
        // synchronously pop the submenu without AppKit dropping the click
        // as "outside the tracked menu". Anchor at the row's right edge
        // so the submenu grows out toward where a real hover-to-open one
        // would have appeared.
        let anchorInWindow = convert(NSPoint(x: bounds.maxX - 4, y: bounds.midY), to: nil)
        let anchor = window?.convertPoint(toScreen: anchorInWindow) ?? NSEvent.mouseLocation
        item.menu?.cancelTracking()
        DispatchQueue.main.async {
            sub.popUp(positioning: nil, at: anchor, in: nil)
        }
    }
}
