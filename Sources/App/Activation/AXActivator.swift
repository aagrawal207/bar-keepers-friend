import AppKit
import ApplicationServices
import BarKeepersFriendCore

/// Best-effort semantic activation through Accessibility, with cancellation and session guards.
/// An accepted action is not an independent observation that its menu opened.
enum AXActivator {

    /// Outcome of attempting to press the matching extra within a set of apps.
    enum PressOutcome: Equatable, Sendable {
        /// An Accessibility action was accepted; menu visibility is not independently observed.
        case pressed
        /// The element was found (or had drifted) but no action worked. Sweeping other apps
        /// is pointless: the element is right, it just isn't pressable that way.
        case matchedNoAction
        /// No extra matched in these apps — a wider sweep may locate it.
        case noMatch
        /// Observed cancellation or session loss is terminal, even if the desktop unlocks later.
        case interrupted
    }

    /// The item must already be revealed so an accepted action can open its menu on-screen.
    /// Interruption throws instead of requesting another activation fallback.
    static func activate(windowID: CGWindowID, pid: pid_t, frame targetFrame: CGRect) async throws -> Bool {
        try await activate(
            pid: pid, canInteract: { DesktopSession.canInteract() }, isTrusted: { AXIsProcessTrusted() },
            runningPIDs: {
                NSWorkspace.shared.runningApplications.compactMap { app in
                    (app.activationPolicy != .prohibited || app.bundleIdentifier != nil)
                        ? app.processIdentifier : nil
                }
            },
            press: { pids, timeout in
                pressMatchingChild(in: pids, windowID: windowID, frame: targetFrame, timeout: timeout)
            }
        )
    }

    static func activate(
        pid: pid_t,
        canInteract: @escaping @Sendable () -> Bool,
        isTrusted: () -> Bool,
        runningPIDs: @MainActor () -> [pid_t],
        press: @escaping @Sendable ([pid_t], Float) -> PressOutcome
    ) async throws -> Bool {
        guard !Task.isCancelled, canInteract() else { throw CancellationError() }
        guard isTrusted() else { return false }

        // Single-app fast path: query only the owning app.
        if pid > 0 {
            let outcome = try await runCancellable(canInteract: canInteract) {
                press([pid], 0.5)
            }
            switch outcome {
            case .pressed:
                return true
            case .matchedNoAction:
                // The matched element rejected semantic activation; a wider sweep would repeat it.
                return false
            case .noMatch:
                break // attribution gave no/wrong pid — a full sweep may locate it
            case .interrupted:
                throw CancellationError()
            }
        }

        guard !Task.isCancelled, canInteract() else { throw CancellationError() }

        // Fallback: attribution didn't give a usable pid (or found nothing in it).
        // Sweep all apps, accumulating candidates so the global nearest wins.
        let pids = await runningPIDs()
        return try await runCancellable(canInteract: canInteract) {
            press(pids, 1.5)
        } == .pressed
    }

    /// Detached AX IPC must inherit caller cancellation and preserve interruption across the await.
    private static func runCancellable(
        canInteract: @Sendable () -> Bool,
        _ work: @Sendable @escaping () -> PressOutcome
    ) async throws -> PressOutcome {
        guard !Task.isCancelled, canInteract() else { throw CancellationError() }
        let task = Task.detached(priority: .userInitiated, operation: work)
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, outcome != .interrupted, canInteract() else { throw CancellationError() }
        return outcome
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
            guard !Task.isCancelled, DesktopSession.canInteract() else { return .interrupted }
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
        guard !Task.isCancelled, DesktopSession.canInteract() else { return .interrupted }
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
        return performActions(
            on: child, windowID: windowID, canInteract: { DesktopSession.canInteract() },
            performAction: { AXUIElementPerformAction($0, $1 as CFString) },
            pressableChild: { nearestPressableChild(of: $0, targetMinX: targetFrame.minX) }
        )
    }

    /// Parent actions precede the position-matched child; no fallback survives an observed interruption.
    static func performActions<Element>(
        on element: Element,
        windowID: CGWindowID,
        canInteract: () -> Bool,
        performAction: (Element, String) -> AXError,
        pressableChild: (Element) -> Element?
    ) -> PressOutcome {
        for action in [kAXPressAction as String, "AXShowMenu"] {
            guard !Task.isCancelled, canInteract() else { return .interrupted }
            let err = performAction(element, action)
            guard !Task.isCancelled, canInteract() else { return .interrupted }
            if err == .success {
                DebugLog.log("AXActivator: \(action) succeeded for \(windowID)")
                return .pressed
            }
            DebugLog.log("AXActivator: \(action) on \(windowID) returned AXError \(err.rawValue)")
        }
        guard !Task.isCancelled, canInteract() else { return .interrupted }
        let pressable = pressableChild(element)
        guard !Task.isCancelled, canInteract() else { return .interrupted }
        if let pressable {
            for action in [kAXPressAction as String, "AXShowMenu"] {
                guard !Task.isCancelled, canInteract() else { return .interrupted }
                let err = performAction(pressable, action)
                guard !Task.isCancelled, canInteract() else { return .interrupted }
                if err == .success {
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
