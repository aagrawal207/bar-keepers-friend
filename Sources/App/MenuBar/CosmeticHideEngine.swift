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
    /// Called when settings should open (anchor right-click / menu).
    var onOpenSettings: (() -> Void)?

    /// The floating bar that mirrors hidden items below the menu bar. When set and enabled
    /// in preferences, the anchor click toggles this panel instead of reflowing items back
    /// into the (possibly too-narrow) menu bar.
    var floatingBar: FloatingBarController?

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

    /// True while a capture sequence is revealing/capturing. Lets the anchor click ignore the
    /// transient reveal (the divider is physically open for capture but not for the user), so a
    /// click during the launch capture window can't misread that state and eat the toggle.
    private(set) var captureInFlight = false

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
            captureInFlight = true
            defer { captureInFlight = false }
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

        let divider = NSStatusBar.system.statusItem(withLength: ControlItemLength.collapsed)
        divider.autosaveName = ControlItem.Identifier.hiddenDivider.rawValue
        if let button = divider.button {
            button.image = Self.dividerImage()
            button.image?.isTemplate = true
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
            self?.setHidden(collapsed: true)
        }
        floatingBar?.scheduleAutoRehideAfterActivation = { [weak self] in
            self?.scheduleAutoRehideAfterActivation()
        }

        if preferences.useFloatingBar {
            // Items must be captured while on-screen (status items can't be captured once
            // off-screen). Reveal → capture+cache → hide, serialized so a later refresh can't
            // race this launch capture for the divider state. Force-collapse after: launch
            // establishes the hidden baseline.
            runCaptureSequence(forceCollapseAfter: true) { [weak self] in
                guard let self else { return }
                await self.floatingBar?.captureAndCache(anchorMinX: self.anchorFrame?.minX ?? 1115)
            }
        } else {
            applyDividerVisibility()
        }
        observeScreenChanges()
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
        self.preferences = preferences
        stateMachine.autoRehideSections = preferences.autoRehide ? [.hidden] : []
        // Show the divider glyph only when section dividers are enabled; otherwise keep it
        // imageless so the boundary is invisible.
        hiddenDivider?.button?.image = preferences.showSectionDividers ? Self.dividerImage() : nil
    }

    // MARK: - Actions

    @objc private func anchorClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            onOpenSettings?()
            return
        }
        if preferences.useFloatingBar, floatingBar != nil {
            toggleFloatingBar()
        } else {
            toggleHidden()
        }
    }

    /// Shows or hides the floating bar. On show it refreshes the mirror first (re-capture +
    /// re-attribute) so names and icons are current rather than the stale launch-time cache.
    private func toggleFloatingBar() {
        guard let bar = floatingBar else { return }
        // Ignore a click while a capture sequence is mid-flight (e.g. the one-time launch
        // capture): the divider is transiently revealed for capture but the state machine
        // hasn't settled, so acting now would misread it — collapsing the section and eating
        // the click, and stacking a duplicate capture. The launch window is ~1s and one-time.
        guard !captureInFlight else { return }
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
        // Refresh the mirror right before showing it: reveal the items on-screen, re-capture
        // their icons and re-attribute names (Accessibility is unreliable at launch, so the
        // launch-time cache can show stale "Control Center" names and blank icons), then
        // collapse the divider and show the panel from the fresh cache. Force-collapse after:
        // the panel (not the in-bar items) is what the user sees. Serialized behind any
        // in-flight capture; we await it, then show.
        let sequence = runCaptureSequence(forceCollapseAfter: true) { [weak self] in
            await bar.captureAndCache(anchorMinX: self?.anchorFrame?.minX ?? 1115)
        }
        Task { @MainActor in
            _ = await sequence.value
            let frame = anchorFrame ?? CGRect(x: (NSScreen.main?.frame.maxX ?? 1440) - 32, y: 0, width: 32, height: 24)
            await bar.show(anchorMinX: frame.minX, anchorRightX: frame.maxX)
        }
    }

    /// Toggles the floating bar exactly as a left anchor click would. Used by the SIGUSR2
    /// diagnostics trigger so the bar can be shown for a screenshot without clicking the menu
    /// bar. No-op outside floating-bar mode.
    func toggleFloatingBarForDiagnostics() {
        guard preferences.useFloatingBar, floatingBar != nil else { return }
        toggleFloatingBar()
    }

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

    /// Expands the divider to hide the section, or restores natural width to reveal it.
    private func setHidden(collapsed: Bool) {
        guard let divider = hiddenDivider else { return }
        if collapsed {
            let screenWidth = NSScreen.main?.frame.width ?? 1440
            divider.length = ControlItemLength.expanded(forScreenWidth: screenWidth)
        } else {
            divider.length = preferences.showSectionDividers
                ? ControlItemLength.collapsed
                : NSStatusItem.variableLength
        }
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
        guard preferences.useFloatingBar else { return }
        refreshFloatingBarCache()
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

    private static func dividerImage() -> NSImage? {
        NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Toggle hidden items")
    }
}
