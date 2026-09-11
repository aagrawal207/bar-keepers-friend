import AppKit
import BarKeepersFriendCore
import CoreGraphics

/// Real `WindowServer` backed by the public window-list API plus the private synthesized-event
/// move/click.
///
/// `menuBarItems()` / `menuBarFrame(...)` enumerate status-item windows via
/// `CGWindowListCopyWindowInfo` (the public, non-private path) so the floating bar can find
/// hidden items. `move(...)` and `click(...)` are the fragile private-API parts — they
/// synthesize CGEvents routed to the item's owning process (the move is verified working
/// on-device; see AGENTS.md "Built") — and are isolated here behind the `WindowServer` seam so
/// the rest of the app depends only on the protocol and the permission-free baseline is unaffected
/// if they ever break.
///
/// Note on Tahoe (macOS 26): `kCGWindowOwnerPID` is unreliable — it reports most items as
/// owned by Control Center (FB18327911). We still capture whatever PID/owner is reported;
/// accurate per-app attribution is handled separately by the Accessibility matcher
/// (`AXAttributionProvider`) before a move so the synthesized events target the real pid. For
/// mirroring images, the window id + frame are sufficient.
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

    /// Uses a Command grab and a drop identified by the destination control's native window ID.
    /// Each attempt revalidates the requested side; a neighbor's reflow is not a successful move.
    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else {
            throw WindowServerError.missingPermission(.accessibility)
        }
        let initial = try menuBarItems()
        guard targetWindowID != item.windowID,
              let reference = initial.first(where: { $0.windowID == targetWindowID }),
              targetX < reference.frame.minX || targetX > reference.frame.maxX else {
            throw WindowServerError.moveFailed(windowID: item.windowID)
        }
        let beforeReference = targetX < reference.frame.minX
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

        for attempt in 1...Self.maxMoveAttempts {
            // Finish each down/up pair atomically; cancellation only stops subsequent gestures.
            try Task.checkCancellation()
            let current = try menuBarItems()
            guard let liveItem = current.first(where: { $0.windowID == item.windowID }),
                  let liveReference = current.first(where: { $0.windowID == targetWindowID }) else {
                throw WindowServerError.moveFailed(windowID: item.windowID)
            }
            if HiddenLayoutPlanner.isPlacementSatisfied(
                item: liveItem, hidden: beforeReference,
                anchorMaxX: liveReference.frame.maxX, dividerMinX: liveReference.frame.minX
            ) { return }
            let dropX = beforeReference
                ? liveReference.frame.minX - HiddenLayoutPlanner.hiddenMargin
                : liveReference.frame.maxX + HiddenLayoutPlanner.shownMargin
            let destination = CGPoint(x: dropX, y: liveItem.frame.midY)
            postMoveGesture(
                source: source, windowID: item.windowID, pid: item.ownerPID,
                targetWindowID: targetWindowID, destination: destination
            )

            try await Task.sleep(for: .milliseconds(Self.moveSettleMs))
            let after = try menuBarItems()
            guard let placed = after.first(where: { $0.windowID == item.windowID }),
                  let target = after.first(where: { $0.windowID == targetWindowID }) else {
                throw WindowServerError.moveFailed(windowID: item.windowID)
            }
            let satisfied = HiddenLayoutPlanner.isPlacementSatisfied(
                item: placed, hidden: beforeReference,
                anchorMaxX: target.frame.maxX, dividerMinX: target.frame.minX
            )
            DebugLog.log("move: attempt=\(attempt) window=\(item.windowID) pid=\(item.ownerPID) startX=\(liveItem.frame.minX) targetWindow=\(targetWindowID) dropX=\(dropX) liveX=\(placed.frame.minX) placed=\(satisfied)")
            if satisfied {
                return
            }
            if attempt < Self.maxMoveAttempts {
                // Nudge an unresponsive item with a plain (no-modifier) click at its current
                // centre, the way Ice "wakes up" a stuck item, then retry.
                wakeUp(source: source, item: placed.attributed(bundleID: item.ownerBundleID, pid: item.ownerPID))
                try await Task.sleep(for: .milliseconds(Self.moveRetryDelayMs))
            }
        }
        throw WindowServerError.moveFailed(windowID: item.windowID)
    }

    /// Posts a complete grab/drop pair through the same relay, including the balancing up on failure.
    ///
    /// CRITICAL (verified on-device 2026-06-28 + against Ice mainline source): a direct
    /// `CGEvent.post(tap: .cgSessionEventTap)` is INERT against another app's status item on macOS
    /// 14.4+/26 — it relocated 0/12 items. The window server only treats the synthetic ⌘-down/up as
    /// a legitimate item drag when each event is delivered to the item's OWNING PROCESS through a
    /// two-tap round-trip (the "scromble" relay). So we route each event via `scrombleEvent` instead
    /// of posting it directly.
    private func postMoveGesture(source: CGEventSource, windowID: CGWindowID, pid: pid_t, targetWindowID: CGWindowID, destination: CGPoint) {
        guard let (down, up) = moveEvents(
            source: source, windowID: windowID, pid: pid,
            targetWindowID: targetWindowID, destination: destination
        ) else { return }
        let downRelayed = scrombleEvent(down, toPid: pid, timeout: Self.scrombleTimeout)
        if !downRelayed { down.post(tap: .cgSessionEventTap) }
        let upRelayed = scrombleEvent(up, toPid: pid, timeout: Self.scrombleTimeout)
        if !upRelayed { up.post(tap: .cgSessionEventTap) }
        DebugLog.log("move relay: window=\(windowID) targetWindow=\(targetWindowID) pid=\(pid) down=\(downRelayed) up=\(upRelayed)")
    }

    /// Builds events without posting them, so routing fields can be verified without moving the mouse.
    func moveEvents(source: CGEventSource, windowID: CGWindowID, pid: pid_t, targetWindowID: CGWindowID, destination: CGPoint) -> (down: CGEvent, up: CGEvent)? {
        // Start far off-screen, like Ice: the down event's location is irrelevant (routing is by
        // windowID), and an off-screen point avoids perturbing anything under the real cursor.
        let offscreen = CGPoint(x: 20_000, y: 20_000)
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: offscreen, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: destination, mouseButton: .left)
        else { return nil }

        down.flags = .maskCommand   // Command on the DOWN only: "begin rearranging this item".
        up.flags = []
        stampWindowID(windowID, pid: pid, into: down)
        stampWindowID(targetWindowID, pid: pid, into: up)
        return (down, up)
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

    /// Move tuning. The mechanism is undocumented and known to be intermittent on recent macOS,
    /// so the retry loop with frame-change confirmation is load-bearing, not polish.
    private static let maxMoveAttempts = 5
    private static let moveSettleMs = 120
    private static let moveRetryDelayMs = 80
    /// Upper bound on a single scromble round-trip. Ice's frame-change wait is ~50ms; the relay
    /// itself is faster, so this is generous headroom that still can't wedge the per-item loop.
    private static let scrombleTimeout: TimeInterval = 0.1

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
        // On-screen is relative to the item's own display: a display left of/above the primary has
        // a negative global x-origin, so a legitimately-revealed item there has minX < 0. Resolve
        // the display origin from the item's midpoint (x is identical in AppKit and CG space).
        let displayMinX = NSScreen.screens.first {
            $0.frame.minX <= item.frame.midX && item.frame.midX <= $0.frame.maxX
        }?.frame.minX ?? 0
        guard item.isClickableOnScreen(displayMinX: displayMinX) else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .privateState) else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }
        let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
        // Save the cursor's current position BEFORE warping, in CG global (top-left) space —
        // the same space as `centre` and the warp, so no coordinate flip and multi-display
        // safe. (NSEvent.mouseLocation is AppKit bottom-left and would need per-screen flipping.)
        // If this read fails we have NO point to warp back to, so we must not warp the cursor onto
        // the item at all — doing so would strand the pointer in the menu bar (the warp below was
        // previously unconditional while the restore was guarded, which is exactly that bug). Bail
        // cleanly instead: a nil read here is a degraded state where activation can't complete
        // tidily anyway, and a failed click is recoverable where a parked cursor is a visible glitch.
        guard let savedCursor = CGEvent(source: nil)?.location else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }

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
        // `savedCursor` is guaranteed valid (we bailed above if the read failed), so the warp is
        // always paired with a restore — the pointer never stays parked on the item.
        CGWarpMouseCursorPosition(centre)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        CGWarpMouseCursorPosition(savedCursor)
    }
}

