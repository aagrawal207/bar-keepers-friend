import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Owns the fuzzy-search panel: a small floating window with a text field that filters the
/// hidden menu bar items (by `SearchRanker`) and activates the chosen one — the same activation
/// path as clicking a mirrored icon in the floating bar.
///
/// AGENT: implement the panel here. The public surface below is fixed — the coordinator sets
/// `itemsProvider` / `onActivate` and calls `toggle()` / `hide()`. Do not change the signatures.
@MainActor
final class SearchController {
    /// Supplies the current hidden items to search over. Set by the coordinator to the floating
    /// bar's `currentItems()` so search and the bar always agree on the item set.
    var itemsProvider: (() -> [FloatingBarItem])?
    /// Activates the chosen item by window id. Set by the coordinator to the floating bar's
    /// `activate(windowID:)`.
    var onActivate: ((CGWindowID) -> Void)?

    private(set) var isVisible = false

    /// The live panel, lazily created on first show and reused across toggles. Reuse keeps the
    /// borderless window's first-responder/focus wiring stable instead of rebuilding it each open.
    private var panel: NSPanel?

    /// Shows the panel if hidden, hides it if shown. Returns the new visibility.
    @discardableResult
    func toggle() -> Bool {
        if isVisible {
            hide()
        } else {
            show()
        }
        return isVisible
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Internals

    /// Builds the SwiftUI view from the current item snapshot, sizes the panel, positions it
    /// Spotlight-style near the top of the main screen, and makes it key so the field accepts
    /// typing. A fresh `SearchView` is hosted each show so its query/selection start clean.
    private func show() {
        let items = itemsProvider?() ?? []
        let root = SearchView(
            items: items,
            onActivate: { [weak self] windowID in
                // Activate via the coordinator's wiring, then dismiss — selecting a result should
                // behave exactly like clicking the mirrored icon and closing the launcher.
                self?.onActivate?(windowID)
                self?.hide()
            },
            onCancel: { [weak self] in self?.hide() }
        )

        let panel = panel ?? makePanel()
        let hosting = NSHostingController(rootView: root)
        panel.contentViewController = hosting

        // Size to the SwiftUI content (fixed 360pt width, height bounded by the row cap) so the
        // panel hugs the view rather than guessing a frame, then position it.
        let fitting = hosting.view.fittingSize
        panel.setContentSize(fitting)
        positionPanel(panel, contentSize: fitting)

        // Become key so the hosted text field can receive keystrokes. The panel is a
        // .nonactivatingPanel, so this does NOT activate the app or pull focus from the user's
        // frontmost window — it just lets our own field type while they keep working.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isVisible = true
    }

    /// Centers the panel horizontally and drops it ~20% down from the top of the main screen's
    /// visible area — the classic launcher position, high enough to read at a glance without
    /// colliding with the menu bar.
    private func positionPanel(_ panel: NSPanel, contentSize: CGSize) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let x = frame.midX - contentSize.width / 2
        // AppKit's origin is bottom-left, so "20% down from the top" is 80% up from the bottom,
        // minus the panel's own height so its TOP sits at that line.
        let y = frame.minY + frame.height * 0.8 - contentSize.height
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func makePanel() -> NSPanel {
        let panel = SearchPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        // Dismiss as soon as the panel loses key (the user clicked away or switched apps), so the
        // launcher behaves like Spotlight rather than lingering as a stray floating box.
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }
}

/// A borderless panel that can still become key. Borderless `NSWindow`s return
/// `canBecomeKey == false` by default, which would stop the hosted SwiftUI text field from
/// receiving keystrokes. As a `.nonactivatingPanel` it takes key status without activating the
/// app, so the field types while the user's frontmost app keeps its focus. It declines to become
/// *main* so it never poses as the app's primary window.
///
/// This mirrors `FloatingBarController`'s private `KeyablePanel`; it's redefined here (rather than
/// shared) because that one is file-private to its owner, and search additionally needs the
/// resign-key dismissal hook below.
private final class SearchPanel: NSPanel {
    /// Invoked when the panel stops being key, so the controller can dismiss on click-away.
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
