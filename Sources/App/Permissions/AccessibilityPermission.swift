import ApplicationServices
import AppKit
import BarKeepersFriendCore

/// Helpers for the Accessibility (AXIsProcessTrusted) permission, which is required to
/// synthesize clicks into other apps' menu bar items.
enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Triggers the system "grant Accessibility" prompt and opens the relevant System
    /// Settings pane, so the user can enable the app. Granting takes effect for new clicks
    /// without a relaunch.
    static func requestAndOpenSettings() {
        // The prompt option surfaces the system dialog if not yet granted. The key string is
        // "AXTrustedCheckOptionPrompt"; using the literal avoids referencing the non-
        // concurrency-safe global constant under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: Permission.accessibility.settingsURLString) {
            NSWorkspace.shared.open(url)
        }
    }
}
