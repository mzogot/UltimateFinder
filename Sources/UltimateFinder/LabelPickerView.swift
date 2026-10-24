import AppKit

/// Finder's row of color dots in the context menu. Clicking a dot gives the items that color;
/// clicking the color they already have removes it.
final class LabelPickerView: NSView {
    /// Finder's order, by label number (see `NSWorkspace.fileLabelColors`): red, orange,
    /// yellow, green, blue, purple, gray.
    private static let order = [6, 7, 5, 2, 4, 3, 1]
    private static let diameter: CGFloat = 14
    private static let spacing: CGFloat = 8
    private static let leadingInset: CGFloat = 16

    /// The label the items share, or 0.
    private let current: Int
    private let onPick: (Int) -> Void
    private var hovered: Int?

    init(current: Int, onPick: @escaping (Int) -> Void) {
        self.current = current
        self.onPick = onPick
        let width = Self.leadingInset * 2 + CGFloat(Self.order.count) * (Self.diameter + Self.spacing)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        autoresizingMask = .width
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        let names = NSWorkspace.shared.fileLabels
        for (index, number) in Self.order.enumerated() where number < names.count {
            addToolTip(dotRect(at: index).insetBy(dx: -Self.spacing / 2, dy: -6), owner: names[number] as NSString, userData: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func dotRect(at index: Int) -> NSRect {
        let x = Self.leadingInset + CGFloat(index) * (Self.diameter + Self.spacing)
        return NSRect(x: x, y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
    }

    private func label(at point: NSPoint) -> Int? {
        Self.order.indices.first { dotRect(at: $0).insetBy(dx: -Self.spacing / 2, dy: -6).contains(point) }
            .map { Self.order[$0] }
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = NSWorkspace.shared.fileLabelColors
        for (index, number) in Self.order.enumerated() where number < colors.count {
            var rect = dotRect(at: index)
            if number == hovered { rect = rect.insetBy(dx: -2, dy: -2) }
            let dot = NSBezierPath(ovalIn: rect)
            colors[number].setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
            if number == current { drawMark(in: rect, removing: number == hovered) }
        }
    }

    /// A tick on the items' color; an × while hovering it, since clicking removes it.
    private func drawMark(in rect: NSRect, removing: Bool) {
        let mark = NSBezierPath()
        let r = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
        if removing {
            mark.move(to: NSPoint(x: r.minX, y: r.minY))
            mark.line(to: NSPoint(x: r.maxX, y: r.maxY))
            mark.move(to: NSPoint(x: r.minX, y: r.maxY))
            mark.line(to: NSPoint(x: r.maxX, y: r.minY))
        } else {
            mark.move(to: NSPoint(x: r.minX, y: r.midY))
            mark.line(to: NSPoint(x: r.midX - r.width * 0.1, y: r.minY))
            mark.line(to: NSPoint(x: r.maxX, y: r.maxY))
        }
        mark.lineWidth = 1.6
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        NSColor.white.setStroke()
        mark.stroke()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    private func updateHover(_ event: NSEvent) {
        let label = label(at: convert(event.locationInWindow, from: nil))
        guard label != hovered else { return }
        hovered = label
        needsDisplay = true
    }

    // Views in menus get the mouse-up, not the mouse-down.
    override func mouseUp(with event: NSEvent) {
        guard let number = label(at: convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        let pick = number == current ? 0 : number
        // Act once the menu has closed, so an error alert doesn't appear under it.
        DispatchQueue.main.async { [onPick] in onPick(pick) }
    }
}
