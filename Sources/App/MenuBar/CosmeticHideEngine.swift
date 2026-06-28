import AppKit
import BarKeepersFriendCore

/// The Phase 1 hide/show engine — the unbreakable baseline.
///
/// It owns two of *our own* `NSStatusItem`s: an always-visible anchor and a hidden-section
/// divider. Hiding works by expanding the divider's `length` so the items to its left are
/// pushed off the screen edge; revealing restores the natural length. This uses **no**
/// private APIs and **no** permissions, so it keeps working regardless of what Apple
/// changes in the private menu-bar internals.
///
/// All visibility *decisions* come from `HideShowStateMachine` in Core; this class only
/// translates the resulting intents into `NSStatusItem.length` mutations.
@MainActor
final class CosmeticHideEngine {
    /// Called when settings should open (chosen from the anchor's right-click menu).
    var onOpenSettings: (() -> Void)?
    /// Called when the user chooses Quit from the anchor's right-click menu.
    var onQuit: (() -> Void)?

    /// The floating bar that mirrors hidden items below the menu bar. When set and enabled
    /// in preferences, the anchor click toggles this panel instead of reflowing items back
    /// into the (possibly too-narrow) menu bar.
    var floatingBar: FloatingBarController?

    /// Performs the per-item Shown/Hidden control by physically moving items across the anchor
    /// (the private synthesized-move path). When set, the engine reconciles the live menu bar
    /// with the user's `itemControls.hiddenInMenuBar` intent inside its reveal/capture sequence.
    var hiddenItemController: HiddenItemController?
    /// Invoked when a reconcile pass needs Accessibility permission that isn't granted, so the
    /// per-item Hidden control can take effect. Routed to the permission prompt by the coordinator.
    var onNeedsAccessibilityForMove: (() -> Void)?

    private var anchorItem: NSStatusItem?
    private var hiddenDivider: NSStatusItem?

    private var stateMachine: HideShowStateMachine
    private var preferences: Preferences
    private let onPreferencesChanged: (Preferences) -> Void

    private var autoRehideWorkItem: DispatchWorkItem?

    /// Serializes reveal → capture → hide sequences. Both the launch capture and any refresh
    /// (menu-bar change, anchor open) drive the shared divider, so running two concurrently
    /// makes them fight over its collapsed state across `await` points — the launch capture
    /// could hide the section out from under a refresh mid-capture, yielding 0 glyphs. Chaining
    /// each sequence onto the previous one guarantees they run one at a time.
    private var captureChain: Task<Void, Never> = Task {}

    /// Number of capture sequences currently revealing/capturing. A COUNTER, not a bool: when a
    /// wedged predecessor is overtaken via `awaitBounded`'s timeout, predecessor and successor run
    /// concurrently for a moment. With a bool, the orphaned predecessor's `defer` would clear the
    /// flag while the successor is still live, defeating the click-during-capture guard (a user
    /// click would then yank the divider shut under an in-flight screenshot). Incrementing/
    /// decrementing means the flag stays true until the LAST sequence finishes.
    private var captureInFlightCount = 0

    /// Whether any capture sequence is revealing/capturing. Lets the anchor click ignore the
    /// transient reveal (the divider is physically open for capture but not for the user), so a
    /// click during the launch capture window can't misread that state and eat the toggle.
    var captureInFlight: Bool { captureInFlightCount > 0 }

    /// Upper bound on a single capture sequence so a wedged ScreenCaptureKit call can't stall
    /// the chain forever (the next sequence waits on this one). Generous vs. the ~1s happy path.
    private static let captureSequenceTimeout: TimeInterval = 8

    /// Whether the hidden section is currently in active use and must not be disturbed by an
    /// opportunistic refresh: the mirror panel is showing, or an activation revealed the section
    /// so a real item's menu can stay open (state is `.shown` only via reveal-for-activation in
    /// floating-bar mode). A refresh that ignored this would collapse the divider out from under
    /// the open menu, or reveal the real items behind the visible panel (duplicated icons).
    private var sectionInUse: Bool {
        (floatingBar?.isVisible ?? false) || stateMachine.visibility(of: .hidden) == .shown
    }

