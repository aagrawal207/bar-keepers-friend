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
///
/// Why a *global* AND a *local* monitor: `addGlobalMonitorForEvents` only fires for events
/// delivered to OTHER apps, never our own — so while the user's pointer is over a window we own
/// (e.g. the floating bar itself, briefly) we'd go blind without the local one. The local monitor
/// covers exactly that gap and must return the event unchanged so it isn't swallowed.
///
/// Why no permission gate: reading `NSEvent.mouseLocation` (or a move event's location) is just
/// reading where the cursor is, which any app may do. The Accessibility/Input-Monitoring prompt
/// is only required to *synthesize* or intercept-and-modify events, neither of which we do here.
///
/// Concurrency: the class is `@MainActor`, and AppKit delivers these monitor callbacks on the
/// main thread. The closures hop onto the main actor with `MainActor.assumeIsolated` so Swift 6
/// can see the call into `handleMove()` is already correctly isolated, with no runtime hop.
@MainActor
final class HoverRevealMonitor {
    /// Returns the anchor's current global (AppKit, bottom-left origin) frame, or nil if the
    /// anchor isn't realized yet. Set by the coordinator.
    var anchorFrameProvider: (() -> CGRect?)?
    /// Invoked on the main actor when the pointer has dwelled over the anchor long enough.
    var onReveal: (() -> Void)?

    /// Opaque tokens from `NSEvent.add*MonitorForEvents`. Non-nil exactly while monitoring is on;
    /// used both as the install guard and as the handles to pass back to `removeMonitor`.
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// The dwell countdown. Scheduled when the pointer enters the anchor region, fired once if it
    /// is still inside `dwellDelay` later, and cancelled the moment it leaves. A `DispatchWorkItem`
    /// (rather than a `Timer`) so replacing/cancelling it is a single cheap, unambiguous operation.
    private var dwellWorkItem: DispatchWorkItem?
    /// Dwell duration in seconds, mirrored from the latest `preferences.hoverRevealDelay` so a
    /// changed preference takes effect on the next enter without reinstalling the monitors.
    private var dwellDelay: TimeInterval = 0.25

    /// True while the pointer is currently considered inside the anchor region. Lets us tell an
    /// ENTER (schedule the dwell) from continued movement WITHIN the region (leave the pending
    /// timer alone) from a LEAVE (cancel it) — without restarting the countdown on every event.
    private var pointerInside = false
    /// Re-arm latch: a reveal only fires when `true`, and it is cleared the instant we fire. It
    /// re-arms only once the pointer has LEFT the region. Without this, the pointer parked over
    /// the anchor would re-fire `onReveal` every `dwellDelay`, fighting whatever the reveal did.
    private var armed = true

    /// How far to inflate the anchor rect before the hit-test, so a near-miss still reveals. The
    /// menu bar is a thin strip and the user aims roughly; a few points of slop on the sides and a
    /// little extra reach BELOW the bar (where the cursor naturally overshoots on the way down)
    /// makes the gesture forgiving without swallowing unrelated pointer travel.
    private static let horizontalSlop: CGFloat = 4
    private static let bottomReach: CGFloat = 6

    /// Starts/stops monitoring to match preferences. Safe to call repeatedly.
    func apply(preferences: Preferences) {
        // Always keep the dwell in sync; cheap and lets a preference change land without a
        // reinstall when monitoring is already running.
        dwellDelay = preferences.hoverRevealDelay

        if preferences.hoverToReveal {
            install() // no-ops if already installed
        } else {
            teardown()
        }
    }

    /// Removes the monitors. Called on teardown.
    func teardown() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancelDwell()
        // Reset the gesture state so a later re-enable starts clean rather than mid-dwell.
        pointerInside = false
        armed = true
    }

    // MARK: - Internals

    /// Installs both monitors, guarding against a double-install (idempotent `apply`).
    private func install() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        // Fires only for events routed to OTHER apps — the common case while the user works.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMove() }
        }
        // Fires for events routed to US; must return the event unchanged so we don't swallow it.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMove() }
            return event
        }
    }

    /// Per-move handler. Kept deliberately tiny because `.mouseMoved` fires at pointer cadence.
    private func handleMove() {
        // Cheap bail when disabled (defensive — monitors are removed when off, but a queued
        // callback could still arrive between removal and drain).
        guard globalMonitor != nil || localMonitor != nil else { return }

        // No anchor yet (bar not realized) — treat as "outside" so a stale dwell can't fire.
        guard let anchor = anchorFrameProvider?() else {
            handleLeave()
            return
        }

        let region = anchor
            .insetBy(dx: -Self.horizontalSlop, dy: 0)            // a little side slop
            .offsetBy(dx: 0, dy: -Self.bottomReach / 2)          // shift down so the extra...
            .insetBy(dx: 0, dy: -Self.bottomReach / 2)           // ...height lands below the bar
        let inside = region.contains(NSEvent.mouseLocation)

        if inside {
            handleEnterOrStay()
        } else {
            handleLeave()
        }
    }

    /// Pointer is inside the region. On the transition from outside, start the dwell countdown;
    /// while it stays inside, do nothing (don't restart the timer on every jiggle).
    private func handleEnterOrStay() {
        guard !pointerInside else { return } // already inside — let the running dwell continue
        pointerInside = true
        guard armed else { return } // fired this visit already; wait for a leave to re-arm
        scheduleDwell()
    }

    /// Pointer is outside the region. Cancel any pending dwell and re-arm so the next genuine
    /// enter can fire again.
    private func handleLeave() {
        guard pointerInside || dwellWorkItem != nil || !armed else { return }
        pointerInside = false
        armed = true
        cancelDwell()
    }

    /// Arms a one-shot main-queue work item for `dwellDelay`. If the pointer is still inside when
    /// it fires, reveal once and disarm until the next leave/enter.
    private func scheduleDwell() {
        cancelDwell()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointerInside, self.armed else { return }
            self.armed = false
            self.dwellWorkItem = nil
            self.onReveal?()
        }
        dwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellDelay, execute: work)
    }

    /// Cancels and clears the pending dwell, if any.
    private func cancelDwell() {
        dwellWorkItem?.cancel()
        dwellWorkItem = nil
    }
}
