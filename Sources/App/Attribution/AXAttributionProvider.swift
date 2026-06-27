import AppKit
import ApplicationServices
import BarKeepersFriendCore

/// Resolves the real owning app of each menu bar item by frame-matching against every
/// running app's Accessibility menu bar extras.
///
/// On macOS 26 `kCGWindowOwnerPID`/`kCGWindowOwnerName` report most status items as owned
/// by Control Center (FB18327911), and `kCGWindowName` is a generic "Item-0". The reliable
/// source of the real app name is the Accessibility tree: each app exposes its menu bar
/// extras via `kAXExtrasMenuBarAttribute`, and each extra has a screen position. We match
/// those positions to our captured item frames (by x-midpoint, within a tolerance) to label
/// items with their real app. Requires Accessibility permission; without it, returns the
/// snapshots unchanged.
enum AXAttributionProvider {

    /// Returns the snapshots with `ownerBundleID` filled in with the real app's display
    /// name wherever a confident frame match is found.
    ///
    /// The Accessibility IPC sweep runs off the main thread: each app's `AXUIElement` query
    /// is synchronous and, even with a per-app timeout, the whole pass can take noticeable
    /// time — running it on the main actor stalled the run loop and blocked the floating
    /// bar's clicks. The list of running apps is read on the main actor first (NSWorkspace's
    /// KVO-backed properties are main-affined), then only the C-level AX calls go off-main.
    static func attribute(_ snapshots: [MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot] {
        guard AXIsProcessTrusted() else { return snapshots }

        let apps: [(pid: pid_t, name: String)] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy != .prohibited || app.bundleIdentifier != nil,
                      let name = app.localizedName else { return nil }
                return (app.processIdentifier, name)
            }
        }

        return await Task.detached(priority: .userInitiated) {
            attributeSync(snapshots, apps: apps)
        }.value
    }

    /// The synchronous AX sweep + frame match. Safe to run off the main thread (AX C-APIs are
    /// thread-agnostic). Called only by `attribute`.
    private static func attributeSync(
        _ snapshots: [MenuBarItemSnapshot],
        apps: [(pid: pid_t, name: String)]
    ) -> [MenuBarItemSnapshot] {
        // Collect every menu bar extra of every running app: its left edge, a display label,
        // and the owning pid. The label is the app name, except for Control Center modules
        // (which all report "Control Center") where we read the element's own title so the
        // user sees "Wi-Fi", "Battery", etc. instead of a wall of identical names.
        var extras: [(leftEdge: CGFloat, label: String, pid: pid_t)] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.pid)
            // Cap each app's Accessibility IPC. Without a timeout a single hung or slow app
            // would stretch the sweep to the system default (~6s+) per app.
            AXUIElementSetMessagingTimeout(axApp, 1.5)
            guard let extrasMenu = copyElement(axApp, attribute: "AXExtrasMenuBar") else { continue }
            let isControlCenter = app.name == "Control Center"
            for child in copyChildren(extrasMenu) {
                guard let position = copyPosition(child) else { continue }
                var label = app.name
                if isControlCenter, let title = moduleLabel(child) {
                    label = title
                }
                extras.append((leftEdge: position.x, label: label, pid: app.pid))
            }
        }
        guard !extras.isEmpty else { return snapshots }

        // Assign each item to at most one extra (1:1, nearest-wins) so two items near the same
        // extra don't both claim it — that was the cause of duplicate names in the bar.
        let assignment = MenuBarExtraMatcher.assignGreedy(
            targetMinXs: snapshots.map { $0.frame.minX },
            extraLeftEdges: extras.map { $0.leftEdge }
        )
        return snapshots.enumerated().map { index, snapshot in
            guard let extraIndex = assignment[index] else { return snapshot }
            let extra = extras[extraIndex]
            return snapshot.attributed(bundleID: extra.label, pid: extra.pid)
        }
    }

    /// Reads a human label for a Control Center module from its Accessibility element, trying
    /// title then description. Returns `nil` if neither is present or it's the generic
    /// "Item-N" placeholder, so the caller can fall back to the app name.
    private static func moduleLabel(_ element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
            if let value = copyString(element, attribute: attribute),
               !value.isEmpty, !value.hasPrefix("Item-") {
                return value
            }
        }
        return nil
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

    private static func copyString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
