import AppKit

protocol FileListHost: AnyObject {
    var showsHidden: Bool { get }
    func fileList(open nodes: [FileNode])
    func fileList(navigateInto folder: FileNode, inNewTab: Bool)
    func fileListSelectionDidChange()
    func fileListSortDidChange(to sort: FileSort)
    func fileList(validateDrop info: NSDraggingInfo, into folder: URL) -> NSDragOperation
    func fileList(acceptDrop info: NSDraggingInfo, into folder: URL) -> Bool
}

/// Finder's list view: Name / Date Modified / Size / Kind, sortable by clicking the headers,
/// with disclosure triangles to expand folders in place.
final class FileListController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scrollView = NSScrollView()
    let outlineView: NSOutlineView = FileOutlineView()
    weak var host: FileListHost?
    private(set) var folder: FileNode?
    private var isApplyingSort = false

    private enum Column: String, CaseIterable {
        case name, dateModified, size, kind

        var sortKey: FileSort.Key { FileSort.Key(rawValue: rawValue)! }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    override init() {
        super.init()

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.sortKey.title
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.sortKey.defaultAscending)
            switch column {
            case .name: tableColumn.width = 320; tableColumn.minWidth = 160
            case .dateModified: tableColumn.width = 170; tableColumn.minWidth = 90
            case .size: tableColumn.width = 80; tableColumn.minWidth = 50
            case .kind: tableColumn.width = 150; tableColumn.minWidth = 60
            }
            if column == .size { tableColumn.headerCell.alignment = .right }
            outlineView.addTableColumn(tableColumn)
            if column == .name { outlineView.outlineTableColumn = tableColumn }
        }

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 22
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = true
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.autosaveName = "UltimateFinderList"
        outlineView.autosaveTableColumns = true
        outlineView.focusRingType = .none
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.every, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.every, forLocal: false)
        applySortIndicator(FileNode.sortOrder)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
    }

    // MARK: Content

    func show(_ folder: FileNode, selecting urls: [URL] = []) {
        self.folder = folder
        outlineView.reloadData()
        select(urls)
        if outlineView.selectedRowIndexes.isEmpty { outlineView.scroll(.zero) }
    }

    var selectedNodes: [FileNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileNode }
    }

    func select(_ urls: [URL]) {
        let rows = IndexSet(urls.compactMap(row(for:)))
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outlineView.scrollRowToVisible(first) }
    }

    func row(for url: URL) -> Int? {
        (0..<outlineView.numberOfRows).first { (outlineView.item(atRow: $0) as? FileNode)?.url.isSameFile(as: url) == true }
    }

    /// The listed folders: the folder itself plus every expanded subfolder.
    var visibleFolders: [FileNode] {
        guard let folder else { return [] }
        let expanded = (0..<outlineView.numberOfRows).compactMap { row -> FileNode? in
            let item = outlineView.item(atRow: row)
            return outlineView.isItemExpanded(item) ? item as? FileNode : nil
        }
        return [folder] + expanded
    }

    /// Re-reads the listed folders (or only those whose canonical paths are in `paths`).
    func refresh(onlyIn paths: Set<String>?) {
        guard let host else { return }
        let selected = selectedNodes.map(\.url)
        var changed = false
        for listed in visibleFolders where paths?.contains(listed.canonicalPath) ?? true {
            if listed.reloadChildren(showingHidden: host.showsHidden) {
                changed = true
                outlineView.reloadItem(listed === folder ? nil : listed, reloadChildren: true)
            }
        }
        if changed { select(selected) }
    }

    /// Reloads everything (after a re-sort or hidden-files toggle), keeping expansion and selection.
    func reloadPreservingState() {
        let expanded = visibleFolders.dropFirst().map(\.url)
        let selected = selectedNodes.map(\.url)
        outlineView.reloadData()
        for url in expanded {  // parents come before children, so each is visible when expanded
            if let row = row(for: url) { outlineView.expandItem(outlineView.item(atRow: row)) }
        }
        select(selected)
    }

    /// Redraws the name cells of `nodes`, e.g. once their icon previews have loaded.
    func reloadIcons(of nodes: [FileNode]) {
        let rows = IndexSet(nodes.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        guard !rows.isEmpty, let column = outlineView.tableColumns.firstIndex(where: { $0 === outlineView.outlineTableColumn })
        else { return }
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: column))
    }

    /// Re-tints the rows of `nodes` after their color labels changed.
    func reloadLabels(of nodes: [FileNode]) {
        for node in nodes {
            let row = outlineView.row(forItem: node)
            guard row >= 0, let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? LabelRowView else { continue }
            rowView.labelColor = node.labelColor
        }
    }

    func applySortIndicator(_ sort: FileSort) {
        isApplyingSort = true
        outlineView.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]
        isApplyingSort = false
    }

    // MARK: Data source

    private func node(_ item: Any?) -> FileNode? {
        item as? FileNode ?? folder
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let host, let parent = node(item), parent.isDirectory else { return 0 }
        return parent.children(showingHidden: host.showsHidden).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = node(item)?.children(showingHidden: host?.showsHidden ?? false) ?? []
        return children.indices.contains(index) ? children[index] : (node(item) as Any)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSort, let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key.flatMap(FileSort.Key.init) else { return }
        host?.fileListSortDidChange(to: FileSort(key: key, ascending: descriptor.ascending))
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let file = item as? FileNode, let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }

        let cell = outlineView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView
            ?? makeCell(identifier: tableColumn.identifier, withIcon: column == .name)
        let text: String
        switch column {
        case .name:
            text = file.name
            cell.imageView?.image = file.icon
        case .dateModified:
            text = file.modificationDate.map(Self.dateFormatter.string(from:)) ?? "--"
        case .size:
            text = file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        case .kind:
            text = file.kind
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = column == .name && !file.isHidden ? .labelColor : .secondaryLabelColor
        cell.textField?.alignment = column == .size ? .right : .left
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let rowView = outlineView.makeView(withIdentifier: identifier, owner: nil) as? LabelRowView ?? LabelRowView()
        rowView.identifier = identifier
        rowView.labelColor = (item as? FileNode)?.labelColor
        return rowView
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        var constraints = [
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        host?.fileListSelectionDidChange()
    }

    // Expanding a folder adds it to the watched set.
    func outlineViewItemDidExpand(_ notification: Notification) {
        host?.fileListSelectionDidChange()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        host?.fileListSelectionDidChange()
    }

    @objc private func doubleClicked() {
        guard let file = outlineView.item(atRow: outlineView.clickedRow) as? FileNode else { return }
        if file.isDirectory {
            host?.fileList(navigateInto: file, inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        } else {
            let selected = selectedNodes
            host?.fileList(open: selected.contains(file) ? selected.filter { !$0.isDirectory } : [file])
        }
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = dropTarget(item) else { return [] }
        outlineView.setDropItem(target === folder ? nil : target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return host?.fileList(validateDrop: info, into: target.url) ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = dropTarget(item) else { return false }
        return host?.fileList(acceptDrop: info, into: target.url) ?? false
    }

    /// Dropping on a folder row targets that folder; anywhere else, the folder the row lives in.
    private func dropTarget(_ item: Any?) -> FileNode? {
        guard let file = item as? FileNode else { return folder }
        if file.isDirectory { return file }
        return outlineView.parent(forItem: file) as? FileNode ?? folder
    }
}

/// Tints the whole row with the item's color label, as Finder did before labels became tags.
/// The selection highlight draws over it.
final class LabelRowView: NSTableRowView {
    var labelColor: NSColor? {
        didSet { if labelColor != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let labelColor else { return }
        labelColor.withAlphaComponent(LabelRowView.tintAlpha).setFill()
        bounds.fill()
    }

    /// Strong enough to read at a glance, light enough to keep the text legible.
    static let tintAlpha: CGFloat = 0.4
}

/// Finder's split between dragging files and drag-selecting: pressing on an item's icon or name
/// drags it, while pressing anywhere else in the row (beside the name, or in another column)
/// and dragging selects the rows the mouse passes over.
private final class FileOutlineView: NSOutlineView {
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        let row = row(at: mouseDownPoint)
        let column = column(at: mouseDownPoint)
        guard row >= 0, column >= 0, tableColumns[column] === outlineTableColumn,
              let cell = view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
              let label = cell.textField
        else { return false }
        let point = cell.convert(mouseDownPoint, from: self)
        let start = cell.imageView?.frame.minX ?? label.frame.minX
        // The label stretches to the column's edge; only its text counts (plus the cell's padding).
        let end = min(label.frame.minX + label.attributedStringValue.size().width + 6, label.frame.maxX)
        guard point.x >= start, point.x <= end else { return false }
        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }
}
