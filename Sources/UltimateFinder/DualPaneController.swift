import AppKit
import Carbon.HIToolbox
import Quartz

/// The visor's contents: one browser pane, or two side by side in split view (⌘U, like
/// TotalFinder's Dual Mode) for dragging files between folders. Each pane keeps its own tabs,
/// history and view mode; sort order, hidden files and favorites are shared.
final class DualPaneController: NSViewController {
    private let panes = [BrowserViewController(pane: .left), BrowserViewController(pane: .right)]
    private let splitView = NSSplitView()
    private var isVisorShown = false
    private var hasShownOnce = false
    private var needsDividerPlacement = true
    /// The left pane's share of the width: half when split view opens, then wherever the divider
    /// is dragged. Kept when the visor moves to a display of another width.
    private var leftFraction: CGFloat = 0.5
    private var laidOutWidth: CGFloat = 0
    /// The pane Quick Look is previewing for, so the session ends where it began.
    private weak var quickLookPane: BrowserViewController?
    private var clickMonitor: Any?

    /// Called after files are opened in another app, so the visor can get out of the way.
    var onOpenedItems: (() -> Void)?

    var isSplit = Settings.isSplitView {
        didSet {
            guard isSplit != oldValue else { return }
            Settings.isSplitView = isSplit
            applySplit()
        }
    }

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        for pane in panes {
            pane.onOpenedItems = { [weak self] in self?.onOpenedItems?() }
            pane.onToggleSplit = { [weak self] in self?.isSplit.toggle() }
            pane.isSplit = isSplit
            splitView.addArrangedSubview(pane.view)
        }
        // Above the panes' content hugging (250), which otherwise squeezes a pane down to its
        // header's minimum width as soon as a divider drag ends.
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        panes[1].view.isHidden = !isSplit
        view = splitView

        // Header buttons and empty space don't take focus, so a click anywhere in a pane makes it
        // the active one; ⌘V then pastes where you clicked.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isSplit, event.window === self.view.window else { return event }
            let pane = self.panes.first { $0.view.bounds.contains($0.view.convert(event.locationInWindow, from: nil)) }
            if let pane, !self.hasFocus(pane) {
                DispatchQueue.main.async { if !self.hasFocus(pane) { pane.focus() } }
            }
            return event
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = splitView.bounds.width
        guard isSplit, width > 0, needsDividerPlacement || width != laidOutWidth else { return }
        needsDividerPlacement = false
        laidOutWidth = width
        splitView.setPosition(((width - splitView.dividerThickness) * leftFraction).rounded(), ofDividerAt: 0)
    }

    private var visiblePanes: ArraySlice<BrowserViewController> {
        panes.prefix(isSplit ? 2 : 1)
    }

    private func hasFocus(_ pane: BrowserViewController) -> Bool {
        (view.window?.firstResponder as? NSView)?.isDescendant(of: pane.view) == true
    }

    /// The pane holding keyboard focus; keys, ⌘W and Quick Look act on it.
    private var activePane: BrowserViewController {
        isSplit && hasFocus(panes[1]) ? panes[1] : panes[0]
    }

    private func applySplit() {
        let right = panes[1]
        panes.forEach { $0.isSplit = isSplit }
        if isSplit {
            right.prepare()
            right.view.isHidden = false
            leftFraction = 0.5
            needsDividerPlacement = true
            view.needsLayout = true
            if isVisorShown { right.visorWillShow() }
        } else {
            if hasFocus(right) { panes[0].focus() }
            right.view.isHidden = true
            right.visorDidHide()
        }
    }

    // MARK: Visor lifecycle

    /// Loads the visible panes ahead of time so the first slide-in doesn't stall.
    func prepare() {
        _ = view
        visiblePanes.forEach { $0.prepare() }
    }

    func visorWillShow() {
        prepare()
        isVisorShown = true
        visiblePanes.forEach { $0.visorWillShow() }
        // On first show AppKit's key-view loop would hand focus to a sidebar; start in the left
        // pane's columns.
        if let window = view.window, !hasShownOnce || window.firstResponder === window {
            panes[0].focus()
        }
        hasShownOnce = true
    }

    func visorDidHide() {
        isVisorShown = false
        panes.forEach { $0.visorDidHide() }
    }

    var showsHiddenFiles: Bool {
        get { panes[0].showsHiddenFiles }
        set { panes[0].showsHiddenFiles = newValue }  // both panes follow
    }

    /// ⌘U toggles split view; everything else goes to the focused pane.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if Int(event.keyCode) == kVK_ANSI_U, event.modifierFlags.userModifiers == .command {
            isSplit.toggle()
            return true
        }
        return activePane.handleKeyDown(event)
    }
}

extension DualPaneController: NSSplitViewDelegate {
    /// Remembers where the divider was dragged; resizes caused by a new width are left alone.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        let available = splitView.bounds.width - splitView.dividerThickness
        guard isSplit, !needsDividerPlacement, available > 0, splitView.bounds.width == laidOutWidth else { return }
        leftFraction = panes[0].view.frame.width / available
    }
}

extension DualPaneController: QuickLookControlling {
    func beginQuickLook(_ panel: QLPreviewPanel) {
        let pane = activePane
        quickLookPane = pane
        pane.beginQuickLook(panel)
    }

    func endQuickLook(_ panel: QLPreviewPanel) {
        (quickLookPane ?? activePane).endQuickLook(panel)
        quickLookPane = nil
    }
}
