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

    /// A nil tab keeps whatever the user last selected; the window is created only once.
    func show(tab: SettingsView.Tab? = nil) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model, initialTab: tab ?? .general))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Bar Keeper's Friend"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else if let tab {
            model.requestedTab = tab
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
        didSet {
            if oldValue.itemControls.hiddenInMenuBar != preferences.itemControls.hiddenInMenuBar
                || oldValue.itemControls.shownInMenuBar != preferences.itemControls.shownInMenuBar {
                // A draft is relative to the arrangement that just changed underneath it.
                if !placementDraft.isEmpty {
                    draftDiscardedNotice = "Your pending placement edits were discarded because the saved arrangement changed (a preset or trigger applied)."
                }
                placementDraft = ItemPlacementDraft()
            }
            onChange(preferences)
        }
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
    private var placementDraft = ItemPlacementDraft()
    var placementInProgress = false
    var placementMessage: String? = nil
    var placementFailed = false
    var placementPending = false
    /// Set once a spacing change was written to the global domain; other apps read it at relaunch.
    var spacingNeedsLogout = false
    /// One-shot tab request from outside the window (onboarding, menu); the view consumes it.
    var requestedTab: SettingsView.Tab?
    /// Shown in the Items footer until the next edit, so a vanished draft is explained.
    var draftDiscardedNotice: String?

    /// Placement reads intent with grouped owners forced Hidden, exactly as the engine does.
    private var effectiveControls: ItemControlStore {
        ItemGroupLibrary.effectiveControls(groups: preferences.itemGroups, base: preferences.itemControls)
    }

    var hasPendingChanges: Bool { !placementDraft.isEmpty }

    /// Grouped owners are placed by their group, so the Items tab must not offer them a choice.
    func group(containing item: FloatingBarItem) -> ItemGroup? {
        guard let key = ItemControlStore.key(for: item.snapshot) else { return nil }
        return ItemGroupLibrary.group(containing: key, in: preferences.itemGroups)
    }
    var pendingChangeCount: Int { placementDraft.count }

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
        if let hidden = placementDraft.hidden(for: item.snapshot) { return hidden }
        let controls = effectiveControls
        if placementInProgress && controls.hasPlacementIntent(item.snapshot) {
            return controls.isHidden(item.snapshot)
        }
        return item.observedHidden ?? controls.isHidden(item.snapshot)
    }

    func hasPendingChange(for item: FloatingBarItem) -> Bool {
        placementDraft.hidden(for: item.snapshot) != nil
    }

    func setHidden(_ hidden: Bool, for item: FloatingBarItem) {
        setHidden(hidden, forAll: [item])
    }

    func setHidden(_ hidden: Bool, forAll items: [FloatingBarItem]) {
        guard !placementInProgress else { return }
        draftDiscardedNotice = nil
        placementDraft = draftSettingHidden(hidden, forAll: items)
    }

    func canSetHidden(_ hidden: Bool, forAll items: [FloatingBarItem]) -> Bool {
        guard !placementInProgress else { return false }
        return draftSettingHidden(hidden, forAll: items) != placementDraft
    }

    private func draftSettingHidden(_ hidden: Bool, forAll items: [FloatingBarItem]) -> ItemPlacementDraft {
        // Grouped owners are placed by their group; staging them would save intent that only
        // takes effect after an ungroup.
        let items = items.filter { group(containing: $0) == nil }
        let keys = Set(items.compactMap { ItemControlStore.key(for: $0.snapshot) })
        let itemIDs = Set(items.map(\.id))
        let siblings = loadedItems.filter {
            guard let key = ItemControlStore.key(for: $0.snapshot) else { return false }
            return keys.contains(key) && !itemIDs.contains($0.id)
        }
        var draft = placementDraft
        draft.setHidden(
            hidden, for: (items + siblings).map { ($0.snapshot, $0.observedHidden) },
            controls: preferences.itemControls
        )
        return draft
    }

    func applyPlacementChanges() {
        guard !placementInProgress, hasPendingChanges else { return }
        let controls = placementDraft.applying(to: preferences.itemControls)
        // Callbacks can synchronously reenter Settings; no applied edits may remain pending.
        placementDraft = ItemPlacementDraft()
        if controls != preferences.itemControls {
            preferences.itemControls = controls
        } else {
            // Cached section membership cannot verify the native destination's full-edge postcondition.
            onRetryPlacement()
        }
    }

    func discardPlacementChanges() {
        guard !placementInProgress else { return }
        placementDraft = ItemPlacementDraft()
    }

    func retryPlacement() {
        guard !placementInProgress, !hasPendingChanges, placementFailed || placementPending else { return }
        onRetryPlacement()
    }

    var placementPreview: (shown: [FloatingBarItem], hidden: [FloatingBarItem], unknown: [FloatingBarItem]) {
        // Apply reconciles every saved owner, including owners not edited in this draft.
        let controls = placementDraft.applying(to: effectiveControls)
        let projectsIntent = hasPendingChanges || placementInProgress
        var shown: [FloatingBarItem] = []
        var hidden: [FloatingBarItem] = []
        var unknown: [FloatingBarItem] = []
        for var item in loadedItems {
            item.alias = preferences.itemAliases.alias(for: item.snapshot)
            let projectedHidden: Bool? = projectsIntent && controls.hasPlacementIntent(item.snapshot)
                ? controls.isHidden(item.snapshot) : item.observedHidden
            switch projectedHidden {
            case true?: hidden.append(item)
            case false?: shown.append(item)
            case nil: unknown.append(item)
            }
        }
        let byID = Dictionary(hidden.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = ItemControlStore.visibleBarItems(from: hidden.map(\.snapshot), controls: controls)
        return (shown, visible.compactMap { byID[$0.windowID] }, unknown)
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
    func importLayout(
        using importer: @MainActor () throws -> Preferences? = { try LayoutTransferService.importLayout() }
    ) {
        do {
            if var imported = try importer() {
                // Keep the login-item registration in sync with the imported flag, and record
                // what actually took: if registration was rejected, don't persist a launchAtLogin
                // the system didn't honor (same truth-over-intent rule as the toggle setter).
                let succeeded = loginItem.setEnabled(imported.launchAtLogin)
                if !succeeded { imported.launchAtLogin = loginItem.isEnabled }
                // A trigger baseline and the onboarding flag describe this machine, not the file.
                imported.triggerState = TriggerRuntimeState()
                imported.hasCompletedOnboarding = preferences.hasCompletedOnboarding
                placementDraft = ItemPlacementDraft()
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
