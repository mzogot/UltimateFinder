import AppKit

/// What the browser needs from a view that shows one folder at a time: list view or icon view.
protocol FolderView: AnyObject {
    var scrollView: NSScrollView { get }
    /// The view that takes keyboard focus and carries the context menu.
    var documentView: NSView { get }
    var selectedNodes: [FileNode] { get }
    /// The listed folders, for the directory watcher.
    var visibleFolders: [FileNode] { get }
    func show(_ folder: FileNode, selecting urls: [URL])
    func select(_ urls: [URL])
    func refresh(onlyIn paths: Set<String>?)
    func reloadPreservingState()
    func reloadIcons(of nodes: [FileNode])
    func reloadLabels(of nodes: [FileNode])
    /// The name label of `node`, scrolled into view, for laying the rename field over it.
    func nameLabel(of node: FileNode) -> NSTextField?
    /// The item whose name (the text itself) is under `locationInWindow`.
    func node(withNameAt locationInWindow: NSPoint) -> FileNode?
    /// Where `url`'s icon is drawn, in window coordinates, for Quick Look's zoom.
    func iconFrameInWindow(of url: URL) -> NSRect?
    /// The items a context menu opened at the mouse acts on. Right-clicking an unselected item
    /// selects it first, like Finder; the background gives none.
    func menuTargets() -> [FileNode]
}

