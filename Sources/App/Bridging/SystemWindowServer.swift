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

        // Positioned events can move the real pointer despite window-ID routing.
        // A restore point is required even when background concealment is unavailable.
        guard let cursor = try CursorConcealment() else {
            throw WindowServerError.moveFailed(windowID: item.windowID)
        }
        defer { cursor.restore() }

        for attempt in 1...Self.maxMoveAttempts {
            // A submitted down still needs its up; cancellation prevents a subsequent gesture.
            try Task.checkCancellation()
            try cursor.checkInterruption()
            let current = try menuBarItems()
            try cursor.checkInterruption()
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
            guard try cursor.performGesture({
                try postMoveGesture(
                    source: source, windowID: item.windowID, pid: item.ownerPID,
                    targetWindowID: targetWindowID, destination: destination, cursor: cursor
                )
            }) else { throw WindowServerError.moveFailed(windowID: item.windowID) }

            try await Task.sleep(for: .milliseconds(Self.moveSettleMs))
            try cursor.checkInterruption()
            let after = try menuBarItems()
            try cursor.checkInterruption()
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
                guard try cursor.performGesture({
                    try wakeUp(source: source, item: placed.attributed(bundleID: item.ownerBundleID, pid: item.ownerPID), cursor: cursor)
                }) else { throw WindowServerError.moveFailed(windowID: item.windowID) }
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
    func postMoveGesture(
        source: CGEventSource, windowID: CGWindowID, pid: pid_t,
        targetWindowID: CGWindowID, destination: CGPoint, cursor: CursorConcealment,
        relay: (CGEvent, pid_t, TimeInterval, CursorConcealment, Bool) -> ScrombleRelay.Result = scrombleEvent
    ) throws {
        try cursor.checkInterruption()
        guard let (down, up) = moveEvents(
            source: source, windowID: windowID, pid: pid,
            targetWindowID: targetWindowID, destination: destination
        ) else { return }
        let downResult = relay(down, pid, Self.scrombleTimeout, cursor, false)
        // A submitted down can already be in flight even when its owner echo was interrupted.
        let upResult = downResult.submitted ? relay(up, pid, Self.scrombleTimeout, cursor, true) : nil
        DebugLog.log("move relay: window=\(windowID) targetWindow=\(targetWindowID) pid=\(pid) down=\(downResult.delivered) up=\(upResult?.delivered ?? false) submitted=\(downResult.submitted) interrupted=\(downResult.interrupted || upResult?.interrupted == true)")
        guard !downResult.interrupted, upResult?.interrupted != true else { throw CancellationError() }
        try cursor.checkInterruption()
    }

    /// Builds events without posting them, so routing fields can be verified without moving the mouse.
    func moveEvents(source: CGEventSource, windowID: CGWindowID, pid: pid_t, targetWindowID: CGWindowID, destination: CGPoint) -> (down: CGEvent, up: CGEvent)? {
        // Window IDs route the off-screen grab, but positioned events can still move the cursor.
        // The caller owns concealment and restoration for the whole down/up pair.
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
    private func wakeUp(source: CGEventSource, item: MenuBarItemSnapshot, cursor: CursorConcealment) throws {
        let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: centre, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: centre, mouseButton: .left)
        else { return }
        stampWindowID(item.windowID, pid: item.ownerPID, into: down)
        stampWindowID(item.windowID, pid: item.ownerPID, into: up)
        try cursor.checkInterruption()
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
        // Allocate events before concealing or moving the cursor to keep the displaced interval short.
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: centre, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: centre, mouseButton: .left)
        else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        // Background capability is best-effort; retain a restore point even if concealment fails.
        guard let cursor = try CursorConcealment() else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }
        defer { cursor.restore() }

        // Session-tap delivery and the real-pointer warp preserve status-item hit-testing.
        // Event submission alone does not confirm menu opening or invisible cursor movement.
        guard try cursor.warp(to: centre) else {
            throw WindowServerError.clickFailed(windowID: item.windowID)
        }
        guard try cursor.performGesture({
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }) else { throw WindowServerError.clickFailed(windowID: item.windowID) }
    }
}

/// Shared mutable state for the two-tap scromble relay, reached by the C `CGEventTapCallBack`s
/// through an `Unmanaged` refcon. Lives at file scope (not nested in `scrombleEvent`) so the
/// strict-concurrency region analysis doesn't trip on the Unmanaged round-trip of a local class.
/// It is only ever mutated synchronously on the run loop that drives the relay, so the
/// `@unchecked Sendable` is sound: there is no cross-thread access.
final class ScrombleRelay: @unchecked Sendable {
    struct Result: Equatable, Sendable {
        var submitted = false
        // Owner forwarding is an API submission, not observed menu or window behavior.
        var delivered = false
        var interrupted = false
    }

