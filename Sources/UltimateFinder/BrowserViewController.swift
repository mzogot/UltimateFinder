import AppKit
import Carbon.HIToolbox
import Quartz

/// One browser pane: a path bar, a Favorites/Locations sidebar and a Finder-style column
/// browser or list view. The visor shows one, or two side by side in split view.
final class BrowserViewController: NSViewController {
    private let pane: Settings.Pane
    private let browser = NSBrowser()
    private let sidebar = SidebarController()
    private let splitView = NSSplitView()
    private let previewController = PreviewViewController()
    private let pathControl = NSPathControl()
    private let newFolderButton = NSButton()
    private let newTabButton = NSButton()
    private let splitButton = NSButton()
    private let hiddenToggle = NSButton()
    private let sortButton = NSButton()
    private let foldersOnTopButton = NSButton()
    private let viewModeControl = NSSegmentedControl()
    private let fileList = FileListController()
    private let contentView = NSView()
    private var viewMode: Settings.ViewMode
    /// The folder shown in list view; a node from `root`'s tree whenever it lies inside the root.
    private var listFolder: FileNode?
    private let tabBar = TabBarView()
    private var tabBarHeight: NSLayoutConstraint!
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var watcher = DirectoryWatcher { [weak self] paths in
        guard let self else { return }
        // Reloading a column would pull the rename field out from under the user; catch up afterwards.
        if self.renameField != nil {
            self.needsRefreshAfterRename = true
            return
        }
        self.refreshVisibleColumns(onlyIn: paths)
    }
    private var renameField: RenameField?
    private var renameTimer: Timer?
    private var needsRefreshAfterRename = false

    // Tabs share one NSBrowser: switching saves the current root + selection and loads the other's.
    private var tabs: [BrowserTab]
    /// Back/forward history, one per tab (same order as `tabs`).
    private var histories: [NavigationHistory]
    private var isRestoringHistory = false
    private let navigationControl = NSSegmentedControl()
    private var mouseMonitor: Any?
    /// Nodes whose icon previews loaded since the rows were last redrawn.
    private var nodesWithNewIcons: [FileNode] = []
    private var activeTab: Int
    private var root: FileNode
    private var isPrepared = false
    private var isVisorShown = false
    private var didSetInitialSidebarWidth = false

    private weak var quickLookPanel: QLPreviewPanel?
    private var quickLookURLs: [URL] = []

    // Targets of the context menu currently open.
    private var menuNodes: [FileNode] = []
    private var menuFolder: FileNode?
    private var sharePicker: NSSharingServicePicker?

    /// Called after files are opened in another app, so the visor can get out of the way.
    var onOpenedItems: (() -> Void)?
    var onToggleSplit: (() -> Void)?
    var isSplit = false {
        didSet { updateSplitButton() }
    }

    /// The pasteboard's change count right after ⌘X, so pasting knows to move rather than copy.
    /// Shared by both panes, so items cut in one can be pasted into the other.
    private static var cutChangeCount: Int?

    // Sort order and hidden files apply to both panes; the pane that changes them tells the other.
    private static let listingOrderDidChange = Notification.Name("BrowserListingOrderDidChange")
    private static let showsHiddenFilesDidChange = Notification.Name("BrowserShowsHiddenFilesDidChange")

