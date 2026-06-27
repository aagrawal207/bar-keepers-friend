import AppKit
import ApplicationServices
import BarKeepersFriendCore

/// Activates a real menu bar item by pressing its Accessibility element.
///
/// A synthesized `CGEvent` click at a status item's frame is unreliable on macOS 26 — the
/// menu rarely opens. The robust path is `AXUIElementPerformAction`: it executes inside the
/// owning app, which then opens and positions its own menu natively. The owning app is found
/// the same way `AXAttributionProvider` finds names — by walking each running app's
/// `AXExtrasMenuBar` children and matching one to the target item's on-screen frame.
///
/// Concurrency: the running-apps list is read on the main actor (NSWorkspace's KVO-backed
/// properties are main-affined), then the synchronous Accessibility IPC runs in a detached
/// task so it never stalls the main run loop. `AXUIElement` (a non-Sendable CF type) never
/// crosses an actor boundary — only `pid_t` in and `Bool` out.
enum AXActivator {

    /// Attempts to press the menu bar element matching `frame`. Returns whether a press
    /// succeeded. The item must already be on-screen (revealed) so the app opens its menu in
    /// the visible menu bar rather than off-screen.
    static func activate(windowID: CGWindowID, frame targetFrame: CGRect) async -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let pids: [pid_t] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                (app.activationPolicy != .prohibited || app.bundleIdentifier != nil)
                    ? app.processIdentifier : nil
            }
        }

        return await Task.detached(priority: .userInitiated) {
            activateSync(windowID: windowID, frame: targetFrame, pids: pids)
        }.value
    }

    /// Synchronous AX sweep + match + press. Safe off the main thread (AX C-APIs are
    /// thread-agnostic). Matches by left edge (within 12 pt) and width (within 6 pt) so a
    /// neighbouring extra at a similar x isn't pressed by mistake.
    private static func activateSync(windowID: CGWindowID, frame targetFrame: CGRect, pids: [pid_t]) -> Bool {
        for pid in pids {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 1.5)
            guard let extras = copyElement(axApp, attribute: "AXExtrasMenuBar") else { continue }
            for child in copyChildren(extras) {
                guard let position = copyPosition(child), let size = copySize(child) else { continue }
                let xMatches = abs(position.x - targetFrame.minX) <= 12
                let widthMatches = abs(size.width - targetFrame.width) <= 6
                guard xMatches, widthMatches else { continue }
                // Prefer the explicit press; fall back to a show-menu action for items that
                // model their menu that way.
                for action in [kAXPressAction as String, "AXShowMenu"] {
                    if AXUIElementPerformAction(child, action as CFString) == .success {
                        DebugLog.log("AXActivator: \(action) succeeded for \(windowID) (pid \(pid))")
                        return true
                    }
                }
            }
        }
        DebugLog.log("AXActivator: no actionable element for \(windowID) at \(targetFrame)")
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

    private static func copySize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