/// Finder's icon view: large icons, or previews of the contents, in a grid with the names
/// underneath, in the shared sort order.
final class FileIconController: NSObject, FolderView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let scrollView = NSScrollView()
    let collectionView = FileCollectionView()
    weak var host: FileListHost?
    private(set) var folder: FileNode?
    private var items: [FileNode] = []
    private weak var dropTargetItem: IconItem?

    static let iconSide: CGFloat = 64
    static let itemSize = NSSize(width: 108, height: 112)

    var documentView: NSView { collectionView }

    override init() {
        super.init()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.controller = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask(.every, forLocal: true)
        collectionView.setDraggingSourceOperationMask(.every, forLocal: false)
        collectionView.autoresizingMask = [.width]

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    // MARK: Content

    func show(_ folder: FileNode, selecting urls: [URL] = []) {
        self.folder = folder
        reloadItems()
        select(urls)
        if collectionView.selectionIndexPaths.isEmpty { collectionView.scroll(.zero) }
    }

    private func reloadItems() {
        items = folder.map { $0.children(showingHidden: host?.showsHidden ?? false) } ?? []
        collectionView.reloadData()
    }

    var selectedNodes: [FileNode] {
        collectionView.selectionIndexPaths.map(\.item).sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    func select(_ urls: [URL]) {
        let paths = Set(urls.compactMap(index(of:)).map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = paths
        if let first = paths.min() {
            collectionView.layoutSubtreeIfNeeded()
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
    }

    private func index(of url: URL) -> Int? {
        items.firstIndex { $0.url.isSameFile(as: url) }
    }

    var visibleFolders: [FileNode] {
        folder.map { [$0] } ?? []
    }

    func refresh(onlyIn paths: Set<String>?) {
        guard let host, let folder, paths?.contains(folder.canonicalPath) ?? true,
              folder.reloadChildren(showingHidden: host.showsHidden) else { return }
        reloadPreservingState()
    }

    func reloadPreservingState() {
        let selected = selectedNodes.map(\.url)
        reloadItems()
        select(selected)
    }

    func reloadIcons(of nodes: [FileNode]) {
        for node in nodes { visibleItem(for: node)?.configure(with: node) }
    }

    func reloadLabels(of nodes: [FileNode]) {
        reloadIcons(of: nodes)
    }

    private func visibleItem(for node: FileNode) -> IconItem? {
        guard let index = items.firstIndex(where: { $0 === node }) else { return nil }
        return collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem
    }

    // MARK: Hit testing

    /// The item whose icon or name is at `point` (in collection view coordinates). The empty
    /// space around them counts as background, as in Finder.
    private func indexOfItem(withIconOrNameAt point: NSPoint) -> Int? {
        guard let path = collectionView.indexPathForItem(at: point),
              let item = collectionView.item(at: path) as? IconItem else { return nil }
        let local = item.view.convert(point, from: collectionView)
        return item.iconFrame.contains(local) || item.nameTextFrame.contains(local) ? path.item : nil
    }

    func nameLabel(of node: FileNode) -> NSTextField? {
        guard let index = items.firstIndex(where: { $0 === node }) else { return nil }
        let path = IndexPath(item: index, section: 0)
        collectionView.layoutSubtreeIfNeeded()
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        return (collectionView.item(at: path) as? IconItem)?.nameField
    }

    func node(withNameAt locationInWindow: NSPoint) -> FileNode? {
        let point = collectionView.convert(locationInWindow, from: nil)
        guard collectionView.visibleRect.contains(point),
              let path = collectionView.indexPathForItem(at: point),
              let item = collectionView.item(at: path) as? IconItem,
              item.nameTextFrame.contains(item.view.convert(point, from: collectionView))
        else { return nil }
        return items[path.item]
    }

    func iconFrameInWindow(of url: URL) -> NSRect? {
        guard let index = index(of: url),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem else { return nil }
        return item.view.convert(item.iconFrame, to: nil)
    }

    func menuTargets() -> [FileNode] {
        guard let window = collectionView.window else { return [] }
        let point = collectionView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let index = indexOfItem(withIconOrNameAt: point) else { return [] }
        let clicked = items[index]
        let selected = selectedNodes
        if selected.contains(where: { $0 === clicked }) { return selected }
        collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        host?.fileListSelectionDidChange()
        return [clicked]
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        (item as? IconItem)?.configure(with: items[indexPath.item])
        return item
    }

    // MARK: Selection & opening

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        host?.fileListSelectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        host?.fileListSelectionDidChange()
    }

    fileprivate func doubleClicked(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard let index = indexOfItem(withIconOrNameAt: point) else { return }
        let file = items[index]
        if file.isDirectory {
            host?.fileList(navigateInto: file, inNewTab: modifiers.contains(.command))
        } else {
            let selected = selectedNodes
            host?.fileList(open: selected.contains(file) ? selected.filter { !$0.isDirectory } : [file])
        }
    }

    /// Type-select: selects the first item whose name starts with what was typed.
    fileprivate func selectItem(withPrefix prefix: String) {
        guard let index = items.firstIndex(where: {
            $0.name.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }) else { return }
        select([items[index].url])
        host?.fileListSelectionDidChange()
    }

    // MARK: Drag out

    /// Only the icon and the name start a drag; elsewhere a drag selects, as in the other views.
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexOfItem(withIconOrNameAt: collectionView.convert(event.locationInWindow, from: nil)) != nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(indexPath.item) ? items[indexPath.item].url as NSURL : nil
    }

    // MARK: Drop in

    /// Dropping on a folder's icon or name targets that folder; anywhere else, the folder shown.
    fileprivate func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        if let index = indexOfItem(withIconOrNameAt: point), items[index].isDirectory,
           let operation = host?.fileList(validateDrop: info, into: items[index].url), !operation.isEmpty {
            highlightDropTarget(collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem)
            return operation
        }
        highlightDropTarget(nil)
        guard let folder else { return [] }
        return host?.fileList(validateDrop: info, into: folder.url) ?? []
    }

    fileprivate func performDrop(_ info: NSDraggingInfo) -> Bool {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        highlightDropTarget(nil)
        if let index = indexOfItem(withIconOrNameAt: point), items[index].isDirectory,
           let host, !host.fileList(validateDrop: info, into: items[index].url).isEmpty {
            return host.fileList(acceptDrop: info, into: items[index].url)
        }
        guard let folder else { return false }
        return host?.fileList(acceptDrop: info, into: folder.url) ?? false
    }

    fileprivate func highlightDropTarget(_ item: IconItem?) {
        guard item !== dropTargetItem else { return }
        dropTargetItem?.isDropTarget = false
        item?.isDropTarget = true
        dropTargetItem = item
    }

    fileprivate func focusDidChange() {
        for case let item as IconItem in collectionView.visibleItems() { item.updateAppearance() }
    }
}