    init(pane: Settings.Pane) {
        self.pane = pane
        viewMode = Settings.viewMode(of: pane)
        (tabs, activeTab) = Settings.tabs(of: pane)
        histories = Array(repeating: NavigationHistory(), count: tabs.count)
        root = FileNode(url: tabs[activeTab].root)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: View

    override func loadView() {
        let container = NSView()

        configureBrowser()
        configureHeader()
        configureSidebar()
        configureFileList()
        configureNavigation()
        tabBar.onSelect = { [weak self] in self?.selectTab($0) }
        tabBar.onClose = { [weak self] in self?.closeTab($0) }
        tabBar.onAdd = { [weak self] in self?.newTab() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(fileIconDidChange(_:)), name: FileNode.iconDidChange, object: nil)
        center.addObserver(self, selector: #selector(listingOrderDidChange(_:)), name: Self.listingOrderDidChange, object: nil)
        center.addObserver(self, selector: #selector(showsHiddenFilesDidChange), name: Self.showsHiddenFilesDidChange, object: nil)

        let header = NSStackView(views: [navigationControl, pathControl, viewModeControl, sortButton, foldersOnTopButton, newFolderButton, newTabButton, splitButton, hiddenToggle])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        let topLine = NSBox()
        topLine.boxType = .separator
        let bottomLine = NSBox()
        bottomLine.boxType = .separator

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebar.scrollView)
        for content in [browser, fileList.scrollView] as [NSView] {
            content.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                content.topAnchor.constraint(equalTo: contentView.topAnchor),
                content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        splitView.addArrangedSubview(contentView)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail

        for subview in [header, topLine, tabBar, splitView, bottomLine, statusLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),

            topLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            tabBar.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBarHeight,

            splitView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            bottomLine.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.topAnchor.constraint(equalTo: bottomLine.bottomAnchor, constant: 5),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

            sidebar.scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            sidebar.scrollView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialSidebarWidth, splitView.bounds.width > 0 {
            didSetInitialSidebarWidth = true
            splitView.setPosition(190, ofDividerAt: 0)
        }
    }

    private func configureBrowser() {
        browser.delegate = self
        browser.target = self
        browser.action = #selector(browserSelectionChanged(_:))
        browser.doubleAction = #selector(browserDoubleClicked(_:))
        browser.isTitled = false
        browser.separatesColumns = true
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.allowsTypeSelect = true
        browser.sendsActionOnArrowKeys = true
        browser.columnResizingType = .userColumnResizing
        browser.setDefaultColumnWidth(240)
        browser.minColumnWidth = 150
        browser.rowHeight = 20
        browser.focusRingType = .none
        browser.columnsAutosaveName = pane == .left ? "UltimateFinderColumns" : "UltimateFinderColumnsRight"
        browser.setDraggingSourceOperationMask(.every, forLocal: true)
        browser.setDraggingSourceOperationMask(.every, forLocal: false)
        browser.registerForDraggedTypes([.fileURL])

        let menu = NSMenu()
        menu.delegate = self
        browser.menu = menu
    }

    private func configureHeader() {
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureHeaderButton(newFolderButton, symbol: "folder.badge.plus", tip: "New Folder (⇧⌘N)",
                              action: #selector(newFolderClicked(_:)))
        configureHeaderButton(newTabButton, symbol: "plus.square.on.square", tip: "New Tab (⌘T)",
                              action: #selector(newTabClicked(_:)))
        configureHeaderButton(splitButton, symbol: "rectangle.split.2x1", tip: "", action: #selector(splitClicked(_:)))
        updateSplitButton()
        configureHeaderButton(hiddenToggle, symbol: "eye.slash", tip: "", action: #selector(hiddenToggleClicked(_:)))
        configureHeaderButton(sortButton, symbol: "arrow.up.arrow.down", tip: "Sort By", action: #selector(sortClicked(_:)))
        configureHeaderButton(foldersOnTopButton, symbol: "folder", tip: "", action: #selector(foldersOnTopClicked(_:)))

        viewModeControl.segmentCount = 2
        viewModeControl.trackingMode = .selectOne
        for (segment, symbol, tip) in [(0, "list.bullet", "as List (⌘2)"), (1, "rectangle.split.3x1", "as Columns (⌘3)")] {
            viewModeControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: segment)
            viewModeControl.setToolTip(tip, forSegment: segment)
            viewModeControl.setWidth(30, forSegment: segment)
        }
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged(_:))
        viewModeControl.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureFileList() {
        fileList.host = self
        if pane == .right { fileList.outlineView.autosaveName = "UltimateFinderListRight" }
        let menu = NSMenu()
        menu.delegate = self
        fileList.outlineView.menu = menu
    }

    /// The view that should hold keyboard focus for the current mode.
    private var primaryView: NSView {
        isListMode ? fileList.outlineView : browser
    }

    func focus() {
        view.window?.makeFirstResponder(primaryView)
    }

    private func configureHeaderButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func configureSidebar() {
        sidebar.onSelect = { [weak self] url in
            guard let self else { return }
            self.setRoot(url)
            self.view.window?.makeFirstResponder(self.primaryView)
        }
        sidebar.onOpenInNewTab = { [weak self] url in self?.newTab(at: url) }
        sidebar.validateFileDrop = { [weak self] info, folder in
            guard let self else { return [] }
            let sources = self.draggedURLs(info)
            guard !sources.isEmpty, !sources.contains(where: { FileOperations.url(folder, isInside: $0) }) else { return [] }
            return self.dragOperation(for: info, sources: sources, into: folder)
        }
        sidebar.acceptFileDrop = { [weak self] info, folder in
            guard let self else { return false }
            let sources = self.draggedURLs(info)
            let operation = self.dragOperation(for: info, sources: sources, into: folder)
            guard !operation.isEmpty else { return false }
            self.transfer(sources, into: folder, move: operation != .copy)
            return true
        }
    }

    // MARK: Visor lifecycle

    /// Loads the first column ahead of time so the first slide-in doesn't stall.
    func prepare() {
        _ = view
        guard !isPrepared else { return }
        isPrepared = true
        updateHiddenToggle()
        updateFoldersOnTopButton()
        loadActiveTab()
    }

    func visorWillShow() {
        prepare()
        isVisorShown = true
        updateWatchedFolders()
        // Pick up changes made while hidden, after the slide has started.
        DispatchQueue.main.async { [weak self] in self?.refreshVisibleColumns() }
    }

    func visorDidHide() {
        cancelPendingRename()
        renameField?.commit()
        isVisorShown = false
        watcher.stop()
        saveTabs()
    }

    // MARK: Tabs

    private var currentTabState: BrowserTab {
        guard isListMode, let listFolder else {
            return BrowserTab(root: root.url, selection: selectedNodes.map(\.url))
        }
        // Also record the column-view equivalent: the selected items inside the list folder, or
        // else the list folder itself (selected, so its contents show in the next column).
        let listSelection = fileList.selectedNodes.map(\.url)
        var selection = listSelection.filter { $0.deletingLastPathComponent().isSameFile(as: listFolder.url) }
        if selection.isEmpty, !listFolder.url.isSameFile(as: root.url) { selection = [listFolder.url] }
        return BrowserTab(root: root.url, selection: selection, listFolder: listFolder.url, listSelection: listSelection)
    }

    func saveTabs() {
        guard isPrepared else { return }
        tabs[activeTab] = currentTabState
        Settings.setTabs(tabs, active: activeTab, of: pane)
    }

    private func loadActiveTab() {
        load(tabs[activeTab])
    }

    private func load(_ tab: BrowserTab) {
        root = FileNode(url: tab.root)
        browser.isHidden = isListMode
        fileList.scrollView.isHidden = !isListMode
        updateViewModeControl()
        if isListMode {
            let folder = tab.listFolder ?? tab.currentFolder
            let selection = tab.listSelection ?? tab.selection.filter { $0.deletingLastPathComponent().isSameFile(as: folder) }
            showList(folder, selecting: selection)
        } else {
            listFolder = nil
            browser.loadColumnZero()
            restoreSelection(tab.selection.compactMap(chain(to:)))
            sidebar.highlight(tab.root)
            updateSelectionUI()
        }
    }

    // MARK: View modes & sorting

    private var isListMode: Bool { viewMode == .list }

    func setViewMode(_ mode: Settings.ViewMode) {
        guard mode != viewMode else { return }
        var state = currentTabState
        // Entering list view starts from what the columns show.
        if mode == .list { state.listFolder = nil; state.listSelection = nil }
        viewMode = mode
        Settings.setViewMode(mode, of: pane)
        load(state)
        view.window?.makeFirstResponder(primaryView)
    }

    private func updateViewModeControl() {
        viewModeControl.selectedSegment = isListMode ? 0 : 1
    }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        setViewMode(sender.selectedSegment == 0 ? .list : .columns)
    }

    /// Shows `url` in list view, moving the root up to it if it lies outside the root.
    private func showList(_ url: URL, selecting selection: [URL] = []) {
        if chain(to: url) == nil, !url.isSameFile(as: root.url) { root = FileNode(url: url) }
        let folder = node(for: url)
        listFolder = folder
        fileList.show(folder, selecting: selection)
        sidebar.highlight(folder.url)
        updateSelectionUI()
    }

    /// `url`'s node in the root's cached tree (sharing its caches), or a fresh node outside it.
    private func node(for url: URL) -> FileNode {
        guard let chain = chain(to: url) else { return url.isSameFile(as: root.url) ? root : FileNode(url: url) }
        var node = root
        for step in chain {
            guard let next = node.children(showingHidden: showsHidden).first(where: { $0.url.isSameFile(as: step) }) else {
                return FileNode(url: url)
            }
            node = next
        }
        return node
    }

    private func applySort(_ sort: FileSort) {
        guard sort != FileNode.sortOrder else { return }
        resort {
            FileNode.sortOrder = sort
            Settings.sortOrder = sort
            fileList.applySortIndicator(sort)
        }
        NotificationCenter.default.post(name: Self.listingOrderDidChange, object: self)
    }

    /// Lists folders above files whatever the sort order (Finder's "Keep folders on top").
    var foldersOnTop: Bool {
        get { FileNode.foldersOnTop }
        set {
            guard newValue != FileNode.foldersOnTop else { return }
            resort {
                FileNode.foldersOnTop = newValue
                Settings.foldersOnTop = newValue
            }
            updateFoldersOnTopButton()
            NotificationCenter.default.post(name: Self.listingOrderDidChange, object: self)
        }
    }

    /// The other pane changed the shared order; its trees are already re-sorted, this one's aren't.
    @objc private func listingOrderDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? !== self else { return }
        fileList.applySortIndicator(FileNode.sortOrder)
        updateFoldersOnTopButton()
        guard isPrepared else { return }
        resort {}
    }

    /// Applies an ordering change to the cached trees and reloads, keeping the selection.
    private func resort(_ change: () -> Void) {
        let state = currentTabState
        change()
        root.resortTree()
        if let listFolder, chain(to: listFolder.url) == nil { listFolder.resortTree() }
        if isListMode {
            fileList.reloadPreservingState()
        } else {
            browser.loadColumnZero()
            restoreSelection(state.selection.compactMap(chain(to:)))
        }
        updateSelectionUI()
    }

    @objc private func sortClicked(_ sender: NSButton) {
        let current = FileNode.sortOrder
        let menu = NSMenu()
        for key in FileSort.Key.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(sortKeyChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = current.key == key ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, ascending) in [("Ascending", true), ("Descending", false)] {
            let item = NSMenuItem(title: title, action: #selector(sortDirectionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ascending
            item.state = current.ascending == ascending ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let foldersItem = NSMenuItem(title: "Keep Folders on Top", action: #selector(foldersOnTopClicked(_:)), keyEquivalent: "")
        foldersItem.target = self
        foldersItem.state = foldersOnTop ? .on : .off
        menu.addItem(foldersItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc private func sortKeyChosen(_ sender: NSMenuItem) {
        guard let key = (sender.representedObject as? String).flatMap(FileSort.Key.init) else { return }
        let current = FileNode.sortOrder
        applySort(FileSort(key: key, ascending: key == current.key ? current.ascending : key.defaultAscending))
    }

    @objc private func sortDirectionChosen(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool else { return }
        applySort(FileSort(key: FileNode.sortOrder.key, ascending: ascending))
    }

    @objc private func foldersOnTopClicked(_ sender: Any?) {
        foldersOnTop.toggle()
    }

    private func updateFoldersOnTopButton() {
        let on = foldersOnTop
        foldersOnTopButton.image = NSImage(systemSymbolName: on ? "folder.fill" : "folder",
                                           accessibilityDescription: "Keep folders on top")
        foldersOnTopButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        foldersOnTopButton.toolTip = on ? "Folders on top: on" : "Keep folders on top"
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTab else { return }
        saveTabs()
        activeTab = index
        loadActiveTab()
        Settings.setTabs(tabs, active: activeTab, of: pane)
    }

    /// Opens a tab after the current one: at `url`, or a copy of the current tab (like ⌘T in Finder).
    func newTab(at url: URL? = nil) {
        saveTabs()
        let tab = url.map { BrowserTab(root: $0, selection: []) } ?? currentTabState
        activeTab += 1
        tabs.insert(tab, at: activeTab)
        histories.insert(NavigationHistory(), at: activeTab)
        loadActiveTab()
        Settings.setTabs(tabs, active: activeTab, of: pane)
        view.window?.makeFirstResponder(primaryView)
    }

    func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        saveTabs()
        tabs.remove(at: index)
        histories.remove(at: index)
        if index < activeTab || activeTab == tabs.count {
            activeTab -= 1
        }
        loadActiveTab()
        Settings.setTabs(tabs, active: activeTab, of: pane)
    }

    private func updateTabBar() {
        tabBarHeight.constant = tabs.count > 1 ? 30 : 0
        tabBar.isHidden = tabs.count < 2
        guard tabs.count > 1 else { return }
        let titles = tabs.indices.map { $0 == activeTab ? currentTabState.title : tabs[$0].title }
        tabBar.update(titles: titles, selected: activeTab)
    }

    // MARK: Navigation & selection

    var showsHidden: Bool { Settings.showHiddenFiles }

    private var selectedNodes: [FileNode] {
        if isListMode { return fileList.selectedNodes }
        return browser.selectionIndexPaths.compactMap { browser.item(at: $0) as? FileNode }
    }

    /// The folder that "New Folder", paste and the status line refer to: the list folder, or the
    /// column holding the selection.
    private var focusedDirectory: FileNode {
        if isListMode { return listFolder ?? root }
        let column = browser.selectedColumn
        if column >= 0, let node = browser.parentForItems(inColumn: column) as? FileNode, node.isDirectory {
            return node
        }
        return root
    }

    func setRoot(_ url: URL, selecting chain: [URL] = []) {
        root = FileNode(url: url)
        if isListMode {
            showList(url)
            return
        }
        browser.loadColumnZero()
        if !chain.isEmpty { restoreSelection([chain]) }
        sidebar.highlight(url)
        updateSelectionUI()
    }

    private func goUp() {
        if isListMode, let listFolder {
            let current = listFolder.url.standardizedFileURL
            guard current.path != "/" else { NSSound.beep(); return }
            showList(current.deletingLastPathComponent(), selecting: [current])
            return
        }
        let current = root.url.standardizedFileURL
        guard current.path != "/" else { NSSound.beep(); return }
        setRoot(current.deletingLastPathComponent(), selecting: [current])
    }

    var showsHiddenFiles: Bool {
        get { Settings.showHiddenFiles }
        set {
            guard newValue != Settings.showHiddenFiles else { return }
            Settings.showHiddenFiles = newValue
            NotificationCenter.default.post(name: Self.showsHiddenFilesDidChange, object: self)
        }
    }

    /// Reloads every listing with or without hidden files, in both panes.
    @objc private func showsHiddenFilesDidChange() {
        updateHiddenToggle()
        guard isPrepared else { return }
        if isListMode {
            root.invalidateTree()
            listFolder?.invalidateTree()
            fileList.reloadPreservingState()
            updateSelectionUI()
            return
        }
        // The cached listings still match the rows on screen until they're invalidated.
        let chains = browser.selectionIndexPaths.map(urlChain(for:))
        root.invalidateTree()
        browser.loadColumnZero()
        restoreSelection(chains)
        updateSelectionUI()
    }

    /// The URLs from the root down to the item at `indexPath`.
    private func urlChain(for indexPath: IndexPath) -> [URL] {
        var urls: [URL] = []
        var node = root
        for index in indexPath {
            let children = node.children(showingHidden: showsHidden)
            guard children.indices.contains(index) else { break }
            node = children[index]
            urls.append(node.url)
        }
        return urls
    }

    /// The URLs from the root down to `url`, or nil if it lies outside the root.
    private func chain(to url: URL) -> [URL]? {
        let rootPath = root.url.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var current = root.url
        return target.dropFirst(prefix.count).split(separator: "/").map {
            current = current.appendingPathComponent(String($0))
            return current
        }
    }

    private func resolve(_ chain: [URL]) -> (path: IndexPath, complete: Bool) {
        var path = IndexPath()
        var node = root
        for url in chain {
            let target = url.standardizedFileURL.path
            let children = node.children(showingHidden: showsHidden)
            guard node.isDirectory,
                  let index = children.firstIndex(where: { $0.url.standardizedFileURL.path == target })
            else { return (path, false) }
            path.append(index)
            node = children[index]
        }
        return (path, true)
    }

    private func restoreSelection(_ chains: [[URL]]) {
        let resolved = chains.map(resolve)
        let complete = resolved.filter { $0.complete && !$0.path.isEmpty }.map(\.path)
        if !complete.isEmpty {
            browser.selectionIndexPaths = complete
        } else if let partial = resolved.map(\.path).max(by: { $0.count < $1.count }), !partial.isEmpty {
            browser.selectionIndexPath = partial
        }
        if let path = browser.selectionIndexPaths.last, let row = path.last {
            browser.scrollRowToVisible(row, inColumn: path.count - 1)
            browser.scrollColumnToVisible(browser.lastColumn)
        }
    }

    /// Re-reads the folders shown in the columns and reloads from the first one that changed.
    /// `paths` limits the check to those canonical folder paths (from FSEvents); nil checks all.
    private func refreshVisibleColumns(onlyIn paths: Set<String>? = nil) {
        guard isPrepared else { return }
        if isListMode {
            fileList.refresh(onlyIn: paths)
            updateSelectionUI()
            return
        }
        guard browser.lastColumn >= 0 else { return }
        let chains = browser.selectionIndexPaths.map(urlChain(for:))

        var firstChanged: Int?
        for column in 0...browser.lastColumn {
            guard let folder = browser.parentForItems(inColumn: column) as? FileNode, folder.isDirectory else { continue }
            if let paths, !paths.contains(folder.canonicalPath) { continue }
            if folder.reloadChildren(showingHidden: showsHidden), firstChanged == nil {
                firstChanged = column
            }
        }
        if let column = firstChanged {
            browser.reloadColumn(column)
            restoreSelection(chains)
        }
        updateSelectionUI()
    }

    /// Refreshes, then selects `urls` (e.g. items just created, pasted or dropped).
    private func select(_ urls: [URL]) {
        refreshVisibleColumns()
        if isListMode {
            fileList.select(urls)
            updateSelectionUI()
            return
        }
        let chains = urls.compactMap(chain(to:))
        guard !chains.isEmpty else { return }
        restoreSelection(chains)
        updateSelectionUI()
    }

    private func updateSelectionUI() {
        let selected = selectedNodes
        pathControl.url = selected.last?.url ?? listFolder?.url ?? root.url

        let folder = focusedDirectory
        let count = folder.children(showingHidden: showsHidden).count
        var status = count == 1 ? "1 item" : "\(count) items"
        if selected.count > 1 { status = "\(selected.count) of \(count) selected" }
        if let available = try? folder.url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
            status += ", " + ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file) + " available"
        }
        statusLabel.stringValue = status

        if let panel = quickLookPanel, panel.isVisible {
            quickLookURLs = selected.map(\.url)
            panel.reloadData()
        }
        updateWatchedFolders()
        updateTabBar()
        recordHistory()
    }

    @objc private func fileIconDidChange(_ notification: Notification) {
        guard let node = notification.object as? FileNode else { return }
        // Previews arrive one by one; redraw them in batches rather than row by row.
        if nodesWithNewIcons.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.reloadRowsWithNewIcons() }
        }
        nodesWithNewIcons.append(node)
    }

    private func reloadRowsWithNewIcons() {
        let nodes = nodesWithNewIcons
        nodesWithNewIcons = []
        fileList.reloadIcons(of: nodes)
        reloadBrowserRows(of: nodes)
    }

    /// Redraws the column-view rows showing `nodes`.
    private func reloadBrowserRows(of nodes: [FileNode]) {
        guard browser.lastColumn >= 0 else { return }
        let changed = Set(nodes.map(ObjectIdentifier.init))
        for column in 0...browser.lastColumn {
            guard let folder = browser.parentForItems(inColumn: column) as? FileNode, folder.isDirectory else { continue }
            let children = folder.children(showingHidden: showsHidden)
            let rows = IndexSet(children.indices.filter { changed.contains(ObjectIdentifier(children[$0])) })
            if !rows.isEmpty { browser.reloadData(forRowIndexes: rows, inColumn: column) }
        }
    }

    /// Watches exactly the folders listed in the visible columns while the visor is shown.
    private func updateWatchedFolders() {
        guard isVisorShown else { return }
        var folders = fileList.visibleFolders
        if !isListMode {
            guard browser.lastColumn >= 0 else { return }
            folders = (0...browser.lastColumn).compactMap { browser.parentForItems(inColumn: $0) as? FileNode }
        }
        watcher.watch(Set(folders.filter(\.isDirectory).map(\.canonicalPath)))
    }

    private func updateHiddenToggle() {
        let showing = Settings.showHiddenFiles
        hiddenToggle.image = NSImage(systemSymbolName: showing ? "eye" : "eye.slash",
                                     accessibilityDescription: "Show hidden files")
        hiddenToggle.toolTip = showing ? "Hide hidden files (⇧⌘.)" : "Show hidden files (⇧⌘.)"
    }

    // MARK: Actions

    @objc private func browserSelectionChanged(_ sender: Any?) {
        updateSelectionUI()
    }

    @objc private func browserDoubleClicked(_ sender: Any?) {
        let nodes = selectedNodes
        // ⌘-double-click opens folders in new tabs, as in Finder.
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            for folder in nodes where folder.isDirectory { newTab(at: folder.url) }
            return
        }
        // Folders are already expanded into the next column; only open files and packages.
        let files = nodes.filter { !$0.isDirectory }
        if !files.isEmpty { open(files) }
    }

    @objc private func newFolderClicked(_ sender: Any?) {
        newFolder(in: focusedDirectory)
    }

    @objc private func newTabClicked(_ sender: Any?) {
        newTab()
    }

    private func addToSidebar(_ nodes: [FileNode]) {
        let folders = nodes.filter(\.isDirectory).map(\.url)
        guard !folders.isEmpty else { NSSound.beep(); return }
        Favorites.add(folders)
        sidebar.reload()
    }

    @objc private func pathControlClicked(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return }
        setRoot(url)
    }

    @objc private func hiddenToggleClicked(_ sender: Any?) {
        showsHiddenFiles.toggle()
    }

    @objc private func splitClicked(_ sender: Any?) {
        onToggleSplit?()
    }

    private func updateSplitButton() {
        splitButton.contentTintColor = isSplit ? .controlAccentColor : .secondaryLabelColor
        splitButton.toolTip = isSplit ? "Close Split View (⌘U)" : "Split View (⌘U)"
    }

    private func open(_ nodes: [FileNode]) {
        if nodes.count == 1, let folder = nodes.first, folder.isDirectory {
            isListMode ? showList(folder.url) : setRoot(folder.url)
            return
        }
        for node in nodes { NSWorkspace.shared.open(node.url) }
        onOpenedItems?()
    }

    private func open(_ urls: [URL], withApplicationAt app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.showError(error) } }
        }
        onOpenedItems?()
    }

    private func showInFinder(_ nodes: [FileNode]) {
        NSWorkspace.shared.activateFileViewerSelecting(nodes.map(\.url))
        onOpenedItems?()
    }

    private func moveToTrash(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        NSWorkspace.shared.recycle(nodes.map(\.url)) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { self?.showError(error) }
                self?.refreshVisibleColumns()
            }
        }
    }

    private func newFolder(in folder: FileNode) {
        createAndRename { try FileOperations.createFolder(in: folder.url) }
    }

    private func newTextFile(in folder: FileNode) {
        createAndRename { try FileOperations.createTextFile(in: folder.url) }
    }

    /// Creates an item, selects it and asks for its name, as Finder does with a new folder.
    private func createAndRename(_ create: () throws -> URL) {
        do {
            let url = try create()
            select([url])
            if let node = selectedNodes.first(where: { $0.url.isSameFile(as: url) }) {
                rename(node)
            }
        } catch {
            showError(error)
        }
    }

    // MARK: Renaming

    /// Renames in place, with a field over the item's name as in Finder; an alert stands in when
    /// the row can't be shown.
    private func rename(_ node: FileNode) {
        cancelPendingRename()
        renameField?.commit()
        guard view.window?.isVisible == true, let field = makeRenameField(for: node) else {
            renameWithAlert(node)
            return
        }
        renameField = field
        field.onEnd = { [weak self, weak field] newName in
            guard let self, let field else { return }
            self.renameField = nil
            if self.view.window?.firstResponder === field.currentEditor() {
                self.view.window?.makeFirstResponder(self.primaryView)
            }
            field.removeFromSuperview()
            if let newName {
                self.applyRename(of: node, to: newName)
            }
            if self.needsRefreshAfterRename {
                self.needsRefreshAfterRename = false
                self.refreshVisibleColumns()
            }
        }
        field.beginEditing(selecting: Self.renameSelection(in: field.stringValue, isDirectory: node.isDirectory))
    }

    /// Lays a rename field over `node`'s name in the list or column view; nil if it isn't showing.
    private func makeRenameField(for node: FileNode) -> RenameField? {
        let name = node.url.lastPathComponent
        if isListMode {
            // In the outline view rather than the cell, which gets reused when rows reload.
            let host = fileList.outlineView
            guard let label = fileList.nameLabel(of: node) else { return nil }
            let labelFrame = host.convert(label.frame, from: label.superview)
            let field = RenameField(name: name, font: label.font ?? .systemFont(ofSize: NSFont.systemFontSize),
                                    textFrame: labelFrame.insetBy(dx: 2, dy: 0), maxX: labelFrame.maxX)
            host.addSubview(field)
            return field
        }

        guard let path = browser.selectionIndexPaths.first(where: { browser.item(at: $0) as? FileNode === node }),
              let row = path.last, let superview = browser.superview
        else { return nil }
        let column = path.count - 1
        browser.scrollColumnToVisible(column)
        browser.scrollRowToVisible(row, inColumn: column)
        let rowFrame = browser.frame(ofRow: row, inColumn: column)
        guard !rowFrame.isEmpty else { return nil }

        // Sit in the column's own view so the field scrolls with the row.
        let center = superview.convert(NSPoint(x: rowFrame.midX, y: rowFrame.midY), from: browser)
        let host = browser.hitTest(center) ?? browser
        let textFrame = host.convert(browserNameFrame(row: row, column: column, node: node), from: browser)
        let field = RenameField(name: name, font: browser.font ?? .systemFont(ofSize: NSFont.systemFontSize),
                                textFrame: textFrame, maxX: host.convert(rowFrame, from: browser).maxX - 2)
        host.addSubview(field)
        return field
    }

    /// Finder selects the name without its extension.
    private static func renameSelection(in name: String, isDirectory: Bool) -> NSRange {
        NSRange(location: 0, length: isDirectory ? name.utf16.count : (name as NSString).deletingPathExtension.utf16.count)
    }

    private func renameWithAlert(_ node: FileNode) {
        let name = node.url.lastPathComponent
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)

        let alert = NSAlert()
        alert.messageText = "Rename “\(name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = field

        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.applyRename(of: node, to: field.stringValue)
        }

        alert.window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = Self.renameSelection(in: name, isDirectory: node.isDirectory)
    }

    private func applyRename(of node: FileNode, to typedName: String) {
        let name = node.url.lastPathComponent
        let newName = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != name else { return }
        guard !newName.contains("/") else { NSSound.beep(); return }

        let destination = node.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: node.url, to: destination)
            select([destination])
        } catch {
            showError(error)
        }
    }

    /// As in Finder, a click on the name of the one selected item starts renaming it, once the
    /// double-click interval has passed without a second click or a drag. Any click outside the
    /// rename field ends renaming.
    private func handleMouseForRename(_ event: NSEvent) {
        cancelPendingRename()
        if let field = renameField, let host = field.superview,
           event.window !== field.window || !field.frame.contains(host.convert(event.locationInWindow, from: nil)) {
            field.commit()
        }
        guard event.type == .leftMouseDown, event.clickCount == 1, event.modifierFlags.userModifiers.isEmpty,
              event.window === view.window, !view.isHiddenOrHasHiddenAncestor, renameField == nil,
              let node = node(withNameAt: event.locationInWindow),
              selectedNodes.count == 1, selectedNodes.first === node
        else { return }

        let start = NSEvent.mouseLocation
        renameTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.renameTimer = nil
            let end = NSEvent.mouseLocation
            guard NSEvent.pressedMouseButtons & 1 == 0, abs(end.x - start.x) < 4, abs(end.y - start.y) < 4,
                  self.view.window?.isKeyWindow == true, self.selectedNodes.count == 1, self.selectedNodes.first === node
            else { return }
            self.rename(node)
        }
    }

    private func cancelPendingRename() {
        renameTimer?.invalidate()
        renameTimer = nil
    }

    /// The item whose name is under `locationInWindow`, in the current view.
    private func node(withNameAt locationInWindow: NSPoint) -> FileNode? {
        if isListMode { return fileList.node(withNameAt: locationInWindow) }
        let point = browser.convert(locationInWindow, from: nil)
        var row = -1
        var column = -1
        guard browser.bounds.contains(point), browser.getRow(&row, column: &column, for: point),
              let node = browser.item(atRow: row, inColumn: column) as? FileNode,
              browserNameFrame(row: row, column: column, node: node).insetBy(dx: -2, dy: 0).contains(point)
        else { return nil }
        return node
    }

    /// Where a browser row draws its name, in browser coordinates: the title starts at the row's
    /// leading edge with a 16pt icon and two spaces.
    private func browserNameFrame(row: Int, column: Int, node: FileNode) -> NSRect {
        let rowFrame = browser.frame(ofRow: row, inColumn: column)
        let font = browser.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let start = rowFrame.minX + 4 + 16 + ("  " as NSString).size(withAttributes: [.font: font]).width
        let width = (node.name as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: start, y: rowFrame.minY, width: max(min(width, rowFrame.maxX - start), 0), height: rowFrame.height)
    }

    /// Shows alerts as sheets on the visor, which keeps keyboard focus even if macOS declines
    /// to activate the app; falls back to a modal alert when the visor is hidden.
    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        if let window = view.window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runAboveVisor())
        }
    }

    private func showError(_ error: Error) {
        present(NSAlert(error: error))
    }

    private func copyToPasteboard(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(nodes.map { $0.url as NSURL })
    }

    /// Files can't be cut on macOS, so ⌘X copies them and remembers to move them on paste.
    private func cutToPasteboard(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        copyToPasteboard(nodes)
        Self.cutChangeCount = NSPasteboard.general.changeCount
    }

    /// True while the pasteboard still holds what was cut (anything copied since replaces it).
    private var pasteboardHoldsCutItems: Bool {
        Self.cutChangeCount == NSPasteboard.general.changeCount
    }

    private func copyPaths(_ nodes: [FileNode]) {
        copyStrings(nodes.map(\.url.path))
    }

    /// Uses the file name on disk, so an extension Finder hides is still copied.
    private func copyNames(_ nodes: [FileNode], withExtension: Bool) {
        copyStrings(nodes.map { withExtension ? $0.url.lastPathComponent : $0.url.deletingPathExtension().lastPathComponent })
    }

    private func copyStrings(_ strings: [String]) {
        guard !strings.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(strings.joined(separator: "\n"), forType: .string)
    }

    private var pasteboardFileURLs: [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func paste(into folder: FileNode, move: Bool) {
        let urls = pasteboardFileURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        guard pasteboardHoldsCutItems else {
            transfer(urls, into: folder.url, move: move)
            return
        }
        // Cut items move once. Afterwards the pasteboard holds them at their new place, so
        // pasting again copies them instead of failing on paths that no longer exist.
        transfer(urls, into: folder.url, move: true) { moved in
            guard !moved.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(moved.map { $0 as NSURL })
            Self.cutChangeCount = nil
        }
    }

    private func transfer(_ urls: [URL], into folder: URL, move: Bool, completion: (([URL]) -> Void)? = nil) {
        // A folder can't be copied or moved into itself.
        guard !urls.contains(where: { FileOperations.url(folder, isInside: $0) }) else {
            NSSound.beep()
            return
        }
        FileOperations.transfer(urls, into: folder, move: move) { [weak self] results, error in
            if let error { self?.showError(error) }
            completion?(results)
            self?.select(results)
        }
    }

    private func convertImages(_ nodes: [FileNode], to format: ImageConverter.Format) {
        let sources = nodes.map(\.url).filter { ImageConverter.format(of: $0) != format }
        guard !sources.isEmpty else { return }
        ImageConverter.convert(sources, to: format) { [weak self] results, error in
            if let error { self?.showError(error) }
            self?.select(results)
        }
    }

    /// Gives `nodes` a color label (0 removes it) and re-tints their rows.
    private func setLabel(_ number: Int, of nodes: [FileNode]) {
        for node in nodes {
            do {
                try node.setLabel(number)
            } catch {
                showError(error)
                break
            }
        }
        fileList.reloadLabels(of: nodes)
        reloadBrowserRows(of: nodes)
    }

    private func openInTerminal(_ folder: FileNode) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        open([folder.url], withApplicationAt: terminal)
    }

    // MARK: Keyboard

    /// Finder's shortcuts. Returns true when the event was handled.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if handleWindowKey(event) { return true }
        let key = (Int(event.keyCode), event.modifierFlags.userModifiers)

        // With the sidebar focused, keys act on favorites, never on the (unfocused) file selection.
        if sidebar.hasFocus {
            if sidebar.handleKeyDown(event) { return true }
            switch key {
            case (kVK_ANSI_N, [.command, .shift]): newFolder(in: focusedDirectory)
            case (kVK_ANSI_Period, [.command, .shift]): showsHiddenFiles.toggle()
            default: return false
            }
            return true
        }

        let nodes = selectedNodes
        switch key {
        case (kVK_Space, []), (kVK_ANSI_Y, .command):
            toggleQuickLook()
        case (kVK_ANSI_T, [.command, .control]):
            addToSidebar(nodes)
        case (kVK_ANSI_O, .command), (kVK_DownArrow, .command):
            guard !nodes.isEmpty else { return false }
            open(nodes)
        case (kVK_UpArrow, .command):
            goUp()
        case (kVK_Delete, .command):
            moveToTrash(nodes)
        case (kVK_ANSI_N, [.command, .shift]):
            newFolder(in: focusedDirectory)
        case (kVK_ANSI_C, .command):
            copyToPasteboard(nodes)
        case (kVK_ANSI_X, .command):
            cutToPasteboard(nodes)
        case (kVK_ANSI_C, [.command, .option]):
            copyPaths(nodes)
        case (kVK_ANSI_V, .command):
            paste(into: focusedDirectory, move: false)
        case (kVK_ANSI_V, [.command, .option]):
            paste(into: focusedDirectory, move: true)
        case (kVK_ANSI_D, .command):
            guard !nodes.isEmpty else { return false }
            transfer(nodes.map(\.url), into: focusedDirectory.url, move: false)
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            guard nodes.count == 1 else { return false }
            rename(nodes[0])
        case (kVK_ANSI_R, .command):
            guard !nodes.isEmpty else { return false }
            showInFinder(nodes)
        case (kVK_ANSI_Period, [.command, .shift]):
            showsHiddenFiles.toggle()
        default:
            return false
        }
        return true
    }

    /// ⌘2 / ⌘3 switch between list and column view, as in Finder; ⌘T, ⌘W (with 2+ tabs),
    /// ⌃Tab / ⌃⇧Tab and ⇧⌘] / ⇧⌘[ manage tabs.
    private func handleWindowKey(_ event: NSEvent) -> Bool {
        switch (Int(event.keyCode), event.modifierFlags.userModifiers) {
        case (kVK_ANSI_2, .command):
            setViewMode(.list)
        case (kVK_ANSI_3, .command):
            setViewMode(.columns)
        case (kVK_ANSI_LeftBracket, .command):
            goBack()
        case (kVK_ANSI_RightBracket, .command):
            goForward()
        case _ where event.modifierFlags.userModifiers == .command && event.charactersIgnoringModifiers == "[":
            goBack()  // non-US layouts, where "[" is not on the US key
        case _ where event.modifierFlags.userModifiers == .command && event.charactersIgnoringModifiers == "]":
            goForward()
        case (kVK_ANSI_T, .command):
            newTab()
        case (kVK_ANSI_W, .command):
            guard tabs.count > 1 else { return false }  // the last tab's ⌘W hides the visor
            closeTab(activeTab)
        case (kVK_Tab, .control), (kVK_ANSI_RightBracket, [.command, .shift]):
            guard tabs.count > 1 else { return false }
            selectTab((activeTab + 1) % tabs.count)
        case (kVK_Tab, [.control, .shift]), (kVK_ANSI_LeftBracket, [.command, .shift]):
            guard tabs.count > 1 else { return false }
            selectTab((activeTab + tabs.count - 1) % tabs.count)
        default:
            return false
        }
        return true
    }
}

