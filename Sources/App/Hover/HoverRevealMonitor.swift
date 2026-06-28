import AppKit
import BarKeepersFriendCore

/// Watches the pointer and reveals the floating bar when it dwells over the menu bar anchor —
/// the Bartender-style "hover to reveal". Off unless `preferences.hoverToReveal` is set.
///
/// AGENT: implement the monitor here. The public surface below is fixed — the coordinator sets
/// `anchorFrameProvider` / `onReveal` and calls `apply(preferences:)`. Do not change signatures.
///
/// Implementation guidance:
///  - Use a global `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` plus a local
///    monitor, so movement is seen whether or not our app is frontmost. This needs no extra
///    permission for mouse *location* (only synthesizing events would).
///  - Debounce: only fire `onReveal` after the pointer has stayed within the anchor's frame for
///    `preferences.hoverRevealDelay` seconds; cancel the pending reveal if it leaves.
///  - Be cheap: a mouse-moved monitor fires often. Do the frame test with a plain CGRect.contains
///    and bail immediately when hover-to-reveal is disabled.
@MainActor
final class HoverRevealMonitor {
    /// Returns the anchor's current global (AppKit, bottom-left origin) frame, or nil if the
    /// anchor isn't realized yet. Set by the coordinator.
    var anchorFrameProvider: (() -> CGRect?)?
    /// Invoked on the main actor when the pointer has dwelled over the anchor long enough.
    var onReveal: (() -> Void)?

    /// Starts/stops monitoring to match preferences. Safe to call repeatedly.
    func apply(preferences: Preferences) {
        // AGENT: install/remove the event monitors based on preferences.hoverToReveal; store the
        // delay; manage the debounce timer.
    }

    /// Removes the monitors. Called on teardown.
    func teardown() {
        // AGENT: remove any installed NSEvent monitors and cancel the debounce timer.
    }
}