    /// Reveals the section, runs `body` (which captures), then restores the divider — never
    /// overlapping another such sequence. The physical reveal is transient and does NOT change
    /// the state machine; on completion the divider is set to match the state machine, unless
    /// `forceCollapseAfter` is set (launch / open-panel), which both collapses the state machine
    /// and the divider. Restoring-to-state (rather than always collapsing) is what keeps a
    /// refresh from slamming shut a section an activation revealed for an open menu.
    /// Returns a task the caller can await if it needs the capture done before showing the panel.
    @discardableResult
    private func runCaptureSequence(
        forceCollapseAfter: Bool,
        _ body: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = captureChain
        let task = Task { @MainActor in
            // Wait for the predecessor, but don't let a wedged one (e.g. a hung ScreenCaptureKit
            // call) block this sequence forever — proceed after a bound. The orphaned
            // predecessor finishes on its own; the worst case is a brief divider overlap, not a
            // permanent stall that prevents the bar from ever showing.
            await awaitBounded(previous, seconds: Self.captureSequenceTimeout)
            captureInFlightCount += 1
            defer { captureInFlightCount -= 1 }
            setHidden(collapsed: false)
            try? await Task.sleep(for: .milliseconds(350))
            // Run the capture inline (NOT in a nested Task — hopping main-actor tasks here
            // shifted capture timing and produced wallpaper-only crops).
            await body()
            if forceCollapseAfter {
                _ = stateMachine.apply(.hide(.hidden))
                setHidden(collapsed: true)
            } else {
                // Restore the divider to whatever the state machine now says — preserves a
                // reveal an activation established while we were capturing.
                setHidden(collapsed: stateMachine.visibility(of: .hidden) == .collapsed)
            }
        }
        captureChain = task
        return task
    }

