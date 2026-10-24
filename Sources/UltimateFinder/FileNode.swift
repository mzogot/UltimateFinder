import AppKit
import QuickLookThumbnailing

/// One file or folder shown in the column or list view.
///
/// NSBrowser's item-based API tracks items by identity (and sends them NSObject messages such as
/// -isEqualTo:), so nodes are NSObjects and a folder's
/// children are cached until refreshed. Refreshing reuses nodes that still exist, which keeps
/// the deeper columns (and their caches) valid.
final class FileNode: NSObject {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .localizedNameKey,
        .contentModificationDateKey, .fileSizeKey, .labelNumberKey,
    ]

    /// Order used for every listing; changing it re-sorts the cached trees (see `resortTree`).
    static var sortOrder = Settings.sortOrder
    /// Lists folders before files whatever the sort order, like Finder's "Keep folders on top".
    static var foldersOnTop = Settings.foldersOnTop

    let url: URL
    let name: String
    /// True for folders the browser can descend into; packages such as .app bundles are leaves.
    let isDirectory: Bool
    let isHidden: Bool
    private(set) var modificationDate: Date?
    /// Logical size in bytes; nil for folders and packages (Finder shows "--").
    private(set) var size: Int?
    /// Finder's color label (1–7, see `NSWorkspace.fileLabelColors`); 0 for none.
    private(set) var labelNumber: Int

    private var cachedChildren: [FileNode]?
    private var cachedIcon: NSImage?
    private var cachedDisplayTitle: NSAttributedString?
    private var didRequestThumbnail = false

    /// Posted with the node as object when its icon preview has loaded and replaced the type icon.
    static let iconDidChange = Notification.Name("FileNodeIconDidChange")

    lazy var canonicalPath: String = FileNode.canonicalPath(of: url)

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        name = values?.localizedName ?? url.lastPathComponent
        isHidden = values?.isHidden ?? false

        var directory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        if values?.isSymbolicLink == true {
            // realpath, not resolvingSymlinksInPath(): the latter maps /private/tmp back to /tmp,
            // which is the symlink itself.
            let resolved = URL(fileURLWithPath: Self.canonicalPath(of: url))
            let target = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            directory = (target?.isDirectory ?? false) && !(target?.isPackage ?? false)
        }
        isDirectory = directory
        modificationDate = values?.contentModificationDate
        size = values?.isDirectory == true ? nil : values?.fileSize
        labelNumber = values?.labelNumber ?? 0
        super.init()
    }

    /// Picks up a new modification date, size or color label from a freshly listed URL.
    /// Returns true if any of them changed.
    fileprivate func updateAttributes(from fresh: URL) -> Bool {
        let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .labelNumberKey])
        let newSize = values?.isDirectory == true ? nil : values?.fileSize
        let changed = values?.contentModificationDate != modificationDate || newSize != size
        let newLabel = values?.labelNumber ?? 0
        let labelChanged = newLabel != labelNumber
        modificationDate = values?.contentModificationDate
        size = newSize
        labelNumber = newLabel
        if changed {
            cachedKind = nil
            // The contents changed, so the icon preview may have too.
            cachedIcon = nil
            cachedDisplayTitle = nil
            didRequestThumbnail = false
        }
        return changed || labelChanged
    }

    /// The row tint for the color label, or nil when the item has none.
    var labelColor: NSColor? {
        let colors = NSWorkspace.shared.fileLabelColors
        return labelNumber > 0 && labelNumber < colors.count ? colors[labelNumber] : nil
    }

    /// Re-reads the color label, which Finder can change without touching the folder (so no
    /// watcher event). Returns true if it changed.
    @discardableResult
    func reloadLabel() -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        let number = (try? fresh.resourceValues(forKeys: [.labelNumberKey]).labelNumber) ?? 0
        defer { labelNumber = number }
        return number != labelNumber
    }

    /// Gives the item a Finder color label (0 removes it). See `FileOperations.setLabel`.
    func setLabel(_ number: Int) throws {
        try FileOperations.setLabel(number, of: url)
        labelNumber = number
    }

    private var cachedKind: String?

    /// Finder's "Kind" column, e.g. "Folder" or "PDF document". Looked up lazily: it's comparatively slow.
    var kind: String {
        if let cachedKind { return cachedKind }
        let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? ""
        cachedKind = kind
        return kind
    }

    /// The row icon. Like Finder's "Show icon preview", files whose contents Quick Look can draw
    /// (images, PDFs, movies, documents…) get a thumbnail; it loads in the background, and the
    /// type icon stands in until `iconDidChange` is posted.
    var icon: NSImage {
        if let cachedIcon { return cachedIcon }
        // NSWorkspace may hand back a shared instance, so resize a copy.
        let image = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        cachedIcon = image
        loadThumbnail()
        return image
    }

    private func loadThumbnail() {
        guard !isDirectory, !didRequestThumbnail else { return }
        didRequestThumbnail = true
        let side: CGFloat = 16
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail
        )
        request.iconMode = true  // Finder's look: a white border, or a page with a folded corner
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let thumbnail = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.didRequestThumbnail else { return }
                // Thumbnails keep their aspect ratio; centre them in a square so rows stay aligned.
                self.cachedIcon = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
                    let size = thumbnail.size
                    let fit = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1), 1)
                    let drawn = NSSize(width: size.width * fit, height: size.height * fit)
                    thumbnail.draw(in: NSRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2,
                                              width: drawn.width, height: drawn.height))
                    return true
                }
                self.cachedDisplayTitle = nil
                NotificationCenter.default.post(name: Self.iconDidChange, object: self)
            }
        }
    }

    /// Icon plus name, as shown in a browser row. Hidden items are dimmed, as in Finder.
    var displayTitle: NSAttributedString {
        if let cachedDisplayTitle { return cachedDisplayTitle }
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let title = NSMutableAttributedString(attachment: attachment)
        var attributes: [NSAttributedString.Key: Any] = [:]
        if isHidden { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        title.append(NSAttributedString(string: "  " + name, attributes: attributes))
        cachedDisplayTitle = title
        return title
    }

    func children(showingHidden showHidden: Bool) -> [FileNode] {
        if let cachedChildren { return cachedChildren }
        let loaded = Self.load(url, showingHidden: showHidden, reusing: [:])
        cachedChildren = loaded
        return loaded
    }

    /// Re-reads an already-loaded folder. Returns true when its listing changed.
    @discardableResult
    func reloadChildren(showingHidden showHidden: Bool) -> Bool {
        guard let old = cachedChildren else { return false }
        let existing = Dictionary(old.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var attributesChanged = false
        let fresh = Self.load(url, showingHidden: showHidden, reusing: existing) { node, freshURL in
            if node.updateAttributes(from: freshURL) { attributesChanged = true }
        }
        cachedChildren = fresh
        return attributesChanged || fresh.map(\.url) != old.map(\.url)
    }

    /// Re-sorts every cached listing below this node with the current `sortOrder` (no disk access).
    func resortTree() {
        guard let children = cachedChildren else { return }
        cachedChildren = children.sorted(by: Self.areInListingOrder)
        children.forEach { $0.resortTree() }
    }

    /// Drops every cached listing below this node, e.g. after toggling hidden files.
    func invalidateTree() {
        cachedChildren?.forEach { $0.invalidateTree() }
        cachedChildren = nil
    }

    private static func load(
        _ directory: URL, showingHidden showHidden: Bool, reusing existing: [URL: FileNode],
        reused: (FileNode, URL) -> Void = { _, _ in }
    ) -> [FileNode] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: resourceKeys, options: options
        ) else { return [] }

        return urls
            .map { url in
                guard let node = existing[url] else { return FileNode(url: url) }
                reused(node, url)
                return node
            }
            .sorted(by: areInListingOrder)
    }

    private static func areInListingOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        if foldersOnTop, a.isDirectory != b.isDirectory { return a.isDirectory }
        return sortOrder.areInIncreasingOrder(a, b)
    }

    /// The fully resolved path, matching what FSEvents reports (e.g. /tmp → /private/tmp).
    static func canonicalPath(of url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// How listings are ordered; shared by the column and list views, like Finder's "Sort By".
struct FileSort: Codable, Equatable {
    enum Key: String, Codable, CaseIterable {
        case name, dateModified, size, kind

        var title: String {
            switch self {
            case .name: return "Name"
            case .dateModified: return "Date Modified"
            case .size: return "Size"
            case .kind: return "Kind"
            }
        }

        /// Direction a first click picks, as in Finder: newest and largest first.
        var defaultAscending: Bool { self == .name || self == .kind }
    }

    var key: Key = .name
    var ascending = true

    func areInIncreasingOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        var order: ComparisonResult
        switch key {
        case .name:
            order = a.name.localizedStandardCompare(b.name)
        case .dateModified:
            order = compare(a.modificationDate ?? .distantPast, b.modificationDate ?? .distantPast)
        case .size:
            order = compare(a.size ?? -1, b.size ?? -1)
        case .kind:
            order = a.kind.localizedStandardCompare(b.kind)
        }
        if order == .orderedSame { order = a.name.localizedStandardCompare(b.name) }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}
