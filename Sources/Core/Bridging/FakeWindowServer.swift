import CoreGraphics
import Foundation

/// An in-memory `WindowServer` for tests and previews. Models a menu bar as an ordered
/// list of item frames and lets tests script moves, clicks, and failure injection — so the
/// entire higher stack runs deterministically without the real window server.
public final class FakeWindowServer: WindowServer, @unchecked Sendable {
    public private(set) var items: [MenuBarItemSnapshot]
    public private(set) var clickedWindowIDs: [CGWindowID] = []
    public private(set) var moveRequests: [(windowID: CGWindowID, targetX: CGFloat)] = []

    /// Frame of the simulated menu bar.
    public var menuBarFrame: CGRect

    /// When set, `menuBarItems()` throws this instead of returning items — used to test the
    /// compatibility-mode kill-switch.
    public var enumerationError: WindowServerError?

    /// When set, `move(item:toX:)` throws instead of succeeding.
    public var moveError: WindowServerError?

    public init(
        items: [MenuBarItemSnapshot] = [],
        menuBarFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 24)
    ) {
        self.items = items
        self.menuBarFrame = menuBarFrame
    }

    public func menuBarItems() throws -> [MenuBarItemSnapshot] {
        if let error = enumerationError { throw error }
        return items
    }

    public func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        menuBarFrame
    }

    public func move(item: MenuBarItemSnapshot, toX targetX: CGFloat) throws {
        if let error = moveError { throw error }
        moveRequests.append((item.windowID, targetX))
        guard let index = items.firstIndex(where: { $0.windowID == item.windowID }) else {
            throw WindowServerError.moveFailed(windowID: item.windowID)
        }
        let moved = MenuBarItemSnapshot(
            windowID: item.windowID,
            ownerPID: item.ownerPID,
            ownerBundleID: item.ownerBundleID,
            title: item.title,
            frame: CGRect(x: targetX, y: item.frame.minY, width: item.frame.width, height: item.frame.height)
        )
        items[index] = moved
    }

    public func click(item: MenuBarItemSnapshot) throws {
        clickedWindowIDs.append(item.windowID)
    }

    /// Test-controllable permission state; defaults to granted.
    public var canSynthesizeClicks: Bool = true
}
