import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Hosts the SwiftUI settings view in an AppKit window. The agent app has no normal window
/// of its own, so we create one on demand and bring the app forward to show it.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(
        preferences: Preferences,
        loginItem: LoginItemService,
        itemsProvider: @escaping () -> [FloatingBarItem],
        refreshItems: @escaping () -> Void,
        onChange: @escaping (Preferences) -> Void
    ) {
        self.model = SettingsModel(
            preferences: preferences,
            loginItem: loginItem,
            itemsProvider: itemsProvider,
            refreshItems: refreshItems,
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
    private let onChange: (Preferences) -> Void
    /// Supplies the current hidden items (the full set, including suppressed ones) so the Items
    /// tab can list everything the user might want to manage.
    private let itemsProvider: () -> [FloatingBarItem]
    /// Asks the engine to refresh the mirror cache (a no-op while the section is in use), so
    /// opening the Items tab picks up items added since the last capture.
    private let refreshItems: () -> Void

    init(
        preferences: Preferences,
        loginItem: LoginItemService,
        itemsProvider: @escaping () -> [FloatingBarItem],
        refreshItems: @escaping () -> Void,
        onChange: @escaping (Preferences) -> Void
    ) {
        self.preferences = preferences
        self.loginItem = loginItem
        self.itemsProvider = itemsProvider
        self.refreshItems = refreshItems
        self.onChange = onChange
    }

    var launchAtLogin: Bool {
        get { preferences.launchAtLogin }
        set {
            loginItem.setEnabled(newValue)
            preferences.launchAtLogin = newValue
        }
    }

    // MARK: - Items management

    /// The current hidden items (full set, including suppressed) to list in the Items tab.
    func items() -> [FloatingBarItem] { itemsProvider() }

    /// Asks the engine to refresh the mirror so the list reflects items added since launch.
    /// Called when the Items tab appears; safe (a no-op while the section is in use).
    func refreshItemList() { refreshItems() }

    /// Whether the item is shown in the floating bar (the inverse of "search only"). Assigning
    /// mutates `preferences.itemControls`, which fires `onChange` so the bar re-renders at once.
    func showsInBar(_ item: FloatingBarItem) -> Bool {
        !preferences.itemControls.isSuppressed(item.snapshot)
    }

    func setShowsInBar(_ shows: Bool, for item: FloatingBarItem) {
        preferences.itemControls.setSuppressed(!shows, for: item.snapshot)
    }

    /// The user's search alias for the item, edited via the alias field. Empty clears it.
    func alias(for item: FloatingBarItem) -> String {
        preferences.itemAliases.alias(for: item.snapshot) ?? ""
    }

    func setAlias(_ alias: String, for item: FloatingBarItem) {
        preferences.itemAliases.setAlias(alias, for: item.snapshot)
    }

    /// Whether this item can be controlled (suppressed/aliased) at all — only items with a
    /// stable owner identity (bundle id) can, since that's the persistence key.
    func isControllable(_ item: FloatingBarItem) -> Bool {
        ItemControlStore.key(for: item.snapshot) != nil
    }

    /// Applies a drag-reorder of the bar items. `order` is the bundle-id-keyed list the user
    /// dragged into place; we write a dense `barOrder` index per controllable item so the bar
    /// renders them in that order. Items without a stable key are skipped (can't be pinned).
    func reorderBarItems(_ ordered: [FloatingBarItem]) {
        var controls = preferences.itemControls
        var index = 0
        for item in ordered {
            guard ItemControlStore.key(for: item.snapshot) != nil else { continue }
            controls.setOrderIndex(index, for: item.snapshot)
            index += 1
        }
        preferences.itemControls = controls
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
    /// triggers `onChange`, so the whole app (engine, bar, hotkeys, hover) re-applies at once.
    func importLayout() {
        do {
            if let imported = try LayoutTransferService.importLayout() {
                // Keep the login-item registration in sync with the imported flag.
                loginItem.setEnabled(imported.launchAtLogin)
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