    /// Awaits `task`, giving up after `seconds` so a wedged predecessor can't stall the chain.
    /// `task` is `Sendable`, so racing it against a sleep in a task group is fine here (unlike
    /// passing our non-Sendable `@MainActor` capture closure, which trips region isolation).
    private func awaitBounded(_ task: Task<Void, Never>, seconds: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    init(preferences: Preferences, onPreferencesChanged: @escaping (Preferences) -> Void) {
        self.preferences = preferences
        self.onPreferencesChanged = onPreferencesChanged
        self.stateMachine = HideShowStateMachine(
            sections: MenuBarSection.phase1,
            autoRehideSections: preferences.autoRehide ? [.hidden] : [],
            // Launch showing everything: the divider stays at its natural width so the
            // anchor is visible and nothing is hidden until the user clicks. Expanding on
            // launch would overflow a notched menu bar and drop the items off-screen.
            initialVisibility: .shown
        )
    }

    // MARK: - Lifecycle

    func install() {
        // Heal an inverted control-item order *before* the items are created — AppKit reads the
        // saved "Preferred Position" slot the moment a status item with an autosaveName is made.
        // The per-item moves can churn these slots until the divider ends up right of the anchor,
        // which makes the launch hide expand the divider straight through the anchor and push it
        // off-screen (every other icon visible, ours gone). See `ControlItemOrder`.
        repairControlItemOrderIfNeeded()

        let anchor = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        anchor.autosaveName = ControlItem.Identifier.anchor.rawValue
        if let button = anchor.button {
            button.image = Self.anchorImage()
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(anchorClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        anchorItem = anchor

        // The hidden divider is purely a mechanism, not a visible control: it carries NO image,
        // so the user never sees a chevron or boundary marker in their menu bar. Its only job is
        // to expand its width and push the hidden items off-screen. It starts at its natural
        // (zero-content) width so it's invisible until it's expanded to hide.
        let divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        divider.autosaveName = ControlItem.Identifier.hiddenDivider.rawValue
        if let button = divider.button {
            button.target = self
            button.action = #selector(dividerClicked(_:))
        }
        hiddenDivider = divider

        // Tell the floating bar which windows are ours, so they're excluded from mirroring.
        publishControlItemWindowIDs()

        // Let the floating bar reveal/re-hide the section so it can click real items
        // (which must be on-screen to receive a click).
        floatingBar?.revealHiddenItems = { [weak self] in
            await self?.revealForActivation()
        }
        floatingBar?.rehideItems = { [weak self] in
            // Reconcile the STATE MACHINE, not just the physical divider. `revealForActivation`
            // advanced the state to `.shown` before every activation; on a failed/off-screen
            // activation the bar calls this to tidy up. If we only collapsed the divider here
            // (the old bug), the state machine would stay stuck at `.shown` forever — making
            // `sectionInUse` permanently true (so refreshes silently no-op and the mirror goes
            // stale) and the next anchor click hit the `.shown` branch and get eaten. Driving the
            // collapse through the state machine keeps model and divider in sync.
            guard let self else { return }
            self.enact(self.stateMachine.apply(.hide(.hidden)))
        }
        floatingBar?.scheduleAutoRehideAfterActivation = { [weak self] in
            self?.scheduleAutoRehideAfterActivation()
        }

        if preferences.useFloatingBar {
            // Items must be captured while on-screen (status items can't be captured once
            // off-screen). Reveal → capture+cache → hide, serialized so a later refresh can't
            // race this launch capture for the divider state. Force-collapse after: launch
            // establishes the hidden baseline.
            //
            // Two passes within ONE reveal (so there's no flicker of the section opening twice):
            //   1. A clean first pass that OMITS any straggler whose glyph hasn't composited yet
            //      (allowFallback: false) — so the first bar the user sees is all real glyphs,
            //      never a monochrome-glyphs-plus-one-color-app-icon mishmash.
            //   2. If anything is still missing, one reconcile pass that DOES allow the app-icon
            //      fallback, so a genuinely uncapturable item isn't omitted forever.
            // The menu bar is usually fully composited by pass 2, so the fallback rarely fires.
            warmUpFloatingBarCache()
            // Then apply the saved per-item Hidden intent by moving those items left of the anchor
            // and re-capturing. Serialized after the warm-up via the capture chain, so the bar is
            // usable immediately and settles into the saved arrangement a beat later. No-op when
            // nothing is marked hidden or the mover isn't wired.
            reconcileHiddenItems()
        } else {
            applyDividerVisibility()
        }
        observeScreenChanges()
    }

    /// The defaults key AppKit uses to persist a status item's horizontal slot, by autosave name.
    private static func preferredPositionKey(_ identifier: ControlItem.Identifier) -> String {
        "NSStatusItem Preferred Position \(identifier.rawValue)"
    }

    /// Rewrites the divider's saved slot when it has drifted to the right of the anchor, so the
    /// hide mechanism keeps pushing items (not the anchor) off-screen. No-op when the order is
    /// already correct or either slot hasn't been persisted yet (first launch — AppKit picks a
    /// sane default order). Must run before the status items are created.
    private func repairControlItemOrderIfNeeded() {
        let defaults = UserDefaults.standard
        let anchorKey = Self.preferredPositionKey(.anchor)
        let dividerKey = Self.preferredPositionKey(.hiddenDivider)
        guard defaults.object(forKey: anchorKey) != nil,
              defaults.object(forKey: dividerKey) != nil else { return }
        let anchorPos = defaults.double(forKey: anchorKey)
        let dividerPos = defaults.double(forKey: dividerKey)
        guard let fixed = ControlItemOrder.repairedDividerPosition(anchor: anchorPos, divider: dividerPos) else { return }
        defaults.set(fixed, forKey: dividerKey)
        DebugLog.log("control-item order was inverted (anchor=\(anchorPos) divider=\(dividerPos)); repaired divider -> \(fixed)")
    }

    /// Reports the app's own status-item window numbers to the floating bar so it never
    /// mirrors the anchor or divider.
    ///
    /// `windowNumber` is an `Int` and can be 0, negative, or an out-of-range sentinel before
    /// the status-item window is realized; `CGWindowID` is a `UInt32`, so a force-conversion
    /// traps. We convert safely and skip any value that doesn't fit. The set is also
    /// refreshed right before the bar is shown, by which point the windows definitely exist.
    private func publishControlItemWindowIDs() {
        var ids: Set<CGWindowID> = []
        for window in [anchorItem?.button?.window, hiddenDivider?.button?.window] {
            if let number = window?.windowNumber,
               let id = WindowIDConversion.cgWindowID(fromWindowNumber: number) {
                ids.insert(id)
            }
        }
        floatingBar?.controlItemWindowIDs = ids
    }

    /// The anchor window's global frame, used to align the floating bar and to determine
    /// which items count as "hidden" (those left of the anchor).
    private var anchorFrame: CGRect? {
        anchorItem?.button?.window?.frame
    }

    func uninstall() {
        autoRehideWorkItem?.cancel()
        if let anchor = anchorItem { NSStatusBar.system.removeStatusItem(anchor) }
        if let divider = hiddenDivider { NSStatusBar.system.removeStatusItem(divider) }
        anchorItem = nil
        hiddenDivider = nil
    }

    // MARK: - Preferences

    func apply(preferences: Preferences) {
        let wasFloatingBar = self.preferences.useFloatingBar
        let previousHidden = self.preferences.itemControls.hiddenInMenuBar
        self.preferences = preferences
        stateMachine.autoRehideSections = preferences.autoRehide ? [.hidden] : []

        // React to a useFloatingBar change at runtime. The launch warm-up (which pre-populates
        // the icon cache and flips `hasCapturedOnce`) only runs in install()'s floating-bar
        // branch, so a user who enables the bar AFTER launch would otherwise get a stuck
        // "Preparing…" spinner on first open until a stale-cache refresh limps in. Mirror the
        // launch behavior on the transition.
        if preferences.useFloatingBar != wasFloatingBar {
            if preferences.useFloatingBar {
                warmUpFloatingBarCache()
            } else {
                floatingBar?.hide()
                applyDividerVisibility()
            }
        }

        // If the per-item Hidden intent changed (the user toggled Shown/Hidden in Settings),
        // physically move the affected items to the correct side of the anchor and refresh the
        // mirror. Only when it actually changed, so an unrelated settings edit doesn't drag icons.
        if preferences.itemControls.hiddenInMenuBar != previousHidden {
            reconcileHiddenItems()
        }
    }

    /// Runs the same two-pass reveal→capture→hide warm-up that `install()` uses, so the floating
    /// bar's cache is pre-populated (and `hasCapturedOnce` set) before the first open. Shared by
    /// launch and the Settings enable-at-runtime path.
    private func warmUpFloatingBarCache() {
        guard preferences.useFloatingBar, floatingBar != nil else { return }
        runCaptureSequence(forceCollapseAfter: true) { [weak self] in
            guard let self, let bar = self.floatingBar else { return }
            let anchorX = self.anchorFrame?.minX ?? 1115
            await bar.captureAndCache(anchorMinX: anchorX, allowFallback: false)
            if bar.hasIncompleteGlyphs {
                try? await Task.sleep(for: .milliseconds(220))
                await bar.captureAndCache(anchorMinX: anchorX, allowFallback: true)
            }
        }
    }

    /// Brings the real menu bar in line with the user's per-item Shown/Hidden intent, then
    /// refreshes the floating-bar mirror so it reflects the new layout. Items can only be moved
    /// while ON-SCREEN, so this rides inside a reveal→(reconcile + capture)→collapse sequence,
    /// serialized behind any in-flight capture exactly like a refresh. No-op while the section is
    /// in active use (don't move items out from under an open menu or the visible panel) and when
    /// there's no mover wired. If moving needs Accessibility and it's missing, route to the prompt
    /// instead of silently failing.
    func reconcileHiddenItems() {
        guard let controller = hiddenItemController else {
            DebugLog.log("reconcileHiddenItems: skipped (no controller)")
            return
        }
        // Only bail if the user has the bar OPEN — moving items out from under a visible panel is
        // the thing to avoid. We deliberately do NOT use the broader `sectionInUse` here: that also
        // trips on the state machine's `.shown`, which at launch is just the initial "nothing hidden
        // yet" baseline (initialVisibility: .shown), not an active reveal. Guarding on it made the
        // launch reconcile skip every time, so the saved per-item Hidden intent was never applied.
        // Reconcile manages its own reveal→move→collapse via `runCaptureSequence(forceCollapseAfter:
        // true)`, serialized behind the warm-up, so it's safe whenever the panel isn't shown.
        guard !(floatingBar?.isVisible ?? false) else {
            DebugLog.log("reconcileHiddenItems: skipped (floating bar visible)")
            return
        }
        guard controller.canMoveItems else {
            DebugLog.log("reconcileHiddenItems: skipped (no Accessibility) hidden=\(preferences.itemControls.hiddenInMenuBar)")
            onNeedsAccessibilityForMove?()
            return
        }
        DebugLog.log("reconcileHiddenItems: proceeding, hidden=\(preferences.itemControls.hiddenInMenuBar)")
        // Make sure our own control-item window ids are excluded from any move.
        publishControlItemWindowIDs()
        controller.controlItemWindowIDs = floatingBar?.controlItemWindowIDs ?? []

        runCaptureSequence(forceCollapseAfter: true) { [weak self] in
            guard let self else { return }
            // Reconcile while items are revealed (on-screen) so they're movable. Use the anchor's
            // live edges as the hide/show boundary.
            if let anchor = self.anchorFrame {
                _ = await controller.reconcile(
                    anchorMinX: anchor.minX,
                    anchorMaxX: anchor.maxX,
                    controls: self.preferences.itemControls,
                    displayXRange: self.anchorDisplayXRange
                )
            }
            // Re-capture so the mirror reflects whatever moved. If the bar is open it re-lays-out.
            if let bar = self.floatingBar {
                let anchorX = self.anchorFrame?.minX ?? 1115
                await bar.captureAndCache(anchorMinX: anchorX, allowFallback: false)
                if bar.hasIncompleteGlyphs {
                    try? await Task.sleep(for: .milliseconds(220))
                    await bar.captureAndCache(anchorMinX: anchorX, allowFallback: true)
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func anchorClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showAnchorMenu()
            return
        }
        if preferences.useFloatingBar, floatingBar != nil {
            toggleFloatingBar()
        } else {
            toggleHidden()
        }
    }

    /// Pops the anchor's right-click menu (Settings…, Quit). Built on demand and attached to the
    /// status item only for the duration of the click, so a normal left-click still routes to
    /// `anchorClicked` (a permanently-assigned `menu` would swallow left-clicks too).
    private func showAnchorMenu() {
        guard let anchor = anchorItem else { return }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Bar Keeper's Friend", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        anchor.menu = menu
        anchor.button?.performClick(nil)
        anchor.menu = nil // restore left-click action handling
    }

    @objc private func menuOpenSettings() { onOpenSettings?() }
    @objc private func menuQuit() { onQuit?() }

    /// Shows or hides the floating bar from the cached mirror — instantly, with no capture on
    /// the open path. The cache is kept current out-of-band (launch capture + on screen change).
    ///
    /// `persistUntilToggled` is passed through to the bar's auto-dismiss policy: a keyboard toggle
    /// (⌥⌘B) sets it so an opened bar the user never mouses onto stays put until they toggle again;
    /// pointer-driven opens (anchor click, hover) leave it false so an abandoned bar tidies away.
    private func toggleFloatingBar(persistUntilToggled: Bool = false) {
        guard let bar = floatingBar else { return }
        // Any deliberate user interaction with the bar cancels a pending auto-rehide. Otherwise a
        // timer armed by an earlier activation (default 15s) could fire later and yank shut a bar
        // the user just re-opened, or collapse a section they re-engaged — a spontaneous-vanish
        // bug. toggleFloatingBar is the single funnel for anchor clicks and the hotkey, so one
        // cancel here covers every re-open path.
        autoRehideWorkItem?.cancel()
        autoRehideWorkItem = nil
        // A click during the one-time launch capture: don't eat it (that felt broken), and don't
        // touch the divider/state machine (the capture is mid-reveal and owns it — collapsing now
        // would yank the section out from under the screenshot). Just show the panel; it renders a
        // "Preparing…" spinner from the not-yet-populated cache, and the warm-up re-lays-it-out
        // with the real glyphs the moment capture lands, then collapses the divider itself.
        if captureInFlight {
            if bar.isVisible {
                bar.hide()
            } else {
                let frame = anchorFrame ?? CGRect(x: (NSScreen.main?.frame.maxX ?? 1440) - 32, y: 0, width: 32, height: 24)
                Task { @MainActor in await bar.show(anchorMinX: frame.minX, anchorRightX: frame.maxX, autoDismissWhenAbandoned: !persistUntilToggled) }
            }
            return
        }
        // Refresh now that the windows are fully realized, so our own items are excluded.
        publishControlItemWindowIDs()
        // If a prior activation left the section revealed in the menu bar, the anchor should
        // tidy it back up (re-hide) rather than show a redundant panel.
        if stateMachine.visibility(of: .hidden) == .shown {
            _ = stateMachine.apply(.hide(.hidden))
            bar.hide()
            setHidden(collapsed: true)
            return
        }
        if bar.isVisible {
            bar.hide()
            return
        }
        // Show INSTANTLY from the cached mirror — never capture on the open path. A capture is
        // reveal + settle + up to 6 screenshot retries (~2s), which made every open lag. The
        // cache is kept current out-of-band: the one-time launch capture, and a re-capture on
        // each screen-parameter change. So opening is just "lay out the cached icons + show".
        let frame = anchorFrame ?? CGRect(x: (NSScreen.main?.frame.maxX ?? 1440) - 32, y: 0, width: 32, height: 24)
        Task { @MainActor in
            await bar.show(anchorMinX: frame.minX, anchorRightX: frame.maxX, autoDismissWhenAbandoned: !persistUntilToggled)
        }
        // If the live menu bar gained/lost items since the cache was built (an app added or
        // removed its status item while we were idle), refresh in the BACKGROUND. The bar is
        // already showing from cache; the refresh updates it for next time without lagging this
        // open. The staleness check is a cheap CGWindowList enumeration (no screenshot), done
        // inside the controller where the window server lives. No-op while the section is in use.
        if bar.cachedMirrorIsStale(anchorMinX: frame.minX) {
            refreshFloatingBarCache()
        }
    }

    /// Toggles the floating bar exactly as a left anchor click would. Used by the SIGUSR2
    /// diagnostics trigger so the bar can be shown for a screenshot without clicking the menu
    /// bar. No-op outside floating-bar mode.
    func toggleFloatingBarForDiagnostics() {
        guard preferences.useFloatingBar, floatingBar != nil else { return }
        toggleFloatingBar()
    }

    /// Toggles the floating bar from a global hotkey. Routes through the same path as an anchor
    /// click in floating-bar mode; in reflow mode it toggles the hidden section instead, so the
    /// shortcut does the right thing either way. A keypress *toggling* is expected behavior.
    func toggleFromShortcut() {
        if preferences.useFloatingBar, floatingBar != nil {
            // A keyboard toggle is deliberate: keep the bar open until the user presses the
            // shortcut again (or interacts with it), rather than auto-dismissing a bar they never
            // moused onto — a vanishing bar would make the shortcut feel like it did nothing.
            toggleFloatingBar(persistUntilToggled: true)
        } else {
            toggleHidden()
        }
    }

    /// The anchor's current global (AppKit, bottom-left origin) frame, for anyone aligning UI to
    /// the anchor. Nil until the status item's window is realized.
    var anchorWindowFrame: CGRect? { anchorFrame }

    @objc private func dividerClicked(_ sender: NSStatusBarButton) {
        anchorClicked(sender)
    }

    func toggleHidden() {
        let intents = stateMachine.apply(.toggle(.hidden))
        enact(intents)
        scheduleAutoRehideIfNeeded()
    }

    /// Reveals the hidden section so a real item can be clicked on-screen. Updates the state
    /// machine to `.shown` and returns after a short settle delay.
    func revealForActivation() async {
        _ = stateMachine.apply(.show(.hidden))
        setHidden(collapsed: false)
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func enact(_ intents: [HideShowStateMachine.Intent]) {
        for intent in intents where intent.section == .hidden {
            setHidden(collapsed: intent.visibility == .collapsed)
        }
    }

    /// Expands the divider to hide the section, or restores natural width to reveal it. The
    /// divider has no image, so its natural (variable) length is effectively zero width — it
    /// leaves no visible gap or marker in the menu bar when the section is revealed.
    private func setHidden(collapsed: Bool) {
        guard let divider = hiddenDivider else { return }
        if collapsed {
            divider.length = ControlItemLength.expanded(forScreenWidth: menuBarScreenWidth)
        } else {
            divider.length = NSStatusItem.variableLength
        }
    }

    /// Width of the display that actually hosts the menu bar (where our status items live), NOT
    /// `NSScreen.main` — on a multi-display rig the menu-bar screen can be far wider (e.g. a
    /// 5120pt Pro Display XDR while main is a 1440pt laptop). Sizing the expanded divider from
    /// the wrong, narrower screen left hidden items un-pushed past the edge, so hiding silently
    /// failed. Prefer the anchor's own screen; fall back to main, then a safe default.
    private var menuBarScreenWidth: CGFloat {
        return (anchorScreen ?? NSScreen.main)?.frame.width ?? 1440
    }

    /// The display the anchor (and therefore the live menu bar we manage) currently sits on.
    /// Prefer the status-item window's own screen; fall back to whichever screen the anchor frame
    /// intersects, then main. On a multi-display rig the menu-bar display can change at runtime.
    private var anchorScreen: NSScreen? {
        anchorItem?.button?.window?.screen
            ?? anchorFrame.flatMap { f in NSScreen.screens.first { $0.frame.intersects(f) } }
    }

    /// The global x-range of the anchor's display, used to scope per-item moves to that display.
    /// AppKit and CoreGraphics share the same x-axis (only y is flipped), so the screen frame's
    /// x-range is valid in the CG-global space the snapshots' frames use. `nil` when the anchor's
    /// screen can't be resolved yet, which disables the filter (single-display behavior).
    private var anchorDisplayXRange: ClosedRange<CGFloat>? {
        guard let frame = anchorScreen?.frame else { return nil }
        return frame.minX...frame.maxX
    }

    private func applyDividerVisibility() {
        // Start collapsed (hidden section tucked away).
        setHidden(collapsed: stateMachine.visibility(of: .hidden) == .collapsed)
    }

    private func scheduleAutoRehideIfNeeded() {
        autoRehideWorkItem?.cancel()
        guard preferences.autoRehide,
              stateMachine.visibility(of: .hidden) == .shown else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.enact(self.stateMachine.apply(.autoRehide))
        }
        autoRehideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.autoRehideDelay, execute: work)
    }

    /// Arms the user-configured auto-rehide after a floating-bar activation revealed the
    /// section. After the delay it collapses the hidden section and dismisses the mirror
    /// panel. No-op when the user disabled auto-rehide; re-arming cancels any prior timer.
    ///
    /// This is the floating-bar counterpart to `scheduleAutoRehideIfNeeded` (which only runs
    /// in the legacy reflow-into-menu-bar mode via `toggleHidden`).
    func scheduleAutoRehideAfterActivation() {
        autoRehideWorkItem?.cancel()
        guard preferences.autoRehide else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Defensive: only tear down if the section is still in its post-activation revealed
            // state. If the user already re-engaged (re-opened the bar, which sets state back to
            // a fresh show), this stale timer must NOT hide the panel out from under them.
            // toggleFloatingBar also cancels this timer on re-interaction; the guard is belt-and-
            // suspenders for any path that doesn't.
            guard self.stateMachine.visibility(of: .hidden) == .shown else { return }
            self.enact(self.stateMachine.apply(.autoRehide))
            self.floatingBar?.hide()
        }
        autoRehideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.autoRehideDelay, execute: work)
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        // The menu bar geometry changed (display added/removed, resolution change). If the
        // section is in active use (panel showing, or an activation revealed it for an open
        // menu), don't disturb it — collapsing or revealing now would slam an open menu shut or
        // show the real items behind the panel as duplicates. Refresh opportunistically only
        // when idle.
        guard !sectionInUse else { return }
        enact(stateMachine.apply(.screenParametersChanged))
        // The state-machine transition above is a no-op when already `.collapsed` (which it
        // almost always is here, since `.shown` implies sectionInUse), so it emits no intents and
        // the divider is never resized. But the new screen may be a different WIDTH, and the
        // expanded length is screen-width-derived — a stale (too-narrow) divider lets hidden items
        // leak back onto the menu bar. So re-apply the physical width unconditionally for the
        // current collapsed state. This also fixes reflow mode, which used to return before any
        // resize because the `useFloatingBar` guard below came first.
        if stateMachine.visibility(of: .hidden) == .collapsed {
            setHidden(collapsed: true)
        }
        guard preferences.useFloatingBar else { return }
        // The menu-bar display may have changed (e.g. the anchor jumped to a newly-attached
        // screen). The per-item Hidden intent was realized on the OLD display's items; re-apply it
        // so the items on the now-current display land on the right side of the anchor. No-op when
        // nothing is marked hidden. The planner is display-scoped (see `anchorDisplayXRange`), so
        // this only touches the active display's items, never the other display's mirror copies.
        if !preferences.itemControls.hiddenInMenuBar.isEmpty {
            reconcileHiddenItems()
        } else {
            refreshFloatingBarCache()
        }
    }

    /// Reveals the section, re-captures the now-on-screen items into the floating bar cache,
    /// then hides them again. Used after menu bar changes so the mirror stays current. A no-op
    /// while the section is in active use, so it never disrupts an open menu or the visible
    /// panel; the next idle refresh (or panel open) picks up the change.
    func refreshFloatingBarCache() {
        guard preferences.useFloatingBar, let bar = floatingBar, !sectionInUse else { return }
        // Reveal → capture → restore, serialized behind any in-flight capture (e.g. the launch
        // one) so they can't fight over the divider. captureAndCache retries internally until
        // the revealed glyphs have composited in. Not a force-collapse: restore to state so we
        // don't fight an activation that begins while we capture.
        runCaptureSequence(forceCollapseAfter: false) { [weak self] in
            await bar.captureAndCache(anchorMinX: self?.anchorFrame?.minX ?? 1115)
        }
    }

    // MARK: - Images

    private static func anchorImage() -> NSImage? {
        NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Bar Keeper's Friend")
    }
}
