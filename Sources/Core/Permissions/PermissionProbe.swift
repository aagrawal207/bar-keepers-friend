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
    public mutating func refresh(using probe: PermissionProbe) {
        for permission in Permission.allCases {
            let fresh = probe.status(of: permission)
            let previous = statuses[permission]
            if previous == .granted, fresh != .granted {
                statuses[permission] = .lapsed
            } else {
                statuses[permission] = fresh
            }
        }
    }
}
