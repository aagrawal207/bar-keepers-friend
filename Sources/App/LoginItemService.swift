import BarKeepersFriendCore
import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` for launch-at-login. The modern (macOS 13+) API:
/// the main app registers itself, no separate helper bundle required.
@MainActor
final class LoginItemService {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The current registration state, mapped to the Core `LoginItemStatus` so the pure
    /// `LoginItemReconciler` can decide what (if anything) to do about it.
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// Registers or unregisters the app as a login item. Returns whether it succeeded.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Opens System Settings › General › Login Items so the user can approve if needed.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Seam over the live registration so Settings can be driven by a fake that never registers,
/// unregisters, or opens System Settings.
@MainActor
protocol LoginItemManaging: AnyObject {
    var status: LoginItemStatus { get }
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool
    func openSystemSettings()
}

extension LoginItemManaging {
    var isEnabled: Bool { status == .enabled }
}

extension LoginItemService: LoginItemManaging {}
