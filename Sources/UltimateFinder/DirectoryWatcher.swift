import Foundation

/// Watches the folders shown in the browser columns: one non-recursive kqueue source per folder.
///
/// Watching only what's on screen (instead of a recursive FSEvents stream on the root) means
/// macOS asks for access to protected folders such as Desktop or Documents only when the user
/// actually opens them.
final class DirectoryWatcher {
    /// Called on the main queue with the canonical paths of folders whose entries changed.
    private let onChange: (Set<String>) -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: Set<String> = []
    private var flushScheduled = false

    init(onChange: @escaping (Set<String>) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// Makes the watched set exactly `paths`, opening and closing sources only for the difference.
    func watch(_ paths: Set<String>) {
        for (path, source) in sources where !paths.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        for path in paths where sources[path] == nil {
            // O_EVTONLY doesn't keep the volume busy, so drives can still be ejected.
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main
            )
            source.setEventHandler { [weak self] in self?.folderChanged(path) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
    }

    func stop() {
        watch([])
    }

    /// Coalesces bursts (e.g. a multi-file copy) into one refresh.
    private func folderChanged(_ path: String) {
        pending.insert(path)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let changed = self.pending
            self.pending = []
            self.onChange(changed)
        }
    }
}
