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

    /// Listens for SIGUSR1 to dump a read-only diagnostics report (development aid).
    private var diagnosticsSignalSource: DispatchSourceSignal?
    /// Listens for SIGUSR2 to toggle the floating bar so it can be screenshotted (dev aid).
    private var showBarSignalSource: DispatchSourceSignal?

    init() {
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
            capture: capture,
            preferences: preferences
        )
        floatingBar = bar

        let engine = CosmeticHideEngine(preferences: preferences) { [weak self] updated in
            self?.persist(updated)
        }
        engine.floatingBar = bar
        engine.install()
        engine.onOpenSettings = { [weak self] in self?.showSettings() }
        engine.onQuit = { NSApp.terminate(nil) }
        bar.onNeedsAccessibility = { AccessibilityPermission.requestAndOpenSettings() }
        hideEngine = engine

        // Prompt for Screen Recording up front when the floating bar is enabled, since it
        // needs capture to show icons. Permission-free hide/show still works without it.
        if preferences.useFloatingBar, !capture.hasScreenRecordingAccess {
            Task { await capture.requestScreenRecordingAccess() }
        }

        installDiagnosticsSignalHandler()
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

    func stop() {
        hideEngine?.uninstall()
    }

    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                preferences: preferences,
                loginItem: loginItem
            ) { [weak self] updated in
                self?.persist(updated)
                self?.hideEngine?.apply(preferences: updated)
                self?.floatingBar?.preferences = updated
            }
        }
        settingsWindowController?.show()
    }

    private func persist(_ updated: Preferences) {
        preferences = updated
        preferencesStore.save(updated)
    }
}
