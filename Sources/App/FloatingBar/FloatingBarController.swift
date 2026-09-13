import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Owns the nonactivating panel that presents cached menu bar icons.
/// Capture and placement stay behind injected WindowServer and attribution seams.
@MainActor
final class FloatingBarController {
    enum Presentation: Equatable, Sendable {
        case click, keyboard, hover
    }

    private var panel: NSPanel?
    private let windowServer: WindowServer
    private let captureIcons: ([MenuBarItemSnapshot]) async -> [CGWindowID: CGImage]
    private let attribute: ([MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot]
    private let activateWithAX: (CGWindowID, pid_t, CGRect) async throws -> Bool
    private let panelFactory: (() -> NSPanel)?

    /// Window ids of the app's own control items, excluded from the mirrored list.
    var controlItemWindowIDs: Set<CGWindowID> = []
    /// The divider, not the visible anchor, determines which items expansion actually hides.
    var hiddenDividerWindowID: CGWindowID?
    /// Nil until the always-hidden tier has a divider; then it splits the tucked items in two.
    var alwaysHiddenDividerWindowID: CGWindowID?

    /// Current preferences (style, etc.). Updated by the coordinator.
    var preferences: Preferences

    /// Reveals the hidden section (brings items on-screen) and returns once they should be
    /// laid out. Set by the engine. Needed because an item can only be clicked on-screen.
    var revealHiddenItems: (() async -> Void)?
    /// Reveals both tiers for an always-hidden item's activation; falls back to `revealHiddenItems`.
    var revealAllHiddenItems: (() async -> Void)?
    /// Re-hides the section after an action. Set by the engine.
    var rehideItems: (() -> Void)?
    /// Invoked when an activation needs Accessibility permission that isn't granted.
    var onNeedsAccessibility: (() -> Void)?
    /// Arms the user-configured auto-rehide after an activation revealed the section. Set by
    /// the engine; honors `preferences.autoRehide`/`autoRehideDelay`.
    var scheduleAutoRehideAfterActivation: (() -> Void)?

    private(set) var isVisible = false
    var windowFrame: CGRect? { panel?.frame }
    var onDidHide: (() -> Void)?
    /// Fires after a capture pass commits new cached glyphs, for consumers that render from the cache.
    var onCacheUpdated: (() -> Void)?

    /// True when at least one tucked item still lacks a real captured glyph (it was omitted or is
    /// showing an app-icon fallback). The launch warm-up uses this to decide whether a second,
    /// fallback-allowing reconcile pass is worth running.
    var hasIncompleteGlyphs: Bool {
        !(cachedHiddenOrder + cachedAlwaysHiddenOrder).allSatisfy { capturedGlyphIDs.contains($0.windowID) }
    }
    var needsCapture: Bool { !hasCapturedOnce || hasIncompleteGlyphs }

    /// The in-flight activation, so a new click can supersede a previous one. Without this,
    /// a slow activation finishing late would warp the cursor and click the menu bar after
    /// the user already moved on.
    private(set) var currentActivationTask: Task<Void, Never>?
    /// Abandons an activation that takes longer than this — a backstop against stale clicks.
    private static let activationDeadline: TimeInterval = 5

    /// Cached icon images keyed by window id. Status items can only be captured while
    /// on-screen, so they are captured before being hidden and shown from this cache.
    private var iconCache: [CGWindowID: NSImage] = [:]
    /// The hidden items in display order at the time of the last capture.
    private var cachedHiddenOrder: [MenuBarItemSnapshot] = []
    /// The intent-backed always-hidden items in display order at the time of the last capture.
    private var cachedAlwaysHiddenOrder: [MenuBarItemSnapshot] = []
    /// Windows physically left of the always-hidden divider at the last capture, whatever their
    /// intent; reaching any of them on-screen needs both dividers revealed.
    private var cachedTierWindowIDs: Set<CGWindowID> = []
    /// Trusted owners are presentation/AX fallbacks, never placement intent. Lifetimes prevent
    /// late attribution from restoring an owner after its window disappeared and its ID was reused.
    private var windowOwners: [CGWindowID: (
        firstSeen: UInt64, resolvedAt: UInt64, owner: (name: String, pid: pid_t)?
    )] = [:]
    private var observationEpoch: UInt64 = 0
    /// Items whose last activation attempt failed via both AX and synthesized click — shown
    /// disabled so the user isn't left clicking a dead icon. Rebuilt on each capture.
    private var unactivatableWindowIDs: Set<CGWindowID> = []
    /// Last finite anchor supplied by capture/show; unknown until a caller supplies a position.
    /// Used for membership only when the divider's raw frame is unavailable.
    private var lastAnchorMinX: CGFloat?
    /// The anchor's trailing edge from the most recent show, reused when re-laying-out the
    /// panel in place (e.g. when a background capture fills in a glyph while the bar is open).
    private var lastAnchorRightX: CGFloat = 0
    /// The CG-global y of the anchor display's menu-bar top, so item enumeration tests the
    /// plausibility filter's top-edge bound relative to that display rather than absolute y=0.
    /// 0 (the primary display's top) until the engine sets it. On a display stacked above/below
    /// the primary the menu bar lives at a large/negative global y; without this the enumeration
    /// would reject every item there and the bar would show nothing. Set by the engine each pass.
    var displayMenuBarTop: CGFloat = 0

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
    /// Re-layout retains the opening policy, including non-key hover presentation.
    private(set) var presentation: Presentation = .click
    /// Whether the last show appended the always-hidden tier; re-layout preserves the choice.
    private var lastIncludeAlwaysHidden = false
    /// True while the visible bar actually shows the always-hidden tier (an Option-click presentation).
    var presentsAlwaysHidden: Bool { isVisible && lastIncludeAlwaysHidden && !cachedAlwaysHiddenOrder.isEmpty }

    init(
        windowServer: WindowServer,
        captureIcons: @escaping ([MenuBarItemSnapshot]) async -> [CGWindowID: CGImage],
        preferences: Preferences,
        attribute: @escaping ([MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot] = { await AXAttributionProvider.attribute($0) },
        activateWithAX: @escaping (CGWindowID, pid_t, CGRect) async throws -> Bool = AXActivator.activate,
        panelFactory: (() -> NSPanel)? = nil
    ) {
        self.windowServer = windowServer
        self.captureIcons = captureIcons
        self.preferences = preferences
        self.attribute = attribute
        self.activateWithAX = activateWithAX
        self.panelFactory = panelFactory
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

    /// Captures items left of the hidden divider while they are on-screen, before expansion.
    /// The caller's anchor is a fallback only when the divider's raw frame is unavailable. Both
    /// tucked tiers are captured in one pass; the always-hidden divider splits them afterward.
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
        guard let snapshots = try? menuBarSnapshots() else { return }
        lastAnchorMinX = anchorMinX.isFinite ? anchorMinX : nil
        let observedAt = observationEpoch
        let validate = observationValidator(for: snapshots)
        let boundaryX = hiddenDividerMinX(in: snapshots) ?? anchorMinX
        guard boundaryX.isFinite else { return }
        let tucked = tuckedItems(in: snapshots, hiddenBoundaryX: boundaryX)
        let hidden = tucked.hidden
        guard !hidden.isEmpty || !tucked.alwaysHidden.isEmpty else {
            // Genuinely nothing hidden: clear the cache so a stale glyph from a previous layout
            // doesn't linger, and record that a pass completed (so the panel shows the real
            // "no hidden items" state rather than "Preparing…").
            cachedHiddenOrder = []
            cachedAlwaysHiddenOrder = []
            cachedTierWindowIDs = []
            iconCache.removeAll()
            capturedGlyphIDs.removeAll()
            unactivatableWindowIDs.removeAll()
            hasCapturedOnce = true
            onCacheUpdated?()
            return
        }
        // Collapse co-located windows that back the same visible icon (Tahoe returns a
        // backing + glyph window per item), which otherwise duplicates rows in the bar.
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(hidden)
        let dedupedAlwaysHidden = HiddenItemsResolver.deduplicateByMidXProximity(tucked.alwaysHidden)
        let tierIDs = Set(dedupedAlwaysHidden.map(\.windowID))
        // Attribute real app names via Accessibility (kCGWindowName is "Item-0" on Tahoe).
        // Runs off the main thread so it can't stall the run loop (and block bar clicks).
        guard let attributed = try? await attributePreservingOwners(
            deduped + dedupedAlwaysHidden, observedAt: observedAt, validate: validate
        ) else { return }

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
            guard (try? validate()) != nil else { return }
            let current = applyingKnownOwners(to: attributed, observedAt: observedAt)
            guard !current.isEmpty else { return }
            let fresh = await captureIcons(current)
            guard (try? validate()) != nil else { return }
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
        let current = applyingKnownOwners(to: attributed, observedAt: observedAt)
        guard !Task.isCancelled, !current.isEmpty else { return }
        unactivatableWindowIDs.removeAll()
        var captured = 0, fellBack = 0, omitted = 0
        for item in current {
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
        // The tier belongs to owners who asked for it; anything else parked past its divider (a
        // newly launched item lands leftmost) is mirrored as plain hidden so it stays reachable.
        let intent = intentControls
        let tierItems = current.filter { tierIDs.contains($0.windowID) }
        let strays = tierItems.filter { !intent.isAlwaysHidden($0) }
        cachedHiddenOrder = strays + current.filter { !tierIDs.contains($0.windowID) }
        cachedAlwaysHiddenOrder = tierItems.filter { intent.isAlwaysHidden($0) }
        cachedTierWindowIDs = Set(tierItems.map(\.windowID))
        // Prune cache entries for items no longer present so stale glyphs can't reappear.
        let liveIDs = Set(current.map { $0.windowID })
        iconCache = iconCache.filter { liveIDs.contains($0.key) }
        capturedGlyphIDs = capturedGlyphIDs.intersection(liveIDs)
        hasCapturedOnce = true
        DebugLog.log("floatingbar: \(hidden.count) hidden -> \(deduped.count) deduped, \(dedupedAlwaysHidden.count) in tier (\(strays.count) without intent); glyphs=\(captured) appIconFallback=\(fellBack) omitted=\(omitted); cache size=\(iconCache.count)")
        onCacheUpdated?()
        // If the bar is open, re-lay-it-out so a freshly captured glyph (or a now-complete set)
        // appears without the user having to reopen it.
        if isVisible {
            await show(
                anchorMinX: lastAnchorMinX ?? anchorMinX, anchorRightX: lastAnchorRightX,
                includeAlwaysHidden: lastIncludeAlwaysHidden
            )
        }
    }

    /// How many times `captureAndCache` re-captures while waiting for the revealed glyphs to
    /// composite in, the pause between attempts, and how many no-progress attempts end the loop
    /// early. Covers the reveal/reflow race without a single over-long fixed delay, and without
    /// burning the whole budget on one item that won't composite this pass.
    private static let maxCaptureAttempts = 6
    private static let captureRetryDelayMs = 180
    private static let maxStalledAttempts = 2

    /// Presents cached icons without waiting for capture. A fresh open establishes its interaction
    /// policy; re-layout must preserve it so hover cannot acquire keyboard focus or manual ownership.
    /// `includeAlwaysHidden` appends the always-hidden tier (Option-click); plain opens omit it.
    func show(
        anchorMinX: CGFloat, anchorRightX: CGFloat,
        presentation: Presentation = .click,
        includeAlwaysHidden: Bool = false
    ) async {
        guard !Task.isCancelled else { return }
        lastAnchorMinX = anchorMinX.isFinite ? anchorMinX : nil
        lastAnchorRightX = anchorRightX
        lastIncludeAlwaysHidden = includeAlwaysHidden
        // The BAR renders the filtered set (any suppressed-from-bar items dropped, explicit order
        // applied). buildItemsFromCache() is the full mirrored set behind that filter.
        let items = barItems()
        let alwaysHiddenItems = includeAlwaysHidden ? barAlwaysHiddenItems() : []
        // "Preparing" is about the capture warm-up, so gate it on the full cache, not the
        // (possibly all-suppressed) bar set: if everything is filtered out we want the real empty
        // state, not a spinner.
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

        let perLine = FloatingBarLayout.itemsPerLine(
            style: preferences.floatingBarStyle,
            displayFrame: layoutFrame,
            menuBarHeight: menuBarHeight,
            metrics: .default
        )

        let root = FloatingBarView(
            items: items,
            alwaysHiddenItems: alwaysHiddenItems,
            style: preferences.floatingBarStyle,
            isPreparing: isPreparing,
            itemsPerLine: perLine,
            onActivate: { [weak self] item in self?.activate(item) }
        )

        // Empty/preparing views are not one-cell grids; size the panel from its actual content.
        let hosting = NSHostingController(rootView: root)
        hosting.view.layoutSubtreeIfNeeded()
        let frame = FloatingBarLayout.panelFrame(
            contentSize: hosting.view.fittingSize,
            anchorRightX: anchorRightX,
            menuBarHeight: menuBarHeight,
            displayFrame: layoutFrame
        )
        let panelFrame = CGRect(
            x: frame.minX, y: screenFrame.maxY - frame.maxY,
            width: frame.width, height: frame.height
        )
        let panel = panel ?? panelFactory?() ?? makePanel()
        panel.contentViewController = hosting
        self.panel = panel
        beginPresentation(presentation)
        present(panel: panel, finalFrame: panelFrame)
        // (Re)arm the mouse-exit watch. A re-layout show() (captureAndCache while visible) tears
        // down then re-installs so monitors never stack; honoring the preference live here means a
        // setting flip takes effect on the next open without retrofitting an already-open bar.
        installMouseExitMonitorIfNeeded()
    }

    /// Re-layout keeps the opening policy; only a fresh presentation may change ownership behavior.
    func beginPresentation(_ presentation: Presentation = .click) {
        if !isVisible {
            pointerHasEnteredPanel = false
            shownAt = Date()
            self.presentation = presentation
        }
        isVisible = true
    }

    /// A deliberate click over a hover-owned bar takes it over: key ordering, the exit watchdog,
    /// and the pre-entry backstop follow the new policy from this moment.
    func adoptPresentation(_ presentation: Presentation) {
        guard isVisible, self.presentation != presentation else { return }
        self.presentation = presentation
        pointerHasEnteredPanel = false
        shownAt = Date()
    }

    /// Hover must not take keyboard focus; clicking its keyable panel can still focus its controls.
    /// Reasserting frame and alpha also recovers a presentation interrupted during a hide animation.
    func present(panel: NSPanel, finalFrame: CGRect) {
        // A show interrupting a hide: reclaim the panel and disarm the stale hide completion.
        isAnimatingHide = false

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        let startFrame = reduceMotion ? finalFrame : finalFrame.offsetBy(dx: 0, dy: Self.slideOffset)
        panel.setFrame(startFrame, display: reduceMotion)
        if presentation == .hover {
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        guard !reduceMotion else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide(notifyDismissal: Bool = true) {
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
        if notifyDismissal { onDidHide?() }

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

    /// Inspects hidden items without pressing, revealing, or moving anything.
    /// Only the presentation/AX caches are refreshed by this diagnostics read.
    func makeDiagnosticsReport() async -> DiagnosticsReport {
        var report = DiagnosticsReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            anchorMinX: Double(lastAnchorMinX ?? 0),
            items: []
        )
        guard let snapshots = try? menuBarSnapshots() else { return report }
        let observedAt = observationEpoch
        let tucked = tuckedItems(in: snapshots, hiddenBoundaryX: hiddenDividerMinX(in: snapshots) ?? lastAnchorMinX ?? 0)
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(tucked.hidden)
            + HiddenItemsResolver.deduplicateByMidXProximity(tucked.alwaysHidden)
        guard let attributed = try? await attributePreservingOwners(
            deduped, observedAt: observedAt, validate: observationValidator(for: snapshots)
        ) else { return report }

        var axInfo: [CGWindowID: AXInspector.ElementInfo] = [:]
        if !Task.isCancelled, !attributed.isEmpty {
            axInfo = await AXInspector.inspect(
                targets: attributed.map { ($0.windowID, $0.frame.minX, $0.frame.width) }
            )
        }

        let current = Task.isCancelled ? [] : applyingKnownOwners(to: attributed, observedAt: observedAt)
        report.items = current.map { snapshot in
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
        return report
    }

    /// Renders the current floating-bar contents to a PNG on disk for visual inspection during
    /// development. Deterministic, unlike screenshotting the live panel (which races the
    /// show/hide toggle). Composites over a neutral backdrop so the translucent material reads
    /// the way it would over a wallpaper. Triggered alongside the SIGUSR1 report.
    func renderDiagnosticSnapshot(to url: URL) {
        // Render what an Option-click bar shows (filtered + ordered, both tiers), so the diagnostic
        // PNG covers every tucked item rather than only the plain presentation.
        let items = barItems()
        let alwaysHiddenItems = barAlwaysHiddenItems()
        let content = FloatingBarView(
            items: items,
            alwaysHiddenItems: alwaysHiddenItems,
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

    private func hiddenDividerMinX(in snapshots: [MenuBarItemSnapshot]) -> CGFloat? {
        controlFrame(in: snapshots, windowID: hiddenDividerWindowID, identifier: .hiddenDivider)?.minX
    }

    /// The always-hidden divider's frame; nil while the tier has no divider (two-tier behavior).
    private func alwaysHiddenDividerFrame(in snapshots: [MenuBarItemSnapshot]) -> CGRect? {
        controlFrame(in: snapshots, windowID: alwaysHiddenDividerWindowID, identifier: .alwaysHiddenDivider)
    }

    private func controlFrame(
        in snapshots: [MenuBarItemSnapshot], windowID: CGWindowID?, identifier: ControlItem.Identifier
    ) -> CGRect? {
        if let control = snapshots.first(where: { $0.windowID == windowID }), control.frame.minX.isFinite {
            return control.frame
        }
        let named = snapshots.filter { $0.title == identifier.rawValue }
        // Multiple display copies cannot be disambiguated by enumeration order.
        guard named.count == 1, let frame = named.first?.frame, frame.minX.isFinite else { return nil }
        return frame
    }

    /// Splits the tucked items into the two tiers; without an always-hidden divider everything
    /// left of the hidden boundary is plain hidden, exactly as before the tier existed.
    private func tuckedItems(
        in snapshots: [MenuBarItemSnapshot], hiddenBoundaryX: CGFloat
    ) -> (hidden: [MenuBarItemSnapshot], alwaysHidden: [MenuBarItemSnapshot]) {
        let tierFrame = alwaysHiddenDividerFrame(in: snapshots)
        let hidden = HiddenItemsResolver.hiddenItems(
            from: snapshots,
            leftOfAnchorX: hiddenBoundaryX,
            rightOfAlwaysHiddenX: tierFrame?.maxX,
            excludingControlItems: controlItemWindowIDs,
            displayMenuBarTop: displayMenuBarTop
        )
        let alwaysHidden = tierFrame.map { frame in
            HiddenItemsResolver.hiddenItems(
                from: snapshots,
                leftOfAnchorX: frame.minX,
                excludingControlItems: controlItemWindowIDs,
                displayMenuBarTop: displayMenuBarTop
            )
        } ?? []
        return (hidden, alwaysHidden)
    }

    /// Grouped owners read as Hidden here exactly as they do for placement.
    private var intentControls: ItemControlStore {
        ItemGroupLibrary.effectiveControls(groups: preferences.itemGroups, base: preferences.itemControls)
    }

    private func menuBarSnapshots() throws -> [MenuBarItemSnapshot] {
        try Task.checkCancellation()
        let snapshots = try windowServer.menuBarItems()
        try Task.checkCancellation()
        // A shown or temporarily implausible window is still alive; only absence ends its identity.
        let liveIDs = Set(snapshots.map(\.windowID))
        guard liveIDs.count == snapshots.count,
              snapshots.allSatisfy({ item in
                  let frame = item.frame
                  return frame.minX.isFinite && frame.maxX.isFinite
                      && frame.minY.isFinite && frame.maxY.isFinite
              }) else {
            throw WindowServerError.invalidServerResponse("invalid menu bar window geometry")
        }
        observationEpoch &+= 1
        windowOwners = windowOwners.filter { liveIDs.contains($0.key) }
        for id in liveIDs where windowOwners[id] == nil {
            windowOwners[id] = (observationEpoch, 0, nil)
        }
        iconCache = iconCache.filter { liveIDs.contains($0.key) }
        capturedGlyphIDs.formIntersection(liveIDs)
        cachedHiddenOrder.removeAll { !liveIDs.contains($0.windowID) }
        cachedAlwaysHiddenOrder.removeAll { !liveIDs.contains($0.windowID) }
        cachedTierWindowIDs.formIntersection(liveIDs)
        unactivatableWindowIDs.formIntersection(liveIDs)
        return snapshots
    }

    private func observationValidator(for snapshots: [MenuBarItemSnapshot]) -> @MainActor () throws -> Void {
        let frames = observationFrames(snapshots)
        let ownNames = Dictionary(uniqueKeysWithValues: snapshots.filter(HiddenItemsResolver.isOwnControlItem)
            .map { ($0.windowID, $0.title) })
        let controls = (controlItemWindowIDs, hiddenDividerWindowID, alwaysHiddenDividerWindowID, displayMenuBarTop)
        let boundaryX = hiddenDividerMinX(in: snapshots)
        let tierFrame = alwaysHiddenDividerFrame(in: snapshots)
        let fallbackBoundaryX = boundaryX == nil ? lastAnchorMinX : nil
        let observedAt = observationEpoch
        return {
            let fresh = try self.menuBarSnapshots()
            let freshOwnNames = Dictionary(uniqueKeysWithValues: fresh.filter(HiddenItemsResolver.isOwnControlItem)
                .map { ($0.windowID, $0.title) })
            // AX matches positions; neither a reflow nor an observed ID reuse can share its sample.
            guard frames == self.observationFrames(fresh), ownNames == freshOwnNames,
                   controls == (self.controlItemWindowIDs, self.hiddenDividerWindowID, self.alwaysHiddenDividerWindowID, self.displayMenuBarTop),
                   boundaryX == self.hiddenDividerMinX(in: fresh),
                   tierFrame == self.alwaysHiddenDividerFrame(in: fresh),
                   fallbackBoundaryX == (boundaryX == nil ? self.lastAnchorMinX : nil),
                  frames.keys.allSatisfy({ (self.windowOwners[$0]?.firstSeen ?? .max) <= observedAt }) else {
                throw WindowServerError.invalidServerResponse("menu bar geometry changed during attribution")
            }
        }
    }

    private func observationFrames(_ snapshots: [MenuBarItemSnapshot]) -> [CGWindowID: CGRect] {
        Self.framesByWindowID(snapshots.filter {
            controlItemWindowIDs.contains($0.windowID) || $0.windowID == hiddenDividerWindowID
                || $0.windowID == alwaysHiddenDividerWindowID
                || HiddenItemsResolver.isOwnControlItem($0)
                || HiddenItemsResolver.isPlausibleMenuBarItem($0, displayMenuBarTop: displayMenuBarTop)
        })
    }

    private static func framesByWindowID(_ snapshots: [MenuBarItemSnapshot]) -> [CGWindowID: CGRect] {
        Dictionary(snapshots.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
    }

    private func attributePreservingOwners(
        _ snapshots: [MenuBarItemSnapshot], observedAt: UInt64, validate: @MainActor () throws -> Void
    ) async throws -> [MenuBarItemSnapshot] {
        try Task.checkCancellation()
        guard !snapshots.isEmpty else { return [] }
        let attributed = await attribute(snapshots)
        try validate()
        guard attributed.count == snapshots.count,
              Self.framesByWindowID(attributed) == Self.framesByWindowID(snapshots) else {
            throw WindowServerError.invalidServerResponse("attribution changed its candidate geometry")
        }
        for item in attributed {
            // Tahoe's blanket owner and empty labels are unresolved, not replacement identities.
            guard let name = item.ownerBundleID, !name.isEmpty, name != "Control Center",
                  var cached = windowOwners[item.windowID], cached.firstSeen <= observedAt,
                  cached.resolvedAt <= observedAt else { continue }
            cached.owner = (name, item.ownerPID)
            cached.resolvedAt = observedAt
            windowOwners[item.windowID] = cached
        }
        return applyingKnownOwners(to: snapshots, observedAt: observedAt)
    }

    private func applyingKnownOwners(
        to snapshots: [MenuBarItemSnapshot], observedAt: UInt64
    ) -> [MenuBarItemSnapshot] {
        snapshots.compactMap { snapshot in
            guard let cached = windowOwners[snapshot.windowID], cached.firstSeen <= observedAt else { return nil }
            guard let owner = cached.owner else { return snapshot }
            return snapshot.attributed(bundleID: owner.name, pid: owner.pid)
        }
    }

    /// Checks physical membership of both tiers with one enumeration, without capturing any images.
    /// Raw geometry cannot tell intent, so the tier is compared by position, not by cache group.
    /// Failure requests a refresh without invalidating the cached mirror.
    func cachedMirrorIsStale(anchorMinX: CGFloat) -> Bool {
        let cachedTucked = Set((cachedHiddenOrder + cachedAlwaysHiddenOrder).map { $0.windowID })
        guard let snapshots = try? menuBarSnapshots() else { return true }
        let tucked = tuckedItems(in: snapshots, hiddenBoundaryX: hiddenDividerMinX(in: snapshots) ?? anchorMinX)
        let liveHidden = Set(HiddenItemsResolver.deduplicateByMidXProximity(tucked.hidden).map { $0.windowID })
        let liveTier = Set(HiddenItemsResolver.deduplicateByMidXProximity(tucked.alwaysHidden).map { $0.windowID })
        return liveHidden.union(liveTier) != cachedTucked || liveTier != cachedTierWindowIDs
    }

    // MARK: - Shared accessors

    /// Enumerates manageable items on every side of the controls without revealing or moving them.
    /// Failed or unstable observations throw so Settings can retain its existing rows.
    func allManageableItems() async throws -> [FloatingBarItem] {
        let snapshots = try menuBarSnapshots()
        let observedAt = observationEpoch
        let boundaryX = hiddenDividerMinX(in: snapshots) ?? lastAnchorMinX
        let tierBoundaryX = alwaysHiddenDividerFrame(in: snapshots)?.minX
        // Filter raw geometry before AX matching, without discarding cosmetically tucked windows.
        let candidates = snapshots.filter {
            !controlItemWindowIDs.contains($0.windowID) && $0.windowID != hiddenDividerWindowID
                && $0.windowID != alwaysHiddenDividerWindowID
                && !HiddenItemsResolver.isOwnControlItem($0)
                && HiddenItemsResolver.isPlausibleMenuBarItem($0, displayMenuBarTop: displayMenuBarTop)
        }
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(candidates)
        let attributed = try await attributePreservingOwners(
            deduped, observedAt: observedAt, validate: observationValidator(for: snapshots)
        )
        try Task.checkCancellation()
        // Apply PID exclusions only after attribution; Tahoe's raw PID can belong to Control Center.
        let immovablePIDs = ImmovableProcessIDs.current()
        let intent = intentControls
        return applyingKnownOwners(to: attributed, observedAt: observedAt)
            .filter { !ImmovableItems.isImmovable($0, immovablePIDs: immovablePIDs) && ItemControlStore.key(for: $0) != nil }
            .sorted { $0.frame.minX < $1.frame.minX } // left-to-right, stable order
            .map { snapshot in
                let image = iconCache[snapshot.windowID] ?? AppIconProvider.icon(forPID: snapshot.ownerPID)
                return FloatingBarItem(
                    snapshot: snapshot,
                    image: image,
                    isDisabled: unactivatableWindowIDs.contains(snapshot.windowID),
                    alias: preferences.itemAliases.alias(for: snapshot),
                    observedPlacement: boundaryX.map { boundary in
                        let physical = HiddenItemsResolver.observedPlacement(
                            of: snapshot, hiddenBoundaryX: boundary, alwaysHiddenBoundaryX: tierBoundaryX
                        )
                        // The tier is intent-only; a stray item parked past its divider reads as hidden.
                        return physical == .alwaysHidden && !intent.isAlwaysHidden(snapshot) ? .hidden : physical
                    }
                )
            }
    }

    /// Activates the real menu bar item with the given window id from the cached order — the
    /// same path a click on the mirrored icon takes. No-op if the id isn't currently cached.
    func activate(windowID: CGWindowID) {
        guard let snapshot = (cachedHiddenOrder + cachedAlwaysHiddenOrder).first(where: { $0.windowID == windowID }) else { return }
        let image = iconCache[windowID] ?? NSImage()
        activate(FloatingBarItem(
            snapshot: snapshot,
            image: image,
            isDisabled: unactivatableWindowIDs.contains(windowID)
        ))
    }

    /// Builds the full mirrored set from the cached order + cached images, tagging each with the
    /// user's display nickname. The BAR render derives from this via `barItems()`.
    private func buildItemsFromCache(_ order: [MenuBarItemSnapshot]? = nil) -> [FloatingBarItem] {
        (order ?? cachedHiddenOrder).compactMap { snapshot in
            guard let image = iconCache[snapshot.windowID] else { return nil }
            return FloatingBarItem(
                snapshot: snapshot,
                image: image,
                isDisabled: unactivatableWindowIDs.contains(snapshot.windowID),
                alias: preferences.itemAliases.alias(for: snapshot)
            )
        }
    }

    /// The items the floating bar should RENDER: the full mirrored set passed through the pure
    /// `ItemControlStore.visibleBarItems` (drops any suppressed-from-bar items, applies any
    /// explicit order); here we just map the chosen snapshots back to their cached `FloatingBarItem`s.
    private func barItems() -> [FloatingBarItem] {
        presentable(buildItemsFromCache())
    }

    /// The always-hidden tier, filtered and ordered by the same presentation controls.
    private func barAlwaysHiddenItems() -> [FloatingBarItem] {
        presentable(buildItemsFromCache(cachedAlwaysHiddenOrder))
    }

    private func presentable(_ full: [FloatingBarItem]) -> [FloatingBarItem] {
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
        hide(notifyDismissal: false)
        // Supersede any in-flight activation so a slow earlier one can't fire its
        // cursor-warping click late. Capture a per-task deadline as a second backstop.
        currentActivationTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.activationDeadline)
        let observedAt = observationEpoch
        // Anything past the always-hidden divider, intent or not, needs both dividers on-screen.
        let inAlwaysHiddenTier = cachedTierWindowIDs.contains(item.snapshot.windowID)
        let reveal = inAlwaysHiddenTier ? (revealAllHiddenItems ?? revealHiddenItems) : revealHiddenItems
        currentActivationTask = Task { @MainActor in
            await reveal?()
            // revealForActivation already settles ~120ms; a short extra wait covers reflow.
            try? await Task.sleep(for: .milliseconds(60))

            // Superseded by a newer click, or this task is ancient. Don't re-hide — the
            // successor task (or the anchor) owns the divider's state.
            guard !Task.isCancelled else {
                DebugLog.log("activate: superseded before press for \(item.snapshot.windowID)")
                return
            }
            guard Date() < deadline else {
                DebugLog.log("activate: expired before press for \(item.snapshot.windowID)")
                rehideItems?()
                return
            }

            // Re-find the item by window id to get its current (on-screen) frame.
            guard let snapshots = try? menuBarSnapshots(),
                  let current = snapshots.first(where: { $0.windowID == item.snapshot.windowID }),
                  (windowOwners[current.windowID]?.firstSeen ?? .max) <= observedAt else {
                guard !Task.isCancelled else { return }
                DebugLog.log("activate: no fresh snapshot for \(item.snapshot.windowID); not clicking")
                rehideItems?()
                return
            }
            // On-screen is relative to the item's OWN display: a display left of/above the primary
            // has a negative global x-origin, so a revealed item there has minX < 0 yet is fully
            // on-screen. Resolve the display origin from the item's (now-revealed) midpoint.
            let displayMinX = Self.screenContaining(globalX: current.frame.midX)?.frame.minX ?? 0
            guard current.isClickableOnScreen(displayMinX: displayMinX) else {
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
            } catch is CancellationError {
                DebugLog.log("activate: CGEvent click interrupted for \(current.windowID)")
                if !Task.isCancelled { rehideItems?() }
                return
            } catch {
                DebugLog.log("activate: CGEvent click failed for \(current.windowID): \(error)")
            }
            // Optional compatibility fallback for a genuine statusItem.menu item that only
            // opens via AXShowMenu. Off by default. Guarded again because it can take a moment.
            if preferences.useAXActivation, !Task.isCancelled, Date() < deadline {
                let pid = windowOwners[current.windowID]?.owner?.pid ?? current.ownerPID
                do {
                    let activated = try await activateWithAX(current.windowID, pid, current.frame)
                    guard !Task.isCancelled else { return }
                    if activated {
                        scheduleAutoRehideAfterActivation?()
                        return
                    }
                } catch is CancellationError {
                    DebugLog.log("activate: AX interrupted for \(current.windowID)")
                    if !Task.isCancelled { rehideItems?() }
                    return
                } catch {
                    DebugLog.log("activate: AX failed for \(current.windowID): \(error)")
                }
            }
            guard !Task.isCancelled else { return }
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
        guard preferences.dismissBarOnMouseExit, presentation != .hover else { return }

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
        let preEntryExpired = presentation == .click
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

/// A nonactivating, borderless panel that can become key when the user clicks its controls.
/// It never becomes the app's main window.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Group status items

extension FloatingBarController {
    /// Cached hidden items with their cached glyph or app-icon fallback, for group menus.
    /// Reads the cache only; nothing is enumerated, captured, or moved.
    func cachedHiddenItems() -> [FloatingBarItem] {
        cachedItems(from: cachedHiddenOrder)
    }

    /// Cached intent-backed always-hidden items, kept apart from `cachedHiddenItems` so groups and
    /// plain presentations never surface the tier by accident.
    func cachedAlwaysHiddenItems() -> [FloatingBarItem] {
        cachedItems(from: cachedAlwaysHiddenOrder)
    }

    private func cachedItems(from order: [MenuBarItemSnapshot]) -> [FloatingBarItem] {
        order.map { snapshot in
            FloatingBarItem(
                snapshot: snapshot,
                image: iconCache[snapshot.windowID] ?? AppIconProvider.icon(forPID: snapshot.ownerPID),
                isDisabled: unactivatableWindowIDs.contains(snapshot.windowID),
                alias: preferences.itemAliases.alias(for: snapshot)
            )
        }
    }

    /// Window ids whose cached image is a captured menu bar glyph rather than an app-icon fallback.
    var capturedGlyphWindowIDs: Set<CGWindowID> { capturedGlyphIDs }
}
