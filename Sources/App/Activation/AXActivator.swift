import AppKit
import ApplicationServices
import BarKeepersFriendCore

/// Activates a real menu bar item by pressing its Accessibility element.
///
/// A synthesized `CGEvent` click at a status item's frame is unreliable on macOS 26 — the
/// menu rarely opens. The robust path is `AXUIElementPerformAction`: it executes inside the
/// owning app, which then opens and positions its own menu natively.
///
/// The owning app's pid comes from attribution (cached by the controller), so the common case
/// queries exactly one app — no full sweep, so activation is near-instant. If the pid is
/// unknown (attribution didn't match the item), it falls back to sweeping all apps. Matching
/// reuses the shared `MenuBarExtraMatcher` (left-edge, nearest-wins) so it can never disagree
/// with how the item was labelled.
///
/// Concurrency: the running-apps list (only needed for the fallback) is read on the main
/// actor; the synchronous Accessibility IPC runs in a detached task. `AXUIElement` (a
/// non-Sendable CF type) never crosses an actor boundary — only `pid_t` in and `Bool` out.
enum AXActivator {

    /// Outcome of attempting to press the matching extra within a set of apps.
    private enum PressOutcome {
        /// An action succeeded — the menu opened.
        case pressed
        /// The element was found (or had drifted) but no action worked. Sweeping other apps
        /// is pointless: the element is right, it just isn't pressable that way.
        case matchedNoAction
        /// No extra matched in these apps — a wider sweep may locate it.
        case noMatch
    }

