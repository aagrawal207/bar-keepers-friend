import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` for launch-at-login. The modern (macOS 13+) API:
/// the main app registers itself, no separate helper bundle required.
@MainActor
final class LoginItemService {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
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