// MARK: - NSBrowserDelegate (item-based API)

extension BrowserViewController: NSBrowserDelegate {
    private func node(_ item: Any?) -> FileNode {
        item as? FileNode ?? root
    }

    func rootItem(for browser: NSBrowser) -> Any? {
        root
    }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        let parent = node(item)
        return parent.isDirectory ? parent.children(showingHidden: showsHidden).count : 0
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        let children = node(item).children(showingHidden: showsHidden)
        return children.indices.contains(index) ? children[index] : node(item)
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        !node(item).isDirectory
    }

    // Current NSBrowser columns draw with NSTextFieldCell rather than NSBrowserCell (it ignores
    // cellClass/cellPrototype), so the icon travels inside the title as a text attachment.
    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        node(item).displayTitle
    }

    /// Tints labelled rows, except selected ones, so the selection highlight stays visible.
    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSTextFieldCell else { return }
        let color = (browser.item(atRow: row, inColumn: column) as? FileNode)?.labelColor
        let isSelected = browser.selectedRowIndexes(inColumn: column)?.contains(row) == true
        cell.drawsBackground = color != nil && !isSelected
        cell.backgroundColor = color?.withAlphaComponent(LabelRowView.tintAlpha)
    }

    func browser(_ browser: NSBrowser, typeSelectStringForRow row: Int, inColumn column: Int) -> String? {
        (browser.item(atRow: row, inColumn: column) as? FileNode)?.name
    }

    func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool {
        false
    }

    func browser(_ browser: NSBrowser, previewViewControllerForLeafItem item: Any) -> NSViewController? {
        previewController.representedObject = item
        return previewController
    }

    // MARK: Drag out

    /// As in Finder, pressing on an item's icon or name drags it; pressing beside the name and
    /// dragging selects the rows the mouse passes over instead.
    func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool {
        let point = browser.convert(event.locationInWindow, from: nil)
        var row = -1
        var hitColumn = -1
        guard browser.getRow(&row, column: &hitColumn, for: point), hitColumn == column,
              let node = browser.item(atRow: row, inColumn: column) as? FileNode
        else { return false }
        return point.x <= browserNameFrame(row: row, column: column, node: node).maxX + 6
    }

    func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
        let urls = rowIndexes.compactMap { (browser.item(atRow: $0, inColumn: column) as? FileNode)?.url as NSURL? }
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls)
    }

    // MARK: Drop in

    func browser(
        _ browser: NSBrowser,
        validateDrop info: NSDraggingInfo,
        proposedRow row: UnsafeMutablePointer<Int>,
        column: UnsafeMutablePointer<Int>,
        dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>
    ) -> NSDragOperation {
        let sources = draggedURLs(info)
        guard !sources.isEmpty else { return [] }

        let ontoFolder = row.pointee >= 0 && dropOperation.pointee == .on
            && (browser.item(atRow: row.pointee, inColumn: column.pointee) as? FileNode)?.isDirectory == true
        if !ontoFolder {
            // Retarget to the whole column, i.e. the folder it lists.
            if column.pointee < 0 { column.pointee = 0 }
            row.pointee = -1
            dropOperation.pointee = .on
        }

        guard let target = dropTarget(row: row.pointee, column: column.pointee, operation: dropOperation.pointee),
              !sources.contains(where: { FileOperations.url(target.url, isInside: $0) })
        else { return [] }
        return dragOperation(for: info, sources: sources, into: target.url)
    }

    func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int, dropOperation: NSBrowser.DropOperation) -> Bool {
        let sources = draggedURLs(info)
        guard let target = dropTarget(row: row, column: column, operation: dropOperation) else { return false }
        let operation = dragOperation(for: info, sources: sources, into: target.url)
        guard !operation.isEmpty else { return false }
        transfer(sources, into: target.url, move: operation != .copy)
        return true
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func dropTarget(row: Int, column: Int, operation: NSBrowser.DropOperation) -> FileNode? {
        if row >= 0, operation == .on, let folder = browser.item(atRow: row, inColumn: column) as? FileNode, folder.isDirectory {
            return folder
        }
        let folder = column >= 0 ? browser.parentForItems(inColumn: column) as? FileNode : root
        return folder?.isDirectory == true ? folder : nil
    }

    /// Finder's rules: move on the same volume, copy across volumes; ⌥ forces copy, ⌘ forces move.
    private func dragOperation(for info: NSDraggingInfo, sources: [URL], into folder: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }

        let folderPath = folder.standardizedFileURL.path
        let alreadyThere = sources.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == folderPath }
        if alreadyThere { return [] }

        if mask == .generic { return .generic }
        if mask.contains(.move), sources.allSatisfy({ FileOperations.isOnSameVolume($0, folder) }) { return .move }
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        return []
    }
}

