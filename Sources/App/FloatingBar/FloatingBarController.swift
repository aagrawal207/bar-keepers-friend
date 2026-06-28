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

    /// True when at least one hidden item still lacks a real captured glyph (it was omitted or is
    /// showing an app-icon fallback). The launch warm-up uses this to decide whether a second,
    /// fallback-allowing reconcile pass is worth running.
    var hasIncompleteGlyphs: Bool {
        !cachedHiddenOrder.allSatisfy { capturedGlyphIDs.contains($0.windowID) }
    }

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
    /// The anchor's trailing edge from the most recent show, reused when re-laying-out the
    /// panel in place (e.g. when a background capture fills in a glyph while the bar is open).
    private var lastAnchorRightX: CGFloat = 0

    /// Window ids for which we hold a REAL captured glyph (not an app-icon fallback). Keeps the
    /// cache monotonic: once an item has a clean glyph we never downgrade it to an app icon on a
    /// later flaky capture, and a warm-up pass can upgrade a fallback to a glyph.
    private var capturedGlyphIDs: Set<CGWindowID> = []
    /// False until the first capture pass finishes. Lets the panel show a "Preparing…" state on
    /// the very first open (during launch warm-up) instead of a misleading "no hidden items".
    private(set) var hasCapturedOnce = false

    // MARK: - Present/dismiss animation + auto-dismiss state

    /// True only while a hide() slide-out is mid-flight (between starting the animation and its
    /// completion firing `orderOut`). Lets a show() that interrupts a hide know it must reclaim a
    /// panel that's part-way faded/slid: without this the completion handler of the *cancelled*
    /// hide could later `orderOut` the panel show() just brought back, leaving the bar stuck
    /// invisible. show() flips this false and reasserts the final frame/alpha so the stale
    /// completion becomes a no-op.
    private var isAnimatingHide = false

    /// How far (points) the panel starts above its final resting spot, toward the menu bar, before
    /// sliding down on show / back up on hide. Small so it reads as a quick drop-in, not a launch.
    private static let slideOffset: CGFloat = 10
    /// Present/dismiss animation duration. Short enough to feel instant, long enough to register as
    /// motion rather than a pop.
    private static let slideDuration: TimeInterval = 0.18

    /// Opaque tokens from `NSEvent.add*MonitorForEvents`, installed on show() when
    /// `dismissBarOnMouseExit` is on and torn down in hide(). Non-nil exactly while the mouse-exit
    /// watch is armed; also serve as the install guard so a re-layout show() can't stack duplicates.
    /// A GLOBAL monitor (events to other apps) plus a LOCAL one (events to us — e.g. the pointer
    /// over our own panel) mirror HoverRevealMonitor: the global alone goes blind whenever the
    /// cursor is over the panel itself, which is exactly when we must NOT dismiss.
    private var exitGlobalMonitor: Any?
    private var exitLocalMonitor: Any?
    /// The grace countdown armed when the pointer leaves the panel frame, cancelled if it returns
    /// before firing. A `DispatchWorkItem` so replace/cancel is one cheap, unambiguous operation.
    private var dismissWorkItem: DispatchWorkItem?
    /// Seconds the pointer may sit outside the panel before the bar dismisses itself. Brushing the
    /// edge for less than this re-enters and cancels the pending dismissal, so it doesn't snap shut.
    private static let mouseExitGraceDelay: TimeInterval = 0.4

    /// False until the pointer has been seen INSIDE the panel at least once since this show(). The
    /// mouse-exit watchdog must not arm before that: a hover-reveal or the ⌥⌘B shortcut opens the
    /// bar while the pointer is elsewhere (over the anchor, or wherever the user left it), which is
    /// "outside the panel" — so an ungated watchdog would arm the 0.4s dismissal the instant the
    /// bar appeared and the bar would vanish ~0.4s later. That's exactly the "reveal disappears
    /// almost instantly" bug AND why the shortcut looked dead (the bar flashed and closed). Gating
    /// on first-entry means the bar stays put until the user has actually moved onto it and then
    /// left, which is the only time auto-dismiss should trigger.
    private var pointerHasEnteredPanel = false
    /// Backstop so a revealed bar the user never moves onto still tidies itself away rather than
    /// lingering forever. If the pointer hasn't entered within this window of the bar opening, we
    /// allow the exit watchdog to arm anyway. Comfortably longer than the time it takes to move
    /// the pointer down onto a just-revealed bar, but short enough that an ignored bar doesn't sit
    /// open indefinitely. Only consulted while `pointerHasEnteredPanel` is still false.
    private static let preEntryGracePeriod: TimeInterval = 3
    /// When the current bar became visible, for the pre-entry backstop above. Set in show().
    private var shownAt: Date?
    /// Whether THIS open should auto-dismiss if the pointer never lands on it (the pre-entry
    /// backstop). True for pointer-driven opens (anchor click, hover) where an abandoned bar
    /// should tidy away; FALSE for a deliberate keyboard toggle (⌥⌘B), which should stay put until
    /// the user toggles it again or moves onto it and leaves — a keypress isn't a "glance", so a
    /// bar that silently vanished a few seconds after the shortcut would read as "the shortcut
    /// doesn't work". Set only on a fresh open; a re-layout show() leaves it untouched.
    private var autoDismissWhenAbandoned = true

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
    ///
    /// `allowFallback` controls what happens to an item that hasn't captured a real glyph this
    /// pass and has none cached: when `true` (a settled refresh, or the final warm-up pass) it
    /// gets the owning app's icon so it's never permanently missing; when `false` (an early
    /// launch/warm-up pass, before the menu bar has settled) it is left ABSENT — omitted from
    /// the bar — rather than shown as a color app icon mixed in among the monochrome glyphs.
    /// That omission is what makes the first load look clean instead of "messed up": a straggler
    /// that just needs another beat to composite shows up correctly a moment later instead of
    /// flashing the wrong (app-icon) image first.
    func captureAndCache(anchorMinX: CGFloat, allowFallback: Bool = true) async {
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
        guard !hidden.isEmpty else {
            // Genuinely nothing hidden: clear the cache so a stale glyph from a previous layout
            // doesn't linger, and record that a pass completed (so the panel shows the real
            // "no hidden items" state rather than "Preparing…").
            cachedHiddenOrder = []
            iconCache.removeAll()
            capturedGlyphIDs.removeAll()
            hasCapturedOnce = true
            return
        }
        // Collapse co-located windows that back the same visible icon (Tahoe returns a
        // backing + glyph window per item), which otherwise duplicates rows in the bar.
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(hidden)
        // Attribute real app names via Accessibility (kCGWindowName is "Item-0" on Tahoe).
        // Runs off the main thread so it can't stall the run loop (and block bar clicks).
        let attributed = await AXAttributionProvider.attribute(deduped)

        // Mirror the REAL menu bar glyph (Bartender-style) by capturing it while on-screen.
        // The capture can race the section's reveal: if the screenshot lands before the glyphs
        // have composited into the (translucent) menu bar, the crops come back as bare wallpaper
        // and `captureIcons` returns nothing for them. So retry, re-capturing on a fresh frame
        // each time, until every capturable item has a real glyph — OR progress stalls.
        //
        // Only items whose (frozen) frame is on-screen can be captured (`captureIcons` filters on
        // exactly this), so gate on that subset: an item off-screen after the reveal can never be
        // captured this pass and must not force every attempt to be burned. Stall detection stops
        // the loop once a straggler stops making progress, so a single hard-to-composite item no
        // longer drags the whole first load out to the full retry budget (~1.8s). The straggler is
        // picked up by the next (calmer) warm-up/refresh pass instead.
        let capturable = attributed.filter { $0.frame.minX >= 0 }
        var images: [CGWindowID: CGImage] = [:]
        var lastGot = -1
        var stalledAttempts = 0
        for attempt in 1...Self.maxCaptureAttempts {
            let fresh = await capture.captureIcons(for: attributed)
            // Only accept non-blank crops; a blank one isn't progress and shouldn't be cached.
            for (id, cg) in fresh where images[id] == nil && !Self.isBlank(cg) { images[id] = cg }
            let got = capturable.filter { images[$0.windowID] != nil }.count
            if capturable.isEmpty || got >= capturable.count { break }
            if got == lastGot { stalledAttempts += 1 } else { stalledAttempts = 0; lastGot = got }
            if stalledAttempts >= Self.maxStalledAttempts {
                DebugLog.log("floatingbar: capture stalled at \(got)/\(capturable.count); stopping early")
                break
            }
            if attempt < Self.maxCaptureAttempts {
                DebugLog.log("floatingbar: capture attempt \(attempt) got \(got)/\(capturable.count) capturable glyphs; retrying")
                try? await Task.sleep(for: .milliseconds(Self.captureRetryDelayMs))
            }
        }

        // Merge into the cache MONOTONICALLY: a real glyph captured this pass always wins (and
        // can upgrade a prior app-icon fallback); an item with no glyph this pass keeps the real
        // glyph it had before rather than being downgraded by a flaky capture.
        var captured = 0, fellBack = 0, omitted = 0
        for item in attributed {
            if let cg = images[item.windowID] {
                // The captured glyph is trimmed to its bounding box; size the NSImage from the
                // glyph's own pixel dimensions so its aspect ratio is preserved when scaled.
                let size = CGSize(width: cg.width, height: cg.height)
                iconCache[item.windowID] = NSImage(cgImage: cg, size: size)
                capturedGlyphIDs.insert(item.windowID)
                captured += 1
            } else if capturedGlyphIDs.contains(item.windowID) {
                captured += 1 // keep the real glyph already cached (monotonic)
            } else if allowFallback {
                // No glyph after this pass and none cached: use the owning app's real icon so the
                // item is never permanently missing. Only on a settled/final pass.
                iconCache[item.windowID] = AppIconProvider.icon(forPID: item.ownerPID)
                fellBack += 1
            } else {
                // Early pass: leave absent so it's omitted from the bar (no jarring app icon)
                // until a later pass composites its real glyph.
                omitted += 1
            }
        }
        cachedHiddenOrder = attributed
        // Prune cache entries for items no longer present so stale glyphs can't reappear.
        let liveIDs = Set(attributed.map { $0.windowID })
        iconCache = iconCache.filter { liveIDs.contains($0.key) }
        capturedGlyphIDs = capturedGlyphIDs.intersection(liveIDs)
        windowIDToPID = Dictionary(attributed.map { ($0.windowID, $0.ownerPID) }, uniquingKeysWith: { _, new in new })
        hasCapturedOnce = true
        DebugLog.log("floatingbar: \(hidden.count) hidden -> \(deduped.count) deduped; glyphs=\(captured) appIconFallback=\(fellBack) omitted=\(omitted); cache size=\(iconCache.count)")
        // If the bar is open, re-lay-it-out so a freshly captured glyph (or a now-complete set)
        // appears without the user having to reopen it.
        if isVisible {
            await show(anchorMinX: lastAnchorMinX, anchorRightX: lastAnchorRightX)
        }
    }

    /// How many times `captureAndCache` re-captures while waiting for the revealed glyphs to
    /// composite in, the pause between attempts, and how many no-progress attempts end the loop
    /// early. Covers the reveal/reflow race without a single over-long fixed delay, and without
    /// burning the whole budget on one item that won't composite this pass.
    private static let maxCaptureAttempts = 6
    private static let captureRetryDelayMs = 180
    private static let maxStalledAttempts = 2

    /// Builds and presents the panel from the cached icons (items are off-screen when the
    /// bar is shown, so they can't be re-captured here — the cache is populated before hide).
    ///
    /// `autoDismissWhenAbandoned` controls only the pre-entry backstop for THIS open (ignored on a
    /// re-layout show() while already visible): pointer-driven opens pass `true` so a bar the user
    /// never moves onto tidies away; a keyboard toggle passes `false` so it stays until re-toggled.
    func show(anchorMinX: CGFloat, anchorRightX: CGFloat, autoDismissWhenAbandoned: Bool = true) async {
        lastAnchorMinX = anchorMinX
        lastAnchorRightX = anchorRightX
        // The BAR renders the filtered + reordered set (suppressed items dropped, pinned items
        // first). Search and currentItems() deliberately use the FULL set, so a suppressed item
        // stays findable — that split is the whole point of "show in search only".
        let items = barItems()
        // "Preparing" is about the capture warm-up, so gate it on the full cache, not the
        // (possibly all-suppressed) bar set: if everything hidden is suppressed we want the real
        // empty state, not a spinner.
        let isPreparing = !hasCapturedOnce && buildItemsFromCache().isEmpty

        // Place the panel on the display the ANCHOR lives on, not NSScreen.main. For a menu-bar
        // agent with no key window, NSScreen.main is whichever screen owns the user's frontmost
        // window — often a *different* monitor than the one whose menu bar the anchor sits in, so
        // the bar would open detached or on the wrong screen. The anchor's x is a global
        // coordinate (identical in CG and AppKit), so pick the screen whose x-range contains it.
        let screen = Self.screenContaining(globalX: anchorRightX) ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBarHeight = NSStatusBar.system.thickness

        // Feed the layout a frame with the screen's REAL global x-origin (so its right/left
        // clamp shares the same coordinate space as the global anchorRightX) but a zero y-origin
        // (the layout's top-left convention treats minY as "distance from the top"). The panel's
        // global x then comes straight out of the layout, and only the y needs flipping into
        // AppKit's bottom-left space using this screen's real maxY.
        let layoutFrame = CGRect(x: screenFrame.minX, y: 0, width: screenFrame.width, height: screenFrame.height)

        // When empty, lay out as if for one item so the "no hidden items" message has a
        // sensibly-sized panel. This gives visible feedback that the click registered.
        let layout = FloatingBarLayout.layout(
            style: preferences.floatingBarStyle,
            itemCount: max(items.count, 1),
            anchorRightX: anchorRightX,
            menuBarHeight: menuBarHeight,
            displayFrame: layoutFrame,
            metrics: .default
        )

        // x is already global (the layout clamped in global x); only convert the top-left y to
        // AppKit's bottom-left, anchored to the chosen screen's real top edge.
        let appKitY = screenFrame.maxY - layout.panelFrame.maxY
        let panelFrame = CGRect(
            x: layout.panelFrame.minX,
            y: appKitY,
            width: layout.panelFrame.width,
            height: layout.panelFrame.height
        )

        let root = FloatingBarView(
            items: items,
            style: preferences.floatingBarStyle,
            isPreparing: isPreparing,
            onActivate: { [weak self] item in self?.activate(item) }
        )

        let panel = panel ?? makePanel()
        panel.contentViewController = NSHostingController(rootView: root)
        self.panel = panel
        // A FRESH open (not a re-layout show() while already visible) resets the mouse-exit
        // entry latch: the pointer hasn't been on this newly-shown bar yet, so the exit watchdog
        // stays disarmed until it arrives. A re-layout show() (captureAndCache landing a glyph
        // while the bar is open) must NOT reset it, or moving the pointer onto the bar and waiting
        // for a glyph to fill in would re-disarm and the bar would never auto-dismiss.
        if !isVisible {
            pointerHasEnteredPanel = false
            shownAt = Date()
            self.autoDismissWhenAbandoned = autoDismissWhenAbandoned
        }
        // Set visible up front so the engine's toggle logic and the `if isVisible { await show }`
        // re-layout path in captureAndCache both see the bar as open the instant we commit to it,
        // not after the animation lands.
        isVisible = true
        present(panel: panel, finalFrame: panelFrame)
        // (Re)arm the mouse-exit watch. A re-layout show() (captureAndCache while visible) tears
        // down then re-installs so monitors never stack; honoring the preference live here means a
        // setting flip takes effect on the next open without retrofitting an already-open bar.
        installMouseExitMonitorIfNeeded()
    }

    /// Presents `panel` at `finalFrame`, sliding it down from just under the menu bar with a fade
    /// (Bartender-style). The panel starts `slideOffset` points HIGHER (toward the menu bar) at
    /// alpha 0, orders front, then animates to the final frame + alpha 1. Because this is an
    /// `NSPanel`, the frame and alpha are driven through `animator()` inside an
    /// `NSAnimationContext` group.
    ///
    /// Re-entrancy: a show() can land while a hide() slide-out is still running. Clearing
    /// `isAnimatingHide` here neuters that hide's completion handler (it checks the flag before
    /// `orderOut`), so the panel we just reclaimed can't be ordered out from under us and left
    /// stuck invisible. We always reassert the final frame + alpha, so an interrupted part-way
    /// state is corrected regardless of where the prior animation was.
    ///
    /// Reduce Motion: if the system asks for reduced motion we skip the slide/fade entirely and
    /// just place the panel at its final frame, full alpha, and order it front.
    private func present(panel: NSPanel, finalFrame: CGRect) {
        // A show interrupting a hide: reclaim the panel and disarm the stale hide completion.
        isAnimatingHide = false

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: true)
            // Become key so the hosted SwiftUI buttons receive clicks. The panel is a
            // .nonactivatingPanel, so this does NOT activate the app or steal focus from the
            // user's frontmost window — it just lets our own controls handle mouse events.
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // Start above the final spot (toward the menu bar) and transparent, then slide down + fade
        // in. Order front BEFORE animating so the panel exists on screen to animate.
        let startFrame = finalFrame.offsetBy(dx: 0, dy: Self.slideOffset)
        panel.alphaValue = 0
        panel.setFrame(startFrame, display: false)
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        // Cancel any in-flight activation: if the bar is being hidden (auto-rehide, an anchor
        // re-click, or the engine tearing down), a slow activation that hasn't fired yet must not
        // later warp the cursor and synthesize a click into the menu bar after the user moved on.
        // This is safe on the activation path itself, which calls hide() BEFORE creating its task:
        // the new task is assigned after this returns, so only a PRIOR activation is cancelled.
        currentActivationTask?.cancel()
        currentActivationTask = nil

        // Re-entrancy: a second hide() while the bar is already hidden (or its slide-out is still
        // running) must be a no-op — otherwise we'd start a fresh fade-from-zero on an invisible
        // panel and/or fight the running animation. `isVisible` is the immediate, authoritative
        // flag; it was set false the first time hide() ran.
        guard isVisible else { return }
        isVisible = false

        // Tear down the mouse-exit watch and any pending grace dismissal so neither leaks nor
        // fires after the bar is closed. Always done, regardless of how we hide.
        removeMouseExitMonitor()

        guard let panel else { return }

        // Reduce Motion: skip the slide/fade and just order out instantly.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }

        // Slide back UP by the same offset (toward the menu bar) while fading to 0, then order out
        // in the completion. `isAnimatingHide` marks this animation as the live one; if a show()
        // interrupts it, show() flips the flag false and the completion below becomes a no-op so it
        // can't order out a panel show() just reclaimed (which would strand the bar invisible).
        isAnimatingHide = true
        let upFrame = panel.frame.offsetBy(dx: 0, dy: Self.slideOffset)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(upFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Superseded by a show() that reclaimed the panel — leave it on screen.
            guard self.isAnimatingHide else { return }
            self.isAnimatingHide = false
            self.panel?.orderOut(nil)
        })
    }

    /// The screen whose horizontal extent contains a global x coordinate — used to place the
    /// panel on the same display as the anchor. Matching on x (rather than a full point) is
    /// robust because the anchor's x is unambiguous across CG and AppKit spaces, and menu bars
    /// span the full width of their display. Returns nil if no screen contains x (caller falls
    /// back to NSScreen.main).
    private static func screenContaining(globalX: CGFloat) -> NSScreen? {
        NSScreen.screens.first { $0.frame.minX <= globalX && globalX <= $0.frame.maxX }
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
        // Render exactly what the bar shows (filtered + ordered), so the diagnostic PNG matches
        // the live panel rather than including suppressed items.
        let items = barItems()
        let content = FloatingBarView(
            items: items,
            style: preferences.floatingBarStyle,
            isPreparing: false,
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

    /// Whether the cached mirror no longer matches the live menu bar — i.e. the set of hidden
    /// items (left of the anchor) changed since the last capture, because an app added or
    /// removed its status item. Cheap: one `CGWindowList` enumeration, no screenshot. The
    /// caller shows the (slightly stale) cache instantly and refreshes in the background only
    /// when this is true, so a normal open never pays for a capture.
    func cachedMirrorIsStale(anchorMinX: CGFloat) -> Bool {
        let snapshots = (try? windowServer.menuBarItems()) ?? []
        let hidden = HiddenItemsResolver.hiddenItems(
            from: snapshots,
            leftOfAnchorX: anchorMinX,
            excludingControlItems: controlItemWindowIDs
        )
        let live = Set(HiddenItemsResolver.deduplicateByMidXProximity(hidden).map { $0.windowID })
        let cached = Set(cachedHiddenOrder.map { $0.windowID })
        return live != cached
    }

    // MARK: - Shared accessors (used by the search panel)

    /// The current mirrored items (cached snapshot + image + disabled state), in display order.
    /// Exposed so the search panel can list and filter the same items the bar shows, without
    /// re-capturing. Empty until the first capture completes.
    func currentItems() -> [FloatingBarItem] {
        buildItemsFromCache()
    }

    /// Enumerates EVERY manageable menu bar item — both currently-shown (right of the anchor) and
    /// hidden (left) — for the Settings Items list, where the user toggles each item Shown/Hidden.
    /// This is broader than `currentItems()` (which is only the hidden, mirrored set): the picker
    /// must show items on both sides so a shown item can be hidden and vice-versa.
    ///
    /// Read-only and non-disruptive: it enumerates + attributes without revealing or moving
    /// anything. Each item gets its cached glyph if we have one (hidden items, captured earlier),
    /// otherwise its owning app's icon — good enough for a settings list, and it never blanks.
    /// Excludes our own control items and immovable system items (which can't be managed).
    func allManageableItems() async -> [FloatingBarItem] {
        let snapshots = (try? windowServer.menuBarItems()) ?? []
        let candidates = snapshots.filter { !controlItemWindowIDs.contains($0.windowID) }
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(candidates)
        let attributed = await AXAttributionProvider.attribute(deduped)
        return attributed
            .filter { !ImmovableItems.isImmovable($0) && ItemControlStore.key(for: $0) != nil }
            .sorted { $0.frame.minX < $1.frame.minX } // left-to-right, stable order
            .map { snapshot in
                let image = iconCache[snapshot.windowID] ?? AppIconProvider.icon(forPID: snapshot.ownerPID)
                return FloatingBarItem(
                    snapshot: snapshot,
                    image: image,
                    isDisabled: unactivatableWindowIDs.contains(snapshot.windowID),
                    alias: preferences.itemAliases.alias(for: snapshot)
                )
            }
    }

    /// Activates the real menu bar item with the given window id from the cached order — the
    /// same path a click on the mirrored icon takes. No-op if the id isn't currently cached.
    func activate(windowID: CGWindowID) {
        guard let snapshot = cachedHiddenOrder.first(where: { $0.windowID == windowID }) else { return }
        let image = iconCache[windowID] ?? NSImage()
        activate(FloatingBarItem(
            snapshot: snapshot,
            image: image,
            isDisabled: unactivatableWindowIDs.contains(windowID)
        ))
    }

    /// Builds the FULL item set from the cached order + cached images, tagging each with the
    /// user's alias. This is the search/`currentItems()` view: it includes items the user marked
    /// "search only", so they remain findable. The BAR uses `barItems()` instead.
    private func buildItemsFromCache() -> [FloatingBarItem] {
        cachedHiddenOrder.compactMap { snapshot in
            guard let image = iconCache[snapshot.windowID] else { return nil }
            return FloatingBarItem(
                snapshot: snapshot,
                image: image,
                isDisabled: unactivatableWindowIDs.contains(snapshot.windowID),
                alias: preferences.itemAliases.alias(for: snapshot)
            )
        }
    }

    /// The items the floating bar should RENDER: the full cached set with suppressed ("search
    /// only") items dropped and the user's explicit bar order applied. The filter/sort is the
    /// pure `ItemControlStore.visibleBarItems` so it's unit-tested in Core; here we just map the
    /// chosen snapshots back to their cached `FloatingBarItem`s. Kept SEPARATE from
    /// `buildItemsFromCache()` so search (which calls `currentItems()`) never loses a suppressed
    /// item — the load-bearing honesty guard for "search only".
    private func barItems() -> [FloatingBarItem] {
        let full = buildItemsFromCache()
        let byID = Dictionary(full.map { ($0.snapshot.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let visibleSnapshots = ItemControlStore.visibleBarItems(
            from: full.map(\.snapshot),
            controls: preferences.itemControls
        )
        return visibleSnapshots.compactMap { byID[$0.windowID] }
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

    // MARK: - Mouse-exit auto-dismiss

    /// Arms the "dismiss when the pointer leaves the bar" watch, if `dismissBarOnMouseExit` is on.
    /// Idempotent and safe to call on every show(): a re-layout show() (captureAndCache while the
    /// bar is visible) calls this again, so we tear down first to guarantee monitors never stack.
    /// Reads the preference LIVE so a setting flip is honored on the next open without retrofitting
    /// an already-open bar. Does nothing — installs nothing — when the preference is off.
    ///
    /// Concurrency mirrors HoverRevealMonitor/HotkeyService: AppKit delivers these callbacks on the
    /// main thread, so the closures reach `@MainActor` state via `MainActor.assumeIsolated` with no
    /// runtime hop. The GLOBAL monitor sees movement over OTHER apps; the LOCAL one sees movement
    /// over US (the pointer parked on the panel itself) and must return the event unchanged so it
    /// isn't swallowed — that local case is precisely when we must keep the bar open.
    private func installMouseExitMonitorIfNeeded() {
        // Always start clean so a re-layout show() can't end up with two sets of monitors.
        removeMouseExitMonitor()
        guard preferences.dismissBarOnMouseExit else { return }

        exitGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseExitMove() }
        }
        exitLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseExitMove() }
            return event
        }
    }

    /// Removes both mouse-exit monitors and cancels any pending grace dismissal. Called from hide()
    /// (so nothing leaks or fires once the bar is closed) and from `installMouseExitMonitorIfNeeded`
    /// before a reinstall.
    private func removeMouseExitMonitor() {
        if let exitGlobalMonitor { NSEvent.removeMonitor(exitGlobalMonitor) }
        if let exitLocalMonitor { NSEvent.removeMonitor(exitLocalMonitor) }
        exitGlobalMonitor = nil
        exitLocalMonitor = nil
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }

    /// Per-move handler for the auto-dismiss watch. Kept tiny because `.mouseMoved` fires at pointer
    /// cadence. If the pointer is inside the panel frame the user is aiming at an icon, so cancel any
    /// pending dismissal and stay open. Once it's outside, arm a one-shot grace timer; if the pointer
    /// returns before it fires, the next inside event cancels it — brushing the edge won't snap the
    /// bar shut.
    private func handleMouseExitMove() {
        // Defensive: a queued callback could arrive between monitor removal and drain, or after the
        // bar hid. Only act while genuinely visible with monitors live.
        guard isVisible, exitGlobalMonitor != nil || exitLocalMonitor != nil else { return }
        guard let frame = panel?.frame else { return }

        if frame.contains(NSEvent.mouseLocation) {
            // Pointer is over the bar — record the entry (which arms exit-dismissal from now on)
            // and cancel a pending dismissal (the user came back / is aiming).
            pointerHasEnteredPanel = true
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            return
        }

        // Pointer is OUTSIDE the panel. Only arm the exit dismissal once the pointer has actually
        // been on the bar — otherwise a bar revealed under a pointer that's elsewhere (hover over
        // the anchor, or the ⌥⌘B shortcut) would dismiss itself ~0.4s after appearing. Once the
        // pointer HAS entered, normal exit-dismissal applies regardless of how the bar opened (a
        // deliberate move-away closes it). The pre-entry backstop — closing a bar the user never
        // touched — fires only for pointer-driven opens; a keyboard toggle stays put until the user
        // toggles it again, since a vanishing bar would make the shortcut feel broken.
        let preEntryExpired = autoDismissWhenAbandoned
            && Date().timeIntervalSince(shownAt ?? Date()) >= Self.preEntryGracePeriod
        guard pointerHasEnteredPanel || preEntryExpired else { return }

        if dismissWorkItem == nil {
            // Nothing scheduled yet — arm the grace countdown. (If one is already pending we let it
            // keep running; restarting it on every outside jiggle would postpone it indefinitely.)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isVisible else { return }
                self.dismissWorkItem = nil
                self.hide()
            }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mouseExitGraceDelay, execute: work)
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
