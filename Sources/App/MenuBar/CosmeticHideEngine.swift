import AppKit
import BarKeepersFriendCore

/// Test seam for the lazily created always-hidden divider, so tests never make a status item.
/// Production leaves it nil and owns a real `NSStatusItem` instead.
struct AlwaysHiddenDividerHooks {
    var create: @MainActor () -> Void
    var windowID: @MainActor () -> CGWindowID?
    var setCollapsed: @MainActor (Bool) -> Void
}

/// The Phase 1 hide/show engine — the unbreakable baseline.
///
/// It owns two of *our own* `NSStatusItem`s: an always-visible anchor and a hidden-section
/// divider. Hiding works by expanding the divider's `length` so the items to its left are
/// pushed off the screen edge; revealing restores the natural length. This uses **no**
/// private APIs and **no** permissions, so it keeps working regardless of what Apple
/// changes in the private menu-bar internals.
///
/// A third status item, the always-hidden divider, is created only once some owner carries
/// Always Hidden intent; until then the two-item baseline is untouched.
///
/// All visibility *decisions* come from `HideShowStateMachine` in Core; this class only
/// translates the resulting intents into `NSStatusItem.length` mutations.
@MainActor
final class CosmeticHideEngine {
    /// Called when settings should open (chosen from the anchor's right-click menu).
    var onOpenSettings: (() -> Void)?
    var onRestart: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    /// Applies a saved preset by id; the coordinator owns preference persistence.
    var onApplyPreset: ((UUID) -> Void)?
    /// Called when the user chooses Quit from the anchor's right-click menu.
    var onQuit: (() -> Void)?

    /// The floating bar that mirrors hidden items below the menu bar. When set and enabled
    /// in preferences, the anchor click toggles this panel instead of reflowing items back
    /// into the (possibly too-narrow) menu bar.
    var floatingBar: FloatingBarController?
    var hoverRevealController: HoverRevealController?
    var scrollRevealMonitor: ScrollRevealMonitor?
    /// Tucks shown items to make room for a notch-clipped reveal and restores them before collapse.
    private(set) var notchOverflowCoordinator: NotchOverflowCoordinator?
    private var makeRoomTask: Task<Void, Never>?
    /// Test seam: hostless fixtures have no notched NSScreen to derive geometry from.
    var notchGeometryProvider: (() -> NotchGeometry?)?
    /// Bumped by every new activation reveal so a stale async collapse cannot close its successor.
    private var activationGeneration = 0
    /// Notch make-room/restore outcomes are reported separately from placement status.
    private(set) var notchMessage: String?
    /// Lets the coordinator re-lay-out style overlays on the same debounced screen change.
    var onScreenParametersChanged: (() -> Void)?
    private var anchorMenuIsOpen = false

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
    private(set) var placementIncludesTierChanges = true
    private(set) var placementTask: Task<Void, Never>?
    private var placementRequestID = 0
    private struct ItemOrderRequest {
        let id = UUID()
        var orders: [ItemPlacement: [String]]
        let controls: ItemControlStore
        let applyPlacement: Bool
    }
    private var itemOrderRequest: ItemOrderRequest?

    /// Prepared before the matching preference write so tier moves and order share one serialized pass.
    func stageItemOrder(_ orders: [ItemPlacement: [String]], controls: ItemControlStore, applyPlacement: Bool = true) {
        if orders.isEmpty {
            guard itemOrderRequest != nil else { return }
            itemOrderRequest = nil
            reconcileHiddenItems(userInitiated: true)
        } else {
            itemOrderRequest = ItemOrderRequest(orders: orders, controls: controls, applyPlacement: applyPlacement)
        }
    }
    private let controlWindowIDsProvider: (() -> (anchor: CGWindowID, divider: CGWindowID)?)?
    private let setDividerCollapsed: ((Bool) -> Void)?
    private let anchorFrameProvider: (() -> CGRect?)?
    private let alwaysHiddenDividerHooks: AlwaysHiddenDividerHooks?
    /// Test seam for the anchor's artwork; production writes the real status button image.
    private let setAnchorImage: ((NSImage) -> Void)?
    /// The artwork currently applied to the anchor, for tests and diagnostics.
    private(set) var anchorSymbol: AppIconChoice.MenuBarSymbol
    private var activationOwnsSection = false
    // Last requested divider state: a predecessor may finish before its successor restores it.
    private var dividerIsCollapsed = false

    private var anchorItem: NSStatusItem?
    private var hiddenDivider: NSStatusItem?
    private var alwaysHiddenDivider: NSStatusItem?
    /// Set once for the session; the item stays even if the tier empties, so its slot survives.
    private(set) var alwaysHiddenDividerInstalled = false

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

    /// Bounded retries bridge cold-launch compositing; invalidation also covers already-queued
    /// optional captures without cancelling their native predecessor.
    private var warmUpRetryWorkItems: [DispatchWorkItem] = []
    private var warmUpRetryGeneration = 0
    private var cacheRefreshGeneration = 0

    /// Coalesces bursts of `didChangeScreenParametersNotification`. macOS posts that notification
    /// multiple times for a single user-visible change (display sleep/wake, mode negotiation, Stage
    /// Manager, an external display handshaking), and each one would otherwise drive a full
    /// reveal→capture→hide — a storm of full-display screenshots that lights the Screen Recording
    /// indicator and repeatedly disturbs the menu bar. We debounce: schedule one refresh and let
    /// later notifications in the burst reset the timer, so only the settled state is captured.
    private var screenChangeWorkItem: DispatchWorkItem?
    /// How long to wait for a burst of screen-parameter notifications to settle before refreshing.
    private static let screenChangeDebounce: TimeInterval = 0.5

    /// A Space switch or a closed bar is the first chance to replace fallbacks left by a pass that
    /// could not photograph the strip. One debounced check each; a complete, current cache asks nothing.
    private var staleCacheWorkItem: DispatchWorkItem?
    /// Past the fullscreen exit animation, and long enough that a reopened bar cancels it first.
    var staleCacheDebounce: TimeInterval = 1.5

    /// Serializes native reveal/capture ownership across suspension. Cached panel opens do not
    /// enqueue capture; event-driven refreshes must yield to presentation or activation.
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
    /// unit-tested rather than hand-assembled here. `updateAvailable` is set by a manual update check.
    var currentStatus: AppStatus {
        AppStatus.derive(
            paused: isPaused,
            moving: reconcileInFlightCount > 0,
            capturing: captureInFlightCount > 0,
            updateAvailable: updateAvailable
        )
    }

