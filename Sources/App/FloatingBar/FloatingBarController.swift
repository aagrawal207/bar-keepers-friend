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

    /// Reveals the hidden section (brings items on-screen) and returns once they should be
    /// laid out. Set by the engine. Needed because an item can only be clicked on-screen.
    var revealHiddenItems: (() async -> Void)?
    /// Re-hides the section after an action. Set by the engine.
    var rehideItems: (() -> Void)?
    /// Invoked when an activation needs Accessibility permission that isn't granted.
    var onNeedsAccessibility: (() -> Void)?

    private(set) var isVisible = false

    /// Cached icon images keyed by window id. Status items can only be captured while
    /// on-screen, so they are captured before being hidden and shown from this cache.
    private var iconCache: [CGWindowID: NSImage] = [:]
    /// The hidden items in display order at the time of the last capture.
    private var cachedHiddenOrder: [MenuBarItemSnapshot] = []
    /// Maps each cached item's window id to the owning app pid resolved by attribution, so
    /// activation can query that one app directly instead of sweeping every running app.
    private var windowIDToPID: [CGWindowID: pid_t] = [:]
    /// The anchor's leading edge from the most recent capture/show, reused when re-hiding
    /// after an activation.
    private var lastAnchorMinX: CGFloat = 0

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
        lastAnchorMinX = anchorMinX
        let snapshots = (try? windowServer.menuBarItems()) ?? []
        let hidden = HiddenItemsResolver.hiddenItems(
            from: snapshots,
            leftOfAnchorX: anchorMinX,
            excludingControlItems: controlItemWindowIDs
        )
        guard !hidden.isEmpty else { return }
        // Collapse co-located windows that back the same visible icon (Tahoe returns a
        // backing + glyph window per item), which otherwise duplicates rows in the bar.
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(hidden)
        // Attribute real app names via Accessibility (kCGWindowName is "Item-0" on Tahoe).
        // Runs off the main thread so it can't stall the run loop (and block bar clicks).
        let attributed = await AXAttributionProvider.attribute(deduped)
        let images = await capture.captureIcons(for: attributed)
        // Merge into the cache so items briefly off-screen keep their last good image.
        for (id, cg) in images {
            let item = attributed.first { $0.windowID == id }
            let size = item?.frame.size ?? CGSize(width: 24, height: 24)
            iconCache[id] = NSImage(cgImage: cg, size: size)
        }
        cachedHiddenOrder = attributed
        windowIDToPID = Dictionary(attributed.map { ($0.windowID, $0.ownerPID) }, uniquingKeysWith: { _, new in new })
        DebugLog.log("floatingbar: \(hidden.count) hidden -> \(deduped.count) deduped; cached \(images.count) icons; cache size=\(iconCache.count)")
    }

    /// Builds and presents the panel from the cached icons (items are off-screen when the
    /// bar is shown, so they can't be re-captured here — the cache is populated before hide).
    func show(anchorMinX: CGFloat, anchorRightX: CGFloat) async {
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
        // Become key so the hosted SwiftUI buttons receive clicks. The panel is a
        // .nonactivatingPanel, so this does NOT activate the app or steal focus from the
        // user's frontmost window — it just lets our own controls handle mouse events.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isVisible = true
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

    /// Activates the real menu bar item behind a mirrored icon.
    ///
    /// The real item is off-screen while hidden, and a status item can only be clicked
    /// on-screen (its menu would otherwise open off-screen). So: hide our panel, reveal the
    /// section, re-enumerate for the item's now-on-screen frame, synthesize a click, and
    /// leave the section revealed so the menu can open. Clicking needs Accessibility — if
    /// it's missing we must NOT reveal (that would strand every icon in the menu bar), so we
    /// check first and route the user to grant it.
    private func activate(_ item: FloatingBarItem) {
        DebugLog.log("activate: onActivate fired for \(item.snapshot.windowID)")
        guard windowServer.canSynthesizeClicks else {
            DebugLog.log("activate: Accessibility not granted — requesting, not revealing")
            onNeedsAccessibility?()
            return
        }
        hide()
        Task { @MainActor in
            await revealHiddenItems?()
            // Give the window server a moment to lay the items back on-screen.
            try? await Task.sleep(for: .milliseconds(250))

            // Re-find the item by window id to get its current (on-screen) frame.
            let snapshots = (try? windowServer.menuBarItems()) ?? []
            let current = snapshots.first { $0.windowID == item.snapshot.windowID } ?? item.snapshot
            guard current.isClickableOnScreen else {
                DebugLog.log("activate: item \(item.snapshot.windowID) still off-screen after reveal; re-hiding")
                rehideItems?()
                return
            }
            // Primary: press the item's Accessibility element — it opens the owning app's
            // menu natively. The frame is already fresh from the re-enumeration above, so we
            // do NOT re-capture here (the full attribution sweep mid-activation only adds
            // latency and lets the frame drift). On success the section stays REVEALED so the
            // menu can open; on failure (no AX action) we fall back to a synthesized click.
            let pid = windowIDToPID[current.windowID] ?? current.ownerPID
            let pressed = await AXActivator.activate(windowID: current.windowID, pid: pid, frame: current.frame)
            if pressed { return }
            do {
                // The AX attempt can take a moment; re-read the frame right before posting so
                // the synthesized click lands on the item's current position, not a stale one.
                let fresh = (try? windowServer.menuBarItems())?.first { $0.windowID == current.windowID } ?? current
                try windowServer.click(item: fresh)
                DebugLog.log("activate: CGEvent fallback clicked \(fresh.windowID) at \(fresh.frame)")
            } catch {
                DebugLog.log("activate: AX + CGEvent both failed for \(current.windowID): \(error) — re-hiding")
                rehideItems?()
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
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

/// A borderless panel that can still become key. Borderless `NSWindow`s return
/// `canBecomeKey == false` by default, which prevents the hosted SwiftUI buttons from
/// receiving clicks. As a `.nonactivatingPanel` it can take key status without activating the
/// app, so our controls work while the user's frontmost app keeps its focus. It declines to
/// become *main* so it never looks like the app's primary window.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
