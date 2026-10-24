import AppKit

/// Finder-style source list: editable Favorites plus mounted volumes.
///
/// Favorites are added by dropping folders between rows (or via "Add to Sidebar"), reordered by
/// dragging, and removed from the context menu or with Delete. Dropping files *onto* a row moves
/// or copies them into that folder, as in Finder.
final class SidebarController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Row {
        case header(String)
        case favorite(index: Int, url: URL)
        case volume(url: URL, title: String, symbol: String, ejectable: Bool)

        var url: URL? {
            switch self {
            case .header: return nil
            case let .favorite(_, url): return url
            case let .volume(url, _, _, _): return url
            }
        }
    }

    /// Private pasteboard type for reordering, so a favorite dragged onto the browser can't be
    /// mistaken for a real folder move.
    private static let favoriteType = NSPasteboard.PasteboardType("com.ultimatefinder.favorite-index")

    let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var rows: [Row] = []
    private var favoriteCount = 0
    private var highlightedURL: URL?
    private var isSyncingSelection = false

    var onSelect: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    /// Validates / performs a drop of files onto a folder row (shared with the browser's rules).
    var validateFileDrop: ((NSDraggingInfo, URL) -> NSDragOperation)?
    var acceptFileDrop: ((NSDraggingInfo, URL) -> Bool)?

    override init() {
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.floatsGroupRows = false
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([.fileURL, Self.favoriteType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .sourceList

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(self, selector: #selector(locationsChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(locationsChanged), name: Favorites.didChange, object: nil)
        reload()
    }

    var hasFocus: Bool {
        tableView.window?.firstResponder === tableView
    }

    @objc private func locationsChanged() {
        reload()
    }

    func reload() {
        var newRows: [Row] = [.header("Favorites")]
        let favorites = Favorites.urls
        newRows += favorites.enumerated().map { .favorite(index: $0.offset, url: $0.element) }
        favoriteCount = favorites.count

        newRows.append(.header("Locations"))
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable ?? true else { continue }
            let isNetwork = values?.volumeIsLocal == false
            let isExternal = values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
            let symbol = isNetwork ? "network" : isExternal ? "externaldrive" : "internaldrive"
            newRows.append(.volume(url: volume, title: values?.volumeLocalizedName ?? volume.lastPathComponent,
                                   symbol: symbol, ejectable: isNetwork || isExternal))
        }

        rows = newRows
        tableView.reloadData()
        if let highlightedURL { highlight(highlightedURL) }
    }

    /// Reflects the browser's root in the sidebar without triggering navigation.
    func highlight(_ url: URL) {
        highlightedURL = url
        let index = rows.firstIndex { $0.url?.isSameFile(as: url) == true }
        isSyncingSelection = true
        if let index {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingSelection = false
    }

    /// Delete / ⌘⌫ removes the selected favorite while the sidebar has focus.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard [51, 117].contains(Int(event.keyCode)),  // delete, forward delete
              tableView.selectedRow >= 0, case let .favorite(index, _) = rows[tableView.selectedRow]
        else { return false }
        Favorites.remove(at: index)
        reload()
        return true
    }

    // MARK: Appearance

    private static func title(for url: URL) -> String {
        // Localized names ("Schreibtisch", "Programme") for the well-known folders only; asking
        // for anything deeper could touch protected folders before the user opens them.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let parent = url.deletingLastPathComponent()
        if url.isSameFile(as: home) || parent.isSameFile(as: home) || url.path == "/Applications" || url.path == "/" {
            return FileManager.default.displayName(atPath: url.path)
        }
        return url.lastPathComponent
    }

    private static func symbol(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known: [(URL, String)] = [
            (home, "house"),
            (home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            (home.appendingPathComponent("Documents"), "doc"),
            (home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            (home.appendingPathComponent("Movies"), "film"),
            (home.appendingPathComponent("Music"), "music.note"),
            (home.appendingPathComponent("Pictures"), "photo"),
            (URL(fileURLWithPath: "/Applications"), "a.square"),
        ]
        return known.first { $0.0.isSameFile(as: url) }?.1 ?? "folder"
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title: String
        let symbol: String
        switch rows[row] {
        case let .header(text):
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let cell = NSTableCellView()
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case let .favorite(_, url):
            title = Self.title(for: url)
            symbol = Self.symbol(for: url)
        case let .volume(_, volumeTitle, volumeSymbol, _):
            title = volumeTitle
            symbol = volumeSymbol
        }

        let identifier = NSUserInterfaceItemIdentifier("LocationCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeLocationCell(identifier)
        cell.textField?.stringValue = title
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        cell.toolTip = rows[row].url?.path
        return cell
    }

    private func makeLocationCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.contentTintColor = .controlAccentColor
        image.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        for view in [image, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, tableView.selectedRow >= 0, let url = rows[tableView.selectedRow].url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        highlightedURL = url
        onSelect?(url)
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case let .favorite(index, _) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(index), forType: Self.favoriteType)
        return item
    }

    /// Favorites occupy rows 1...favoriteCount; insertion points are rows 1...favoriteCount + 1.
    private var favoriteInsertionRows: ClosedRange<Int> { 1...(favoriteCount + 1) }

    private func draggedFavoriteIndex(_ info: NSDraggingInfo) -> Int? {
        guard (info.draggingSource as? NSTableView) === tableView else { return nil }
        return info.draggingPasteboard.string(forType: Self.favoriteType).flatMap(Int.init)
    }

    private func draggedFolders(_ info: NSDraggingInfo) -> [URL]? {
        let urls = info.draggingPasteboard.existingFileURLs
        guard !urls.isEmpty else { return nil }
        let folders = urls.filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
        return folders.count == urls.count ? folders : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let insertion = min(max(row, favoriteInsertionRows.lowerBound), favoriteInsertionRows.upperBound)

        if draggedFavoriteIndex(info) != nil {
            tableView.setDropRow(insertion, dropOperation: .above)
            return .move
        }

        // Onto a favorite or volume: move/copy the files into it.
        if dropOperation == .on, rows.indices.contains(row), let folder = rows[row].url {
            return validateFileDrop?(info, folder) ?? []
        }

        // Between rows: add folders to Favorites.
        guard draggedFolders(info) != nil else { return [] }
        tableView.setDropRow(insertion, dropOperation: .above)
        let mask = info.draggingSourceOperationMask
        return [NSDragOperation.link, .generic, .copy, .move].first { mask.contains($0) } ?? []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if let source = draggedFavoriteIndex(info) {
            Favorites.move(from: source, to: row - 1)
            reload()
            return true
        }
        if dropOperation == .on, rows.indices.contains(row), let folder = rows[row].url {
            return acceptFileDrop?(info, folder) ?? false
        }
        guard let folders = draggedFolders(info) else { return false }
        Favorites.add(folders, at: row - 1)
        reload()
        return true
    }

    // MARK: Context menu

    private var menuRow = -1

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuRow = tableView.clickedRow
        let row = rows.indices.contains(menuRow) ? rows[menuRow] : nil

        if let url = row?.url {
            addItem(to: menu, "Open in New Tab", #selector(menuOpenInNewTab))
            addItem(to: menu, "Show in Finder", #selector(menuShowInFinder))
            if case .favorite = row {
                menu.addItem(.separator())
                addItem(to: menu, "Remove from Sidebar", #selector(menuRemove))
            }
            if case let .volume(_, _, _, ejectable) = row, ejectable {
                menu.addItem(.separator())
                addItem(to: menu, "Eject “\(url.lastPathComponent)”", #selector(menuEject))
            }
            menu.addItem(.separator())
        }
        addItem(to: menu, "Import Finder Favorites…", #selector(menuImport))
        addItem(to: menu, "Restore Default Favorites", #selector(menuRestoreDefaults))
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private var menuURL: URL? {
        rows.indices.contains(menuRow) ? rows[menuRow].url : nil
    }

    @objc private func menuOpenInNewTab() {
        if let url = menuURL { onOpenInNewTab?(url) }
    }

    @objc private func menuShowInFinder() {
        if let url = menuURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func menuRemove() {
        guard rows.indices.contains(menuRow), case let .favorite(index, _) = rows[menuRow] else { return }
        Favorites.remove(at: index)
        reload()
    }

    @objc private func menuEject() {
        guard let url = menuURL else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        } catch {
            present(NSAlert(error: error))
        }
    }

    @objc private func menuRestoreDefaults() {
        Favorites.resetToDefaults()
        reload()
    }

    @objc func importFinderFavorites() {
        menuImport()
    }

    @objc private func menuImport() {
        do {
            let imported = try Favorites.finderFavorites()
            let before = Favorites.urls.count
            Favorites.add(imported)
            reload()
            let added = Favorites.urls.count - before
            let alert = NSAlert()
            alert.messageText = added == 0 ? "No new favorites to import" : "Imported \(added) favorite\(added == 1 ? "" : "s") from Finder"
            if added == 0 { alert.informativeText = "Every folder in Finder's sidebar is already in your favorites." }
            present(alert)
        } catch Favorites.ImportError.needsFullDiskAccess {
            let alert = NSAlert()
            alert.messageText = "UltimateFinder needs Full Disk Access to read Finder's favorites"
            alert.informativeText = """
                macOS keeps Finder's sidebar list in a protected location. To import it, allow \
                UltimateFinder under System Settings › Privacy & Security › Full Disk Access, then choose \
                Import Finder Favorites again (you may need to quit and reopen UltimateFinder first).

                This is optional: you can also add folders by dragging them onto the sidebar.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            present(alert) { response in
                if response == .alertFirstButtonReturn { Favorites.openFullDiskAccessSettings() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't find Finder's favorites"
            alert.informativeText = "Add folders by dragging them onto the sidebar instead."
            present(alert)
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        if let window = tableView.window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runAboveVisor())
        }
    }
}
