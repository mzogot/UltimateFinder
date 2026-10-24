import AppKit

/// The user's sidebar favorites, persisted as plain paths.
///
/// Paths (rather than bookmarks) mean nothing inside protected folders such as Documents is
/// touched until the user actually opens a favorite, so the sidebar never triggers privacy prompts.
enum Favorites {
    private static let key = "favoritePaths"
    /// Posted when the list changes, so both panes' sidebars stay in step.
    static let didChange = Notification.Name("FavoritesDidChange")

    static var urls: [URL] {
        get {
            guard let paths = UserDefaults.standard.stringArray(forKey: key) else { return defaultURLs }
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set {
            var seen = Set<String>()
            let paths = newValue.map(\.standardizedFileURL.path).filter { seen.insert($0).inserted }
            UserDefaults.standard.set(paths, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var defaultURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home,
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Documents"),
        ]
    }

    static func contains(_ url: URL) -> Bool {
        urls.contains { $0.isSameFile(as: url) }
    }

    static func add(_ new: [URL], at index: Int? = nil) {
        var list = urls
        let additions = new.filter { url in !list.contains { $0.isSameFile(as: url) } }
        list.insert(contentsOf: additions, at: min(index ?? list.count, list.count))
        urls = list
    }

    static func remove(at index: Int) {
        var list = urls
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        urls = list
    }

    static func move(from source: Int, to destination: Int) {
        var list = urls
        guard list.indices.contains(source) else { return }
        let item = list.remove(at: source)
        // `destination` is an insertion point in the list as it was before removing the item.
        list.insert(item, at: min(destination > source ? destination - 1 : destination, list.count))
        urls = list
    }

    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Finder import

    enum ImportError: Error {
        case needsFullDiskAccess
        case notFound
    }

    /// Finder's list file, newest format first (macOS 27 uses .sfl4).
    private static let listFileNames = ["sfl4", "sfl3", "sfl2"].map { "com.apple.LSSharedFileList.FavoriteItems.\($0)" }

    /// Reads the folders in Finder's own sidebar Favorites, in Finder's order.
    ///
    /// Finder keeps them in a keyed archive under ~/Library/Application Support, which macOS only
    /// lets apps with Full Disk Access read. Without that, macOS's own `sfltool archive` can still
    /// export a copy. Rather than depend on the archive's private classes, this pulls out every
    /// embedded bookmark (they start with the bytes "book") and resolves it.
    static func finderFavorites() throws -> [URL] {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        var deniedAccess = false
        let data = readListFile(in: folder, deniedAccess: &deniedAccess) ?? readListFileViaSFLTool()
        guard let data else { throw deniedAccess ? ImportError.needsFullDiskAccess : ImportError.notFound }
        return try parseFavorites(data)
    }

    private static func readListFile(in folder: URL, deniedAccess: inout Bool) -> Data? {
        for name in listFileNames {
            do {
                return try Data(contentsOf: folder.appendingPathComponent(name))
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                deniedAccess = true
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
                deniedAccess = true
            } catch {
                continue
            }
        }
        return nil
    }

    /// `sfltool archive <dir>` copies all shared file lists (recent documents included) into `dir`,
    /// so it goes into a private temporary folder that is deleted right after reading.
    private static func readListFileViaSFLTool() -> Data? {
        let fm = FileManager.default
        let tool = URL(fileURLWithPath: "/usr/bin/sfltool")
        guard fm.isExecutableFile(atPath: tool.path) else { return nil }
        let temp = fm.temporaryDirectory.appendingPathComponent("UltimateFinder-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let process = Process()
            process.executableURL = tool
            process.arguments = ["archive", temp.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // This runs on the main thread, so a hung sfltool must not freeze the visor.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
        } catch {
            return nil
        }
        var ignored = false
        return readListFile(in: temp.appendingPathComponent("Application Support/com.apple.sharedfilelist"), deniedAccess: &ignored)
    }

    private static func parseFavorites(_ data: Data) throws -> [URL] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any]
        else { throw ImportError.notFound }

        let magic = Data("book".utf8)
        var result: [URL] = []
        for case let bookmark as Data in objects where bookmark.prefix(4) == magic {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.isFileURL,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !result.contains(where: { $0.isSameFile(as: url) })
            else { continue }
            result.append(url)
        }
        return result
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
