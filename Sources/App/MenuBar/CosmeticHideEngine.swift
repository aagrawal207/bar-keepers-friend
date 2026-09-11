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
    var onPlacementStatusChanged: (() -> Void)?
    var onPlacementCompleted: (() async -> Void)?
    private(set) var placementInProgress = false
    private(set) var placementMessage: String?
    private(set) var placementFailed = false
    private(set) var placementPending = false
    private(set) var placementTask: Task<Void, Never>?
    private var placementRequestID = 0
    private let controlWindowIDsProvider: (() -> (anchor: CGWindowID, divider: CGWindowID)?)?
    private let setDividerCollapsed: ((Bool) -> Void)?
    private var activationOwnsSection = false

    private var anchorItem: NSStatusItem?
    private var hiddenDivider: NSStatusItem?

    private(set) var stateMachine: HideShowStateMachine
    private var preferences: Preferences
    /// Callback to persist preference changes the engine itself makes. CURRENTLY UNUSED: the engine
    /// mutates no persisted preference on its own — it rewrites the control-item slots directly under
    /// AppKit's `UserDefaults` keys (`repairControlItemOrderIfNeeded`), and all user-facing changes
    /// flow the other way (Settings → `apply(preferences:)`). Retained as a wired seam so a future
    /// engine-originated change (e.g. persisting `controlItemPositions`) has somewhere to report to
    /// without re-threading the call site; see the note on `Preferences.controlItemPositions`.
    private let onPreferencesChanged: (Preferences) -> Void

    private var autoRehideWorkItem: DispatchWorkItem?

    /// Pending escalating warm-up retries scheduled by `warmUpFloatingBarCache`, one per
    /// `WarmUpRetrySchedule` offset. They bridge the COLD-LAUNCH glyph gap: on a cold launch the
    /// menu-bar glyphs don't composite into the capturable image for ~tens of seconds, long after
    /// the launch warm-up (and its in-loop retries) have all finished at ~1.5s capturing 0 glyphs.
    /// Each fires one more `runCaptureSequence` pass, but only WHILE glyphs are still incomplete —
    /// each re-checks `hasIncompleteGlyphs` when it fires and self-cancels the rest once the set is
    /// complete. Cancelled wholesale (`cancelWarmUpRetries`) when the user opens the bar, a reconcile
    /// runs, the app is paused, the bar is disabled, or on uninstall — so they never fight a
    /// user-driven open or multiply the privacy-indicator flashes beyond the bounded schedule.
    private var warmUpRetryWorkItems: [DispatchWorkItem] = []

    /// Coalesces bursts of `didChangeScreenParametersNotification`. macOS posts that notification
    /// multiple times for a single user-visible change (display sleep/wake, mode negotiation, Stage
    /// Manager, an external display handshaking), and each one would otherwise drive a full
    /// reveal→capture→hide — a storm of full-display screenshots that lights the Screen Recording
    /// indicator and repeatedly disturbs the menu bar. We debounce: schedule one refresh and let
    /// later notifications in the burst reset the timer, so only the settled state is captured.
    private var screenChangeWorkItem: DispatchWorkItem?
    /// How long to wait for a burst of screen-parameter notifications to settle before refreshing.
    private static let screenChangeDebounce: TimeInterval = 0.5

    /// Serializes reveal → capture → hide sequences. Both the launch capture and any refresh
    /// (menu-bar change, anchor open) drive the shared divider, so running two concurrently
    /// makes them fight over its collapsed state across `await` points — the launch capture
    /// could hide the section out from under a refresh mid-capture, yielding 0 glyphs. Chaining
    /// each sequence onto the previous one guarantees they run one at a time.
    private(set) var captureChain: Task<Void, Never> = Task {}

    /// Only the latest enqueued sequence may restore the divider. Cancellation also invalidates
    /// this ownership, so late completion cannot override Pause or a successor.
    private var latestCaptureEpoch = 0

    /// Tracks transient reveals so a user toggle does not collapse the divider during capture.
    private var captureInFlightCount = 0

    /// Whether any capture sequence is revealing/capturing. Lets the anchor click ignore the
    /// transient reveal (the divider is physically open for capture but not for the user), so a
    /// click during the launch capture window can't misread that state and eat the toggle.
    var captureInFlight: Bool { captureInFlightCount > 0 }

    /// True while a reconcile (the physical synthesized move of items across the anchor) is running,
    /// so the status line can show "Working…" — more specific than the "Collecting…" a plain
    /// capture shows. A counter, like `captureInFlightCount`, in case two reconciles ever overlap.
    private var reconcileInFlightCount = 0

    /// Whether the user has paused the app from the anchor menu. While paused the engine reveals
    /// hidden items in place and ignores every hide/reveal/reconcile/auto-rehide/hotkey trigger, so
    /// the menu bar behaves like a vanilla one. SESSION-ONLY (not persisted): pause is an "I'm
    /// looking for something right now" mode, and a silently-paused app after reboot would be a
    /// worse surprise than just starting un-paused. Also keeps the change off the launch path.
    private var isPaused = false

    /// A plain-language summary of what the engine is doing right now, for the anchor menu's status
    /// line. Derived in Core (`AppStatus.derive`) from the engine's live counters so the label is
    /// unit-tested rather than hand-assembled here. `updateAvailable` is wired false until Sparkle
    /// lands (see "Features not yet built").
    var currentStatus: AppStatus {
        AppStatus.derive(
            paused: isPaused,
            moving: reconcileInFlightCount > 0,
            capturing: captureInFlightCount > 0,
            updateAvailable: false
        )
    }

    /// Whether the app is currently paused (for the menu's checkmark).
    var paused: Bool { isPaused }

    /// Deadline for the predecessor race, not a hard timeout: `awaitBounded` still joins its waiter.
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
    func runCaptureSequence(
        forceCollapseAfter: Bool,
        _ body: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        guard !isPaused else { return Task {} }
        let previous = captureChain
        // Stamp this sequence with the next epoch (synchronously, before the task suspends), so its
        // tail can tell whether it's still the latest sequence when its body returns.
        latestCaptureEpoch += 1
        let epoch = latestCaptureEpoch
        let task = Task { @MainActor in
            // Cancelling the tail must also reach an in-flight predecessor, including when
            // this task was cancelled before it started running.
            await withTaskCancellationHandler {
                await awaitBounded(previous, seconds: Self.captureSequenceTimeout)
            } onCancel: {
                previous.cancel()
            }
            guard !Task.isCancelled, !isPaused else { return }
            captureInFlightCount += 1
            defer { captureInFlightCount -= 1 }
            // Tell the bar which display's menu-bar top to measure item plausibility against, so a
            // display stacked above/below the primary isn't enumerated as "all items below the bar".
            // Every capture path funnels through here, so this one assignment covers them all.
            floatingBar?.displayMenuBarTop = anchorDisplayMenuBarTop
            setHidden(collapsed: false)
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, !isPaused else { return }
            // Run the capture inline (NOT in a nested Task — hopping main-actor tasks here
            // shifted capture timing and produced wallpaper-only crops).
            await body()
            // A late completion must not override the state established by Pause or newer work.
            guard !Task.isCancelled, !isPaused, epoch == latestCaptureEpoch else { return }
            if forceCollapseAfter && !activationOwnsSection {
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

    private func cancelCaptureSequences() {
        latestCaptureEpoch += 1
        captureChain.cancel()
        cancelWarmUpRetries()
        if placementInProgress {
            placementPending = true
            updatePlacementStatus(applying: false)
        }
        DebugLog.log("capture: cancelled queued and in-flight sequences")
    }

    /// The group joins its task-value waiter even if the timer wins; this is not a hard timeout.
    /// Allowing overlap requires isolating native move/capture side effects first (see AGENTS.md).
    private func awaitBounded(_ task: Task<Void, Never>, seconds: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    init(
        preferences: Preferences,
        controlWindowIDs: (() -> (anchor: CGWindowID, divider: CGWindowID)?)? = nil,
        setDividerCollapsed: ((Bool) -> Void)? = nil,
        onPreferencesChanged: @escaping (Preferences) -> Void
    ) {
        self.preferences = preferences
        self.controlWindowIDsProvider = controlWindowIDs
        self.setDividerCollapsed = setDividerCollapsed
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
            guard let self, !self.isPaused, !Task.isCancelled else { return }
            self.enact(self.stateMachine.apply(.hide(.hidden)))
            self.resumePendingPlacement()
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
        if let controls = placementControlIDs {
            ids.formUnion([controls.anchor, controls.divider])
            floatingBar?.hiddenDividerWindowID = controls.divider
        }
        floatingBar?.controlItemWindowIDs = ids
        // Keep the bar's display-top current for the non-capture paths too (e.g. the pre-show
        // staleness check), so its item enumeration measures against the anchor's display.
        floatingBar?.displayMenuBarTop = anchorDisplayMenuBarTop
    }

    /// The anchor window's global frame, used to align the floating bar and to determine
    /// which items count as "hidden" (those left of the anchor).
    private var anchorFrame: CGRect? {
        anchorItem?.button?.window?.frame
    }

    private var placementControlIDs: (anchor: CGWindowID, divider: CGWindowID)? {
        if let controlWindowIDsProvider { return controlWindowIDsProvider() }
        guard let anchor = anchorItem?.button?.window?.windowNumber,
              let divider = hiddenDivider?.button?.window?.windowNumber,
              let anchorID = WindowIDConversion.cgWindowID(fromWindowNumber: anchor),
              let dividerID = WindowIDConversion.cgWindowID(fromWindowNumber: divider) else {
            // Tahoe's status-item proxy may expose frames but no usable AppKit window number.
            return hiddenItemController?.controlWindowIDs(
                displayXRange: anchorDisplayXRange, displayMenuBarTop: anchorDisplayMenuBarTop
            )
        }
        return (anchorID, dividerID)
    }

    func uninstall() {
        autoRehideWorkItem?.cancel()
        screenChangeWorkItem?.cancel()
        cancelCaptureSequences()
        floatingBar?.hide()
        if let anchor = anchorItem { NSStatusBar.system.removeStatusItem(anchor) }
        if let divider = hiddenDivider { NSStatusBar.system.removeStatusItem(divider) }
        anchorItem = nil
        hiddenDivider = nil
        placementPending = false
        updatePlacementStatus(applying: false)
    }

    // MARK: - Preferences

    func apply(preferences: Preferences) {
        let wasFloatingBar = self.preferences.useFloatingBar
        let previousControls = self.preferences.itemControls
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
                cancelCaptureSequences()
                floatingBar?.hide()
                applyDividerVisibility()
                resumePendingPlacement()
            }
        }

        // If the per-item Hidden intent changed (the user toggled Shown/Hidden in Settings),
        // physically move the affected items to the correct side of the anchor and refresh the
        // mirror. Only when it actually changed, so an unrelated settings edit doesn't drag icons.
        if preferences.itemControls.hiddenInMenuBar != previousControls.hiddenInMenuBar
            || preferences.itemControls.shownInMenuBar != previousControls.shownInMenuBar {
            reconcileHiddenItems(userInitiated: true)
        }
    }

    /// Runs the same two-pass reveal→capture→hide warm-up that `install()` uses, so the floating
    /// bar's cache is pre-populated (and `hasCapturedOnce` set) before the first open. Shared by
    /// launch and the Settings enable-at-runtime path.
    private func warmUpFloatingBarCache() {
        guard !isPaused, preferences.useFloatingBar, floatingBar != nil else { return }
        runCaptureSequence(forceCollapseAfter: true) { [weak self] in
            guard let self, let bar = self.floatingBar else { return }
            let anchorX = self.anchorFrame?.minX ?? 1115
            await bar.captureAndCache(anchorMinX: anchorX, allowFallback: false)
            if !Task.isCancelled, bar.needsCapture {
                try? await Task.sleep(for: .milliseconds(220))
                await bar.captureAndCache(anchorMinX: anchorX, allowFallback: true)
            }
        }
        // Bridge the cold-launch glyph gap. The pass above (like all the warm-up + in-loop retries)
        // finishes within ~1.5s; on a cold launch the menu-bar glyphs haven't composited into the
        // capturable image yet, so it lands app-icon fallbacks. Schedule a SMALL, BOUNDED set of
        // escalating retries that each run one more capture pass over the window where the
        // compositor typically warms up — but only while glyphs are still incomplete.
        scheduleWarmUpRetries()
    }

    /// Arms the escalating warm-up retries (`WarmUpRetrySchedule`). Each is a one-shot timer that,
    /// when it fires, runs ONE more `runCaptureSequence` warm-up pass — but only if the bar still
    /// has incomplete glyphs and isn't in active use. The moment a pass completes the set
    /// (`hasIncompleteGlyphs == false`) the remaining timers cancel themselves, so a fast machine
    /// pays for at most one or two extra captures and a slow one stops as soon as glyphs land. The
    /// whole set is bounded by the schedule (at most `WarmUpRetrySchedule.count` extra captures, so
    /// at most that many extra privacy-indicator flashes).
    ///
    /// Always starts from a clean slate (`cancelWarmUpRetries`) so a re-arm (e.g. the Settings
    /// enable-at-runtime path calling `warmUpFloatingBarCache` again) can't stack two sets of timers.
    private func scheduleWarmUpRetries() {
        cancelWarmUpRetries()
        guard !isPaused, !Task.isCancelled, preferences.useFloatingBar, floatingBar != nil else { return }
        for offsetMs in WarmUpRetrySchedule.offsetsMs {
            let work = DispatchWorkItem { [weak self] in self?.fireWarmUpRetry() }
            warmUpRetryWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs), execute: work)
        }
    }

    /// One escalating warm-up retry firing. No-op (and cancels the rest) once glyphs are complete,
    /// the bar is disabled, the app is paused, or the section is in active use — so it never fights
    /// a user-driven open / an open menu, and self-cancels the instant the work is done.
    private func fireWarmUpRetry() {
        guard preferences.useFloatingBar, let bar = floatingBar, !isPaused else {
            cancelWarmUpRetries()
            return
        }
        // Glyphs are complete — nothing left to bridge. Drop the remaining timers.
        guard bar.needsCapture else {
            cancelWarmUpRetries()
            return
        }
        // The section is in active use (panel open, or an activation revealed it for an open menu):
        // don't disturb it. Leave the LATER timers armed — by the time one of them fires the user
        // may be done, glyphs may still need filling, and a calmer moment can pick it up.
        guard !sectionInUse else { return }
        // Re-use the very same serialized warm-up pass as launch (clean pass, then a
        // fallback-allowing reconcile only if still incomplete), so it rides the captureChain/epoch
        // machinery exactly like every other capture and can't race a refresh or a launch pass.
        runCaptureSequence(forceCollapseAfter: true) { [weak self] in
            guard let self, let bar = self.floatingBar else { return }
            let anchorX = self.anchorFrame?.minX ?? 1115
            await bar.captureAndCache(anchorMinX: anchorX, allowFallback: false)
            if !Task.isCancelled, bar.needsCapture {
                try? await Task.sleep(for: .milliseconds(220))
                await bar.captureAndCache(anchorMinX: anchorX, allowFallback: true)
            }
        }
    }

    /// Cancels every pending warm-up retry. Called when the set completes, when the user opens the
    /// bar / a reconcile takes over the divider, when the app is paused or the bar disabled, and on
    /// uninstall — so a stale timer never drives a capture after warm-up is moot.
    private func cancelWarmUpRetries() {
        warmUpRetryWorkItems.forEach { $0.cancel() }
        warmUpRetryWorkItems.removeAll()
    }

    /// Explicit Settings commands take ownership of the section; background requests wait for
    /// dismissal or permission recovery. Superseded commands never publish stale completion.
    func reconcileHiddenItems(userInitiated: Bool = false) {
        placementRequestID += 1
        let requestID = placementRequestID
        let wasApplying = placementInProgress
        placementTask?.cancel()
        guard !preferences.itemControls.hiddenInMenuBar.isEmpty || !preferences.itemControls.shownInMenuBar.isEmpty else {
            placementPending = false
            updatePlacementStatus(applying: false)
            guard wasApplying else { return }
            // A cancelled reveal still needs an owner to restore it when no replacement is queued.
            let previous = captureChain
            latestCaptureEpoch += 1
            let epoch = latestCaptureEpoch
            let restore = Task { @MainActor in
                await withTaskCancellationHandler {
                    await previous.value
                } onCancel: {
                    previous.cancel()
                }
                guard !Task.isCancelled, !self.isPaused,
                      requestID == self.placementRequestID, epoch == self.latestCaptureEpoch else { return }
                self.setHidden(collapsed: self.stateMachine.visibility(of: .hidden) == .collapsed)
            }
            captureChain = restore
            placementTask = restore
            return
        }
        placementPending = true
        guard !isPaused else {
            updatePlacementStatus(applying: false, message: "Changes will apply when Bar Keeper's Friend resumes.")
            return
        }
        if userInitiated {
            activationOwnsSection = false
            floatingBar?.hide()
        }
        guard !activationOwnsSection else {
            updatePlacementStatus(applying: false, message: "Changes will apply after the open menu is dismissed.")
            return
        }
        guard let controller = hiddenItemController else {
            updatePlacementStatus(applying: false, message: "Menu bar controls are not available yet.", failed: true)
            return
        }
        guard !(floatingBar?.isVisible ?? false) else {
            updatePlacementStatus(applying: false, message: "Changes will apply when the floating bar closes.")
            return
        }
        guard controller.canMoveItems else {
            updatePlacementStatus(applying: false, message: "Allow Accessibility in System Settings to move menu bar items.", failed: true)
            if userInitiated { onNeedsAccessibilityForMove?() }
            return
        }
        placementPending = false
        autoRehideWorkItem?.cancel()
        autoRehideWorkItem = nil
        cancelWarmUpRetries()
        updatePlacementStatus(applying: true)
        DebugLog.log("placement: queued request=\(requestID) hidden=\(preferences.itemControls.hiddenInMenuBar.count) shown=\(preferences.itemControls.shownInMenuBar.count)")

        placementTask = runCaptureSequence(forceCollapseAfter: false) { [weak self] in
            guard let self, !Task.isCancelled, requestID == self.placementRequestID else { return }
            self.publishControlItemWindowIDs()
            controller.controlItemWindowIDs = self.floatingBar?.controlItemWindowIDs ?? []
            let result: HiddenItemController.ReconcileResult
            if let controls = self.placementControlIDs {
                DebugLog.log("placement: starting request=\(requestID) anchorWindow=\(controls.anchor) dividerWindow=\(controls.divider)")
                self.reconcileInFlightCount += 1
                defer { self.reconcileInFlightCount -= 1 }
                result = await controller.reconcile(
                    anchorWindowID: controls.anchor,
                    dividerWindowID: controls.divider,
                    controls: self.preferences.itemControls,
                    displayXRange: self.anchorDisplayXRange,
                    displayMenuBarTop: self.anchorDisplayMenuBarTop
                )
            } else {
                result = HiddenItemController.ReconcileResult(observationFailed: true)
            }
            guard !Task.isCancelled, requestID == self.placementRequestID else { return }
            self.placementPending = result.observationFailed
            // Invalid control geometry must not let an expanded divider hide the anchor itself.
            _ = self.stateMachine.apply(result.observationFailed ? .show(.hidden) : .hide(.hidden))
            if !result.observationFailed, self.preferences.useFloatingBar, let bar = self.floatingBar {
                let anchorX = self.anchorFrame?.minX ?? 1115
                await bar.captureAndCache(anchorMinX: anchorX, allowFallback: false)
                if !Task.isCancelled, bar.needsCapture {
                    try? await Task.sleep(for: .milliseconds(220))
                    await bar.captureAndCache(anchorMinX: anchorX, allowFallback: true)
                }
                if !Task.isCancelled, bar.needsCapture {
                    self.scheduleWarmUpRetries()
                }
            }
            guard !Task.isCancelled, requestID == self.placementRequestID else { return }
            await self.onPlacementCompleted?()
            guard !Task.isCancelled, requestID == self.placementRequestID else { return }
            if result.observationFailed {
                self.updatePlacementStatus(applying: false, message: "Couldn't read a stable menu bar layout. Items have been left revealed; try again.", failed: true)
            } else if !result.failed.isEmpty {
                self.updatePlacementStatus(applying: false, message: "Couldn't move \(result.failed.count) item(s). Choose Shown or Hidden to retry.", failed: true)
            } else {
                self.updatePlacementStatus(applying: false)
            }
        }
    }

    func resumePendingPlacement() {
        guard placementPending, !isPaused, !activationOwnsSection, !(floatingBar?.isVisible ?? false),
              hiddenItemController?.canMoveItems == true else { return }
        reconcileHiddenItems()
    }

    private func updatePlacementStatus(applying: Bool, message: String? = nil, failed: Bool = false) {
        placementInProgress = applying
        placementMessage = message
        placementFailed = failed
        DebugLog.log("placement: applying=\(applying) pending=\(placementPending) failed=\(failed)")
        onPlacementStatusChanged?()
    }

    // MARK: - Actions

    @objc private func anchorClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showAnchorMenu()
            return
        }
        // While paused the section is revealed in place; a left-click does nothing (the right-click
        // menu, with the Pause toggle, is always available above).
        guard !isPaused else { return }
        if preferences.useFloatingBar, floatingBar != nil {
            toggleFloatingBar()
        } else {
            toggleHidden()
        }
    }

    /// Pops the anchor's right-click menu. Built on demand and attached to the status item only for
    /// the duration of the click, so a normal left-click still routes to `anchorClicked` (a
    /// permanently-assigned `menu` would swallow left-clicks too).
    ///
    /// Layout: an app-identity header (name + version) and a live status line (both disabled, so
    /// they read as information, not actions), then the actions — Settings, About — and Quit.
    private func showAnchorMenu() {
        guard let anchor = anchorItem else { return }
        let menu = NSMenu()
        // We manage each item's enabled state by hand. With AppKit's default auto-validation on,
        // every action item would be silently DISABLED: this engine isn't an NSObject subclass, so
        // AppKit can't query it via respondsToSelector:/validateMenuItem: to confirm it handles the
        // action, and a disabled item eats the click ("nothing happens"). The status-bar buttons
        // dodge this because NSControl dispatches the @objc selector directly; menu items don't.
        // Turning auto-validation off keeps the action items enabled, and dispatch then runs over the
        // same NSApp.sendAction path the buttons already use. The informational rows below stay
        // disabled because we set isEnabled = false on them explicitly.
        menu.autoenablesItems = false

        // Header: app name + version, as a disabled (informational) row.
        let header = NSMenuItem(title: Self.appName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let version = NSMenuItem(title: "Version \(Self.appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        // Live status line — what the engine is doing right now (Ready / Working / Collecting).
        menu.addItem(.separator())
        let status = NSMenuItem(title: "Status: \(currentStatus.label)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        // Pause: a checkable mode toggle. Checked while paused; reveals items in place and stops
        // all automated hide/reveal/move until toggled off.
        let pause = NSMenuItem(title: "Pause Bar Keeper's Friend", action: #selector(menuTogglePause), keyEquivalent: "")
        pause.target = self
        pause.state = isPaused ? .on : .off
        menu.addItem(pause)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About \(Self.appName)", action: #selector(menuShowAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(Self.appName)", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        anchor.menu = menu
        anchor.button?.performClick(nil)
        anchor.menu = nil // restore left-click action handling
    }

    /// The app's display name, falling back to the product name if Info.plist lacks it.
    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Bar Keeper's Friend"
    }

    /// The display version (short + build, e.g. "0.1.0 (1)"), composed by the same pure
    /// `AppInfo.displayVersion` the Settings header uses — so the menu and Settings never disagree
    /// about the version (they did briefly: this read short-only while the header showed short+build).
    private static var appVersion: String {
        AppInfo.displayVersion(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    @objc private func menuOpenSettings() { onOpenSettings?() }
    @objc private func menuQuit() { onQuit?() }

    /// Pause reveals items and cancels automation; resume restores saved intent and unfinished
    /// icon collection. An already-posted native gesture finishes before cancellation takes effect.
    @objc func menuTogglePause() {
        isPaused.toggle()
        autoRehideWorkItem?.cancel()
        autoRehideWorkItem = nil
        if isPaused {
            activationOwnsSection = false
            // Pausing stops all automated activity; the cold-launch warm-up retries are exactly that,
            // so drop them rather than let one fire and no-op (or flash a reveal) while paused.
            cancelCaptureSequences()
            screenChangeWorkItem?.cancel()
            // Reveal in place: hide the mirror panel if open, drive the state machine to shown so no
            // stray refresh re-collapses it, and un-tuck the divider so left-of-anchor items return.
            floatingBar?.hide()
            _ = stateMachine.apply(.show(.hidden))
            setHidden(collapsed: false)
            updatePlacementStatus(applying: false, message: "Changes will apply when Bar Keeper's Friend resumes.")
        } else {
            // Back to baseline: collapse the section again, then re-apply the saved per-item Hidden
            // intent (a Settings toggle or display change made WHILE paused recorded intent but was
            // not moved). reconcileHiddenItems now passes its `!isPaused` guard and no-ops cheaply
            // when there's nothing hidden or the mover isn't wired.
            _ = stateMachine.apply(.hide(.hidden))
            setHidden(collapsed: true)
            if let bar = floatingBar, bar.needsCapture {
                warmUpFloatingBarCache()
            }
            reconcileHiddenItems()
        }
    }

    /// Shows the standard AppKit About panel. The agent app has no menu bar of its own, so we
    /// surface it from here. `orderFrontStandardAboutPanel` reads name/version/copyright from
    /// Info.plist; activate first so the panel comes forward (an accessory app isn't frontmost).
    @objc private func menuShowAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Shows or hides the floating bar from the cached mirror — instantly, with no capture on
    /// the open path. The cache is kept current out-of-band (launch capture + on screen change).
    ///
    /// `persistUntilToggled` is passed through to the bar's auto-dismiss policy: a keyboard toggle
    /// (⌥⌘B) sets it so an opened bar the user never mouses onto stays put until they toggle again;
    /// pointer-driven opens (anchor click, hover) leave it false so an abandoned bar tidies away.
    private func toggleFloatingBar(persistUntilToggled: Bool = false) {
        guard !isPaused, let bar = floatingBar else { return }
        // Any deliberate user interaction with the bar cancels a pending auto-rehide. Otherwise a
        // timer armed by an earlier activation (default 15s) could fire later and yank shut a bar
        // the user just re-opened, or collapse a section they re-engaged — a spontaneous-vanish
        // bug. toggleFloatingBar is the single funnel for anchor clicks and the hotkey, so one
        // cancel here covers every re-open path.
        autoRehideWorkItem?.cancel()
        autoRehideWorkItem = nil
        // A deliberate user open takes over the bar: drop any pending cold-launch warm-up retries.
        // The user is about to look at (or just toggled) the bar, so a later background warm-up pass
        // must not reveal/re-hide the section or re-lay-it-out under them. If glyphs are still
        // incomplete the on-screen-while-open re-capture and the existing event-driven refreshes
        // remain the backstop, exactly as before this change.
        cancelWarmUpRetries()
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
                Task { @MainActor in
                    guard !self.isPaused else { return }
                    await bar.show(anchorMinX: frame.minX, anchorRightX: frame.maxX, autoDismissWhenAbandoned: !persistUntilToggled)
                }
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
            resumePendingPlacement()
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
            guard !self.isPaused else { return }
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
        // Paused means "stop reacting" — the hotkey is inert until the user un-pauses from the menu.
        guard !isPaused else { return }
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
        guard !isPaused else { return }
        let intents = stateMachine.apply(.toggle(.hidden))
        enact(intents)
        scheduleAutoRehideIfNeeded()
        if stateMachine.visibility(of: .hidden) == .collapsed { resumePendingPlacement() }
    }

    /// Reveals the hidden section so a real item can be clicked on-screen. Updates the state
    /// machine to `.shown` and returns after a short settle delay.
    func revealForActivation() async {
        guard !isPaused, !Task.isCancelled else { return }
        activationOwnsSection = true
        _ = stateMachine.apply(.show(.hidden))
        if placementInProgress {
            placementRequestID += 1
            placementPending = true
            placementTask?.cancel()
            updatePlacementStatus(applying: false, message: "Changes will apply after the open menu is dismissed.")
        }
        // A replacement activation must join the same draining gesture, even after status is idle.
        await placementTask?.value
        guard !Task.isCancelled, !isPaused, activationOwnsSection else { return }
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
        if collapsed { activationOwnsSection = false }
        if let setDividerCollapsed {
            setDividerCollapsed(collapsed)
            return
        }
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

    /// The y-coordinate of the anchor's display's menu-bar top, in CoreGraphics global space
    /// (top-left origin) — the space the snapshots' frames use. The menu bar sits at the top of
    /// each screen; CG-y of a screen's top is `primaryHeight − screenFrame.maxY` (AppKit screen
    /// frames are bottom-left). For the primary, zero-origin display this is 0, matching the
    /// single-display default. Used to make the plausibility filter's top-edge test relative to
    /// the anchor's display, so items on a display stacked above/below the primary aren't rejected.
    private var anchorDisplayMenuBarTop: CGFloat {
        guard let anchorScreen else { return 0 }
        // Resolve against the TRUE primary (the zero-origin display), not `screens.first` — the
        // array order isn't guaranteed to lead with the primary, and trusting it skewed the y-flip
        // on a multi-display rig. The pure helper finds the zero-origin screen and no-ops to 0 if
        // none is present (transient reconfiguration), matching the single-display default.
        return DisplayGeometry.menuBarTopY(
            of: anchorScreen.frame,
            allScreenFrames: NSScreen.screens.map(\.frame)
        )
    }

    private func applyDividerVisibility() {
        // Start collapsed (hidden section tucked away).
        setHidden(collapsed: stateMachine.visibility(of: .hidden) == .collapsed)
    }

    private func scheduleAutoRehideIfNeeded() {
        autoRehideWorkItem?.cancel()
        guard !isPaused, preferences.autoRehide,
              stateMachine.visibility(of: .hidden) == .shown else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPaused else { return }
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
        guard !isPaused, !Task.isCancelled, preferences.autoRehide else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPaused else { return }
            // Defensive: only tear down if the section is still in its post-activation revealed
            // state. If the user already re-engaged (re-opened the bar, which sets state back to
            // a fresh show), this stale timer must NOT hide the panel out from under them.
            // toggleFloatingBar also cancels this timer on re-interaction; the guard is belt-and-
            // suspenders for any path that doesn't.
            guard self.stateMachine.visibility(of: .hidden) == .shown else { return }
            self.enact(self.stateMachine.apply(.autoRehide))
            self.floatingBar?.hide()
            self.resumePendingPlacement()
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

    /// Notification entry point: debounce a burst into one settled refresh (see
    /// `screenChangeWorkItem`). The actual work runs in `applyScreenParametersChange`.
    @objc private func screenParametersChanged() {
        screenChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyScreenParametersChange() }
        screenChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.screenChangeDebounce, execute: work)
    }

    private func applyScreenParametersChange() {
        DebugLog.log("screenParametersChanged (debounced): anchorScreenWidth=\(menuBarScreenWidth) sectionInUse=\(sectionInUse)")
        // The menu bar geometry changed (display added/removed, resolution change). If the
        // section is in active use (panel showing, or an activation revealed it for an open
        // menu), don't disturb it — collapsing or revealing now would slam an open menu shut or
        // show the real items behind the panel as duplicates. Refresh opportunistically only
        // when idle.
        guard !isPaused else { return }
        if sectionInUse {
            placementPending = !preferences.itemControls.hiddenInMenuBar.isEmpty || !preferences.itemControls.shownInMenuBar.isEmpty
            return
        }
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
        if !preferences.itemControls.hiddenInMenuBar.isEmpty || !preferences.itemControls.shownInMenuBar.isEmpty {
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
        guard !isPaused, preferences.useFloatingBar, let bar = floatingBar, !sectionInUse else { return }
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
