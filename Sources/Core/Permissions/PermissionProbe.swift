import Foundation

/// Abstracts how the app discovers permission status, so the permission state machine can
/// be tested without real TCC prompts. The real implementation (app target) calls
/// `AXIsProcessTrusted` and the screen-capture preflight; tests inject a fake.
public protocol PermissionProbe: Sendable {
    func status(of permission: Permission) -> PermissionStatus
}

/// Derives a coherent view of permissions and detects lapses over time.
///
/// Pure aside from the injected probe, so every transition (none → granted → lapsed, etc.)
/// is unit-testable. The app polls `refresh()` roughly once a second to update the UI when
/// the user flips a toggle in System Settings.
public struct PermissionState: Equatable, Sendable {
    public private(set) var statuses: [Permission: PermissionStatus]

    public init(statuses: [Permission: PermissionStatus] = [:]) {
        self.statuses = statuses
    }

    public func status(of permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    /// True when all non-optional permissions are granted. Phase 1 requires none, so this
    /// is `true` by default — the core app is always usable.
    public var canRunCore: Bool {
        Permission.allCases
            .filter { !$0.isOptional }
            .allSatisfy { status(of: $0) == .granted }
    }

    /// Updates from a probe, marking a previously-granted permission as `.lapsed` if the
    /// probe now reports it ungranted (the recurring Sequoia/Tahoe re-prompt case).
    ///
    /// `.lapsed` must be **sticky**: the app polls this roughly once a second while Settings is
    /// open, and a lapse stays a lapse until the user actually re-grants. So a permission counts as
    /// "was granted" if its previous state is either `.granted` OR already `.lapsed` — otherwise the
    /// SECOND poll after the lapse (previous == .lapsed, fresh still ungranted) would fall through to
    /// the `else` and silently downgrade the row from "Needs re-approval" to "Not granted" after ~1s,
    /// which is exactly the never-granted-vs-lapsed confusion `.lapsed` exists to prevent. A fresh
    /// `.granted` from the probe always wins and clears the lapse.
    public mutating func refresh(using probe: PermissionProbe) {
        for permission in Permission.allCases {
            let fresh = probe.status(of: permission)
            let wasGranted = statuses[permission] == .granted || statuses[permission] == .lapsed
            if wasGranted, fresh != .granted {
                statuses[permission] = .lapsed
            } else {
                statuses[permission] = fresh
            }
        }
    }
}
