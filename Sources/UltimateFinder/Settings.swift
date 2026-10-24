import AppKit
import Carbon.HIToolbox

struct HotKeyPreset: Equatable {
    let id: String
    let title: String
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    static let presets: [HotKeyPreset] = [
        HotKeyPreset(id: "option-space", title: "⌥ Space", keyCode: UInt32(kVK_Space), modifiers: [.option]),
        HotKeyPreset(id: "option-grave", title: "⌥ `", keyCode: UInt32(kVK_ANSI_Grave), modifiers: [.option]),
        HotKeyPreset(id: "control-option-space", title: "⌃⌥ Space", keyCode: UInt32(kVK_Space), modifiers: [.control, .option]),
    ]

    static let standard = presets[0]

    static func preset(id: String?) -> HotKeyPreset {
        presets.first { $0.id == id } ?? standard
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    /// The character used to display this shortcut next to a menu item.
    var menuKeyEquivalent: String { keyCode == UInt32(kVK_Space) ? " " : "`" }

    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode && event.modifierFlags.userModifiers == modifiers
    }
}

extension NSEvent.ModifierFlags {
    /// The modifiers a user deliberately holds; drops caps lock, fn and the numeric-pad flag.
    var userModifiers: NSEvent.ModifierFlags {
        intersection([.command, .option, .control, .shift])
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Fraction of the screen height the visor covers.
    static let heightFraction: CGFloat = 0.6

    static var hotKey: HotKeyPreset {
        get { .preset(id: defaults.string(forKey: "hotKey")) }
        set { defaults.set(newValue.id, forKey: "hotKey") }
    }

    static var hideOnFocusLoss: Bool {
        get { defaults.bool(forKey: "hideOnFocusLoss") }
        set { defaults.set(newValue, forKey: "hideOnFocusLoss") }
    }

    static var showHiddenFiles: Bool {
        get { defaults.bool(forKey: "showHiddenFiles") }
        set { defaults.set(newValue, forKey: "showHiddenFiles") }
    }

    static var sortOrder: FileSort {
        get { defaults.data(forKey: "sortOrder").flatMap { try? JSONDecoder().decode(FileSort.self, from: $0) } ?? FileSort() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "sortOrder") }
    }

    static var foldersOnTop: Bool {
        get { defaults.bool(forKey: "foldersOnTop") }
        set { defaults.set(newValue, forKey: "foldersOnTop") }
    }

    enum ViewMode: String {
        case columns, list
    }

    /// The two browsers of split view. The left one is also the only pane outside split view,
    /// and keeps the unprefixed keys it had before split view existed.
    enum Pane {
        case left, right

        fileprivate func key(_ name: String) -> String {
            self == .left ? name : "right" + name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    static var isSplitView: Bool {
        get { defaults.bool(forKey: "splitView") }
        set { defaults.set(newValue, forKey: "splitView") }
    }

    static func viewMode(of pane: Pane) -> ViewMode {
        defaults.string(forKey: pane.key("viewMode")).flatMap(ViewMode.init) ?? .columns
    }

    static func setViewMode(_ mode: ViewMode, of pane: Pane) {
        defaults.set(mode.rawValue, forKey: pane.key("viewMode"))
    }

    /// A pane's open tabs and which one is active. Falls back to one tab at the pre-tabs root (or home).
    static func tabs(of pane: Pane) -> (tabs: [BrowserTab], active: Int) {
        if let data = defaults.data(forKey: pane.key("tabs")),
           let saved = try? JSONDecoder().decode([BrowserTab].self, from: data) {
            let existing = saved.filter { FileManager.default.fileExists(atPath: $0.root.path) }
            if !existing.isEmpty {
                return (existing, min(max(defaults.integer(forKey: pane.key("activeTab")), 0), existing.count - 1))
            }
        }
        var root = FileManager.default.homeDirectoryForCurrentUser
        if pane == .left, let path = defaults.string(forKey: "rootPath"), FileManager.default.fileExists(atPath: path) {
            root = URL(fileURLWithPath: path, isDirectory: true)
        }
        return ([BrowserTab(root: root, selection: [])], 0)
    }

    static func setTabs(_ tabs: [BrowserTab], active: Int, of pane: Pane) {
        defaults.set(try? JSONEncoder().encode(tabs), forKey: pane.key("tabs"))
        defaults.set(active, forKey: pane.key("activeTab"))
    }
}

/// One browser tab: the root folder shown in the first column and the selected items, plus the
/// folder and selection shown in list view (nil until the tab has been viewed as a list).
struct BrowserTab: Codable {
    var root: URL
    var selection: [URL]
    var listFolder: URL?
    var listSelection: [URL]?

    /// Finder titles a tab after the folder you're looking into.
    var title: String {
        FileManager.default.displayName(atPath: currentFolder.path)
    }

    /// The folder you're looking into: the list folder, else the selected folder in the columns
    /// (or the folder holding the selected file).
    var currentFolder: URL {
        if let listFolder { return listFolder }
        var folder = root
        if let last = selection.last {
            let isFolder = (try? last.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                .map { $0.isDirectory == true && $0.isPackage != true } ?? false
            folder = isFolder && selection.count == 1 ? last : last.deletingLastPathComponent()
        }
        return folder
    }
}

extension NSApplication {
    func activateCompat() {
        if #available(macOS 14, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

extension NSAlert {
    /// Runs the alert modally above the visor, which otherwise sits over normal modal panels.
    @discardableResult
    func runAboveVisor() -> NSApplication.ModalResponse {
        NSApp.activateCompat()
        layout()
        window.level = .statusBar
        return runModal()
    }

    static func show(_ error: Error) {
        NSAlert(error: error).runAboveVisor()
    }
}
