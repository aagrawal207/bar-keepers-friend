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
        // Build a list of (midX, appName) for every menu bar extra of every running app.
        var extras: [(midX: CGFloat, name: String)] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.pid)
            // Cap each app's Accessibility IPC. Without a timeout a single hung or slow app
            // would stretch the sweep to the system default (~6s+) per app.
            AXUIElementSetMessagingTimeout(axApp, 1.5)
            guard let extrasMenu = copyElement(axApp, attribute: "AXExtrasMenuBar") else { continue }
            for child in copyChildren(extrasMenu) {
                if let position = copyPosition(child) {
                    extras.append((midX: position.x, name: app.name))
                }
            }
        }
        guard !extras.isEmpty else { return snapshots }

        let tolerance: CGFloat = 12
        return snapshots.map { snapshot in
            // Match the closest extra whose x is within tolerance of the item's left edge
            // (AX position is the element's top-left; the window frame minX aligns closely).
            let best = extras.min { a, b in
                abs(a.midX - snapshot.frame.minX) < abs(b.midX - snapshot.frame.minX)
            }
            if let best, abs(best.midX - snapshot.frame.minX) <= tolerance {
                return snapshot.attributed(bundleID: best.name, pid: snapshot.ownerPID)
            }
            return snapshot
        }
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
