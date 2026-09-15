import AppKit
import BarKeepersFriendCore

/// Wires together the runtime pieces and owns their lifetimes. Kept deliberately thin:
/// all decision-making lives in Core; this class only connects Core to AppKit objects.
@MainActor
final class AppCoordinator {
    private let preferencesStore = PreferencesStore(backing: UserDefaults.standard)
    private var preferences: Preferences
    private var hideEngine: CosmeticHideEngine?
    private var settingsWindowController: SettingsWindowController?
    private let loginItem = LoginItemService()

    private let windowServer: WindowServer = SystemWindowServer()
    private let capture = IconCaptureService()
    private var floatingBar: FloatingBarController?
    private var hiddenItemController: HiddenItemController?

    private let hotkeys = HotkeyService()
    private var activationObserver: NSObjectProtocol?

    private var groupStatusItems: GroupStatusItemsController?
    private let triggerMonitor = TriggerMonitor.system()
    private let menuBarSpacing = MenuBarSpacingService()
    private var spacingNeedsLogout = false
    private let restart = RestartService()
    private let updates = UpdateCheckService()
    private var updateCheckInFlight = false
    private var onboardingController: OnboardingWindowController?
    /// True while a trigger rewrites intent, so placement defers instead of acting like a Settings edit.
    private var backgroundApplyInFlight = false
    private var widgetStatusItems: WidgetStatusItemsController?
    private let menuBarStyleOverlay = MenuBarStyleOverlayController()

    /// Listens for SIGUSR1 to dump a read-only diagnostics report (development aid).
    private var diagnosticsSignalSource: DispatchSourceSignal?
    /// Listens for SIGUSR2 to toggle the floating bar so it can be screenshotted (dev aid).
    private var showBarSignalSource: DispatchSourceSignal?

    /// Captured before the first save so an upgrade from a pre-onboarding build is not "fresh".
    private let isFreshInstall: Bool

    init() {
        isFreshInstall = !preferencesStore.hasSavedPreferences
        preferences = preferencesStore.load()
    }