/// Adds what NSCollectionView lacks for a file browser: double-click, type-select, and drops
/// onto folders or the background without an insertion gap.
final class FileCollectionView: NSCollectionView {
    fileprivate weak var controller: FileIconController?
    private var typedPrefix = ""
    private var lastTypeTime: TimeInterval = 0

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            controller?.doubleClicked(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.userModifiers.subtracting(.shift)
        guard modifiers.isEmpty, let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy(Self.isTypeable) else {
            super.keyDown(with: event)
            return
        }
        if event.timestamp - lastTypeTime > 1 { typedPrefix = "" }
        lastTypeTime = event.timestamp
        typedPrefix += characters
        controller?.selectItem(withPrefix: typedPrefix)
    }

    /// Printable characters; not control characters or the arrow and function keys.
    private static func isTypeable(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }

    override func becomeFirstResponder() -> Bool {
        defer { controller?.focusDidChange() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { controller?.focusDidChange() }
        return super.resignFirstResponder()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.updateDrop(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.updateDrop(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.highlightDropTarget(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.performDrop(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.highlightDropTarget(nil)
    }
}

/// One icon in icon view: the icon or preview on a rounded backdrop when selected, and the name
/// underneath, highlighted when selected and tinted with the item's color label otherwise.
final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")

    private let iconBackdrop = NSView()
    private let iconView = NSImageView()
    let nameField = NSTextField(wrappingLabelWithString: "")
    private var labelColor: NSColor?
    private var isHiddenFile = false

    var isDropTarget = false {
        didSet { updateAppearance() }
    }

    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateAppearance() }
    }

    private static let backdropSide = FileIconController.iconSide + 10
    private static let nameWidth = FileIconController.itemSize.width - 6

    override func loadView() {
        let container = IconItemView()
        container.onAppearanceChange = { [weak self] in self?.updateAppearance() }

        iconBackdrop.wantsLayer = true
        iconBackdrop.layer?.cornerRadius = 6
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameField.font = .systemFont(ofSize: 12)
        nameField.alignment = .center
        nameField.maximumNumberOfLines = 2
        nameField.lineBreakMode = .byWordWrapping
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.preferredMaxLayoutWidth = Self.nameWidth
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = 4

        for subview in [iconBackdrop, iconView, nameField] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            iconBackdrop.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            iconBackdrop.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconBackdrop.widthAnchor.constraint(equalToConstant: Self.backdropSide),
            iconBackdrop.heightAnchor.constraint(equalToConstant: Self.backdropSide),

            iconView.centerXAnchor.constraint(equalTo: iconBackdrop.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackdrop.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: FileIconController.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: FileIconController.iconSide),

            nameField.topAnchor.constraint(equalTo: iconBackdrop.bottomAnchor, constant: 3),
            nameField.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: Self.nameWidth),
        ])
        view = container
    }

    func configure(with node: FileNode) {
        iconView.image = node.icon(side: FileIconController.iconSide)
        nameField.stringValue = node.name
        labelColor = node.labelColor
        isHiddenFile = node.isHidden
        updateAppearance()
    }

    /// The icon's area in the item's view, for hit testing.
    var iconFrame: NSRect { iconBackdrop.frame }

    /// The name's text (not the whole label width) in the item's view, for hit testing.
    var nameTextFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameField.frame.insetBy(dx: -2, dy: 0)
    }

    func updateAppearance() {
        guard isViewLoaded else { return }
        let selected: Bool
        switch highlightState {
        case .forSelection: selected = true
        case .forDeselection: selected = false
        default: selected = isSelected
        }
        let emphasized = collectionView.map { $0.window?.firstResponder === $0 && $0.window?.isKeyWindow == true } ?? false

        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let backdrop: NSColor? = isDropTarget ? .selectedContentBackgroundColor.withAlphaComponent(0.35)
                : selected ? .labelColor.withAlphaComponent(0.1) : nil
            iconBackdrop.layer?.backgroundColor = backdrop?.cgColor

            let nameBackground: NSColor?
            if selected {
                nameBackground = emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
            } else {
                nameBackground = labelColor?.withAlphaComponent(LabelRowView.tintAlpha)
            }
            nameField.layer?.backgroundColor = nameBackground?.cgColor
        }
        nameField.textColor = selected && emphasized ? .alternateSelectedControlTextColor
            : isHiddenFile ? .secondaryLabelColor : .labelColor
        iconView.alphaValue = isHiddenFile ? 0.5 : 1
    }
}

private final class IconItemView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
