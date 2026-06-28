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

    /// Physically moves another app's status item by synthesizing the same gesture the user makes
    /// to rearrange the menu bar: a Command-down, then an up at the destination. This is the one
    /// genuinely fragile, undocumented capability in the app, so it is fenced in here and is fully
    /// self-validating — it confirms the item's frame actually changed and retries, throwing if it
    /// can't, so a caller can fall back gracefully.
    ///
    /// ## Mechanism (from studying Ice's MenuBarItemManager — clean-room, mechanism only)
    ///
    /// macOS routes a status-item rearrange not by where the cursor is but by a **windowID stamped
    /// into the mouse event's fields**. So we do NOT drag the physical pointer across the bar.
    /// Instead, for the item being moved:
    ///   1. post a `leftMouseDown` carrying `.maskCommand` at a far OFF-SCREEN point, with the
    ///      moved item's windowID stamped into the routing fields; then
    ///   2. post a `leftMouseUp` (no modifier) at the DESTINATION x (just past the anchor edge),
    ///      again stamped with the item's windowID.
    /// The window server interprets that as "the user ⌘-grabbed this item and dropped it there"
    /// and snaps it into the nearest slot on that side of the anchor.
    ///
    /// The windowID goes into THREE integer fields — the two documented routing fields
    /// (`kCGMouseEventWindowUnderMousePointer` = 91, `...ThatCanHandleThisEvent` = 92) plus an
    /// undocumented private field (51 / 0x33) that Ice also sets — because the field the server
    /// actually routes on has varied across releases; stamping all three is belt-and-suspenders.
    /// Command is on the DOWN event only (that's the gesture the server recognizes as "begin
    /// rearrange"); the UP carries no modifier.
    ///
    /// Coordinates are CoreGraphics global, top-left origin (same space as `item.frame`).
    ///
    /// Retry: the mechanism is known to go sluggish/intermittent (notably on Tahoe, where many
    /// items live under Control Center). So we attempt up to `maxMoveAttempts`, re-reading the
    /// item's live frame after each to confirm it actually moved, with a short settle between
    /// tries. The cursor is hidden for the duration and restored after.
    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat) async throws {
        guard AXIsProcessTrusted() else {
            throw WindowServerError.missingPermission(.accessibility)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw WindowServerError.moveFailed(windowID: item.windowID)
        }
        // Let synthetic events through any active suppression window, and don't debounce them.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateRemoteMouseDrag
        )
        source.localEventsSuppressionInterval = 0

        // Hide the cursor during the synthetic gesture and restore it after. We never warp it to
        // perform the move (the windowID fields do the routing), so this only prevents any stray
        // flicker; balanced via defer so a throw can't strand a hidden cursor.
        let savedCursor = CGEvent(source: nil)?.location
        CGDisplayHideCursor(kCGNullDirectDisplay)
        defer {
            if let savedCursor { CGWarpMouseCursorPosition(savedCursor) }
            CGDisplayShowCursor(kCGNullDirectDisplay)
        }

        let startFrame = item.frame
        // Destination point: the target x at the item's own vertical midline (menu bar row).
        let destination = CGPoint(x: targetX, y: item.frame.midY)

        for attempt in 1...Self.maxMoveAttempts {
            postMoveGesture(source: source, windowID: item.windowID, pid: item.ownerPID, destination: destination)

            // Confirm by re-reading the live frame: did THIS item actually move off its start x?
            try? await Task.sleep(for: .milliseconds(Self.moveSettleMs))
            if let live = liveFrame(forWindowID: item.windowID), abs(live.minX - startFrame.minX) > Self.moveConfirmEpsilon {
                return
            }
            if attempt < Self.maxMoveAttempts {
                // Nudge an unresponsive item with a plain (no-modifier) click at its current
                // centre, the way Ice "wakes up" a stuck item, then retry.
                wakeUp(source: source, item: item)
                try? await Task.sleep(for: .milliseconds(Self.moveRetryDelayMs))
            }
        }
        throw WindowServerError.moveFailed(windowID: item.windowID)
    }

    /// Posts the two-event move gesture (Command-down off-screen, then up at the destination),
    /// each stamped with the target window id so the server routes it to that item.
    private func postMoveGesture(source: CGEventSource, windowID: CGWindowID, pid: pid_t, destination: CGPoint) {
        // Start far off-screen, like Ice: the down event's location is irrelevant (routing is by
        // windowID), and an off-screen point avoids perturbing anything under the real cursor.
        let offscreen = CGPoint(x: 20_000, y: 20_000)
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: offscreen, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: destination, mouseButton: .left)
        else { return }

        down.flags = .maskCommand   // Command on the DOWN only: "begin rearranging this item".
        up.flags = []
        stampWindowID(windowID, pid: pid, into: down)
        stampWindowID(windowID, pid: pid, into: up)

        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// A plain left click at the item's current centre (no modifier), used between failed move
    /// attempts to nudge an item whose owning process has gone unresponsive to the synthetic move.
    private func wakeUp(source: CGEventSource, item: MenuBarItemSnapshot) {
        let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: centre, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: centre, mouseButton: .left)
        else { return }
        stampWindowID(item.windowID, pid: item.ownerPID, into: down)
        stampWindowID(item.windowID, pid: item.ownerPID, into: up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Stamps a window id (and owner pid) into the mouse-event fields the window server routes a
    /// status-item rearrange on. Three fields are set because the one actually honored has varied
    /// across macOS releases: the two documented `WindowUnderMousePointer` fields (91, 92) and an
    /// undocumented private field (0x33). Raw field values are used for the undocumented one since
    /// it has no `CGEventField` case.
    private func stampWindowID(_ windowID: CGWindowID, pid: pid_t, into event: CGEvent) {
        let id = Int64(windowID)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: id)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: id)
        if let privateWindowIDField = CGEventField(rawValue: 0x33) {
            event.setIntegerValueField(privateWindowIDField, value: id)
        }
    }

    /// Re-reads the live frame of a single status-item window by id, for move confirmation.
    /// Returns nil if the window is no longer present.
    private func liveFrame(forWindowID windowID: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in raw {
            guard (info[kCGWindowNumber as String] as? CGWindowID) == windowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            return frame
        }
        return nil
    }

    /// Move tuning. The mechanism is undocumented and known to be intermittent on recent macOS,
    /// so the retry loop with frame-change confirmation is load-bearing, not polish.
    private static let maxMoveAttempts = 5
    private static let moveSettleMs = 120
    private static let moveRetryDelayMs = 80
    /// How many points the leading edge must shift to count the move as real (vs. layout jitter).
    private static let moveConfirmEpsilon: CGFloat = 2

    /// Synthesizes a left click at the centre of the item's frame.
    ///
    /// The item must be ON-SCREEN: a click at an off-screen point would open the item's menu
    /// off-screen. The floating bar therefore reveals the hidden section before routing a
    /// click here. Requires Accessibility permission to post events into other processes.
    ///
    /// Menu bar item frames are already in the top-left global coordinate space that
    /// `CGEvent` mouse positions use, so no flipping is needed.
    var canSynthesizeClicks: Bool { AXIsProcessTrusted() }

    func click(item: MenuBarItemSnapshot) throws {
        guard AXIsProcessTrusted() else {
            throw WindowServerError.missingPermission(.accessibility)
        }
        guard item.isClickableOnScreen else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .privateState) else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }
        let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
        // Save the cursor's current position BEFORE warping, in CG global (top-left) space —
        // the same space as `centre` and the warp, so no coordinate flip and multi-display
        // safe. (NSEvent.mouseLocation is AppKit bottom-left and would need per-screen flipping.)
        let savedCursor = CGEvent(source: nil)?.location

        // Build the click events BEFORE touching the cursor, so the pointer spends the absolute
        // minimum time displaced (warp → post → restore with no allocation in between). This
        // shrinks the visible jump to a sub-frame blip on its own — and on the throw path we
        // never moved the cursor at all.
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: centre, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: centre, mouseButton: .left)
        else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        // Hide the cursor across the warp→click→restore so the user never SEES it dart into the
        // menu bar and back — the jarring part of activation. We still physically move the pointer
        // (status-item hit-testing tracks the REAL cursor, so the warp is unavoidable), but it's
        // hidden. `CGDisplayHideCursor`/`ShowCursor` are reference-counted; `defer` balances the
        // show on every exit so we can never strand a hidden cursor. NOTE: `CGDisplayHideCursor`
        // is honored only while the calling app is foreground, and our panel is a
        // .nonactivatingPanel (we don't steal focus), so the hide may no-op — which is exactly why
        // the events are pre-built and the cursor is restored immediately, bounding any still-
        // visible motion to a single-frame flicker rather than a travel-and-return.
        CGDisplayHideCursor(kCGNullDirectDisplay)
        defer { CGDisplayShowCursor(kCGNullDirectDisplay) }

        // Warp onto the item, post via the session tap (the .cghidEventTap HID layer bypasses the
        // dispatcher the menu bar's tracking loop listens on, which is why the old path silently
        // failed), then immediately warp back to where the user left it so the pointer doesn't
        // stay parked in the menu bar. The warp emits no move event and the just-opened menu's
        // modal loop doesn't dismiss on cursor motion, so the restore is safe with no delay.
        // Restore only if the pre-warp read succeeded — never warp to a fabricated point.
        CGWarpMouseCursorPosition(centre)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        if let savedCursor {
            CGWarpMouseCursorPosition(savedCursor)
        }
    }
}