/// Shared mutable state for the two-tap scromble relay, reached by the C `CGEventTapCallBack`s
/// through an `Unmanaged` refcon. Lives at file scope (not nested in `scrombleEvent`) so the
/// strict-concurrency region analysis doesn't trip on the Unmanaged round-trip of a local class.
/// It is only ever mutated synchronously on the run loop that drives the relay, so the
/// `@unchecked Sendable` is sound: there is no cross-thread access.
private final class ScrombleRelay: @unchecked Sendable {
    var realEvent: CGEvent?
    var realTag: Int64 = 0
    var nullTag: Int64 = 0
    var pid: pid_t = 0
    var tap1: CFMachPort?
    var tap2: CFMachPort?
    var delivered = false
}

/// The two-tap event shuttle ("scromble") that makes a synthesized menu-bar move actually land,
/// reconstructed clean-room from Ice's `MenuBarItemManager.scrombleEvent` (mechanism only).
///
/// Why this exists: posting a synthetic ⌘-mouse event straight to the session tap does not make the
/// window server move another app's status item on macOS 14.4+/26 (verified 0/12 on-device). The
/// server only honors the drag when the event reaches the item's owning process via a round-trip:
/// post a tagged *null* event to a tap installed ON the owning pid; that tap swallows the null and
/// re-emits the REAL event to the session tap; a listen-only tap there sees it and re-posts it back
/// into the owning pid, where the now-disabled first tap lets it pass through into the process.
/// Routing identity travels in the stamped windowID fields (91/92/0x33) + a unique
/// `eventSourceUserData` tag the taps match on.
///
/// Returns true if the real event was delivered through the round-trip, false if the relay couldn't
/// be set up (the caller then does a plain direct post as a last resort). Synchronous and bounded:
/// it pumps the current run loop until the relay completes or `timeout` elapses.
///
/// A free (non-isolated) function, NOT a method: the equivalent method on `SystemWindowServer`
/// crashed the Swift 6.3.2 `SendNonSendable` SIL pass (region analysis over the `Unmanaged` +
/// CGEvent + C-callback shape inside an actor-isolated context). Lifting it to file scope sidesteps
/// that compiler bug; it touches no instance state, so nothing is lost.
private func scrombleEvent(_ realEvent: CGEvent, toPid pid: pid_t, timeout: TimeInterval) -> Bool {
    // Tag the real event so the taps recognize exactly our event. A null trigger event carries a
    // distinct tag so the pid-tap can tell "kick" from "payload".
    let realTag = Int64(truncatingIfNeeded: ObjectIdentifier(realEvent).hashValue)
    realEvent.setIntegerValueField(.eventSourceUserData, value: realTag)
    guard let nullEvent = CGEvent(source: nil) else { return false }
    let nullTag = realTag &+ 1
    nullEvent.setIntegerValueField(.eventSourceUserData, value: nullTag)

    let relay = ScrombleRelay()
    relay.realEvent = realEvent
    relay.realTag = realTag
    relay.nullTag = nullTag
    relay.pid = pid
    let refcon = Unmanaged.passRetained(relay).toOpaque()
    defer { Unmanaged<ScrombleRelay>.fromOpaque(refcon).release() }

    // Tap 1: ACTIVE tap scoped to the owning pid. On seeing the tagged null it disables itself,
    // re-emits the REAL event to the session tap, and swallows the null (returns nil).
    let tap1Callback: CGEventTapCallBack = { _, _, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let relay = Unmanaged<ScrombleRelay>.fromOpaque(userInfo).takeUnretainedValue()
        if event.getIntegerValueField(.eventSourceUserData) == relay.nullTag {
            if let tap1 = relay.tap1 { CGEvent.tapEnable(tap: tap1, enable: false) }
            relay.realEvent?.post(tap: .cgSessionEventTap)
            return nil // swallow the kick
        }
        return Unmanaged.passUnretained(event)
    }
    let nullMask: CGEventMask = 1 << CGEventType.null.rawValue
    guard let tap1 = CGEvent.tapCreateForPid(
        pid: pid,
        place: .tailAppendEventTap,
        options: .defaultTap,
        eventsOfInterest: nullMask,
        callback: tap1Callback,
        userInfo: refcon
    ) else {
        DebugLog.log("move relay: pid tap unavailable pid=\(pid) postAccess=\(CGPreflightPostEventAccess()) listenAccess=\(CGPreflightListenEventAccess())")
        return false
    }
    relay.tap1 = tap1

    // Tap 2: LISTEN-ONLY tap at the session tap. On seeing the REAL event (matched by tag) it
    // disables itself and re-posts the real event back into the owning pid — the delivery the
    // server accepts as a genuine item drag.
    let tap2Callback: CGEventTapCallBack = { _, _, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let relay = Unmanaged<ScrombleRelay>.fromOpaque(userInfo).takeUnretainedValue()
        if event.getIntegerValueField(.eventSourceUserData) == relay.realTag {
            if let tap2 = relay.tap2 { CGEvent.tapEnable(tap: tap2, enable: false) }
            if let real = relay.realEvent {
                real.postToPid(relay.pid)
                relay.delivered = true
            }
        }
        return Unmanaged.passUnretained(event)
    }
    let realMask: CGEventMask = 1 << realEvent.type.rawValue
    guard let tap2 = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .tailAppendEventTap,
        options: .listenOnly,
        eventsOfInterest: realMask,
        callback: tap2Callback,
        userInfo: refcon
    ) else {
        DebugLog.log("move relay: session tap unavailable pid=\(pid) postAccess=\(CGPreflightPostEventAccess()) listenAccess=\(CGPreflightListenEventAccess())")
        CFMachPortInvalidate(tap1)
        return false
    }
    relay.tap2 = tap2

    let source1 = CFMachPortCreateRunLoopSource(nil, tap1, 0)
    let source2 = CFMachPortCreateRunLoopSource(nil, tap2, 0)
    let runLoop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(runLoop, source1, .commonModes)
    CFRunLoopAddSource(runLoop, source2, .commonModes)
    CGEvent.tapEnable(tap: tap1, enable: true)
    CGEvent.tapEnable(tap: tap2, enable: true)
    defer {
        CFMachPortInvalidate(tap1)
        CFMachPortInvalidate(tap2)
        CFRunLoopRemoveSource(runLoop, source1, .commonModes)
        CFRunLoopRemoveSource(runLoop, source2, .commonModes)
    }

    // Kick the shuttle by posting the tagged null INTO the owning pid, where Tap1 (scoped to that
    // pid) catches it and re-emits the real event to the session tap. Then pump this run loop until
    // tap2 has re-delivered the real event or the deadline elapses. Bounded so a missed tap can
    // never wedge the move loop.
    nullEvent.postToPid(pid)
    let deadline = Date().addingTimeInterval(timeout)
    while !relay.delivered, Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.005, true)
    }
    return relay.delivered
}
