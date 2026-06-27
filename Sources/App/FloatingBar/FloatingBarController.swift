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
    /// Arms the user-configured auto-rehide after an activation revealed the section. Set by
    /// the engine; honors `preferences.autoRehide`/`autoRehideDelay`.
    var scheduleAutoRehideAfterActivation: (() -> Void)?

    private(set) var isVisible = false

    /// The in-flight activation, so a new click can supersede a previous one. Without this,
    /// a slow activation finishing late would warp the cursor and click the menu bar after
    /// the user already moved on.
    private var currentActivationTask: Task<Void, Never>?
    /// Abandons an activation that takes longer than this — a backstop against stale clicks.
    private static let activationDeadline: TimeInterval = 5

    /// Cached icon images keyed by window id. Status items can only be captured while
    /// on-screen, so they are captured before being hidden and shown from this cache.
    private var iconCache: [CGWindowID: NSImage] = [:]
    /// The hidden items in display order at the time of the last capture.
    private var cachedHiddenOrder: [MenuBarItemSnapshot] = []
    /// Maps each cached item's window id to the owning app pid resolved by attribution, so
    /// activation can query that one app directly instead of sweeping every running app.
    private var windowIDToPID: [CGWindowID: pid_t] = [:]
    /// Items whose last activation attempt failed via both AX and synthesized click — shown
    /// disabled so the user isn't left clicking a dead icon. Rebuilt on each capture.
    private var unactivatableWindowIDs: Set<CGWindowID> = []
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
        // The menu bar may have changed; forget which items were previously unactivatable so
        // a now-fixed item isn't left disabled.
        unactivatableWindowIDs.removeAll()
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

        // Mirror the REAL menu bar glyph (Bartender-style) by capturing it while on-screen.
        // The capture can race the section's reveal: if the screenshot lands before the glyphs
        // have composited into the (translucent) menu bar, the crops come back as bare
        // wallpaper and `captureIcons` returns nothing for them. So retry until every item has
        // a real glyph (or we exhaust the attempts and fall back to app icons), re-capturing on
        // a fresh frame each time. Items stay revealed across attempts (the caller hides after).
        // Only items whose (frozen) frame is on-screen can be captured — `captureIcons` filters
        // on exactly this. Gate the retry loop on that subset so an item that's off-screen after
        // the reveal (and thus never capturable this pass) doesn't force every attempt to be
        // burned; it falls through to the app-icon fallback instead.
        let capturable = attributed.filter { $0.frame.minX >= 0 }
        var images: [CGWindowID: CGImage] = [:]
        for attempt in 1...Self.maxCaptureAttempts {
            // Each call takes a fresh screenshot, so retrying recovers glyphs that hadn't yet
            // composited into the (translucent) menu bar on an earlier attempt.
            let fresh = await capture.captureIcons(for: attributed)
            for (id, cg) in fresh where images[id] == nil { images[id] = cg }
            let got = capturable.filter { images[$0.windowID] != nil }.count
            if capturable.isEmpty || got >= capturable.count { break }
            if attempt < Self.maxCaptureAttempts {
                DebugLog.log("floatingbar: capture attempt \(attempt) got \(got)/\(capturable.count) capturable glyphs; retrying")
                try? await Task.sleep(for: .milliseconds(Self.captureRetryDelayMs))
            }
        }

        var captured = 0, fellBack = 0
        for item in attributed {
            if let cg = images[item.windowID], !Self.isBlank(cg) {
                // The captured glyph is trimmed to its bounding box; size the NSImage from the
                // glyph's own pixel dimensions so its aspect ratio is preserved when the view
                // scales it to fit the icon frame.
                let size = CGSize(width: cg.width, height: cg.height)
                iconCache[item.windowID] = NSImage(cgImage: cg, size: size)
                captured += 1
            } else {
                // No glyph after all attempts (rare): fall back to the owning app's real icon
                // so we never show an empty box or a wallpaper tile.
                iconCache[item.windowID] = AppIconProvider.icon(forPID: item.ownerPID)
                fellBack += 1
            }
        }
        cachedHiddenOrder = attributed
        windowIDToPID = Dictionary(attributed.map { ($0.windowID, $0.ownerPID) }, uniquingKeysWith: { _, new in new })
        DebugLog.log("floatingbar: \(hidden.count) hidden -> \(deduped.count) deduped; glyphs=\(captured) appIconFallback=\(fellBack); cache size=\(iconCache.count)")
    }

    /// How many times `captureAndCache` re-captures while waiting for the revealed glyphs to
    /// composite in, and the pause between attempts. Covers the reveal/reflow race without a
    /// single over-long fixed delay.
    private static let maxCaptureAttempts = 6
    private static let captureRetryDelayMs = 180

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

    // MARK: - Diagnostics

    /// Builds a read-only diagnostics report of the current hidden-item understanding: the
    /// cached attribution plus a deep Accessibility dump of each item's extra element. Presses
    /// nothing, mutates no state. Triggered by SIGUSR1 for inspection during development.
    func makeDiagnosticsReport() async -> DiagnosticsReport {
        // Refresh the cache first so the report reflects the live menu bar (this reveals and
        // re-hides briefly via captureAndCache's callers; here we just re-enumerate + attribute
        // without touching the divider, to stay read-only).
        let snapshots = (try? windowServer.menuBarItems()) ?? []
        let hidden = HiddenItemsResolver.hiddenItems(
            from: snapshots,
            leftOfAnchorX: lastAnchorMinX,
            excludingControlItems: controlItemWindowIDs
        )
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(hidden)
        let attributed = await AXAttributionProvider.attribute(deduped)

        let axInfo = await AXInspector.inspect(
            targets: attributed.map { ($0.windowID, $0.frame.minX, $0.frame.width) }
        )

        let items = attributed.map { snapshot in
            DiagnosticsReport.Item(
                windowID: snapshot.windowID,
                displayName: FloatingBarItem(snapshot: snapshot, image: NSImage()).displayName,
                attributedOwner: snapshot.ownerBundleID,
                ownerPID: snapshot.ownerPID,
                rawTitle: snapshot.title,
                frame: [snapshot.frame.minX, snapshot.frame.minY, snapshot.frame.width, snapshot.frame.height].map(Double.init),
                isDisabled: unactivatableWindowIDs.contains(snapshot.windowID),
                axElement: axInfo[snapshot.windowID]
            )
        }
        return DiagnosticsReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            anchorMinX: Double(lastAnchorMinX),
            items: items
        )
    }

    /// Renders the current floating-bar contents to a PNG on disk for visual inspection during
    /// development. Deterministic, unlike screenshotting the live panel (which races the
    /// show/hide toggle). Composites over a neutral backdrop so the translucent material reads
    /// the way it would over a wallpaper. Triggered alongside the SIGUSR1 report.
    func renderDiagnosticSnapshot(to url: URL) {
        let items = buildItemsFromCache()
        let content = FloatingBarView(
            items: items,
            style: preferences.floatingBarStyle,
            onActivate: { _ in }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else {
            DebugLog.log("diag: bar snapshot skipped — zero-size content (\(items.count) items)")
            return
        }

        // Backdrop so .ultraThinMaterial isn't rendered over transparency (which would make the
        // PNG unreadable). Mid-gray approximates a wallpaper behind the Liquid Glass panel.
        let pad: CGFloat = 24
        let container = NSView(frame: CGRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.20, alpha: 1).cgColor
        hosting.frame = CGRect(origin: CGPoint(x: pad, y: pad), size: size)
        container.addSubview(hosting)

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        DebugLog.log("diag: wrote bar snapshot \(Int(size.width))x\(Int(size.height)) (\(items.count) items) to \(url.lastPathComponent)")
    }

    // MARK: - Internals

    /// Builds the items to show from the cached order + cached images.
    private func buildItemsFromCache() -> [FloatingBarItem] {
        cachedHiddenOrder.compactMap { snapshot in
            guard let image = iconCache[snapshot.windowID] else { return nil }
            return FloatingBarItem(
                snapshot: snapshot,
                image: image,
                isDisabled: unactivatableWindowIDs.contains(snapshot.windowID)
            )
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
        // Supersede any in-flight activation so a slow earlier one can't fire its
        // cursor-warping click late. Capture a per-task deadline as a second backstop.
        currentActivationTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.activationDeadline)
        currentActivationTask = Task { @MainActor in
            await revealHiddenItems?()
            // revealForActivation already settles ~120ms; a short extra wait covers reflow.
            try? await Task.sleep(for: .milliseconds(60))

            // Superseded by a newer click, or this task is ancient. Don't re-hide — the
            // successor task (or the anchor) owns the divider's state.
            guard !Task.isCancelled, Date() < deadline else {
                DebugLog.log("activate: superseded/stale before press for \(item.snapshot.windowID)")
                return
            }

            // Re-find the item by window id to get its current (on-screen) frame.
            let snapshots = (try? windowServer.menuBarItems()) ?? []
            let current = snapshots.first { $0.windowID == item.snapshot.windowID } ?? item.snapshot
            guard current.isClickableOnScreen else {
                DebugLog.log("activate: item \(item.snapshot.windowID) still off-screen after reveal; re-hiding")
                rehideItems?()
                return
            }
            // Primary: a synthesized click, which opens the owning app's menu natively. AX
            // press (AXUIElementPerformAction) is NOT used by default — most status items
            // advertise AXPress but return ActionUnsupported/NotImplemented, so it just adds
            // ~1.5s of latency and fails. The frame is fresh from the re-enumeration above; on
            // success the section stays REVEALED so the menu can open, and auto-rehide tidies
            // it away after the delay.
            let clickStart = Date()
            do {
                try windowServer.click(item: current)
                DebugLog.log("activate: CGEvent clicked \(current.windowID) at \(current.frame) (\(ms(from: clickStart)))")
                scheduleAutoRehideAfterActivation?()
                return
            } catch {
                DebugLog.log("activate: CGEvent click failed for \(current.windowID): \(error)")
            }
            // Optional compatibility fallback for a genuine statusItem.menu item that only
            // opens via AXShowMenu. Off by default. Guarded again because it can take a moment.
            if preferences.useAXActivation, !Task.isCancelled, Date() < deadline {
                let pid = windowIDToPID[current.windowID] ?? current.ownerPID
                if await AXActivator.activate(windowID: current.windowID, pid: pid, frame: current.frame) {
                    scheduleAutoRehideAfterActivation?()
                    return
                }
            }
            DebugLog.log("activate: could not activate \(current.windowID) — disabling + re-hiding")
            unactivatableWindowIDs.insert(current.windowID)
            rehideItems?()
        }
    }

    /// Milliseconds elapsed since `start`, for the activation-timing log.
    private func ms(from start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000))ms"
    }

    /// Whether a captured glyph is effectively empty (fully transparent) — the failure mode
    /// when capturing the translucent menu bar goes wrong. Such crops trigger the app-icon
    /// fallback so the bar never shows a blank box. Samples alpha; cheap for a ~30pt crop.
    private static func isBlank(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return true }
        var alpha = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Consider it blank if fewer than 1% of pixels have any opacity.
        let opaque = alpha.reduce(0) { $0 + ($1 > 8 ? 1 : 0) }
        return opaque * 100 < w * h
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
