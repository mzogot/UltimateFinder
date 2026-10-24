import AppKit

/// Finder-style tab strip: equal-width tabs, a close button on hover and a trailing "+".
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let stack = NSStackView()
    private let addButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "New Tab (⌘T)"
        addButton.target = self
        addButton.action = #selector(addClicked)

        for view in [stack, addButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -6),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(titles: [String], selected: Int) {
        while stack.arrangedSubviews.count > titles.count {
            stack.arrangedSubviews.last?.removeFromSuperview()
        }
        while stack.arrangedSubviews.count < titles.count {
            stack.addArrangedSubview(TabItemView(bar: self))
        }
        for (index, view) in stack.arrangedSubviews.enumerated() {
            guard let item = view as? TabItemView else { continue }
            item.index = index
            item.title = titles[index]
            item.isSelected = index == selected
        }
    }

    @objc private func addClicked() {
        onAdd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

private final class TabItemView: NSView {
    private weak var bar: TabBarView?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isHovered = false {
        didSet {
            closeButton.isHidden = !isHovered
            needsDisplay = true
        }
    }

    var index = 0
    var title = "" {
        didSet {
            label.stringValue = title
            toolTip = title
        }
    }
    var isSelected = false {
        didSet {
            label.textColor = isSelected ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    init(bar: TabBarView) {
        self.bar = bar
        super.init(frame: .zero)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.isHidden = true
        closeButton.toolTip = "Close Tab (⌘W)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        for view in [label, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        bar?.onSelect?(index)
    }

    // Middle-click closes, as in browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { closeClicked() }
    }

    @objc private func closeClicked() {
        bar?.onClose?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        NSColor.labelColor.withAlphaComponent(isSelected ? 0.11 : 0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
