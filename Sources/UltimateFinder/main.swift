import AppKit

// Only one visor per user session: a second copy would fight over the hotkey.
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Mirrors LSUIElement so `swift run` (no bundle, no Info.plist) behaves the same as the .app.
app.setActivationPolicy(.accessory)
app.run()
