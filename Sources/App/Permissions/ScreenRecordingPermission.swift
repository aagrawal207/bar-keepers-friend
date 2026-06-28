import AppKit
import BarKeepersFriendCore
import CoreGraphics

/// Helpers for the Screen Recording permission, which is required to capture images of hidden
/// menu bar icons for the floating bar. Mirrors `AccessibilityPermission`.
enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Opens the Screen Recording privacy pane in System Settings so the user can enable the app.
    /// Unlike Accessibility there's no in-process prompt API that behaves well here (the reliable
    /// trigger is touching `SCShareableContent`, which `IconCaptureService` already does at
    /// launch); this button just routes the user to the pane to flip the toggle.
    static func openSettings() {
        if let url = URL(string: Permission.screenRecording.settingsURLString) {
            NSWorkspace.shared.open(url)
        }
    }
}
