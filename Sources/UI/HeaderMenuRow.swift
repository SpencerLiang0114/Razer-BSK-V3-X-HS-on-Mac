import AppKit

/// The status header at the top of the tray menu. A custom-view menu item
/// so AppKit's disabled-item dim doesn't fade the device name to grey —
/// setting `isEnabled = false` on a plain NSMenuItem plus attributedTitle
/// gives us that dim regardless of the colors we set, which reads as
/// "unavailable" instead of "informational". Rendering via NSView bypasses
/// that path entirely; the text lands in whatever colors we ask for.
///
/// Not interactive: no hover highlight, no click behavior. Text is
/// vertically centered around the row's midline so the row's presence
/// matches the Profile row without an avatar dominating.
@MainActor
final class HeaderMenuRowView: NSView {
    private static let rowHeight: CGFloat = 44
    private static let padLeft: CGFloat = 14
    private static let padRight: CGFloat = 14

    private let nameField = NSTextField(labelWithString: "")
    private let subField = NSTextField(labelWithString: "")

    init(nameText: String, subText: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.rowHeight))
        autoresizingMask = [.width]
        setupFields()
        update(nameText: nameText, subText: subText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    private func setupFields() {
        let center = Self.rowHeight / 2.0

        nameField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameField.textColor = NSColor.labelColor
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.frame = NSRect(x: Self.padLeft, y: center + 1,
                                 width: 220, height: 16)
        addSubview(nameField)

        subField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subField.textColor = NSColor.secondaryLabelColor
        subField.isBordered = false
        subField.drawsBackground = false
        subField.isEditable = false
        subField.isSelectable = false
        subField.frame = NSRect(x: Self.padLeft, y: center - 15,
                                width: 220, height: 14)
        addSubview(subField)
    }

    func update(nameText: String, subText: String) {
        nameField.stringValue = nameText
        subField.stringValue = subText
    }
}
