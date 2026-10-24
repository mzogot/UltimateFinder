import AppKit

/// Finder's inline rename: an editable field laid over an item's name. Return, Tab or clicking
/// elsewhere keeps the new name, Escape restores the old one.
final class RenameField: NSTextField, NSTextFieldDelegate {
    /// Called once, with the typed name, or nil when cancelled.
    var onEnd: ((String?) -> Void)?
    private let textFont: NSFont
    private let maxX: CGFloat
    private var isFinished = false

    /// `textFrame` is where the name's text is drawn in the host view; the field can widen up to `maxX`.
    init(name: String, font: NSFont, textFrame: NSRect, maxX: CGFloat) {
        textFont = font
        self.maxX = maxX
        super.init(frame: .zero)
        stringValue = name
        self.font = font
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byClipping
        delegate = self

        // A bezeled field insets its text by about 3pt; line the text up with the name underneath.
        let height = ceil(font.ascender - font.descender + font.leading) + 6
        frame = NSRect(x: textFrame.minX - 3, y: textFrame.midY - height / 2, width: 0, height: height)
        fitWidth(to: name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        frame.size.width = max(min(ceil(textWidth) + 14, maxX - frame.minX), 40)
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
