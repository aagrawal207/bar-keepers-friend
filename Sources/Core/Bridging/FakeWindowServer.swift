import CoreGraphics
import Foundation

/// An in-memory `WindowServer` for tests and previews. Models a menu bar as an ordered
/// list of item frames and lets tests script moves, clicks, and failure injection — so the
/// entire higher stack runs deterministically without the real window server.
public final class FakeWindowServer: WindowServer, @unchecked Sendable {
    /// Settable so a test can move, add, or hide items between reads.
    public var items: [MenuBarItemSnapshot]
    public private(set) var clickedWindowIDs: [CGWindowID] = []
    public private(set) var moveRequests: [(windowID: CGWindowID, targetX: CGFloat, targetWindowID: CGWindowID)] = []

    /// Frame of the simulated menu bar.
    public var menuBarFrame: CGRect

    /// When set, `menuBarItems()` throws this instead of returning items — used to test the
    /// compatibility-mode kill-switch.
    public var enumerationError: WindowServerError?

    /// When set, `move(item:toX:relativeTo:)` throws instead of succeeding.
    public var moveError: WindowServerError?

    public var clickError: WindowServerError?
    /// Opt-in row reflow for ordering workflows; legacy fixtures retain their absolute-frame behavior.
    public var reflowsOnMove = false

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

    public func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        if let error = moveError { throw error }
        moveRequests.append((item.windowID, targetX, targetWindowID))
        guard let index = items.firstIndex(where: { $0.windowID == item.windowID }) else {
            throw WindowServerError.moveFailed(windowID: item.windowID)
        }
        let reference = items.first { $0.windowID == targetWindowID }
        let beforeReference = reference.map { targetX < $0.frame.midX } ?? false
        if reflowsOnMove, let reference {
            let row = items.filter { abs($0.frame.minY - item.frame.minY) < 1 }
                .sorted { $0.frame.minX < $1.frame.minX }
            var reordered = row.filter { $0.windowID != item.windowID }
            guard let referenceIndex = reordered.firstIndex(where: { $0.windowID == reference.windowID }) else {
                throw WindowServerError.moveFailed(windowID: item.windowID)
            }
            reordered.insert(items[index], at: referenceIndex + (beforeReference ? 0 : 1))
            var x = row.first?.frame.minX ?? 0
            for (position, snapshot) in reordered.enumerated() {
                let updated = MenuBarItemSnapshot(
                    windowID: snapshot.windowID, ownerPID: snapshot.ownerPID, ownerBundleID: snapshot.ownerBundleID,
                    title: snapshot.title,
                    frame: CGRect(x: x, y: snapshot.frame.minY, width: snapshot.frame.width, height: snapshot.frame.height),
                    isOnScreen: snapshot.isOnScreen
                )
                if let index = items.firstIndex(where: { $0.windowID == snapshot.windowID }) { items[index] = updated }
                x += snapshot.frame.width
                if position + 1 < row.count { x += max(0, row[position + 1].frame.minX - row[position].frame.maxX) }
            }
            return
        }
        let frame = items[index].frame
        let moved = MenuBarItemSnapshot(
            windowID: item.windowID,
            ownerPID: item.ownerPID,
            ownerBundleID: item.ownerBundleID,
            title: item.title,
            frame: CGRect(
                x: beforeReference ? targetX - frame.width : targetX,
                y: frame.minY, width: frame.width, height: frame.height
            ),
            isOnScreen: item.isOnScreen
        )
        items[index] = moved
    }

    public func click(item: MenuBarItemSnapshot) throws {
        if let error = clickError { throw error }
        clickedWindowIDs.append(item.windowID)
    }

    /// Test-controllable permission state; defaults to granted.
    public var canSynthesizeClicks: Bool = true
}
