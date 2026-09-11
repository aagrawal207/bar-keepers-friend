import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Hosts the SwiftUI settings view in an AppKit window. The agent app has no normal window
/// of its own, so we create one on demand and bring the app forward to show it.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    let model: SettingsModel

    init(
        preferences: Preferences,
        loginItem: LoginItemService,
        itemsProvider: @escaping () async throws -> [FloatingBarItem],
        onRetryPlacement: @escaping () -> Void = {},
        onChange: @escaping (Preferences) -> Void
    ) {
        self.model = SettingsModel(
            preferences: preferences,
            loginItem: loginItem,
            itemsProvider: itemsProvider,
            onRetryPlacement: onRetryPlacement,
            onChange: onChange
        )
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Bar Keeper's Friend"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Observable bridge between the SwiftUI view and `Preferences`. Lives in the app target
/// because it touches AppKit (`LoginItemService`); the data it edits is the pure Core type.
@MainActor
@Observable
final class SettingsModel {
    var preferences: Preferences {
        didSet { onChange(preferences) }
    }

    private let loginItem: LoginItemService
    private let onRetryPlacement: () -> Void
    private let onChange: (Preferences) -> Void
    /// Supplies every manageable menu bar item (both shown and hidden) so the Items tab can list
    /// everything the user might want to toggle. Async because it enumerates + attributes the live
    /// menu bar (an Accessibility sweep off the main thread).
    private let itemsProvider: () async throws -> [FloatingBarItem]

    init(
        preferences: Preferences,
        loginItem: LoginItemService,
        itemsProvider: @escaping () async throws -> [FloatingBarItem],
        onRetryPlacement: @escaping () -> Void = {},
        onChange: @escaping (Preferences) -> Void
    ) {
        self.preferences = preferences
        self.loginItem = loginItem
        self.itemsProvider = itemsProvider
        self.onRetryPlacement = onRetryPlacement
        self.onChange = onChange
    }

    var launchAtLogin: Bool {
        get { preferences.launchAtLogin }
        set {
            // Persist what ACTUALLY happened, not what was asked. If SMAppService rejects the
            // change (e.g. the user must approve it in System Settings), `setEnabled` returns
            // false and we keep the prior value — so the @Observable toggle snaps back instead
            // of claiming "on" while the app won't actually launch.
            let succeeded = loginItem.setEnabled(newValue)
            preferences.launchAtLogin = succeeded ? newValue : preferences.launchAtLogin
        }
    }

    // MARK: - Permissions

    /// Live authorization state for Accessibility + Screen Recording, refreshed from the probe.
    /// The Pro features fail silently without these, so the Settings UI surfaces them and lets the
    /// user jump straight to the right System Settings pane.
    private(set) var permissions = PermissionState()
    private let permissionProbe: PermissionProbe = SystemPermissionProbe()
    var onAccessibilityGranted: (() -> Void)?

    /// Re-reads permission status from the system. Called when the Settings window appears and
    /// can be polled while it's open so a grant the user just toggled in System Settings shows up
    /// without reopening. Cheap (two boolean syscalls); promotes a regranted-then-revoked
    /// permission to `.lapsed` via the pure state machine.
    func refreshPermissions() {
        let wasGranted = permissions.status(of: .accessibility) == .granted
        permissions.refresh(using: permissionProbe)
        if !wasGranted, permissions.status(of: .accessibility) == .granted {
            onAccessibilityGranted?()
        }
    }

    /// Status of a single permission for the UI to render.
    func status(of permission: Permission) -> PermissionStatus {
        permissions.status(of: permission)
    }

    /// Opens the System Settings pane for a permission (and, for Accessibility, fires the grant
    /// prompt so the app appears in the list). Invoked by the Permissions section's button.
    func openPermissionSettings(_ permission: Permission) {
        switch permission {
        case .accessibility:
            AccessibilityPermission.requestAndOpenSettings()
        case .screenRecording:
            ScreenRecordingPermission.openSettings()
        }
    }

    // MARK: - Items management

    private(set) var loadedItems: [FloatingBarItem] = []
    private(set) var itemsLoading = true
    private(set) var itemsLoadError: String? = nil
    @ObservationIgnored private var itemsLoadGeneration: UInt64 = 0
    var placementInProgress = false
    var placementMessage: String? = nil
    var placementFailed = false

    func reloadItems() async {
        guard !Task.isCancelled else { return }
        itemsLoadGeneration &+= 1
        let generation = itemsLoadGeneration
        itemsLoading = true
        itemsLoadError = nil
        // Tab loads and placement refreshes can overlap without cancelling each other.
        defer {
            if generation == itemsLoadGeneration { itemsLoading = false }
        }
        do {
            let refreshed = try await itemsProvider()
            guard generation == itemsLoadGeneration, !Task.isCancelled else { return }
            loadedItems = refreshed
        } catch {
            guard generation == itemsLoadGeneration,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            itemsLoadError = "Could not read menu bar items. Try again."
        }
    }

    /// Grouping and row controls must agree so a failed move keeps its opposite action available.
    func partition(_ items: [FloatingBarItem]) -> (hidden: [FloatingBarItem], shown: [FloatingBarItem]) {
        var hidden: [FloatingBarItem] = []
        var shown: [FloatingBarItem] = []
        for item in items {
            if isHidden(item) { hidden.append(item) } else { shown.append(item) }
        }
        return (hidden, shown)
    }

    /// Pending placement can display intent, but an observed failure must remain actionable.
    func isHidden(_ item: FloatingBarItem) -> Bool {
        let controls = preferences.itemControls
        if placementInProgress && controls.hasPlacementIntent(item.snapshot) {
            return controls.isHidden(item.snapshot)
        }
        return item.observedHidden ?? controls.isHidden(item.snapshot)
    }

    func setHidden(_ hidden: Bool, for item: FloatingBarItem) {
        setHidden(hidden, forAll: [item])
    }

    /// A batch needs only one preference write. Identical intent still needs a retry because
    /// a native move may have failed without changing the saved request.
    func setHidden(_ hidden: Bool, forAll items: [FloatingBarItem]) {
        var controls = preferences.itemControls
        for item in items {
            controls.setHidden(hidden, for: item.snapshot)
        }
        if controls == preferences.itemControls {
            onRetryPlacement()
        } else {
            preferences.itemControls = controls
        }
    }

    /// The user's display nickname for the item, edited via the name field. Empty clears it.
    func alias(for item: FloatingBarItem) -> String {
        preferences.itemAliases.alias(for: item.snapshot) ?? ""
    }

    func setAlias(_ alias: String, for item: FloatingBarItem) {
        preferences.itemAliases.setAlias(alias, for: item.snapshot)
    }

    // MARK: - Layout export/import

    /// A short status line shown under the Backup buttons after an export/import. `nil` when
    /// there's nothing to report; `transferFailed` colors it as an error.
    private(set) var transferMessage: String?
    private(set) var transferFailed = false

    /// Writes the current settings to a user-chosen JSON file.
    func exportLayout() {
        if let url = LayoutTransferService.exportLayout(preferences) {
            transferFailed = false
            transferMessage = "Exported to \(url.lastPathComponent)."
        } else {
            // Nil means the user cancelled or the write failed; treat a cancel as no-news.
            transferMessage = nil
        }
    }

    /// Reads settings from a user-chosen JSON file and applies them. A malformed/incompatible
    /// file surfaces an error line instead of throwing into the UI. Assigning `preferences`
    /// triggers `onChange`, so the whole app (engine, bar, hotkeys) re-applies at once.
    func importLayout() {
        do {
            if var imported = try LayoutTransferService.importLayout() {
                // Keep the login-item registration in sync with the imported flag, and record
                // what actually took: if registration was rejected, don't persist a launchAtLogin
                // the system didn't honor (same truth-over-intent rule as the toggle setter).
                let succeeded = loginItem.setEnabled(imported.launchAtLogin)
                if !succeeded { imported.launchAtLogin = loginItem.isEnabled }
                preferences = imported
                transferFailed = false
                transferMessage = "Imported settings."
            } else {
                transferMessage = nil // cancelled
            }
        } catch {
            transferFailed = true
            transferMessage = "Couldn't import that file — it isn't a valid layout."
        }
    }
}