    /// Whether the app is currently paused (for the menu's checkmark).
    var paused: Bool { isPaused }

    /// Grouped owners are hidden behind their group icon, so placement treats them as Hidden.
    private var placementControls: ItemControlStore {
        ItemGroupLibrary.effectiveControls(groups: preferences.itemGroups, base: preferences.itemControls)
    }

    /// Set while a manual update check found a newer release; feeds the status line.
    var updateAvailable = false

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

    /// Revalidates optional work after joining its predecessor, before any physical reveal.
    /// Launch may establish a collapsed baseline; skipped work only restores the current state.
    @discardableResult
    func runCaptureSequence(
        forceCollapseAfter: Bool,
        canStart: @escaping @MainActor () -> Bool = { true },
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
            guard canStart() else {
                // The predecessor may have left restoration to this epoch, even if it does no work.
                if epoch == latestCaptureEpoch {
                    restoreDividersFromState()
                }
                DebugLog.log("capture: skipped optional refresh")
                return
            }
            captureInFlightCount += 1
            defer { captureInFlightCount -= 1 }
            // Tell the bar which display's menu-bar top to measure item plausibility against, so a
            // display stacked above/below the primary isn't enumerated as "all items below the bar".
            // Every capture path funnels through here, so this one assignment covers them all.
            floatingBar?.displayMenuBarTop = anchorDisplayMenuBarTop
            floatingBar?.displayXRange = anchorDisplayXRange
            if floatingBar?.menuBarVisibility() == .hidden {
                // Nothing is drawn: a reveal would only flash the items if the bar slid in mid-pass,
                // and a screenshot would photograph the cover. Membership still refreshes.
                DebugLog.log("capture: menu bar hidden; skipping reveal")
            } else {
                // Both tiers must be on-screen to capture; the always-hidden divider re-expands below.
                setHidden(collapsed: false)
                setAlwaysHiddenCollapsed(false)
            }
            // The settle also covers a launch expansion still in flight when no reveal was needed.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, !isPaused else { return }
            // Run the capture inline (NOT in a nested Task — hopping main-actor tasks here
            // shifted capture timing and produced wallpaper-only crops).
            await body()
            // A late completion must not override the state established by Pause or newer work.
            guard !Task.isCancelled, !isPaused, epoch == latestCaptureEpoch else { return }
            if forceCollapseAfter && !activationOwnsSection {
                _ = stateMachine.apply(.hide(.hidden))
                _ = stateMachine.apply(.hide(.alwaysHidden))
                setHidden(collapsed: true)
                setAlwaysHiddenCollapsed(true)
            } else {
                // Restore the dividers to whatever the state machine now says — preserves a
                // reveal an activation established while we were capturing.
                restoreDividersFromState()
            }
        }
        captureChain = task
        return task
    }

    /// Physical divider widths follow the state machine; the always-hidden write is a no-op
    /// until that divider exists.
    private func restoreDividersFromState() {
        setHidden(collapsed: stateMachine.visibility(of: .hidden) == .collapsed)
        setAlwaysHiddenCollapsed(stateMachine.visibility(of: .alwaysHidden) == .collapsed)
    }

    private func cancelCaptureSequences() {
        latestCaptureEpoch += 1
        captureChain.cancel()
        cancelPendingCacheRefreshes()
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
        anchorFrame: (() -> CGRect?)? = nil,
        alwaysHiddenDivider: AlwaysHiddenDividerHooks? = nil,
        setAnchorImage: ((NSImage) -> Void)? = nil,
        onPreferencesChanged: @escaping (Preferences) -> Void
    ) {
        self.preferences = preferences
        self.controlWindowIDsProvider = controlWindowIDs
        self.setDividerCollapsed = setDividerCollapsed
        self.anchorFrameProvider = anchorFrame
        self.alwaysHiddenDividerHooks = alwaysHiddenDivider
        self.setAnchorImage = setAnchorImage
        self.anchorSymbol = preferences.appIcon.menuBarSymbol
        self.onPreferencesChanged = onPreferencesChanged
        self.stateMachine = HideShowStateMachine(
            sections: MenuBarSection.allCases,
            autoRehideSections: Self.autoRehideSections(for: preferences),
            // Launch showing everything: the divider stays at its natural width so the
            // anchor is visible and nothing is hidden until the user clicks. Expanding on
            // launch would overflow a notched menu bar and drop the items off-screen.
            initialVisibility: .shown
        )
    }

    /// Auto re-hide always re-collapses both tiers; an option-click reveal must not outlive it.
    private static func autoRehideSections(for preferences: Preferences) -> Set<MenuBarSection> {
        preferences.autoRehide ? [.hidden, .alwaysHidden] : []
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
            button.image = AppIconRenderer.menuBarImage(preferences.appIcon.menuBarSymbol)
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
        // Created after the two baseline items so a first-ever divider lands left of them.
        ensureAlwaysHiddenDividerIfNeeded()

        // Tell the floating bar which windows are ours, so they're excluded from mirroring.
        publishControlItemWindowIDs()

        // Let the floating bar reveal/re-hide the section so it can click real items
        // (which must be on-screen to receive a click).
        floatingBar?.revealHiddenItems = { [weak self] in
            await self?.revealForActivation()
        }
        floatingBar?.revealAllHiddenItems = { [weak self] in
            await self?.revealForActivation(includeAlwaysHidden: true)
        }
        floatingBar?.rehideItems = { [weak self] in
            self?.rehideAfterActivation()
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
        updateHoverMonitoring()
        updateScrollMonitoring()
    }

    /// The defaults key AppKit uses to persist a status item's horizontal slot, by autosave name.
    private static func preferredPositionKey(_ identifier: ControlItem.Identifier) -> String {
        "NSStatusItem Preferred Position \(identifier.rawValue)"
    }

    /// Rewrites saved slots that drifted out of order so expansion pushes items, not our own
    /// controls, off-screen. Must run before the status items are created (AppKit reads slots then).
    private func repairControlItemOrderIfNeeded() {
        let defaults = UserDefaults.standard
        let anchorKey = Self.preferredPositionKey(.anchor)
        let dividerKey = Self.preferredPositionKey(.hiddenDivider)
        let alwaysHiddenKey = Self.preferredPositionKey(.alwaysHiddenDivider)
        guard defaults.object(forKey: anchorKey) != nil,
              defaults.object(forKey: dividerKey) != nil else { return }
        let anchorPos = defaults.double(forKey: anchorKey)
        let dividerPos = defaults.double(forKey: dividerKey)
        let alwaysHiddenPos = defaults.object(forKey: alwaysHiddenKey) == nil ? nil : defaults.double(forKey: alwaysHiddenKey)
        let repaired = ControlItemOrder.repairedPositions(
            anchor: anchorPos, hiddenDivider: dividerPos, alwaysHiddenDivider: alwaysHiddenPos
        )
        if let fixed = repaired.hiddenDivider {
            defaults.set(fixed, forKey: dividerKey)
            DebugLog.log("control-item order was inverted (anchor=\(anchorPos) divider=\(dividerPos)); repaired divider -> \(fixed)")
        }
        if let fixed = repaired.alwaysHiddenDivider, let alwaysHiddenPos {
            defaults.set(fixed, forKey: alwaysHiddenKey)
            DebugLog.log("always-hidden divider slot was inverted (divider=\(repaired.hiddenDivider ?? dividerPos) alwaysHidden=\(alwaysHiddenPos)); repaired -> \(fixed)")
        }
    }

    /// Mid-session creation: only the always-hidden slot is rewritten, since the live hidden
    /// divider already has its position and AppKit owns re-persisting it.
    private func repairAlwaysHiddenDividerSlotIfNeeded() {
        let defaults = UserDefaults.standard
        let anchorKey = Self.preferredPositionKey(.anchor)
        let dividerKey = Self.preferredPositionKey(.hiddenDivider)
        let alwaysHiddenKey = Self.preferredPositionKey(.alwaysHiddenDivider)
        guard defaults.object(forKey: anchorKey) != nil,
              defaults.object(forKey: dividerKey) != nil,
              defaults.object(forKey: alwaysHiddenKey) != nil else { return }
        let repaired = ControlItemOrder.repairedPositions(
            anchor: defaults.double(forKey: anchorKey), hiddenDivider: defaults.double(forKey: dividerKey),
            alwaysHiddenDivider: defaults.double(forKey: alwaysHiddenKey)
        )
        guard let fixed = repaired.alwaysHiddenDivider else { return }
        defaults.set(fixed, forKey: alwaysHiddenKey)
        DebugLog.log("always-hidden divider slot repaired before creation -> \(fixed)")
    }

    /// Creates the always-hidden divider the first time some owner carries Always Hidden intent.
    /// Never removed within the session: a fresh item would lose its saved slot and reorder.
    private func ensureAlwaysHiddenDividerIfNeeded() {
        guard !alwaysHiddenDividerInstalled, !placementControls.alwaysHiddenInMenuBar.isEmpty else { return }
        if let hooks = alwaysHiddenDividerHooks {
            hooks.create()
        } else {
            // Only an installed engine owns status items; install() calls back in once it does.
            guard anchorItem != nil else { return }
            repairAlwaysHiddenDividerSlotIfNeeded()
            let divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            divider.autosaveName = ControlItem.Identifier.alwaysHiddenDivider.rawValue
            if let button = divider.button {
                button.target = self
                button.action = #selector(dividerClicked(_:))
            }
            alwaysHiddenDivider = divider
        }
        alwaysHiddenDividerInstalled = true
        DebugLog.log("always-hidden divider created (intent=\(placementControls.alwaysHiddenInMenuBar.count))")
        publishControlItemWindowIDs()
        setAlwaysHiddenCollapsed(stateMachine.visibility(of: .alwaysHidden) == .collapsed)
    }

    /// Reports the app's own status-item window numbers to the floating bar so it never
    /// mirrors the anchor or dividers.
    ///
    /// `windowNumber` is an `Int` and can be 0, negative, or an out-of-range sentinel before
    /// the status-item window is realized; `CGWindowID` is a `UInt32`, so a force-conversion
    /// traps. We convert safely and skip any value that doesn't fit. The set is also
    /// refreshed right before the bar is shown, by which point the windows definitely exist.
    private func publishControlItemWindowIDs() {
        var ids: Set<CGWindowID> = []
        for window in [anchorItem?.button?.window, hiddenDivider?.button?.window, alwaysHiddenDivider?.button?.window] {
            if let number = window?.windowNumber,
               let id = WindowIDConversion.cgWindowID(fromWindowNumber: number) {
                ids.insert(id)
            }
        }
        if let controls = placementControlIDs {
            ids.formUnion([controls.anchor, controls.divider])
            floatingBar?.hiddenDividerWindowID = controls.divider
        }
        let alwaysHiddenID = alwaysHiddenControlWindowID
        if let alwaysHiddenID { ids.insert(alwaysHiddenID) }
        floatingBar?.alwaysHiddenDividerWindowID = alwaysHiddenID
        floatingBar?.controlItemWindowIDs = ids
        // Non-capture readers, including Settings, also measure against the anchor's display.
        floatingBar?.displayMenuBarTop = anchorDisplayMenuBarTop
    }

    /// The anchor window's global frame, used to align the floating bar and to determine
    /// which items count as "hidden" (those left of the anchor).
    private var anchorFrame: CGRect? {
        if let anchorFrameProvider { return anchorFrameProvider() }
        return anchorItem?.button?.window?.frame
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

    /// Nil until the tier's divider exists; falls back to the native name lookup like the pair above.
    private var alwaysHiddenControlWindowID: CGWindowID? {
        guard alwaysHiddenDividerInstalled else { return nil }
        if let hooks = alwaysHiddenDividerHooks { return hooks.windowID() }
        if let number = alwaysHiddenDivider?.button?.window?.windowNumber,
           let id = WindowIDConversion.cgWindowID(fromWindowNumber: number) {
            return id
        }
        return hiddenItemController?.alwaysHiddenControlWindowID(
            displayXRange: anchorDisplayXRange, displayMenuBarTop: anchorDisplayMenuBarTop
        )
    }

    func uninstall() {
        hoverRevealController?.stop()
        scrollRevealMonitor?.stop()
        makeRoomTask?.cancel()
        autoRehideWorkItem?.cancel()
        screenChangeWorkItem?.cancel()
        staleCacheWorkItem?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        cancelCaptureSequences()
        floatingBar?.hide()
        if let anchor = anchorItem { NSStatusBar.system.removeStatusItem(anchor) }
        if let divider = hiddenDivider { NSStatusBar.system.removeStatusItem(divider) }
        if let divider = alwaysHiddenDivider { NSStatusBar.system.removeStatusItem(divider) }
        anchorItem = nil
        hiddenDivider = nil
        alwaysHiddenDivider = nil
        alwaysHiddenDividerInstalled = false
        itemOrderRequest = nil
        placementPending = false
        updatePlacementStatus(applying: false)
    }

    // MARK: - Preferences

    /// Background callers (triggers) must defer like launch placement instead of closing menus
    /// or prompting for Accessibility the way an explicit Settings change does.
    func apply(preferences: Preferences, userInitiated: Bool = true) {
        let wasFloatingBar = self.preferences.useFloatingBar
        let previousControls = placementControls
        let previousGroups = self.preferences.itemGroups
        self.preferences = preferences
        var orderInvalidated = false
        if let request = itemOrderRequest,
           !request.controls.hasSamePlacementIntent(as: preferences.itemControls)
            || request.controls.barOrder != preferences.itemControls.barOrder || previousGroups != preferences.itemGroups {
            itemOrderRequest = nil
            orderInvalidated = true
        }
        stateMachine.autoRehideSections = Self.autoRehideSections(for: preferences)
        updateHoverMonitoring()
        updateScrollMonitoring()
        ensureAlwaysHiddenDividerIfNeeded()
        applyAnchorArtwork()

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

        // An invalidated order must relinquish its queued work; unrelated edits never schedule moves.
        if !placementControls.hasSamePlacementIntent(as: previousControls) || orderInvalidated {
            reconcileHiddenItems(userInitiated: userInitiated)
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

    /// Re-arming replaces only retry work, so the bounded warm-up schedule cannot stack.
    /// Each retry rechecks cache completeness and section ownership before revealing.
    func scheduleWarmUpRetries() {
        cancelWarmUpRetries()
        guard !isPaused, !Task.isCancelled, preferences.useFloatingBar, floatingBar != nil else { return }
        for offsetMs in WarmUpRetrySchedule.offsetsMs {
            let work = DispatchWorkItem { [weak self] in self?.fireWarmUpRetry() }
            warmUpRetryWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs), execute: work)
        }
    }

    /// Complete or disabled caches cancel remaining retries; active use leaves later timers armed.
    func fireWarmUpRetry() {
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
        let generation = warmUpRetryGeneration
        // Retries preserve the current state; only the essential launch pass establishes a baseline.
        runCaptureSequence(forceCollapseAfter: false, canStart: { [weak self] in
            guard let self else { return false }
            return generation == self.warmUpRetryGeneration && self.preferences.useFloatingBar
                && self.floatingBar === bar && !self.sectionInUse && bar.needsCapture
        }) { [weak self] in
            guard let self, let bar = self.floatingBar else { return }
            let anchorX = self.anchorFrame?.minX ?? 1115
            await bar.captureAndCache(anchorMinX: anchorX, allowFallback: false)
            if !Task.isCancelled, bar.needsCapture {
                try? await Task.sleep(for: .milliseconds(220))
                await bar.captureAndCache(anchorMinX: anchorX, allowFallback: true)
            }
        }
    }

    /// Invalidates queued optional work without cancelling the capture chain's native owner.
    /// Timer cancellation alone cannot stop a retry that already enqueued its capture task.
    private func cancelPendingCacheRefreshes() {
        cacheRefreshGeneration += 1
        staleCacheWorkItem?.cancel()
        cancelWarmUpRetries()
    }

    /// Called when the bar closes or the active Space changes. Only an incomplete or out-of-date
    /// mirror requests work, so a settled cache never flashes the items again.
    func refreshFloatingBarCacheIfStale() {
        staleCacheWorkItem?.cancel()
        guard !isPaused, preferences.useFloatingBar, floatingBar != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPaused, self.preferences.useFloatingBar, let bar = self.floatingBar,
                  !self.sectionInUse else { return }
            let anchorX = self.anchorFrame?.minX ?? 1115
            guard bar.needsCapture || bar.cachedMirrorIsStale(anchorMinX: anchorX) else { return }
            DebugLog.log("capture: mirror incomplete or stale after close/Space change; refreshing")
            self.refreshFloatingBarCache()
        }
        staleCacheWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + staleCacheDebounce, execute: work)
    }

    /// Cache completeness and retry re-arming do not invalidate event-driven refresh requests.
    private func cancelWarmUpRetries() {
        warmUpRetryGeneration += 1
        warmUpRetryWorkItems.forEach { $0.cancel() }
        warmUpRetryWorkItems.removeAll()
    }

    /// Explicit Settings commands take ownership of the section; background requests wait for
    /// dismissal or permission recovery. Superseded commands never publish stale completion.
    func reconcileHiddenItems(userInitiated: Bool = false) {
        placementIncludesTierChanges = itemOrderRequest?.applyPlacement ?? true
        placementRequestID += 1
        let requestID = placementRequestID
        let wasApplying = placementInProgress
        placementTask?.cancel()
        let controls = placementControls
        guard controls.hasAnyPlacementIntent || itemOrderRequest != nil else {
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
                self.restoreDividersFromState()
            }
            captureChain = restore
            placementTask = restore
            return
        }
        // The tier's control must exist before the planner can target it.
        ensureAlwaysHiddenDividerIfNeeded()
        placementPending = true
        guard !isPaused else {
            updatePlacementStatus(applying: false, message: "Changes will apply when Bar Keeper's Friend resumes.")
            return
        }
        if userInitiated {
            hoverRevealController?.relinquishForManualInteraction()
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
        cancelPendingCacheRefreshes()
        updatePlacementStatus(applying: true)
        DebugLog.log("placement: queued request=\(requestID) hidden=\(controls.hiddenInMenuBar.count) shown=\(controls.shownInMenuBar.count) alwaysHidden=\(controls.alwaysHiddenInMenuBar.count)")

        placementTask = runCaptureSequence(forceCollapseAfter: false) { [weak self] in
            guard let self, !Task.isCancelled, requestID == self.placementRequestID else { return }
            self.publishControlItemWindowIDs()
            controller.controlItemWindowIDs = self.floatingBar?.controlItemWindowIDs ?? []
            let result: HiddenItemController.ReconcileResult
            let requestControls = self.placementControls
            let orderRequest = self.itemOrderRequest
            if let controls = self.placementControlIDs {
                let alwaysHiddenID = self.alwaysHiddenControlWindowID
                DebugLog.log("placement: starting request=\(requestID) anchorWindow=\(controls.anchor) dividerWindow=\(controls.divider) alwaysHiddenWindow=\(alwaysHiddenID.map(String.init) ?? "none")")
                self.reconcileInFlightCount += 1
                defer { self.reconcileInFlightCount -= 1 }
                // Tucked victims are shown items; planning against them would read them as Hidden.
                await self.restoreNotchVictimsIfNeeded()
                guard !Task.isCancelled, requestID == self.placementRequestID else { return }
                result = await controller.reconcile(
                    anchorWindowID: controls.anchor,
                    dividerWindowID: controls.divider,
                    alwaysHiddenDividerWindowID: alwaysHiddenID,
                    controls: requestControls,
                    displayXRange: self.anchorDisplayXRange,
                    displayMenuBarTop: self.anchorDisplayMenuBarTop,
                    orders: orderRequest?.orders ?? [:],
                    applyPlacement: orderRequest?.applyPlacement ?? true
                )
            } else {
                result = HiddenItemController.ReconcileResult(observationFailed: true)
            }
            guard !Task.isCancelled, requestID == self.placementRequestID else { return }
            if let orderRequest, self.itemOrderRequest?.id == orderRequest.id {
                for tier in result.completedOrderTiers { self.itemOrderRequest?.orders[tier] = nil }
                if self.itemOrderRequest?.orders.isEmpty == true { self.itemOrderRequest = nil }
            }
            if result.cancelled {
                // Native session loss need not cancel this task; keep intent for a fresh request.
                self.placementPending = true
                self.updatePlacementStatus(applying: false, message: "Placement was interrupted. Changes are pending; try again when the desktop is available.")
                DebugLog.log("placement: interrupted request=\(requestID); retaining pending intent")
                return
            }
            self.placementPending = result.observationFailed
            // Invalid control geometry must not let an expanded divider hide the anchor itself.
            _ = self.stateMachine.apply(result.observationFailed ? .show(.hidden) : .hide(.hidden))
            _ = self.stateMachine.apply(result.observationFailed ? .show(.alwaysHidden) : .hide(.alwaysHidden))
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
                self.updatePlacementStatus(applying: false, message: "Couldn't move \(result.failed.count) item(s). Choose Retry to apply the saved placement again.", failed: true)
            } else if !result.orderFailed.isEmpty {
                self.updatePlacementStatus(applying: false, message: "Couldn't finish ordering the items. Choose Retry; pending native order is kept until the app quits.", failed: true)
            } else if result.unappliedPlacement {
                self.updatePlacementStatus(applying: false, message: "Order applied. Some saved placement requests are still unmet; choose Retry to apply them.", failed: true)
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
        anchorLeftClick(optionHeld: event?.modifierFlags.contains(.option) == true)
    }

    /// A plain click reveals the hidden tier only; Option also reveals the always-hidden tier
    /// (in place, or appended to the floating bar). Paused: the section is already revealed.
    func anchorLeftClick(optionHeld: Bool) {
        // While paused the section is revealed in place; a left-click does nothing (the right-click
        // menu, with the Pause toggle, is always available above).
        guard !isPaused else { return }
        if preferences.useFloatingBar, floatingBar != nil {
            toggleFloatingBar(includeAlwaysHidden: optionHeld)
        } else if optionHeld {
            toggleAllSections()
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
    func showAnchorMenu() {
        if hoverRevealController?.ownsPanel == true { floatingBar?.hide() }
        hoverRevealController?.relinquishForManualInteraction()
        guard let anchor = anchorItem else { return }
        anchorMenuIsOpen = true
        defer { anchorMenuIsOpen = false }
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

        if !preferences.presets.isEmpty {
            menu.addItem(.separator())
            let active = PresetLibrary.activePreset(in: preferences)?.id
            let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for preset in preferences.presets {
                let item = NSMenuItem(title: preset.name, action: #selector(menuApplyPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id.uuidString
                item.state = preset.id == active ? .on : .off
                submenu.addItem(item)
            }
            presetsItem.submenu = submenu
            menu.addItem(presetsItem)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About \(Self.appName)", action: #selector(menuShowAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart \(Self.appName)", action: #selector(menuRestart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
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
    @objc private func menuRestart() { onRestart?() }
    @objc private func menuCheckForUpdates() { onCheckForUpdates?() }
    @objc private func menuApplyPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        onApplyPreset?(id)
    }

    /// Pause reveals items and cancels automation; resume restores saved intent and unfinished
    /// icon collection. An already-posted native gesture finishes before cancellation takes effect.
    @objc func menuTogglePause() {
        isPaused.toggle()
        updateHoverMonitoring()
        updateScrollMonitoring()
        autoRehideWorkItem?.cancel()
        autoRehideWorkItem = nil
        if isPaused {
            activationOwnsSection = false
            // Pausing stops all automated activity; the cold-launch warm-up retries are exactly that,
            // so drop them rather than let one fire and no-op (or flash a reveal) while paused.
            cancelCaptureSequences()
            screenChangeWorkItem?.cancel()
            // Reveal in place: hide the mirror panel if open, drive the state machine to shown so no
            // stray refresh re-collapses it, and un-tuck both dividers so every tucked item returns.
            floatingBar?.hide()
            _ = stateMachine.apply(.show(.hidden))
            _ = stateMachine.apply(.show(.alwaysHidden))
            setHidden(collapsed: false)
            setAlwaysHiddenCollapsed(false)
            // Pause reveals everything, which includes undoing BKF's own make-room displacement.
            if notchOverflowCoordinator?.hasTuckedItems == true || makeRoomTask != nil {
                Task { @MainActor in await self.restoreNotchVictimsIfNeeded() }
            }
            updatePlacementStatus(applying: false, message: "Changes will apply when Bar Keeper's Friend resumes.")
        } else {
            // Back to baseline: collapse both tiers, then re-apply intent recorded while paused.
            let resume: @MainActor () -> Void = { [weak self] in
                guard let self, !self.isPaused else { return }
                _ = self.stateMachine.apply(.hide(.hidden))
                _ = self.stateMachine.apply(.hide(.alwaysHidden))
                self.setHidden(collapsed: true)
                self.setAlwaysHiddenCollapsed(true)
                if let bar = self.floatingBar, bar.needsCapture {
                    self.warmUpFloatingBarCache()
                }
                self.reconcileHiddenItems()
            }
            if notchOverflowCoordinator?.hasTuckedItems == true {
                Task { @MainActor in
                    await self.restoreNotchVictimsIfNeeded()
                    resume()
                }
            } else {
                resume()
            }
        }
    }

    /// Shows the standard AppKit About panel with the chosen artwork. The agent app has no menu bar
    /// of its own, so we surface it from here; activate first so the panel comes forward.
    @objc private func menuShowAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: AppIconRenderer.appImage(preferences.appIcon.appTheme)
        ])
    }

    /// Manual toggles present cached icons; keyboard opens disable the pre-entry dismissal backstop.
    /// Hover uses a separate ownership policy and exit timer. `includeAlwaysHidden` (Option-click)
    /// appends the always-hidden tier; asking for it while a plain bar is open widens that bar.
    private func toggleFloatingBar(persistUntilToggled: Bool = false, includeAlwaysHidden: Bool = false) {
        hoverRevealController?.relinquishForManualInteraction()
        guard !isPaused, let bar = floatingBar else { return }
        // Any deliberate user interaction with the bar cancels a pending auto-rehide. Otherwise a
        // timer armed by an earlier activation (default 15s) could fire later and yank shut a bar
        // the user just re-opened, or collapse a section they re-engaged — a spontaneous-vanish
        // bug. toggleFloatingBar is the single funnel for anchor clicks and the hotkey, so one
        // cancel here covers every re-open path.
        autoRehideWorkItem?.cancel()
        autoRehideWorkItem = nil
        // Presentation uses only cached icons, even when stale; freshness waits for idle refreshes.
        cancelPendingCacheRefreshes()
        let presentation: FloatingBarController.Presentation = persistUntilToggled ? .keyboard : .click
        // Only a real tier can widen an open bar; without one an Option-click toggles like a click.
        let widensOpenBar = bar.isVisible && includeAlwaysHidden && !bar.presentsAlwaysHidden
            && alwaysHiddenDividerInstalled && !bar.cachedAlwaysHiddenItems().isEmpty
        // Widening is a deliberate click, even over a bar that hover opened.
        if widensOpenBar { bar.adoptPresentation(presentation) }
        // A click during the one-time launch capture: don't eat it (that felt broken), and don't
        // touch the divider/state machine (the capture is mid-reveal and owns it — collapsing now
        // would yank the section out from under the screenshot). Just show the panel; it renders a
        // "Preparing…" spinner from the not-yet-populated cache, and the warm-up re-lays-it-out
        // with the real glyphs the moment capture lands, then collapses the divider itself.
        if captureInFlight {
            if bar.isVisible, !widensOpenBar {
                bar.hide()
            } else {
                let frame = anchorFrame ?? CGRect(x: (NSScreen.main?.frame.maxX ?? 1440) - 32, y: 0, width: 32, height: 24)
                Task { @MainActor in
                    guard !self.isPaused else { return }
                    await bar.show(
                        anchorMinX: frame.minX, anchorRightX: frame.maxX, presentation: presentation,
                        includeAlwaysHidden: includeAlwaysHidden
                    )
                }
            }
            return
        }
        // Refresh now that the windows are fully realized, so our own items are excluded.
        publishControlItemWindowIDs()
        // If a prior activation left the section revealed in the menu bar, the anchor should
        // tidy it back up (re-hide) rather than show a redundant panel.
        if stateMachine.visibility(of: .hidden) == .shown {
            bar.hide()
            afterRestoringNotchVictims { [weak self] in
                guard let self else { return }
                _ = self.stateMachine.apply(.hide(.hidden))
                _ = self.stateMachine.apply(.hide(.alwaysHidden))
                self.setHidden(collapsed: true)
                self.setAlwaysHiddenCollapsed(true)
                self.resumePendingPlacement()
            }
            return
        }
        if bar.isVisible, !widensOpenBar {
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
            await bar.show(
                anchorMinX: frame.minX, anchorRightX: frame.maxX, presentation: presentation,
                includeAlwaysHidden: includeAlwaysHidden
            )
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

    var canRevealOnHover: Bool {
        preferences.revealOnHover && preferences.useFloatingBar && floatingBar != nil
            && !isPaused && !anchorMenuIsOpen && !activationOwnsSection && !placementInProgress
            && !captureInFlight && dividerIsCollapsed && stateMachine.visibility(of: .hidden) == .collapsed
    }

    private func updateHoverMonitoring() {
        hoverRevealController?.setEnabled(preferences.revealOnHover && preferences.useFloatingBar && !isPaused)
    }

    private func updateScrollMonitoring() {
        scrollRevealMonitor?.setEnabled(preferences.revealOnScroll && preferences.useFloatingBar && !isPaused)
    }

    /// A scroll gesture is deliberate like a click, so it takes ownership from hover and opens
    /// from the cache; hide closes whatever presentation is showing.
    func revealFloatingBarOnScroll() {
        guard !isPaused, preferences.revealOnScroll, preferences.useFloatingBar,
              let bar = floatingBar, !bar.isVisible, !captureInFlight, !activationOwnsSection,
              !placementInProgress, stateMachine.visibility(of: .hidden) == .collapsed else { return }
        toggleFloatingBar()
    }

    func hideFloatingBarOnScroll() {
        guard !isPaused, preferences.revealOnScroll, let bar = floatingBar, bar.isVisible else { return }
        hoverRevealController?.relinquishForManualInteraction()
        bar.hide()
    }

    func revealFloatingBarOnHover() async {
        guard !Task.isCancelled, canRevealOnHover, let bar = floatingBar,
              !bar.isVisible, let frame = anchorFrame else { return }
        autoRehideWorkItem?.cancel()
        autoRehideWorkItem = nil
        cancelPendingCacheRefreshes()
        publishControlItemWindowIDs()
        await bar.show(
            anchorMinX: frame.minX, anchorRightX: frame.maxX,
            presentation: .hover
        )
    }

    @objc private func dividerClicked(_ sender: NSStatusBarButton) {
        anchorClicked(sender)
    }

    /// Builds the notch coordinator from the engine's own control geometry; the window server
    /// and attribution are the same ones placement uses.
    func configureNotchOverflow(
        windowServer: WindowServer,
        attribute: @escaping ([MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot]
    ) {
        notchOverflowCoordinator = NotchOverflowCoordinator(
            observe: { try windowServer.menuBarItems() },
            move: { try await windowServer.move(item: $0, toX: $1, relativeTo: $2) },
            controls: { [weak self] in
                guard let self, let ids = self.placementControlIDs else { return nil }
                let tierTucked = self.stateMachine.visibility(of: .alwaysHidden) == .collapsed
                return .init(anchor: ids.anchor, divider: ids.divider,
                             alwaysHidden: tierTucked ? self.alwaysHiddenControlWindowID : nil)
            },
            notch: { [weak self] in
                if let provider = self?.notchGeometryProvider { return provider() }
                guard let screen = self?.anchorScreen else { return nil }
                return NotchGeometry(displayFrame: screen.frame, leftArea: screen.auxiliaryTopLeftArea,
                                     rightArea: screen.auxiliaryTopRightArea)
            },
            displayMenuBarTop: { [weak self] in self?.anchorDisplayMenuBarTop ?? 0 },
            excludedWindowIDs: { [weak self] in self?.floatingBar?.controlItemWindowIDs ?? [] },
            immovable: { ImmovableItems.isImmovable($0, immovablePIDs: ImmovableProcessIDs.current()) },
            attribute: attribute
        )
    }

    /// Make-room shares the native mover with placement, so it never starts while a batch or capture runs.
    private var notchOverflowActive: Bool {
        preferences.notchOverflow == .whenNeeded && !isPaused && hiddenItemController?.canMoveItems == true
            && notchOverflowCoordinator != nil && !placementInProgress && !captureInFlight
    }

    /// Runs after a reveal has settled; a `.never` mode or missing notch returns without observing.
    private func makeRoomForNotchIfNeeded() async {
        guard notchOverflowActive, let coordinator = notchOverflowCoordinator else { return }
        coordinator.currentMode = preferences.notchOverflow
        let task = Task { @MainActor [weak self] in
            let result = await coordinator.makeRoomIfNeeded(mode: coordinator.currentMode)
            guard let self else { return }
            if result.needed {
                DebugLog.log("notch: required=\(Int(result.requiredWidth)) tucked=\(result.tucked.count) failed=\(result.failed.count) remaining=\(Int(result.remainingDeficit))")
            }
            self.notchMessage = result.failed.isEmpty ? nil
                : "Couldn't move \(result.failed.count) item(s) to make room near the notch."
        }
        makeRoomTask = task
        await task.value
        // A finished pass must not leave every later collapse on the async restore path.
        if makeRoomTask == task { makeRoomTask = nil }
    }

    /// Victims must return before the divider expands, or a reconcile would read them as Hidden.
    private func restoreNotchVictimsIfNeeded() async {
        guard let coordinator = notchOverflowCoordinator, coordinator.hasTuckedItems || makeRoomTask != nil else { return }
        makeRoomTask?.cancel()
        makeRoomTask = nil
        let result = await coordinator.restore()
        if !result.failed.isEmpty {
            notchMessage = "Couldn't restore \(result.failed.count) item(s) moved to make room near the notch."
        } else if !result.allRestored {
            DebugLog.log("notch: restore incomplete remaining=\(result.remaining) cancelled=\(result.cancelled) observationFailed=\(result.observationFailed)")
        } else {
            notchMessage = nil
        }
    }

    /// Quit-time hook: victims left tucked would persist on the wrong side of the bar, so the app
    /// delegate defers termination until this returns. Bounded so a wedged move cannot block quit.
    func restoreNotchVictimsBeforeQuit(timeout: Duration = .seconds(3)) async {
        makeRoomTask?.cancel()
        guard let coordinator = notchOverflowCoordinator, coordinator.hasTuckedItems else { return }
        let restore = Task { @MainActor in await self.restoreNotchVictimsIfNeeded() }
        // Poll rather than race tasks: the restore may not honor cancellation mid-gesture.
        let deadline = ContinuousClock.now + timeout
        while coordinator.hasTuckedItems, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        restore.cancel()
    }

    /// Whether quitting now would strand shown items in the hidden section.
    var hasNotchVictimsToRestore: Bool { notchOverflowCoordinator?.hasTuckedItems == true }

    /// Every collapse site funnels through here so victims are never stranded in the hidden section.
    private func afterRestoringNotchVictims(_ collapse: @escaping @MainActor () -> Void) {
        guard notchOverflowCoordinator?.hasTuckedItems == true || makeRoomTask != nil else { return collapse() }
        Task { @MainActor in
            await self.restoreNotchVictimsIfNeeded()
            guard !self.isPaused else { return }
            collapse()
        }
    }

    func toggleHidden() {
        guard !isPaused else { return }
        hoverRevealController?.relinquishForManualInteraction()
        if stateMachine.visibility(of: .hidden) == .shown,
           notchOverflowCoordinator?.hasTuckedItems == true || makeRoomTask != nil {
            // Restoring is a native move sequence, so the collapse waits for it.
            afterRestoringNotchVictims { [weak self] in
                guard let self, self.stateMachine.visibility(of: .hidden) == .shown else { return }
                self.collapseHiddenAfterToggle()
            }
            return
        }
        let intents = stateMachine.apply(.toggle(.hidden))
        enact(intents)
        // Collapsing the hidden tier ends any option-click reveal; a plain reveal never opens it.
        if stateMachine.visibility(of: .hidden) == .collapsed {
            enact(stateMachine.apply(.hide(.alwaysHidden)))
        } else if notchOverflowActive {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !self.isPaused, self.stateMachine.visibility(of: .hidden) == .shown else { return }
                await self.makeRoomForNotchIfNeeded()
            }
        }
        scheduleAutoRehideIfNeeded()
        if stateMachine.visibility(of: .hidden) == .collapsed { resumePendingPlacement() }
    }

    private func collapseHiddenAfterToggle() {
        enact(stateMachine.apply(.toggle(.hidden)))
        enact(stateMachine.apply(.hide(.alwaysHidden)))
        scheduleAutoRehideIfNeeded()
        resumePendingPlacement()
    }

    /// Option-click in reflow mode: reveals both tiers in place, or collapses both once shown.
    func toggleAllSections() {
        guard !isPaused else { return }
        hoverRevealController?.relinquishForManualInteraction()
        let bothShown = stateMachine.visibility(of: .hidden) == .shown
            && stateMachine.visibility(of: .alwaysHidden) == .shown
        let events: [HideShowStateMachine.Event] = bothShown
            ? [.hide(.hidden), .hide(.alwaysHidden)]
            : [.show(.hidden), .show(.alwaysHidden)]
        let apply: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            for event in events { self.enact(self.stateMachine.apply(event)) }
            self.scheduleAutoRehideIfNeeded()
            if self.stateMachine.visibility(of: .hidden) == .collapsed {
                self.resumePendingPlacement()
            } else if self.notchOverflowActive {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !self.isPaused, self.stateMachine.visibility(of: .hidden) == .shown else { return }
                    await self.makeRoomForNotchIfNeeded()
                }
            }
        }
        if bothShown { afterRestoringNotchVictims(apply) } else { apply() }
    }

    /// Reveals the hidden section (and, on request, the always-hidden one) so a real item can be
    /// clicked on-screen. Updates the state machine to `.shown` and returns after a short settle.
    func revealForActivation(includeAlwaysHidden: Bool = false) async {
        guard !isPaused, !Task.isCancelled else { return }
        hoverRevealController?.relinquishForManualInteraction()
        activationOwnsSection = true
        activationGeneration += 1
        _ = stateMachine.apply(.show(.hidden))
        if includeAlwaysHidden { _ = stateMachine.apply(.show(.alwaysHidden)) }
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
        if includeAlwaysHidden { setAlwaysHiddenCollapsed(false) }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, !isPaused, activationOwnsSection else { return }
        await makeRoomForNotchIfNeeded()
    }

    /// Failed or interrupted current activations must release both logical and physical ownership.
    /// A superseded task or Pause must not collapse the state established by its successor.
    func rehideAfterActivation() {
        guard !isPaused, !Task.isCancelled else { return }
        let generation = activationGeneration
        afterRestoringNotchVictims { [weak self] in
            // A successor activation re-revealed the section; its own rehide owns the collapse.
            guard let self, generation == self.activationGeneration else { return }
            self.enact(self.stateMachine.apply(.hide(.hidden)))
            self.enact(self.stateMachine.apply(.hide(.alwaysHidden)))
            self.resumePendingPlacement()
        }
    }

    private func enact(_ intents: [HideShowStateMachine.Intent]) {
        for intent in intents {
            switch intent.section {
            case .hidden: setHidden(collapsed: intent.visibility == .collapsed)
            case .alwaysHidden: setAlwaysHiddenCollapsed(intent.visibility == .collapsed)
            case .visible: break
            }
        }
    }

    /// Expands the divider to hide the section, or restores natural width to reveal it. The
    /// divider has no image, so its natural (variable) length is effectively zero width — it
    /// leaves no visible gap or marker in the menu bar when the section is revealed.
    private func setHidden(collapsed: Bool) {
        dividerIsCollapsed = collapsed
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

    /// Same mechanism for the always-hidden divider; a no-op until that divider exists, so a bar
    /// that never uses the tier sees no extra writes.
    private func setAlwaysHiddenCollapsed(_ collapsed: Bool) {
        guard alwaysHiddenDividerInstalled else { return }
        if let hooks = alwaysHiddenDividerHooks {
            hooks.setCollapsed(collapsed)
            return
        }
        guard let divider = alwaysHiddenDivider else { return }
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
        restoreDividersFromState()
    }

    private func scheduleAutoRehideIfNeeded() {
        autoRehideWorkItem?.cancel()
        guard !isPaused, preferences.autoRehide,
              stateMachine.visibility(of: .hidden) == .shown else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPaused else { return }
            self.afterRestoringNotchVictims { [weak self] in
                guard let self else { return }
                self.enact(self.stateMachine.apply(.autoRehide))
            }
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
            let generation = self.activationGeneration
            self.afterRestoringNotchVictims { [weak self] in
                guard let self, generation == self.activationGeneration,
                      self.stateMachine.visibility(of: .hidden) == .shown else { return }
                self.enact(self.stateMachine.apply(.autoRehide))
                self.floatingBar?.hide()
                self.resumePendingPlacement()
            }
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
        // Entering a fullscreen Space hides the menu bar; leaving it is when a deferred capture can succeed.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func activeSpaceChanged() {
        refreshFloatingBarCacheIfStale()
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
        onScreenParametersChanged?()
        // The menu bar geometry changed (display added/removed, resolution change). If the
        // section is in active use (panel showing, or an activation revealed it for an open
        // menu), don't disturb it — collapsing or revealing now would slam an open menu shut or
        // show the real items behind the panel as duplicates. Refresh opportunistically only
        // when idle.
        guard !isPaused else { return }
        if sectionInUse {
            placementPending = placementControls.hasAnyPlacementIntent || itemOrderRequest != nil
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
        if stateMachine.visibility(of: .alwaysHidden) == .collapsed {
            setAlwaysHiddenCollapsed(true)
        }
        guard preferences.useFloatingBar else { return }
        // The menu-bar display may have changed (e.g. the anchor jumped to a newly-attached
        // screen). The per-item Hidden intent was realized on the OLD display's items; re-apply it
        // so the items on the now-current display land on the right side of the anchor. No-op when
        // nothing is marked hidden. The planner is display-scoped (see `anchorDisplayXRange`), so
        // this only touches the active display's items, never the other display's mirror copies.
        if placementControls.hasAnyPlacementIntent || itemOrderRequest != nil {
            reconcileHiddenItems()
        } else {
            refreshFloatingBarCache()
        }
    }

    /// Optional event-driven refreshes yield to user interaction, including while queued.
    /// Cached panel opens never request one; stale icons wait for the next idle refresh.
    func refreshFloatingBarCache() {
        guard !isPaused, preferences.useFloatingBar, let bar = floatingBar, !sectionInUse else { return }
        // Reveal → capture → restore, serialized behind any in-flight capture (e.g. the launch
        // one) so they can't fight over the divider. captureAndCache retries internally until
        // the revealed glyphs have composited in. Not a force-collapse: restore to state so we
        // don't fight an activation that begins while we capture.
        let generation = cacheRefreshGeneration
        runCaptureSequence(forceCollapseAfter: false, canStart: { [weak self] in
            guard let self else { return false }
            return generation == self.cacheRefreshGeneration && self.preferences.useFloatingBar
                && self.floatingBar === bar && !self.sectionInUse
        }) { [weak self] in
            await bar.captureAndCache(anchorMinX: self?.anchorFrame?.minX ?? 1115)
        }
    }

    // MARK: - Images

    /// Only a changed symbol touches the status button; icon edits never recreate the item.
    private func applyAnchorArtwork() {
        let symbol = preferences.appIcon.menuBarSymbol
        guard symbol != anchorSymbol else { return }
        anchorSymbol = symbol
        let image = AppIconRenderer.menuBarImage(symbol)
        if let setAnchorImage {
            setAnchorImage(image)
        } else {
            anchorItem?.button?.image = image
        }
    }
}
