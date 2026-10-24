import AppKit
import Carbon.HIToolbox

/// Registers the visor shortcut system-wide.
///
/// Carbon's `RegisterEventHotKey` is tried first: it needs no permission and swallows the
/// keystroke so the frontmost app never sees it. If another app already owns the combination,
/// we fall back to `NSEvent` monitors, which macOS only allows for apps trusted for Accessibility.
final class GlobalHotKey {
    enum Mode: Equatable {
        case carbon
        case eventMonitor
        case needsAccessibility
    }

    private static let signature: OSType = 0x5546_5644 // 'UFVD'

    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature, let userData else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(_ preset: HotKeyPreset) -> Mode {
        unregister()

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            preset.keyCode,
            preset.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        )
        if status == noErr { return .carbon }
        hotKeyRef = nil

        guard AXIsProcessTrusted() else { return .needsAccessibility }

        // Global monitors only see events headed to other apps, so pair one with a local monitor.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if preset.matches(event), !event.isARepeat { self?.action() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard preset.matches(event) else { return event }
            if !event.isARepeat { self?.action() }
            return nil
        }
        return .eventMonitor
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Adds the app to the Accessibility list (unchecked) and shows the system prompt.
    static func requestSystemPrompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    enum Choice { case openSettings, chooseAnother, later }

    static func explain(shortcut: String) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "UltimateFinder needs Accessibility access for \(shortcut)"
        alert.informativeText = """
            Another app has already claimed \(shortcut), so UltimateFinder can't reserve it the usual way. \
            To still notice the shortcut, macOS requires you to allow UltimateFinder under \
            System Settings › Privacy & Security › Accessibility.

            UltimateFinder only uses this to watch for its own shortcut. It never reads, stores or \
            sends anything else you type.

            Alternatively, pick a different shortcut, which needs no permission at all.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Choose Another Shortcut")
        alert.addButton(withTitle: "Not Now")

        switch alert.runAboveVisor() {
        case .alertFirstButtonReturn: return .openSettings
        case .alertSecondButtonReturn: return .chooseAnother
        default: return .later
        }
    }
}
