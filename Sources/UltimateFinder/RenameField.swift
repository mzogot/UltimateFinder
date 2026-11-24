import AppKit

/// Finder's inline rename: an editable field laid over an item's name. Return, Tab or clicking
/// elsewhere keeps the new name, Escape restores the old one.
final class RenameField: NSTextField, NSTextFieldDelegate {
    /// Called once, with the typed name, or nil when cancelled.
    var onEnd: ((String?) -> Void)?
    private let textFont: NSFont
    private let minX: CGFloat
    private let maxX: CGFloat
    /// Set for icon view, where the name is centred under the icon and the field grows both ways.
    private let centerX: CGFloat?
    private var isFinished = false

    /// Horizontal space between the field's edge and its text.
    fileprivate static let textInset: CGFloat = 3

    override class var cellClass: AnyClass? {
        get { RenameFieldCell.self }
        set {}
    }

    /// `textFrame` is where the name's text is drawn in the host view; the field can widen up to
    /// `maxX`. With `centered`, the field stays centred on `textFrame` and widens both ways.
    init(name: String, font: NSFont, textFrame: NSRect, maxX: CGFloat, minX: CGFloat? = nil, centered: Bool = false) {
        textFont = font
        self.maxX = maxX
        self.minX = minX ?? textFrame.minX - Self.textInset
        centerX = centered ? textFrame.midX : nil
        super.init(frame: .zero)
        stringValue = name
        self.font = font
        // Not bezeled: on current macOS a bezeled field ignores its background colour, so the
        // name underneath showed through. The field draws its own opaque box instead.
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 1
        updateLayerColors()
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byClipping
        alignment = centered ? .center : .natural
        delegate = self

        let height = ceil(font.ascender - font.descender + font.leading) + 4
        frame = NSRect(x: textFrame.minX - Self.textInset, y: textFrame.midY - height / 2, width: 0, height: height)
        fitWidth(to: name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
    }

    /// Focuses the field and selects `range` of the name (Finder leaves out the extension).
    func beginEditing(selecting range: NSRange) {
        window?.makeFirstResponder(self)
        currentEditor()?.selectedRange = range
    }

    func commit() {
        finish(currentEditor()?.string ?? stringValue)
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ name: String?) {
        guard !isFinished else { return }
        isFinished = true
        onEnd?(name)
    }

    private func fitWidth(to text: String) {
        let textWidth = (text as NSString).size(withAttributes: [.font: textFont]).width
        if let centerX {
            let width = max(min(ceil(textWidth) + 4 * Self.textInset, maxX - minX), 40)
            frame.origin.x = min(max(centerX - width / 2, minX), maxX - width)
            frame.size.width = width
        } else {
            frame.size.width = max(min(ceil(textWidth) + 4 * Self.textInset, maxX - frame.minX), 40)
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        fitWidth(to: currentEditor()?.string ?? stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            commit()
        default:
            return false
        }
        return true
    }

    /// Focus moved elsewhere (a click outside, the visor hiding): keep what was typed.
    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
    }
}

/// Centres the text vertically and insets it a little from the field's border, both while
/// drawing and while editing.
private final class RenameFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let lineHeight = ceil((font ?? .systemFont(ofSize: NSFont.systemFontSize)).boundingRectForFont.height)
        let height = min(lineHeight, rect.height)
        return NSRect(x: rect.minX + RenameField.textInset - 2, y: rect.midY - height / 2,
                      width: rect.width - 2 * (RenameField.textInset - 2), height: height)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}
