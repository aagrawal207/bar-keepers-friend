import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Owns the floating panel that mirrors hidden menu bar items below the menu bar.
///
/// On show it: enumerates status items (via the injected `WindowServer`), resolves which are
/// hidden, captures their images (`IconCaptureService`), computes the panel frame with the
/// pure `FloatingBarLayout`, and presents an `NSPanel` hosting `FloatingBarView`. The panel
/// is non-activating so showing it doesn't steal focus, and floats above normal windows.
@MainActor
final class FloatingBarController {
    private var panel: NSPanel?
    private let windowServer: WindowServer
    private let capture: IconCaptureService

    /// Window ids of the app's own control items, excluded from the mirrored list.
    var controlItemWindowIDs: Set<CGWindowID> = []

    /// Current preferences (style, etc.). Updated by the coordinator.
    var preferences: Preferences

    private(set) var isVisible = false

    init(
        windowServer: WindowServer,
        capture: IconCaptureService,
        preferences: Preferences
    ) {
        self.windowServer = windowServer
        self.capture = capture
        self.preferences = preferences
    }

    /// Toggles the floating bar. Returns the new visibility.
    @discardableResult
    func toggle(anchorRightX: CGFloat) async -> Bool {
        if isVisible {
            hide()
            return false
        }
        await show(anchorRightX: anchorRightX)
        return isVisible
    }

    /// Builds and presents the panel.
    func show(anchorRightX: CGFloat) async {
        NSLog("BKF floatingbar: show(anchorRightX=\(anchorRightX)) style=\(preferences.floatingBarStyle.rawValue)")
        let items = await buildItems()
        guard !items.isEmpty else {
            NSLog("BKF floatingbar: nothing to show — panel not presented (drag icons to the LEFT of the anchor to hide them)")
            // Nothing to show (no hidden items, or capture unavailable). Don't pop an
            // empty panel — leave any existing one hidden.
            hide()
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let displayFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBarHeight = NSStatusBar.system.thickness

        let layout = FloatingBarLayout.layout(
            style: preferences.floatingBarStyle,
            itemCount: items.count,
            anchorRightX: anchorRightX,
            menuBarHeight: menuBarHeight,
            displayFrame: CGRect(origin: .zero, size: displayFrame.size),
            metrics: .default
        )

        // Convert from the layout's top-left origin (y down from top) to AppKit's
        // bottom-left global coordinates.
        let appKitY = displayFrame.maxY - layout.panelFrame.maxY
        let panelFrame = CGRect(
            x: displayFrame.minX + layout.panelFrame.minX,
            y: appKitY,
            width: layout.panelFrame.width,
            height: layout.panelFrame.height
        )

        let root = FloatingBarView(
            items: items,
            style: preferences.floatingBarStyle,
            onActivate: { [weak self] item in self?.activate(item) }
        )

        let panel = panel ?? makePanel()
        panel.contentViewController = NSHostingController(rootView: root)
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        isVisible = true
        NSLog("BKF floatingbar: presented panel with \(items.count) items at \(panelFrame)")
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Internals

    private func buildItems() async -> [FloatingBarItem] {
        let snapshots = (try? windowServer.menuBarItems()) ?? []
        let hidden = HiddenItemsResolver.hiddenItems(
            from: snapshots,
            visibleMinX: 0,
            excludingControlItems: controlItemWindowIDs
        )
        NSLog("BKF floatingbar: enumerated \(snapshots.count) status items, \(hidden.count) hidden (off-screen left of x=0). screenRecording=\(capture.hasScreenRecordingAccess)")
        guard !hidden.isEmpty else { return [] }

        let images = await capture.captureIcons(for: hidden)
        NSLog("BKF floatingbar: captured \(images.count)/\(hidden.count) icon images")
        return hidden.compactMap { snapshot in
            guard let cg = images[snapshot.windowID] else { return nil }
            return FloatingBarItem(snapshot: snapshot, image: NSImage(cgImage: cg, size: snapshot.frame.size))
        }
    }

    /// Click routing is implemented in the next step; for now this is a safe no-op.
    private func activate(_ item: FloatingBarItem) {
        try? windowServer.click(item: item.snapshot)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
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
        return panel
    }
}
