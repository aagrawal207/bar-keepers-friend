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
        onChange: @escaping (Preferences) -> Void
    ) {
        self.model = SettingsModel(
            preferences: preferences,
            loginItem: loginItem,
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

    init(
        preferences: Preferences,
        loginItem: LoginItemService,
        onChange: @escaping (Preferences) -> Void
    ) {
        self.preferences = preferences
        self.loginItem = loginItem
        self.onChange = onChange
    }

    var launchAtLogin: Bool {
        get { preferences.launchAtLogin }
        set {
            loginItem.setEnabled(newValue)
            preferences.launchAtLogin = newValue
        }
    }
}
