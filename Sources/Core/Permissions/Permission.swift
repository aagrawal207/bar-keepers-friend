import Foundation

/// The macOS privacy permissions this app can require.
///
/// Crucially, the Phase 1 cosmetic hide/show needs **neither** of these — that is what
/// keeps the baseline unbreakable. They are only required by the Pro layer.
public enum Permission: String, CaseIterable, Sendable {
    /// Needed to move/reorder and click other apps' items (synthesized events).
    case accessibility
    /// Needed to render images of hidden items for search / the overflow bar.
    case screenRecording

    /// Whether the core app can function without this permission.
    public var isOptional: Bool {
        switch self {
        case .accessibility: return true       // Pro reorder/click; core works without it
        case .screenRecording: return true      // only for icon previews
        }
    }

    /// The System Settings deep-link that opens the relevant privacy pane.
    public var settingsURLString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}

/// Authorization state of a single permission.
public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    /// Granted previously but the system is re-prompting (Sequoia/Tahoe recurring prompt).
    case lapsed
    case notDetermined
}
