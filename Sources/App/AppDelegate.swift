import AppKit
import BarKeepersFriendCore

/// Entry point and lifecycle owner for the agent app.
///
/// Phase 0/1 responsibilities only: enforce single-instance, become an accessory (no Dock
/// icon), stand up the cosmetic hide/show engine, and own the settings window. The
/// fragile Pro layers are wired in later behind their protocol seams.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: visible only as a status item.
        NSApp.setActivationPolicy(.accessory)

        // Refuse to run a second copy — duplicate status items would be confusing.
        if AppCoordinator.anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }

        let coordinator = AppCoordinator()
        coordinator.start()
        self.coordinator = coordinator
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
