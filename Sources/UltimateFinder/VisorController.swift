import AppKit
import Carbon.HIToolbox
import Quartz

/// Owns the visor panel: placement on the active screen, the slide animation and focus handling.
final class VisorController: NSObject {
    private let panel = VisorPanel()
    let contentController = DualPaneController()

    private(set) var isShown = false
    private var currentScreen: NSScreen?
    private var animationGeneration = 0
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?

    private let showDuration: TimeInterval = 0.2
    private let hideDuration: TimeInterval = 0.16

    override init() {
        super.init()

        let background = VisorBackgroundView(cornerRadius: 12)
        panel.contentView = background
        let content = contentController.view
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel.quickLookController = self
        panel.onCancel = { [weak self] in self?.hide() }
        contentController.onOpenedItems = { [weak self] in self?.hide() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Not `self?.handleKeyDown(event) ?? event`: a nil ("consumed") result would turn back into the event.
            guard let self else { return event }
            return self.handleKeyDown(event)
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(panelResignedKey),
                           name: NSWindow.didResignKeyNotification, object: panel)
        center.addObserver(self, selector: #selector(appBecameActive),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// Lays the panel out off-screen at launch so the first toggle is as fast as later ones.
    func prewarm() {
        let screen = Self.screenWithMouse()
        panel.setFrame(hiddenFrame(on: screen), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        contentController.prepare()
    }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        let screen = Self.screenWithMouse()
        let target = shownFrame(on: screen)

        // Start from above the top edge unless we're reversing a hide on the same screen.
        if !panel.isVisible || currentScreen != screen {
            panel.setFrame(hiddenFrame(on: screen), display: false)
        }
        currentScreen = screen

        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        isShown = true
        animationGeneration += 1
        // Activation makes the panel the main window too, which Quick Look and sheets rely on.
        // The panel is non-activating, so it takes keys right away even if activation lags or
        // is declined; didBecomeActive re-asserts focus once activation lands.
        NSApp.activateCompat()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        contentController.visorWillShow()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = showDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    @objc private func appBecameActive() {
        // On activation AppKit restores the previously key window (possibly none); keep the visor key.
        guard isShown, NSApp.keyWindow == nil || NSApp.keyWindow === panel else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        animationGeneration += 1
        let generation = animationGeneration

        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        contentController.visorDidHide()

        let screen = currentScreen ?? Self.screenWithMouse()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame(on: screen), display: true)
        }, completionHandler: { [weak self] in
            guard let self, generation == self.animationGeneration else { return }
            self.panel.orderOut(nil)
        })

        // Hand focus back to whatever the user was doing before the visor appeared.
        if NSApp.isActive {
            if let previousApp, !previousApp.isTerminated {
                previousApp.activate()
            } else {
                NSApp.hide(nil)
            }
        }
    }

    // MARK: Geometry

    private func shownFrame(on screen: NSScreen) -> NSRect {
        let height = (screen.frame.height * Settings.heightFraction).rounded()
        let top = screen.visibleFrame.maxY // directly below the menu bar
        return NSRect(x: screen.frame.minX, y: top - height, width: screen.frame.width, height: height)
    }

    private func hiddenFrame(on screen: NSScreen) -> NSRect {
        var frame = shownFrame(on: screen)
        frame.origin.y = screen.frame.maxY
        return frame
    }

    static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    @objc private func screensChanged() {
        guard isShown else { return }
        let screen = currentScreen.flatMap { s in NSScreen.screens.first { $0 == s } } ?? Self.screenWithMouse()
        currentScreen = screen
        panel.setFrame(shownFrame(on: screen), display: true)
    }

    // MARK: Quick Look

    /// Quick Look closes itself if no responder accepts control, so both the visor panel and the
    /// app delegate (always in the chain, even once the preview panel is key) defer to this.
    var acceptsQuickLook: Bool { isShown }

    // MARK: Focus & keys

    @objc private func panelResignedKey() {
        guard Settings.hideOnFocusLoss, isShown else { return }
        // Wait a tick: Quick Look, menus and alerts of our own take key status legitimately.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown, NSApp.keyWindow == nil else { return }
            self.hide()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, isShown, !(panel.firstResponder is NSText) else { return event }

        if Int(event.keyCode) == kVK_Escape, event.modifierFlags.userModifiers.isEmpty {
            hide()
            return nil
        }
        if contentController.handleKeyDown(event) { return nil }
        // ⌘W closes the current tab (handled above); with only one tab left it hides the visor.
        if Int(event.keyCode) == kVK_ANSI_W, event.modifierFlags.userModifiers == .command {
            hide()
            return nil
        }
        return event
    }
}

extension VisorController: QuickLookControlling {
    func beginQuickLook(_ quickLook: QLPreviewPanel) {
        // Sit above the visor, and follow it onto whichever Space/display it is showing on.
        quickLook.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        quickLook.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        // Stay up even if macOS hands activation back to another app (cooperative activation).
        quickLook.hidesOnDeactivate = false
        contentController.beginQuickLook(quickLook)
    }

    func endQuickLook(_ quickLook: QLPreviewPanel) {
        contentController.endQuickLook(quickLook)
    }
}
