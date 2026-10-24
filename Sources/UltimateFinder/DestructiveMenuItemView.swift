import AppKit

/// A context-menu row drawn as a red pill with a white icon and title, so destructive commands
/// like Move to Trash stand out. Plain menu items can't have a background, hence the view.
final class DestructiveMenuItemView: NSView {
    private static let horizontalInset: CGFloat = 5
    private static let iconInset: CGFloat = 12
    private static let iconWidth: CGFloat = 16

    private let title: String
    private let icon: NSImage?
    private let action: () -> Void
    private var hovered = false

    init(title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
        let width = Self.horizontalInset * 2 + Self.iconInset + Self.iconWidth + 8 + textWidth + 20
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        autoresizingMask = .width
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovered || enclosingMenuItem?.isHighlighted == true
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: Self.horizontalInset, dy: 2), xRadius: 6, yRadius: 6)
        (highlighted ? NSColor.systemRed.blended(withFraction: 0.2, of: .black) ?? .systemRed : .systemRed).setFill()
        pill.fill()

        var x = Self.horizontalInset + Self.iconInset
        if let icon {
            let size = icon.size
            icon.draw(in: NSRect(x: x + (Self.iconWidth - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height))
        }
        x += Self.iconWidth + 8

        let font = NSFont.menuFont(ofSize: 0)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.white])
        let height = text.size().height
        text.draw(at: NSPoint(x: x, y: (bounds.height - height) / 2))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    // Views in menus get the mouse-up, not the mouse-down.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        // Act once the menu has closed, so an error alert doesn't appear under it.
        DispatchQueue.main.async { [action] in action() }
    }
}
