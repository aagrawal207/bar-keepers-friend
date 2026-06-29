import Foundation

/// Launch-at-login registration state, mirrored from `SMAppService.Status` so the reconcile
/// decision can be expressed (and tested) in Core without importing ServiceManagement.
public enum LoginItemStatus: Equatable, Sendable {
    /// Registered and will launch at login.
    case enabled
    /// Not a login item.
    case notRegistered
    /// Registered but the user must approve it in System Settings › Login Items (or has toggled
    /// it off there). The system already knows our intent — re-registering won't force it on.
    case requiresApproval
    /// The service couldn't be located (shouldn't happen for the main app).
    case notFound
}

/// What to do to bring the actual registration in line with the desired preference.
public enum LoginItemAction: Equatable, Sendable {
    case none
    case register
    case unregister
}

/// Pure decision for keeping launch-at-login registration in sync with the saved preference.
///
/// Two reachable bugs motivated this: (1) the app never re-applied the saved pref at startup, so
/// a registration lost to an OS update or a manual removal stayed lost; (2) the toggle persisted
/// the user's choice even when `SMAppService` rejected it, so the UI could claim "on" while the
/// app would not actually launch. The logic that decides *what* to do lives here, pure and
/// tested; the app only performs the chosen action and reflects the real resulting state.
public enum LoginItemReconciler {

    /// The registration action that reconciles `actual` with the user's `desired` pref.
    ///
    /// `requiresApproval` is treated as "leave it": the system already has our registration on
    /// file pending the user's approval, so re-registering every launch would only fight a user
    /// who deliberately disabled it in System Settings. `notRegistered`/`notFound` while desired
    /// is the lost-registration case worth re-asserting.
    public static func decide(desired: Bool, actual: LoginItemStatus) -> LoginItemAction {
        switch (desired, actual) {
        case (true, .notRegistered), (true, .notFound):
            return .register
        case (false, .enabled):
            return .unregister
        default:
            return .none
        }
    }
}
