import AppKit
import QuickLookThumbnailing

/// The trailing preview column NSBrowser shows when a file (leaf) is selected.
final class PreviewViewController: NSViewController {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let infoGrid = NSGridView()
    private var thumbnailRequest: QLThumbnailGenerator.Request?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    override var representedObject: Any? {
        didSet {
            guard (representedObject as? FileNode)?.url != (oldValue as? FileNode)?.url else { return }
            update()
        }
    }

    override func loadView() {
        // NSBrowser hosts this in the preview column's scroll view and keeps the view's own height.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 440))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 3
        infoGrid.rowSpacing = 4
        infoGrid.columnSpacing = 8

        let stack = NSStackView(views: [imageView, nameLabel, infoGrid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
            imageView.heightAnchor.constraint(equalToConstant: 160),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        update()
    }

    private func update() {
        guard isViewLoaded, let node = representedObject as? FileNode else { return }
        let url = node.url

        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
        icon.size = NSSize(width: 256, height: 256)
        imageView.image = icon
        nameLabel.stringValue = node.name
        fillInfo(for: url)
        loadThumbnail(for: url)
    }

    private func fillInfo(for url: URL) {
        // removeRow(at:) leaves the row's labels in the view hierarchy, so remove them explicitly.
        while infoGrid.numberOfRows > 0 { infoGrid.removeRow(at: 0) }
        infoGrid.subviews.forEach { $0.removeFromSuperview() }
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .isPackageKey, .creationDateKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }

        var rows: [(String, String)] = []
        if let kind = values.localizedTypeDescription { rows.append(("Kind", kind)) }
        if values.isPackage != true, let size = values.fileSize {
            rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let created = values.creationDate { rows.append(("Created", Self.dateFormatter.string(from: created))) }
        if let modified = values.contentModificationDate { rows.append(("Modified", Self.dateFormatter.string(from: modified))) }

        for (title, value) in rows {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.alignment = .right
            let valueLabel = NSTextField(labelWithString: value)
            valueLabel.lineBreakMode = .byTruncatingMiddle
            for label in [titleLabel, valueLabel] { label.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
            infoGrid.addRow(with: [titleLabel, valueLabel])
        }
    }

    private func loadThumbnail(for url: URL) {
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 256, height: 256), scale: scale, representationTypes: .thumbnail
        )
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, (self.representedObject as? FileNode)?.url == url else { return }
                self.imageView.image = image
            }
        }
    }
}