    /// True if another copy of this app (same bundle id) is already running.
    static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        // Count includes ourselves; more than one means a duplicate.
        return running.count > 1
    }

    func start() {
        let bar = FloatingBarController(
            windowServer: windowServer,
            captureIcons: capture.captureIcons,
            preferences: preferences,
            glyphStore: .default
        )
        floatingBar = bar

        // Attribute snapshots through Accessibility so the move targets each item's REAL owning pid
        // (Tahoe's kCGWindowOwnerPID reports Control Center; the move's relay needs the true pid).
        let mover = HiddenItemController(
            windowServer: windowServer,
            attribute: { await AXAttributionProvider.attribute($0) }
        )
        hiddenItemController = mover

        let engine = CosmeticHideEngine(preferences: preferences) { [weak self] updated in
            self?.persist(updated)
        }
        engine.floatingBar = bar
        engine.hiddenItemController = mover
        engine.configureNotchOverflow(windowServer: windowServer) { await AXAttributionProvider.attribute($0) }
        let hover = HoverRevealController(
            anchorFrame: { [weak engine] in engine?.anchorWindowFrame },
            panelFrame: { [weak bar] in bar?.windowFrame },
            isPanelVisible: { [weak bar] in bar?.isVisible == true },
            canReveal: { [weak engine] in engine?.canRevealOnHover == true },
            showPanel: { [weak engine] in await engine?.revealFloatingBarOnHover() },
            hidePanel: { [weak bar] in bar?.hide() }
        )
        engine.hoverRevealController = hover
        hideEngine = engine
        engine.onOpenSettings = { [weak self] in self?.showSettings() }
        engine.onQuit = { NSApp.terminate(nil) }
        engine.onRestart = { [weak self] in
            // Quitting without a helper would just leave the app closed.
            guard self?.restart.restart() == true else {
                let alert = NSAlert()
                alert.messageText = "Could not restart"
                alert.informativeText = "The relaunch helper failed to start. Quit and reopen Bar Keeper's Friend manually."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
            NSApp.terminate(nil)
        }
        engine.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        engine.onApplyPreset = { [weak self] id in self?.applyPreset(id: id) }
        let scroll = ScrollRevealMonitor(
            menuBarFrame: { [windowServer] point in try? windowServer.menuBarFrame(forDisplayContaining: point) },
            onReveal: { [weak engine] in engine?.revealFloatingBarOnScroll() },
            onHide: { [weak engine] in engine?.hideFloatingBarOnScroll() }
        )
        engine.scrollRevealMonitor = scroll
        engine.liveLayoutMonitor = LiveLayoutMonitor.system(
            isUserInteracting: { [weak engine] in engine?.isBusyForLiveLayout ?? true },
            previewMoves: { [weak engine] in await engine?.previewPlacementMoves() },
            requestReconcile: { [weak engine] in engine?.reconcileHiddenItems(userInitiated: false) }
        )
        engine.onScreenParametersChanged = { [weak self] in self?.menuBarStyleOverlay.screensChanged() }
        let groups = GroupStatusItemsController(activate: { [weak bar] id in bar?.activate(windowID: id) })
        groupStatusItems = groups
        bar.onCacheUpdated = { [weak self] in self?.refreshGroupStatusItems() }
        let widgets = WidgetStatusItemsController(
            runner: WidgetActionRunner(toggleBar: { [weak engine] in engine?.toggleFromShortcut() })
        )
        widgetStatusItems = widgets
        engine.onNeedsAccessibilityForMove = { AccessibilityPermission.requestAndOpenSettings() }
        engine.onPlacementStatusChanged = { [weak self] in self?.syncPlacementStatus() }
        engine.onPlacementCompleted = { [weak self] in
            await self?.settingsWindowController?.model.reloadItems()
        }
        bar.onNeedsAccessibility = { AccessibilityPermission.requestAndOpenSettings() }
        bar.onDidHide = { [weak engine, weak hover] in
            hover?.relinquishForManualInteraction()
            Task { @MainActor in
                engine?.resumePendingPlacement()
                engine?.refreshFloatingBarCacheIfStale()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak engine] _ in
            MainActor.assumeIsolated { engine?.resumePendingPlacement() }
        }
        engine.install()

        // Global hotkey: toggle the bar. Carbon-based, so no Accessibility prompt.
        hotkeys.onToggle = { [weak self] in self?.hideEngine?.toggleFromShortcut() }
        hotkeys.onActivateItem = { [weak self] key in
            Task { @MainActor [weak self] in
                guard let bar = self?.floatingBar, let id = await bar.windowID(forOwnerKey: key) else { return }
                bar.activate(windowID: id)
            }
        }
        hotkeys.apply(preferences: preferences)
        widgets.update(widgets: preferences.widgets)
        menuBarStyleOverlay.apply(style: preferences.menuBarStyle)
        applyAppIcon(preferences.appIcon.appTheme)

        // Prompt for Screen Recording up front when the floating bar is enabled, since it
        // needs capture to show icons. Permission-free hide/show still works without it.
        if preferences.useFloatingBar, !capture.hasScreenRecordingAccess {
            Task { await capture.requestScreenRecordingAccess() }
        }

        reconcileLoginItem()
        installDiagnosticsSignalHandler()
        refreshGroupStatusItems()
        spacingNeedsLogout = menuBarSpacing.applyAtLaunch(preferences.menuBarSpacing)
        triggerMonitor.onEnvironmentChanged = { [weak self] environment in self?.evaluateTriggers(environment) }
        triggerMonitor.update(rules: preferences.triggers)
        if isFreshInstall, !preferences.hasCompletedOnboarding { showOnboarding() }
    }

    /// Group icons show cached glyphs; rebuilt after every capture and preference change.
    private func refreshGroupStatusItems() {
        guard let bar = floatingBar else { return }
        groupStatusItems?.update(
            groups: preferences.itemGroups,
            items: bar.cachedHiddenItems(),
            aliases: preferences.itemAliases,
            capturedGlyphWindowIDs: bar.capturedGlyphWindowIDs
        )
    }

    /// Triggers rewrite saved intent through the same path as a Settings change, so placement
    /// and the open Settings window stay consistent with what the rule applied.
    private func evaluateTriggers(_ environment: TriggerEnvironment) {
        let result = TriggerEvaluator.step(
            state: preferences.triggerState, rules: preferences.triggers, presets: preferences.presets,
            environment: environment, currentControls: preferences.itemControls
        )
        var updated = preferences
        updated.triggerState = result.state
        if let controls = result.controls { updated.itemControls = controls }
        guard updated != preferences else { return }
        DebugLog.log("triggers: active=\(result.state.activeRuleID?.uuidString ?? "none") changedControls=\(result.controls != nil)")
        backgroundApplyInFlight = true
        defer { backgroundApplyInFlight = false }
        applyPreferences(updated)
    }

    private func applyPreset(id: UUID) {
        guard let preset = preferences.presets.first(where: { $0.id == id }) else { return }
        applyPreferences(PresetLibrary.applying(preset, to: preferences))
    }

    /// One funnel for every preference change made outside the Settings window.
    private func applyPreferences(_ updated: Preferences) {
        if let model = settingsWindowController?.model {
            // The model's didSet re-fires onChange, which persists and re-applies once.
            model.preferences = updated
        } else {
            handlePreferencesChange(updated)
        }
    }

    private func handlePreferencesChange(_ updated: Preferences) {
        let previous = preferences
        persist(updated)
        hideEngine?.apply(preferences: updated, userInitiated: !backgroundApplyInFlight)
        floatingBar?.preferences = updated
        hotkeys.apply(preferences: updated)
        settingsWindowController?.model.hotkeyRegistrationFailures = hotkeys.lastRegistrationFailures
        widgetStatusItems?.update(widgets: updated.widgets)
        if updated.menuBarStyle != previous.menuBarStyle { menuBarStyleOverlay.apply(style: updated.menuBarStyle) }
        if updated.appIcon.appTheme != previous.appIcon.appTheme { applyAppIcon(updated.appIcon.appTheme) }
        triggerMonitor.update(rules: updated.triggers)
        // A deleted or edited preset changes what an active rule means; rules alone would not re-evaluate.
        if updated.presets != previous.presets { triggerMonitor.refresh() }
        refreshGroupStatusItems()
        // Only an explicit spacing edit may touch the global domain; other apps' manual values stay.
        if updated.menuBarSpacing != previous.menuBarSpacing, menuBarSpacing.apply(updated.menuBarSpacing) {
            spacingNeedsLogout = true
        }
        settingsWindowController?.model.spacingNeedsLogout = spacingNeedsLogout
    }

    /// Alerts and any AppKit panel that reads the app icon follow the theme; `nil` restores the
    /// bundled icon. This never rewrites the signed bundle, so Finder keeps the shipped icon.
    private func applyAppIcon(_ theme: AppIconChoice.AppTheme) {
        NSApp.applicationIconImage = theme == .ocean ? nil : AppIconRenderer.appImage(theme)
    }

    private func checkForUpdates() {
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updateCheckInFlight = false }
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let result = await self.updates.checkNow(currentVersion: current)
            self.hideEngine?.updateAvailable = result.isAvailable
            let alert = NSAlert()
            alert.messageText = result.alertTitle
            alert.informativeText = result.alertMessage
            alert.addButton(withTitle: "OK")
            if case .available(_, let url) = result {
                alert.addButton(withTitle: "Open GitHub")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
            } else {
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func showOnboarding() {
        let model = OnboardingModel(
            onOpenSettings: { [weak self] in self?.showSettings(tab: .items) },
            onComplete: { [weak self] in
                guard let self else { return }
                var updated = self.preferences
                updated.hasCompletedOnboarding = true
                self.applyPreferences(updated)
                self.onboardingController = nil
            }
        )
        onboardingController = OnboardingWindowController(model: model)
        onboardingController?.show()
    }

    /// Dumps a read-only diagnostics report on `kill -USR1 <pid>`, and toggles the floating
    /// bar (as if the anchor were clicked) on `kill -USR2 <pid>`. Development aids: let the
    /// app's Accessibility view be inspected and the bar be shown for a screenshot without
    /// physically clicking the menu bar.
    private func installDiagnosticsSignalHandler() {
        signal(SIGUSR1, SIG_IGN) // ignore default-terminate; the dispatch source handles it
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                // Refresh the mirror from the live menu bar first so both the report and the
                // rendered snapshot reflect current state, not a stale cache.
                self?.hideEngine?.refreshFloatingBarCache()
                try? await Task.sleep(for: .milliseconds(600))
                guard let bar = self?.floatingBar else { return }
                let report = await bar.makeDiagnosticsReport()
                report.write()
                let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Logs", isDirectory: true)
                bar.renderDiagnosticSnapshot(to: logs.appendingPathComponent("BKF-bar.png"))
            }
        }
        source.resume()
        diagnosticsSignalSource = source

        signal(SIGUSR2, SIG_IGN)
        let showSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        showSource.setEventHandler { [weak self] in
            self?.hideEngine?.toggleFloatingBarForDiagnostics()
        }
        showSource.resume()
        showBarSignalSource = showSource
    }

    /// Re-applies the saved launch-at-login preference at startup. If the SMAppService
    /// registration was lost (an OS update or a manual removal in System Settings), the saved
    /// `true` would otherwise never be restored. The pure reconciler decides whether to act;
    /// `requiresApproval` is deliberately left alone (the user disabled it on purpose).
    private func reconcileLoginItem() {
        let action = LoginItemReconciler.decide(desired: preferences.launchAtLogin, actual: loginItem.status)
        switch action {
        case .register: loginItem.setEnabled(true)
        case .unregister: loginItem.setEnabled(false)
        case .none: break
        }
    }

    /// True when quitting should first put notch make-room victims back where they were.
    var needsRestoreBeforeQuit: Bool { hideEngine?.hasNotchVictimsToRestore == true }

    func restoreBeforeQuit() async {
        await hideEngine?.restoreNotchVictimsBeforeQuit()
    }

    func stop() {
        hideEngine?.uninstall()
        hotkeys.teardown()
        triggerMonitor.stop()
        menuBarStyleOverlay.removeAll()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func showSettings(tab: SettingsView.Tab? = nil) {
        floatingBar?.hide()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                preferences: preferences,
                loginItem: loginItem,
                itemsProvider: { [weak self] in try await self?.floatingBar?.allManageableItems() ?? [] },
                onRetryPlacement: { [weak self] in self?.hideEngine?.reconcileHiddenItems(userInitiated: true) }
            ) { [weak self] updated in
                self?.handlePreferencesChange(updated)
            }
            settingsWindowController?.model.onAccessibilityGranted = { [weak self] in
                self?.hideEngine?.resumePendingPlacement()
            }
            settingsWindowController?.model.spacingNeedsLogout = spacingNeedsLogout
            settingsWindowController?.model.hotkeyRegistrationFailures = hotkeys.lastRegistrationFailures
        }
        syncPlacementStatus()
        settingsWindowController?.show(tab: tab)
    }

    private func syncPlacementStatus() {
        guard let engine = hideEngine, let model = settingsWindowController?.model else { return }
        model.placementInProgress = engine.placementInProgress
        model.placementPending = engine.placementPending
        model.placementMessage = engine.placementMessage
        model.placementFailed = engine.placementFailed
    }

    private func persist(_ updated: Preferences) {
        preferences = updated
        preferencesStore.save(updated)
    }
}
