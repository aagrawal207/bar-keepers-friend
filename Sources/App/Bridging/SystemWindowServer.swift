import AppKit
import BarKeepersFriendCore
import CoreGraphics

/// Real `WindowServer` backed by the public window-list API.
///
/// Phase-2 read-only foundation: it enumerates menu bar status-item windows via
/// `CGWindowListCopyWindowInfo` (the public, non-private path) so the floating bar can find
/// hidden items. Movement and clicking (the private-API parts) are added in a later step
/// and currently throw `notImplemented`, keeping the fragile surface out of this milestone.
///
/// Note on Tahoe (macOS 26): `kCGWindowOwnerPID` is unreliable — it reports most items as
/// owned by Control Center (FB18327911). We still capture whatever PID/owner is reported;
/// accurate per-app attribution is handled separately by the Accessibility matcher when the
/// click-routing step lands. For mirroring images, the window id + frame are sufficient.
final class SystemWindowServer: WindowServer, @unchecked Sendable {

    /// Status-item windows live at this layer (`kCGStatusWindowLevel`).
    private static let statusLayer = Int(CGWindowLevelForKey(.statusWindow))

    func menuBarItems() throws -> [MenuBarItemSnapshot] {
        // Must NOT use .optionOnScreenOnly: the hidden items we care about are pushed
        // off-screen (negative x) by the expanded divider, and on-screen-only enumeration
        // would exclude exactly those. Enumerate all windows and filter to the status layer.
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw WindowServerError.invalidServerResponse("CGWindowListCopyWindowInfo returned nil")
        }

        let snapshots: [MenuBarItemSnapshot] = raw.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == Self.statusLayer else {
                return nil
            }
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else {
                return nil
            }
            let pid = (info[kCGWindowOwnerPID as String] as? pid_t) ?? -1
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let title = info[kCGWindowName as String] as? String
            return MenuBarItemSnapshot(
                windowID: windowID,
                ownerPID: pid,
                ownerBundleID: ownerName, // best-effort; refined during click-routing step
                title: title,
                frame: frame
            )
        }
        return snapshots
    }

    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        // The menu bar occupies the top strip of the display containing the point.
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let screen else {
            throw WindowServerError.invalidServerResponse("no screen for point")
        }
        let height = screen.frame.height - screen.visibleFrame.height
            - (screen.visibleFrame.origin.y - screen.frame.origin.y)
        let menuBarHeight = max(height, NSStatusBar.system.thickness)
        return CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - menuBarHeight,
            width: screen.frame.width,
            height: menuBarHeight
        )
    }

    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat) throws {
        throw WindowServerError.invalidServerResponse("move() not implemented in read-only foundation")
    }

    func click(item: MenuBarItemSnapshot) throws {
        throw WindowServerError.invalidServerResponse("click() not implemented in read-only foundation")
    }
}
