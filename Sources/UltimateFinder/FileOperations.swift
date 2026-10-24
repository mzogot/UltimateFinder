import AppKit

/// Finder-style copy/move helpers. Work runs off the main thread; completions return to it.
enum FileOperations {
    static func isOnSameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: key).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: key).volumeIdentifier as? NSObject
        else { return false }
        return va.isEqual(vb)
    }

    /// True if `url` is `folder` itself or somewhere inside it.
    static func url(_ url: URL, isInside folder: URL) -> Bool {
        let path = FileNode.canonicalPath(of: url)
        let folderPath = FileNode.canonicalPath(of: folder)
        return path == folderPath || path.hasPrefix(folderPath + "/")
    }

    /// "Report.pdf" → "Report copy.pdf" when duplicating in place, otherwise "Report 2.pdf".
    static func availableDestination(for source: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        let candidate = folder.appendingPathComponent(source.lastPathComponent)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        let duplicating = source.deletingLastPathComponent().isSameFile(as: folder)
        for n in 1... {
            let suffix = duplicating ? (n == 1 ? " copy" : " copy \(n)") : " \(n + 1)"
            let name = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
            let url = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
        }
        return candidate
    }

    /// Copies or moves `sources` into `folder`, never overwriting existing items.
    static func transfer(_ sources: [URL], into folder: URL, move: Bool, completion: @escaping ([URL], Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var results: [URL] = []
            var failure: Error?
            for source in sources {
                // Moving something to the folder it is already in is a no-op.
                if move, source.deletingLastPathComponent().isSameFile(as: folder) { continue }
                let destination = availableDestination(for: source, in: folder)
                do {
                    if move {
                        try moveExclusively(source, to: destination)
                    } else {
                        try fm.copyItem(at: source, to: destination)
                    }
                    results.append(destination)
                } catch {
                    failure = error
                    break
                }
            }
            DispatchQueue.main.async { completion(results, failure) }
        }
    }

    /// Moves or renames without ever replacing an item that appeared at `destination` after its
    /// name was chosen: rename(2) alone would. FileManager handles the rest (other volumes,
    /// file systems without RENAME_EXCL) and words the error when the name is taken.
    static func moveExclusively(_ source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// Converted copies keep the original's download provenance, as Finder's copies do.
    static func copyQuarantine(from source: URL, to destination: URL) {
        let attribute = "com.apple.quarantine"
        let size = getxattr(source.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(source.path, attribute, &value, size, 0, XATTR_NOFOLLOW) == size else { return }
        setxattr(destination.path, attribute, value, size, 0, XATTR_NOFOLLOW)
    }

    /// "untitled folder" → "untitled folder 2", "Photo.png" → "Photo 2.png": the first name not taken in `folder`.
    static func unusedURL(named name: String, in folder: URL) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static func createFolder(in folder: URL) throws -> URL {
        let url = unusedURL(named: "untitled folder", in: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A blank rich-text document, which opens in TextEdit by default.
    static func createTextFile(in folder: URL) throws -> URL {
        let url = unusedURL(named: "untitled.rtf", in: folder)
        let empty = NSAttributedString()
        let data = try empty.data(from: NSRange(location: 0, length: 0), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    // MARK: Color labels

    /// Gives `url` Finder's color label `number` (1–7; 0 removes it), keeping its other tags.
    ///
    /// Finder stores colors as tags named in the user's language ("Rot", "Blau"…), names AppKit
    /// can't provide. So any color tag is stripped first, and when no other tags remain the color
    /// is written as a legacy label, which Finder shows as its own, localized tag.
    static func setLabel(_ number: Int, of url: URL) throws {
        var url = url
        let tags = userTags(of: url)
        let colorNames = colorTagNames
        let others = tags.filter { $0.color == 0 || !colorNames.contains($0.name) }.map(\.name)
        defer { url.removeAllCachedResourceValues() }

        // URLResourceValues.tagNames is only settable from macOS 26; NSURL's setter is older.
        let file = url as NSURL
        var values = URLResourceValues()
        if others.isEmpty {
            if !tags.isEmpty { try file.setResourceValue([String](), forKey: .tagNamesKey) }
            values.labelNumber = number
            try url.setResourceValues(values)
        } else {
            // A legacy label would hide behind the other tags, so add the color as a tag.
            values.labelNumber = 0
            try url.setResourceValues(values)
            let names = others + (number > 0 ? [NSWorkspace.shared.fileLabels[number]] : [])
            try file.setResourceValue(names, forKey: .tagNamesKey)
        }
    }

    /// The names Finder's standard color tags may carry: AppKit's (English) label names plus
    /// Finder's favorite tags, which start out as the colors in the user's language.
    private static var colorTagNames: Set<String> {
        let finderFavorites = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames") ?? []
        return Set(NSWorkspace.shared.fileLabels.dropFirst() + finderFavorites.filter { !$0.isEmpty })
    }

    /// The item's tags with their colors, read from the raw "Name\n6" entries Finder writes.
    /// A symlink's own tags, not its target's: those are the ones `setLabel` writes.
    private static func userTags(of url: URL) -> [(name: String, color: Int)] {
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size,
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return entries.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts.first ?? ""), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }
}

extension NSPasteboard {
    /// The file URLs on the pasteboard or in a drag, normalised. Any app can put URLs there, and
    /// "folder/.." would otherwise be copied as a folder named ".. 2".
    var existingFileURLs: [URL] {
        let urls = readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.compactMap { url in
            let clean = url.standardizedFileURL
            guard clean.path != "/", ![".", ".."].contains(clean.lastPathComponent),
                  (try? clean.checkResourceIsReachable()) == true
            else { return nil }
            return clean
        }
    }
}

extension URL {
    /// Path equality; `==` on URLs is fooled by the trailing slash directory listings add.
    func isSameFile(as other: URL) -> Bool {
        standardizedFileURL.path == other.standardizedFileURL.path
    }
}
