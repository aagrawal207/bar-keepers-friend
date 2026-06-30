import AppKit
import BarKeepersFriendCore

/// Resolves the set of process IDs whose menu-bar items must never be moved.
///
/// Two owners are off-limits no matter what intent a snapshot carries:
///   - **Control Center.** Every Control Center *module* (Wi-Fi, Battery, Sound, Clock, the
///     screen-recording/location privacy indicator, …) is a child of the single Control Center
///     process, so one pid catches them all — and it's locale-independent, unlike matching each
///     module's localized display label. These items can't be relocated by the window server
///     (they snap back), so planning a move for them just fails forever.
///   - **Our own app.** A stray "Hide All" (or a corrupt imported layout) can otherwise sweep
///     BKF's own status windows — anchor, divider, or any other — into the hidden set. Moving our
///     own anchor shifts the very hide/show boundary every reconcile measures against, which sends
///     reconcile into an endless re-plan loop (the anchor walks across the bar and never settles).
///     Excluding our pid is a belt-and-suspenders backstop to the window-id / "BKF" name guards.
///
/// Passed to `HiddenLayoutPlanner.moves` and the Settings picker (both operate on ATTRIBUTED
/// snapshots, where each item carries its real owning pid — the only place this set is valid;
/// on raw snapshots every item reports the bogus Control-Center pid, FB18327911).
enum ImmovableProcessIDs {

    /// Control Center's bundle id — the owner of every Control Center module item.
    static let controlCenterBundleID = "com.apple.controlcenter"

    /// The current immovable-pid set: Control Center (if running) plus this process.
    static func current() -> Set<pid_t> {
        var pids: Set<pid_t> = [getpid()]
        if let cc = NSRunningApplication
            .runningApplications(withBundleIdentifier: controlCenterBundleID)
            .first?
            .processIdentifier {
            pids.insert(cc)
        }
        return pids
    }
}
