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
        let engine = CosmeticHideEngine(preferences: preferences) { [weak self] updated in
            self?.persist(updated)
        }
        engine.install()
        engine.onOpenSettings = { [weak self] in self?.showSettings() }
        hideEngine = engine
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
            }
        }
        settingsWindowController?.show()
    }

    private func persist(_ updated: Preferences) {
        preferences = updated
        preferencesStore.save(updated)
    }
}