    var realEvent: CGEvent?
    var realTag: Int64 = 0
    var nullTag: Int64 = 0
    var pid: pid_t = 0
    var tap1: CFMachPort?
    var tap2: CFMachPort?
    private(set) var result = Result()
    private let canSubmit: () -> Bool
    private let balancingUp: Bool
    private var finished = false

    init(canSubmit: @escaping () -> Bool, balancingUp: Bool) {
        self.canSubmit = canSubmit
        self.balancingUp = balancingUp
    }

    var canPost: Bool {
        if !result.interrupted, !canSubmit() { result.interrupted = true }
        // Only a release for an already-submitted down can bypass an interruption.
        return balancingUp || !result.interrupted
    }

    var shouldContinue: Bool {
        !finished && !result.delivered && (!result.interrupted || balancingUp)
    }

    func handleTrigger(tag: Int64, disable: () -> Void, send: () -> Void) -> Bool {
        guard tag == nullTag else { return false }
        guard !finished else { return true }
        disable()
        guard !result.submitted, canPost else { return true }
        result.submitted = true
        send()
        return true
    }

    func handleEcho(tag: Int64, disable: () -> Void, send: () -> Void) {
        guard !finished, tag == realTag, result.submitted, !result.delivered else { return }
        disable()
        guard canPost else { return }
        result.delivered = true
        send()
    }

    func perform(run: () -> Void, fallback: () -> Void) -> Result {
        guard !finished else { return result }
        if canPost { run() }
        // Seal delayed callbacks before fallback; submission is distinct from an owner echo.
        finished = true
        let permitted = canPost
        if !result.submitted, permitted {
            result.submitted = true
            fallback()
        }
        // A fallback can submit before interruption becomes observable; its up is still required.
        _ = canPost
        return result
    }
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
/// Reports submission separately from owner forwarding, with a guarded fallback only if unsubmitted.
/// It pumps the current run loop until completion, interruption, or `timeout`.
///
/// A free (non-isolated) function, NOT a method: the equivalent method on `SystemWindowServer`
/// crashed the Swift 6.3.2 `SendNonSendable` SIL pass (region analysis over the `Unmanaged` +
/// CGEvent + C-callback shape inside an actor-isolated context). Lifting it to file scope sidesteps
/// that compiler bug; it touches no instance state, so nothing is lost.
private func scrombleEvent(
    _ realEvent: CGEvent, toPid pid: pid_t, timeout: TimeInterval,
    cursor: CursorConcealment, balancingUp: Bool
) -> ScrombleRelay.Result {
    let relay = ScrombleRelay(canSubmit: { cursor.canSubmitInput }, balancingUp: balancingUp)
    return relay.perform(
        run: { runScrombleRelay(realEvent, toPid: pid, timeout: timeout, relay: relay) },
        fallback: { realEvent.post(tap: .cgSessionEventTap) }
    )
}

private func runScrombleRelay(
    _ realEvent: CGEvent, toPid pid: pid_t, timeout: TimeInterval, relay: ScrombleRelay
) {
    // Tag the real event so the taps recognize exactly our event. A null trigger event carries a
    // distinct tag so the pid-tap can tell "kick" from "payload".
    let realTag = Int64(truncatingIfNeeded: ObjectIdentifier(realEvent).hashValue)
    realEvent.setIntegerValueField(.eventSourceUserData, value: realTag)
    guard let nullEvent = CGEvent(source: nil) else { return }
    let nullTag = realTag &+ 1
    nullEvent.setIntegerValueField(.eventSourceUserData, value: nullTag)

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
        let consumed = relay.handleTrigger(
            tag: event.getIntegerValueField(.eventSourceUserData),
            disable: { if let tap1 = relay.tap1 { CGEvent.tapEnable(tap: tap1, enable: false) } },
            send: { relay.realEvent?.post(tap: .cgSessionEventTap) }
        )
        if consumed { return nil }
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
        return
    }
    relay.tap1 = tap1

    // Tap 2: LISTEN-ONLY tap at the session tap. On seeing the REAL event (matched by tag) it
    // disables itself and re-posts the real event back into the owning pid — the delivery the
    // server accepts as a genuine item drag.
    let tap2Callback: CGEventTapCallBack = { _, _, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let relay = Unmanaged<ScrombleRelay>.fromOpaque(userInfo).takeUnretainedValue()
        relay.handleEcho(
            tag: event.getIntegerValueField(.eventSourceUserData),
            disable: { if let tap2 = relay.tap2 { CGEvent.tapEnable(tap: tap2, enable: false) } },
            send: { relay.realEvent?.postToPid(relay.pid) }
        )
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
        return
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
    guard relay.canPost else { return }
    nullEvent.postToPid(pid)
    let deadline = Date().addingTimeInterval(timeout)
    while relay.shouldContinue, Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.005, true)
    }
}