    /// Attempts to press the menu bar element matching `frame`, preferring the app `pid` when
    /// known. Returns whether a press succeeded. The item must already be on-screen (revealed)
    /// so the app opens its menu in the visible menu bar rather than off-screen.
    static func activate(windowID: CGWindowID, pid: pid_t, frame targetFrame: CGRect) async -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return false }

        // Single-app fast path: query only the owning app.
        if pid > 0 {
            let outcome = await runCancellable {
                pressMatchingChild(in: [pid], windowID: windowID, frame: targetFrame, timeout: 0.5)
            }
            switch outcome {
            case .pressed:
                return true
            case .matchedNoAction:
                // Correct element, unsupported action. Don't sweep (it would re-find and
                // re-fail the same element, the multi-second slow path); hand off to the
                // caller's frame-based CGEvent fallback, which also fixes a wrong-pid match.
                return false
            case .noMatch:
                break // attribution gave no/wrong pid — a full sweep may locate it
            }
        }

        // If a newer activation superseded this one while the fast path ran, don't start the
        // expensive all-apps sweep — its result would be discarded anyway. `activate` runs in the
        // caller's task, so `Task.isCancelled` here reflects the caller's `cancel()`.
        if Task.isCancelled { return false }

        // Fallback: attribution didn't give a usable pid (or found nothing in it).
        // Sweep all apps, accumulating candidates so the global nearest wins.
        let pids: [pid_t] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                (app.activationPolicy != .prohibited || app.bundleIdentifier != nil)
                    ? app.processIdentifier : nil
            }
        }
        return await runCancellable {
            pressMatchingChild(in: pids, windowID: windowID, frame: targetFrame, timeout: 1.5)
        } == .pressed
    }

    /// Runs the synchronous Accessibility IPC off the main actor in a detached task, while still
    /// honoring the *caller's* cancellation. A bare `Task.detached` severs cancellation (a detached
    /// task has no parent), so a superseded activation's sweep would otherwise grind through every
    /// app at the full per-app timeout (1.5s × N) producing a result no one wants. Wiring the
    /// caller's cancellation through `withTaskCancellationHandler` cancels the detached task, and
    /// `pressMatchingChild` then bails on `Task.isCancelled`. When NOT cancelled this is exactly
    /// `await task.value` — byte-identical to the previous inline `Task.detached { … }.value`.
    private static func runCancellable(_ work: @Sendable @escaping () -> PressOutcome) async -> PressOutcome {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Finds the extra (across `pids`) whose left edge is nearest the target frame and presses
    /// it. Collects all candidates first so the *global* nearest wins (items can be ~3 pt
    /// apart). Safe off the main thread; no `AXUIElement` escapes this function.
    private static func pressMatchingChild(
        in pids: [pid_t],
        windowID: CGWindowID,
        frame targetFrame: CGRect,
        timeout: Float
    ) -> PressOutcome {
        var candidates: [(leftEdge: CGFloat, value: AXUIElement)] = []
        var candidateYs: [CGFloat] = []
        for pid in pids {
            // Bail if a newer activation superseded us mid-sweep: each app can cost up to the full
            // messaging timeout, so a cancelled all-apps sweep would otherwise keep blocking on
            // unresponsive apps long after its result stopped mattering.
            if Task.isCancelled { return .noMatch }
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, timeout)
            guard let extrasMenu = copyElement(axApp, attribute: "AXExtrasMenuBar") else { continue }
            for child in copyChildren(extrasMenu) {
                if let position = copyPosition(child) {
                    candidates.append((leftEdge: position.x, value: child))
                    candidateYs.append(position.y)
                }
            }
        }
        // Match on left edge AND a y band: the fallback sweeps every app across every display, so
        // without y an extra on another display's menu bar (same x, far-off y) could win and we'd
        // press the wrong item. The single-app fast path collects only one bar's extras, but the
        // band is harmless there. Shares MenuBarExtraMatcher with attribution so the two agree.
        guard let child = MenuBarExtraMatcher.nearest(
            to: targetFrame.minX,
            among: candidates,
            targetY: targetFrame.minY,
            candidateYs: candidateYs
        ) else {
            DebugLog.log("AXActivator: no actionable element for \(windowID) at \(targetFrame)")
            return .noMatch
        }
        // Re-read the matched element's live position; if it has drifted out of tolerance the
        // frame was stale (or a pid was reused for a different app) — don't press the wrong one.
        if let live = copyPosition(child), abs(live.x - targetFrame.minX) > MenuBarExtraMatcher.tolerance {
            DebugLog.log("AXActivator: matched element drifted for \(windowID) (live \(live.x) vs \(targetFrame.minX))")
            return .matchedNoAction
        }
        for action in [kAXPressAction as String, "AXShowMenu"] {
            guard !Task.isCancelled else { return .noMatch }
            let err = AXUIElementPerformAction(child, action as CFString)
            if err == .success {
                DebugLog.log("AXActivator: \(action) succeeded for \(windowID)")
                return .pressed
            }
            DebugLog.log("AXActivator: \(action) on \(windowID) returned AXError \(err.rawValue)")
        }
        // Some extras (e.g. Control Center module groups) aren't pressable themselves but wrap
        // a pressable child. Try the position-matched child so we don't press the wrong module.
        if let pressable = nearestPressableChild(of: child, targetMinX: targetFrame.minX) {
            for action in [kAXPressAction as String, "AXShowMenu"] {
                guard !Task.isCancelled else { return .noMatch }
                if AXUIElementPerformAction(pressable, action as CFString) == .success {
                    DebugLog.log("AXActivator: \(action) succeeded on child of \(windowID)")
                    return .pressed
                }
            }
        }
        DebugLog.log("AXActivator: element matched but no action succeeded for \(windowID)")
        return .matchedNoAction
    }

    /// Among `element`'s direct children that advertise a press action, returns the one whose
    /// left edge is nearest `targetMinX` within tolerance — so a multi-control group (Control
    /// Center) is never pressed on the wrong child.
    private static func nearestPressableChild(of element: AXUIElement, targetMinX: CGFloat) -> AXUIElement? {
        var candidates: [(leftEdge: CGFloat, value: AXUIElement)] = []
        for child in copyChildren(element) {
            var actions: CFArray?
            guard AXUIElementCopyActionNames(child, &actions) == .success,
                  let names = actions as? [String], names.contains(kAXPressAction as String),
                  let position = copyPosition(child) else { continue }
            candidates.append((leftEdge: position.x, value: child))
        }
        return MenuBarExtraMatcher.nearest(to: targetMinX, among: candidates)
    }

    // MARK: - AX helpers

    private static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static func copyPosition(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
}
