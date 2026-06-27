import AppKit
import ApplicationServices
import BarKeepersFriendCore

/// Read-only Accessibility inspection for diagnostics. Given the hidden items' frames, it
/// finds each one's menu bar extra element and dumps everything about it — role, subrole,
/// supported actions, title/description, and a couple of levels of children — WITHOUT
/// pressing anything. This is how we see *why* an item activates or doesn't (e.g. the matched
/// element is an `AXGroup` with no actions whose pressable button is a child).
enum AXInspector {

    /// A snapshot of one Accessibility element, encodable for the diagnostics report.
    struct ElementInfo: Codable, Sendable {
        var role: String?
        var subrole: String?
        var title: String?
        var roleDescription: String?
        var help: String?
        var identifier: String?
        var actions: [String]
        var position: [Double]?   // [x, y], CG global top-left
        var size: [Double]?       // [w, h]
        var children: [ElementInfo]
    }

    /// Inspects the extra matching each target frame. `targets` is (windowID, leftEdge, width).
    /// Returns windowID → element info for the nearest matching extra (within tolerance).
    static func inspect(targets: [(windowID: CGWindowID, minX: CGFloat, width: CGFloat)]) async -> [CGWindowID: ElementInfo] {
        guard AXIsProcessTrusted() else { return [:] }

        let pids: [pid_t] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                (app.activationPolicy != .prohibited || app.bundleIdentifier != nil)
                    ? app.processIdentifier : nil
            }
        }

        return await Task.detached(priority: .userInitiated) {
            // Collect every extra across all apps once, then match each target to the nearest.
            var extras: [(leftEdge: CGFloat, element: AXUIElement)] = []
            for pid in pids {
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 1.0)
                guard let extrasMenu = copyElement(axApp, attribute: "AXExtrasMenuBar") else { continue }
                for child in copyChildren(extrasMenu) {
                    if let position = copyPoint(child, attribute: kAXPositionAttribute as String) {
                        extras.append((leftEdge: position.x, element: child))
                    }
                }
            }

            var result: [CGWindowID: ElementInfo] = [:]
            for target in targets {
                let candidates = extras.map { (leftEdge: $0.leftEdge, value: $0.element) }
                guard let element = MenuBarExtraMatcher.nearest(to: target.minX, among: candidates) else { continue }
                result[target.windowID] = describe(element, depth: 2)
            }
            return result
        }.value
    }

    // MARK: - Inspection

    private static func describe(_ element: AXUIElement, depth: Int) -> ElementInfo {
        let point = copyPoint(element, attribute: kAXPositionAttribute as String)
        let size = copySize(element)
        let children = depth > 0 ? copyChildren(element).map { describe($0, depth: depth - 1) } : []
        return ElementInfo(
            role: copyString(element, attribute: kAXRoleAttribute as String),
            subrole: copyString(element, attribute: kAXSubroleAttribute as String),
            title: copyString(element, attribute: kAXTitleAttribute as String),
            roleDescription: copyString(element, attribute: kAXRoleDescriptionAttribute as String),
            help: copyString(element, attribute: kAXHelpAttribute as String),
            identifier: copyString(element, attribute: kAXIdentifierAttribute as String),
            actions: copyActions(element),
            position: point.map { [Double($0.x), Double($0.y)] },
            size: size.map { [Double($0.width), Double($0.height)] },
            children: children
        )
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

    private static func copyString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyActions(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success, let names = value as? [String] else { return [] }
        return names
    }

    private static func copyPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
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
