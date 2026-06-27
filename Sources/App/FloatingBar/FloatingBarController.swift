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

    /// Cached icon images keyed by window id. Status items can only be captured while
    /// on-screen, so they are captured before being hidden and shown from this cache.
    private var iconCache: [CGWindowID: NSImage] = [:]
    /// The hidden items in display order at the time of the last capture.
    private var cachedHiddenOrder: [MenuBarItemSnapshot] = []

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
    func toggle(anchorMinX: CGFloat, anchorRightX: CGFloat) async -> Bool {
        if isVisible {
            hide()
            return false
        }
        await show(anchorMinX: anchorMinX, anchorRightX: anchorRightX)
        return isVisible
    }

    /// Captures the icons of items left of the anchor and caches them. Must be called while
    /// those items are still ON-SCREEN (before the divider hides them), because off-screen
    /// status items cannot be captured. The engine calls this just before expanding the
    /// divider, and refreshes it whenever the menu bar changes.
    func captureAndCache(anchorMinX: CGFloat) async {
        let snapshots = (try? windowServer.menuBarItems()) ?? []
        let hidden = HiddenItemsResolver.hiddenItems(
            from: snapshots,
            leftOfAnchorX: anchorMinX,
            excludingControlItems: controlItemWindowIDs
        )
        guard !hidden.isEmpty else { return }
        let images = await capture.captureIcons(for: hidden)
        // Merge into the cache so items briefly off-screen keep their last good image.
        for (id, cg) in images {
            let item = hidden.first { $0.windowID == id }
            let size = item?.frame.size ?? CGSize(width: 24, height: 24)
            iconCache[id] = NSImage(cgImage: cg, size: size)
        }
        cachedHiddenOrder = hidden
        DebugLog.log("floatingbar: cached \(images.count)/\(hidden.count) icons; cache size=\(iconCache.count)")
    }

    /// Builds and presents the panel.
    func show(anchorMinX: CGFloat, anchorRightX: CGFloat) async {
        DebugLog.log("floatingbar: show(anchorMinX=\(anchorMinX), anchorRightX=\(anchorRightX)) style=\(preferences.floatingBarStyle.rawValue)")
        // Try a fresh capture first (covers the case where items are still visible); fall
        // back to the cache for items that are now off-screen.
        await captureAndCache(anchorMinX: anchorMinX)
        let items = buildItemsFromCache()

        let screen = NSScreen.main ?? NSScreen.screens.first
        let displayFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBarHeight = NSStatusBar.system.thickness

        // When empty, lay out as if for one item so the "no hidden items" message has a
        // sensibly-sized panel. This gives visible feedback that the click registered.
        let layout = FloatingBarLayout.layout(
            style: preferences.floatingBarStyle,
            itemCount: max(items.count, 1),
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
        DebugLog.log("floatingbar: presented panel with \(items.count) items at \(panelFrame)")
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Internals

    /// Builds the items to show from the cached order + cached images.
    private func buildItemsFromCache() -> [FloatingBarItem] {
        cachedHiddenOrder.compactMap { snapshot in
            guard let image = iconCache[snapshot.windowID] else { return nil }
            return FloatingBarItem(snapshot: snapshot, image: image)
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
