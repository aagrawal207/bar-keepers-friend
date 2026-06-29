import Foundation

/// What the app is doing right now, surfaced as a single line in the anchor's right-click menu so
/// the user has a plain-language read on whether it's idle or busy.
///
/// Pure and derived from counters/flags the engine already tracks, so the label shown to the user
/// is computed (and unit-tested) here rather than assembled ad-hoc in the menu builder. Ordered by
/// precedence: when several conditions hold at once, `derive` returns the most informative one.
public enum AppStatus: Equatable, Sendable {
    /// The user has paused the app: it reveals hidden items in place and stops all hiding,
    /// revealing, and moving until un-paused. A deliberate mode, not a transient activity.
    case paused
    /// Idle — nothing in flight.
    case ready
    /// Physically moving items across the anchor (a reconcile / synthesized move is running).
    case working
    /// A capture sequence is running (revealing + screenshotting the menu bar to refresh icons).
    case collecting
    /// An update is available to install (Sparkle found one). Not wired yet; modeled now so the
    /// menu's status line and the future Check-for-Updates item agree on one source of truth.
    case updateAvailable

    /// The user-facing label for the menu's status line.
    public var label: String {
        switch self {
        case .paused: return "Paused"
        case .ready: return "Ready"
        case .working: return "Working…"
        case .collecting: return "Collecting icons…"
        case .updateAvailable: return "Update available"
        }
    }

    /// Derives the status from the engine's live signals, most-informative-first.
    ///
    /// `paused` wins over everything: it's the dominant mode the user chose, and while paused the
    /// app does nothing else anyway. Then `updateAvailable` (a standing fact to act on), then the
    /// two transient busy states (a move, then a capture), else `ready`. The caller passes whatever
    /// it tracks — `paused` from the pause flag, `moving` from the reconcile path, `capturing` from
    /// `captureInFlight`, `updateAvailable` from the (future) updater.
    public static func derive(
        paused: Bool,
        moving: Bool,
        capturing: Bool,
        updateAvailable: Bool
    ) -> AppStatus {
        if paused { return .paused }
        if updateAvailable { return .updateAvailable }
        if moving { return .working }
        if capturing { return .collecting }
        return .ready
    }
}
