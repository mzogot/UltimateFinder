import AppKit
import Quartz

/// The borderless panel that slides down from the top of the screen.
///
/// It is a non-activating panel so it can take keyboard focus the instant the hotkey fires,
/// without waiting on (or depending on) app activation.
final class VisorPanel: NSPanel {
    /// Receives Quick Look panel control; the panel is always in the responder chain.
    weak var quickLookController: QuickLookControlling?
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Just under the menu bar, so the panel appears to emerge from beneath it.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Allow positioning above the visible area for the slide-in.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookController != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookController?.beginQuickLook(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookController?.endQuickLook(panel)
    }
}

protocol QuickLookControlling: AnyObject {
    func beginQuickLook(_ panel: QLPreviewPanel)
    func endQuickLook(_ panel: QLPreviewPanel)
}

/// Translucent background with rounded bottom corners. The window shadow follows its shape.
final class VisorBackgroundView: NSVisualEffectView {
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        maskImage = Self.bottomRoundedMask(radius: cornerRadius)

        // Clip opaque subviews (e.g. the browser) to the same shape.
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func bottomRoundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
            path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                           radius: radius, startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                           radius: radius, startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The visor's bottom edge. Dragging it makes the visor taller or shorter, so it can be pulled
/// up off something underneath; double-clicking it restores the default height.
final class VisorResizeHandle: NSView {
    /// Called while dragging with the bottom edge's new y position, in screen coordinates.
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    /// Distance from the window's bottom edge to the mouse when the drag started.
    private var grabOffset: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.cursor)
    }

    private static var cursor: NSCursor {
        if #available(macOS 15, *) {
            return .frameResize(position: .bottom, directions: .all)
        }
        return .resizeUpDown
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        grabOffset = NSEvent.mouseLocation.y - (window?.frame.minY ?? 0)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation.y - grabOffset)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount < 2 { onEnd?() }
    }
}