// MARK: - Context menu

extension BrowserViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sharePicker = nil

        if isListMode {
            prepareListMenuTargets()
        } else {
            prepareColumnMenuTargets()
        }
        buildMenu(menu)
    }

    /// Right-clicking an unselected row selects it first, like Finder.
    private func prepareListMenuTargets() {
        let outline = fileList.outlineView
        let row = outline.clickedRow
        menuNodes = []
        menuFolder = listFolder ?? root
        guard row >= 0, let clicked = outline.item(atRow: row) as? FileNode else { return }
        if fileList.selectedNodes.contains(where: { $0 === clicked }) {
            menuNodes = fileList.selectedNodes
        } else {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            menuNodes = [clicked]
        }
    }

    private func prepareColumnMenuTargets() {
        var row = -1
        var column = -1
        if let window = view.window {
            let point = browser.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            browser.getRow(&row, column: &column, for: point)
        }

        menuNodes = []
        if row >= 0, column >= 0, let clicked = browser.item(atRow: row, inColumn: column) as? FileNode {
            let selected = selectedNodes
            if selected.contains(where: { $0 === clicked }) {
                menuNodes = selected
            } else {
                // Right-clicking an unselected item selects it, like Finder.
                var path = browser.indexPath(forColumn: column)
                path.append(row)
                browser.selectionIndexPath = path
                updateSelectionUI()
                menuNodes = [clicked]
            }
        }
        if column >= 0, let folder = browser.parentForItems(inColumn: column) as? FileNode, folder.isDirectory {
            menuFolder = folder
        } else {
            menuFolder = focusedDirectory
        }
    }

    private func buildMenu(_ menu: NSMenu) {
        if !menuNodes.isEmpty {
            let nodes = menuNodes
            let subject = nodes.count == 1 ? "“\(nodes[0].name)”" : "\(nodes.count) Items"
            addItem(to: menu, "Open", #selector(menuOpen))
            if nodes.contains(where: \.isDirectory) {
                addItem(to: menu, "Open in New Tab", #selector(menuOpenInNewTab))
            }
            if let openWith = openWithItem(for: nodes) { menu.addItem(openWith) }
            addItem(to: menu, "Quick Look \(subject)", #selector(menuQuickLook))
            menu.addItem(.separator())
            addItem(to: menu, "Show in Finder", #selector(menuShowInFinder))
            addItem(to: menu, "Cut \(subject)", #selector(menuCut))
            addItem(to: menu, "Copy \(subject)", #selector(menuCopy))
            addItem(to: menu, "Copy Name", #selector(menuCopyName))
            addItem(to: menu, "Copy Name Without Extension", #selector(menuCopyBaseName))
            addItem(to: menu, "Copy Path", #selector(menuCopyPath))
            if nodes.contains(where: \.isDirectory) {
                addItem(to: menu, "Add to Sidebar", #selector(menuAddToSidebar))
            }
            addItem(to: menu, "Duplicate", #selector(menuDuplicate))
            if let convert = convertImageItem(for: nodes) { menu.addItem(convert) }
            if nodes.count == 1 { addItem(to: menu, "Rename…", #selector(menuRename)) }
            menu.addItem(.separator())
            let trash = NSMenuItem()
            trash.view = DestructiveMenuItemView(title: "Move to Trash", symbol: "trash") { [weak self] in
                self?.moveToTrash(nodes)
            }
            menu.addItem(trash)
            menu.addItem(.separator())
            menu.addItem(labelItem(for: nodes))
            menu.addItem(.separator())
            let picker = NSSharingServicePicker(items: nodes.map(\.url))
            sharePicker = picker
            menu.addItem(picker.standardShareMenuItem)
            menu.addItem(.separator())
        }

        addItem(to: menu, "New Folder", #selector(menuNewFolder))
        addItem(to: menu, "New Text File", #selector(menuNewTextFile))
        if !pasteboardFileURLs.isEmpty {
            let count = pasteboardFileURLs.count
            let items = count == 1 ? "Item" : "\(count) Items"
            addItem(to: menu, "Paste \(items)", #selector(menuPaste))
            // Holding ⌥ turns Paste into Move, as in Finder (cut items move either way).
            if !pasteboardHoldsCutItems {
                let move = NSMenuItem(title: "Move \(items) Here", action: #selector(menuMoveHere), keyEquivalent: "")
                move.target = self
                move.keyEquivalentModifierMask = .option
                move.isAlternate = true
                menu.addItem(move)
            }
        }
        addItem(to: menu, "Open in Terminal", #selector(menuOpenInTerminal))
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func labelItem(for nodes: [FileNode]) -> NSMenuItem {
        // Pick up labels changed in Finder, so clicking the current color really removes it.
        let changed = nodes.filter { $0.reloadLabel() }
        if !changed.isEmpty {
            fileList.reloadLabels(of: changed)
            reloadBrowserRows(of: changed)
        }
        let shared = Set(nodes.map(\.labelNumber))
        let item = NSMenuItem()
        item.view = LabelPickerView(current: shared.count == 1 ? shared.first! : 0) { [weak self] number in
            self?.setLabel(number, of: nodes)
        }
        return item
    }

    /// Offered when every target is an image, listing the formats they aren't all in already.
    private func convertImageItem(for nodes: [FileNode]) -> NSMenuItem? {
        guard nodes.allSatisfy({ !$0.isDirectory && ImageConverter.canConvert($0.url) }) else { return nil }
        let current = Set(nodes.map { ImageConverter.format(of: $0.url) })
        let submenu = NSMenu()
        for format in ImageConverter.Format.allCases where current != [format] {
            let item = NSMenuItem(title: format.title, action: #selector(menuConvertImage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Convert Image", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func openWithItem(for nodes: [FileNode]) -> NSMenuItem? {
        guard let first = nodes.first else { return nil }
        let workspace = NSWorkspace.shared
        let apps = workspace.urlsForApplications(toOpen: first.url)
        guard !apps.isEmpty else { return nil }
        let defaultApp = workspace.urlForApplication(toOpen: first.url)

        func appItem(_ app: URL, isDefault: Bool) -> NSMenuItem {
            var name = FileManager.default.displayName(atPath: app.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            let item = NSMenuItem(title: isDefault ? "\(name) (default)" : name, action: #selector(menuOpenWith(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = workspace.icon(forFile: app.path).copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            return item
        }

        let submenu = NSMenu()
        if let defaultApp {
            submenu.addItem(appItem(defaultApp, isDefault: true))
            submenu.addItem(.separator())
        }
        for app in apps where !(defaultApp.map(app.isSameFile(as:)) ?? false) {
            submenu.addItem(appItem(app, isDefault: false))
        }
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func menuOpen() { open(menuNodes) }
    @objc private func menuAddToSidebar() { addToSidebar(menuNodes) }

    @objc private func menuOpenInNewTab() {
        for folder in menuNodes where folder.isDirectory { newTab(at: folder.url) }
    }
    @objc private func menuQuickLook() { toggleQuickLook() }
    @objc private func menuShowInFinder() { showInFinder(menuNodes) }
    @objc private func menuCut() { cutToPasteboard(menuNodes) }
    @objc private func menuCopy() { copyToPasteboard(menuNodes) }
    @objc private func menuCopyPath() { copyPaths(menuNodes) }
    @objc private func menuCopyName() { copyNames(menuNodes, withExtension: true) }
    @objc private func menuCopyBaseName() { copyNames(menuNodes, withExtension: false) }

    @objc private func menuOpenWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        open(menuNodes.map(\.url), withApplicationAt: app)
    }

    @objc private func menuDuplicate() {
        guard let folder = menuFolder else { return }
        transfer(menuNodes.map(\.url), into: folder.url, move: false)
    }

    @objc private func menuRename() {
        if let node = menuNodes.first { rename(node) }
    }

    @objc private func menuNewFolder() {
        if let folder = menuFolder { newFolder(in: folder) }
    }

    @objc private func menuNewTextFile() {
        if let folder = menuFolder { newTextFile(in: folder) }
    }

    @objc private func menuConvertImage(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? ImageConverter.Format else { return }
        convertImages(menuNodes, to: format)
    }

    @objc private func menuPaste() {
        if let folder = menuFolder { paste(into: folder, move: false) }
    }

    @objc private func menuMoveHere() {
        if let folder = menuFolder { paste(into: folder, move: true) }
    }

    @objc private func menuOpenInTerminal() {
        if let folder = menuFolder { openInTerminal(folder) }
    }
}

// MARK: - Quick Look

extension BrowserViewController: QuickLookControlling, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !selectedNodes.isEmpty else { NSSound.beep(); return }
        // Quick Look looks for its controller via the key window's responder chain, and in split
        // view the focused pane is the one it previews (the context menu doesn't move focus).
        NSApp.activateCompat()
        focus()
        view.window?.makeKeyAndOrderFront(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func beginQuickLook(_ panel: QLPreviewPanel) {
        quickLookPanel = panel
        quickLookURLs = selectedNodes.map(\.url)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func endQuickLook(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookPanel = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let code = Int(event.keyCode)
        // Arrow keys keep moving through the browser while the preview is up, like Finder.
        if [kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow].contains(code) {
            view.window?.firstResponder?.keyDown(with: event)
            updateSelectionUI()
            return true
        }
        return false
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL, let window = view.window else { return .zero }
        if isListMode {
            guard let row = fileList.row(for: url) else { return .zero }
            let outline = fileList.outlineView
            let cell = outline.frameOfCell(atColumn: 0, row: row)
            let iconRect = NSRect(x: cell.minX + 2, y: cell.midY - 8, width: 16, height: 16)
            return window.convertToScreen(outline.convert(iconRect, to: nil))
        }
        for path in browser.selectionIndexPaths {
            guard let node = browser.item(at: path) as? FileNode, node.url == url, let row = path.last else { continue }
            let rowRect = browser.frame(ofRow: row, inColumn: path.count - 1)
            let iconRect = NSRect(x: rowRect.minX + 4, y: rowRect.midY - 8, width: 16, height: 16)
            return window.convertToScreen(browser.convert(iconRect, to: nil))
        }
        return .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item.previewItemURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - List view

extension BrowserViewController: FileListHost {
    func fileList(open nodes: [FileNode]) {
        if !nodes.isEmpty { open(nodes) }
    }

    func fileList(navigateInto folder: FileNode, inNewTab: Bool) {
        if inNewTab {
            newTab(at: folder.url)
        } else {
            showList(folder.url)
        }
    }

    func fileListSelectionDidChange() {
        updateSelectionUI()
    }

    func fileListSortDidChange(to sort: FileSort) {
        applySort(sort)
    }

    func fileList(validateDrop info: NSDraggingInfo, into folder: URL) -> NSDragOperation {
        let sources = draggedURLs(info)
        guard !sources.isEmpty, !sources.contains(where: { FileOperations.url(folder, isInside: $0) }) else { return [] }
        return dragOperation(for: info, sources: sources, into: folder)
    }

    func fileList(acceptDrop info: NSDraggingInfo, into folder: URL) -> Bool {
        let sources = draggedURLs(info)
        let operation = dragOperation(for: info, sources: sources, into: folder)
        guard !operation.isEmpty else { return false }
        transfer(sources, into: folder, move: operation != .copy)
        return true
    }
}

// MARK: - Back / forward

/// One tab's navigation history. An entry is recorded whenever the folder you're looking into
/// changes, and holds the full view state, so going back also restores the selection.
private struct NavigationHistory {
    static let limit = 100

    var back: [BrowserTab] = []
    var forward: [BrowserTab] = []
    /// The latest state at the current position; pushed onto `back` when the folder changes.
    var current: BrowserTab?
}

extension BrowserViewController {
    fileprivate func configureNavigation() {
        navigationControl.segmentCount = 2
        navigationControl.trackingMode = .momentary
        for (segment, symbol, tip) in [(0, "chevron.left", "Back (⌘[)"), (1, "chevron.right", "Forward (⌘])")] {
            navigationControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: segment)
            navigationControl.setToolTip(tip, forSegment: segment)
            navigationControl.setWidth(28, forSegment: segment)
        }
        navigationControl.target = self
        navigationControl.action = #selector(navigationClicked(_:))
        navigationControl.setContentHuggingPriority(.required, for: .horizontal)

        // Mouse back/forward buttons (buttons 4 and 5) and trackpad / Magic Mouse page swipes,
        // for the pane under the mouse. Clicks also start and end inline renaming.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseUp, .swipe]) { [weak self] event in
            guard let self else { return event }
            self.handleMouseForRename(event)
            guard event.type == .otherMouseUp || event.type == .swipe,
                  event.window === self.view.window, !self.view.isHiddenOrHasHiddenAncestor,
                  self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil))
            else { return event }
            switch event.type {
            case .otherMouseUp where event.buttonNumber == 3:
                self.goBack()
            case .otherMouseUp where event.buttonNumber == 4:
                self.goForward()
            case .swipe where event.deltaX > 0:
                self.goBack()
            case .swipe where event.deltaX < 0:
                self.goForward()
            default:
                return event
            }
            return nil
        }
    }

    @objc fileprivate func navigationClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? goBack() : goForward()
    }

    func goBack() {
        guard histories.indices.contains(activeTab), let previous = histories[activeTab].back.popLast() else {
            NSSound.beep()
            return
        }
        histories[activeTab].forward.append(currentTabState)
        restoreHistory(previous)
    }

    func goForward() {
        guard histories.indices.contains(activeTab), let next = histories[activeTab].forward.popLast() else {
            NSSound.beep()
            return
        }
        histories[activeTab].back.append(currentTabState)
        restoreHistory(next)
    }

    private func restoreHistory(_ state: BrowserTab) {
        isRestoringHistory = true
        load(state)
        isRestoringHistory = false
        histories[activeTab].current = currentTabState
        updateNavigationControl()
        view.window?.makeFirstResponder(primaryView)
    }

    /// Called after every navigation or selection change.
    fileprivate func recordHistory() {
        guard !isRestoringHistory, histories.indices.contains(activeTab) else { return }
        let state = currentTabState
        var history = histories[activeTab]
        if let current = history.current, !current.currentFolder.isSameFile(as: state.currentFolder) {
            history.back.append(current)
            if history.back.count > NavigationHistory.limit { history.back.removeFirst() }
            history.forward.removeAll()
        }
        history.current = state
        histories[activeTab] = history
        updateNavigationControl()
    }

    private func updateNavigationControl() {
        guard histories.indices.contains(activeTab) else { return }
        navigationControl.setEnabled(!histories[activeTab].back.isEmpty, forSegment: 0)
        navigationControl.setEnabled(!histories[activeTab].forward.isEmpty, forSegment: 1)
    }
}
