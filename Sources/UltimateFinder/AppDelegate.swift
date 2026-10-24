import AppKit
import Quartz
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let visor = VisorController()
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.visor.toggle() }
    private var hotKeyMode: GlobalHotKey.Mode = .carbon
    private var trustPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpMainMenu()
        visor.prewarm()
        registerHotKey(explainIfBlocked: true)

        if CommandLine.arguments.contains("--show") {
            visor.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching the app again (e.g. from Spotlight) toggles the visor.
        visor.toggle()
        return false
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        visor.acceptsQuickLook
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        visor.beginQuickLook(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        visor.endQuickLook(panel)
    }

    // MARK: Hotkey

    private func registerHotKey(explainIfBlocked: Bool) {
        let preset = Settings.hotKey
        hotKeyMode = hotKey.register(preset)
        guard hotKeyMode == .needsAccessibility else {
            stopPollingTrust()
            return
        }
        startPollingTrust()
        guard explainIfBlocked else { return }

        switch AccessibilityPermission.explain(shortcut: preset.title) {
        case .openSettings:
            AccessibilityPermission.requestSystemPrompt()
            AccessibilityPermission.openSystemSettings()
        case .chooseAnother:
            statusItem.button?.performClick(nil)
        case .later:
            break
        }
    }

    /// Once the user ticks the checkbox in System Settings, start listening without a relaunch.
    private func startPollingTrust() {
        guard trustPollTimer == nil else { return }
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, AccessibilityPermission.isTrusted else { return }
            self.registerHotKey(explainIfBlocked: false)
        }
    }

    private func stopPollingTrust() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
    }

    // MARK: Main menu

    /// The menu bar never shows for a menu-bar agent, but text fields get ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z
    /// only from the main menu's key equivalents, so it still needs an Edit menu.
    private func setUpMainMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        mainMenu.addItem(NSMenuItem())  // the application menu's slot
        let editItem = NSMenuItem()
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "UltimateFinder")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let preset = Settings.hotKey

        let toggle = NSMenuItem(title: visor.isShown ? "Hide Visor" : "Show Visor", action: #selector(toggleVisor), keyEquivalent: preset.menuKeyEquivalent)
        toggle.keyEquivalentModifierMask = preset.modifiers
        toggle.target = self
        menu.addItem(toggle)

        if hotKeyMode == .needsAccessibility {
            let warning = NSMenuItem(title: "Shortcut Needs Accessibility Access…", action: #selector(explainAccessibility), keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warning)
        } else if hotKeyMode == .carbon, AccessibilityPermission.isTrusted {
            // The grant lets an app control others; say so once the shortcut no longer needs it.
            let unneeded = NSMenuItem(title: "Accessibility Access No Longer Needed…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            unneeded.target = self
            unneeded.toolTip = "The shortcut works without it now. You can turn UltimateFinder off under Privacy & Security › Accessibility."
            menu.addItem(unneeded)
        }
        menu.addItem(.separator())

        let shortcutMenu = NSMenu()
        for option in HotKeyPreset.presets {
            let item = NSMenuItem(title: option.title, action: #selector(selectHotKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            item.state = option == preset ? .on : .off
            shortcutMenu.addItem(item)
        }
        let shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        addToggle(to: menu, "Hide When Focus Is Lost", Settings.hideOnFocusLoss, #selector(toggleHideOnFocusLoss))
        addToggle(to: menu, "Show Hidden Files", Settings.showHiddenFiles, #selector(toggleHiddenFiles))
        addToggle(to: menu, "Split View", Settings.isSplitView, #selector(toggleSplitView))
        if Bundle.main.bundleURL.pathExtension == "app" {
            addToggle(to: menu, "Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin))
        }

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About UltimateFinder", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit UltimateFinder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addToggle(to menu: NSMenu, _ title: String, _ isOn: Bool, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        menu.addItem(item)
    }

    @objc private func toggleVisor() {
        visor.toggle()
    }

    @objc private func explainAccessibility() {
        registerHotKey(explainIfBlocked: true)
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSystemSettings()
    }

    @objc private func selectHotKey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.hotKey = .preset(id: id)
        registerHotKey(explainIfBlocked: true)
    }

    @objc private func toggleHideOnFocusLoss() {
        Settings.hideOnFocusLoss.toggle()
    }

    @objc private func toggleHiddenFiles() {
        visor.contentController.showsHiddenFiles.toggle()
    }

    @objc private func toggleSplitView() {
        visor.contentController.isSplit.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert.show(error)
        }
    }

    @objc private func showAbout() {
        NSApp.activateCompat()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
