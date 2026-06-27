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

    /// Attempts to press the menu bar element matching `frame`, preferring the app `pid` when
    /// known. Returns whether a press succeeded. The item must already be on-screen (revealed)
    /// so the app opens its menu in the visible menu bar rather than off-screen.
    static func activate(windowID: CGWindowID, pid: pid_t, frame targetFrame: CGRect) async -> Bool {
        guard AXIsProcessTrusted() else { return false }

        // Single-app fast path: query only the owning app.
        if pid > 0 {
            let pressed = await Task.detached(priority: .userInitiated) {
                pressMatchingChild(in: [pid], windowID: windowID, frame: targetFrame, timeout: 0.5)
            }.value
            if pressed { return true }
        }

        // Fallback: attribution didn't give a usable pid (or the single-app match failed).
        // Sweep all apps, accumulating candidates so the global nearest wins.
        let pids: [pid_t] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                (app.activationPolicy != .prohibited || app.bundleIdentifier != nil)
                    ? app.processIdentifier : nil
            }
        }
        return await Task.detached(priority: .userInitiated) {
            pressMatchingChild(in: pids, windowID: windowID, frame: targetFrame, timeout: 1.5)
        }.value
    }

    /// Finds the extra (across `pids`) whose left edge is nearest the target frame and presses
    /// it. Collects all candidates first so the *global* nearest wins (items can be ~3 pt
    /// apart). Safe off the main thread; no `AXUIElement` escapes this function.
    private static func pressMatchingChild(
        in pids: [pid_t],
        windowID: CGWindowID,
        frame targetFrame: CGRect,
        timeout: Float
    ) -> Bool {
        var candidates: [(leftEdge: CGFloat, value: AXUIElement)] = []
        for pid in pids {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, timeout)
            guard let extrasMenu = copyElement(axApp, attribute: "AXExtrasMenuBar") else { continue }
            for child in copyChildren(extrasMenu) {
                if let position = copyPosition(child) {
                    candidates.append((leftEdge: position.x, value: child))
                }
            }
        }
        guard let child = MenuBarExtraMatcher.nearest(to: targetFrame.minX, among: candidates) else {
            DebugLog.log("AXActivator: no actionable element for \(windowID) at \(targetFrame)")
            return false
        }
        // Re-read the matched element's live position; if it has drifted out of tolerance the
        // frame was stale (or a pid was reused for a different app) — don't press the wrong one.
        if let live = copyPosition(child), abs(live.x - targetFrame.minX) > MenuBarExtraMatcher.tolerance {
            DebugLog.log("AXActivator: matched element drifted for \(windowID) (live \(live.x) vs \(targetFrame.minX))")
            return false
        }
        for action in [kAXPressAction as String, "AXShowMenu"] {
            if AXUIElementPerformAction(child, action as CFString) == .success {
                DebugLog.log("AXActivator: \(action) succeeded for \(windowID)")
                return true
            }
        }
        DebugLog.log("AXActivator: element matched but no action succeeded for \(windowID)")
        return false
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
