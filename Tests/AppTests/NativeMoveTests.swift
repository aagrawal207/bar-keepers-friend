import BarKeepersFriendCore
import CoreGraphics
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct NativeMoveTests {
    enum PostDropFault: CaseIterable, Sendable {
        case missingItem, missingReference, readFailure
    }

    @Test(arguments: [false, true], [0.04, 0.08])
    func ownerEchoDoesNotReleaseBeforeObservedGrab(hidden: Bool, grabDelay: TimeInterval) async throws {
        let fixture = NativeMoveFixture(hidden: hidden, grabDelay: grabDelay)

        try await fixture.run()

        #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        let down = try #require(fixture.events.first)
        let up = try #require(fixture.events.last)
        #expect(down.windowID == Int64(fixture.item.windowID))
        #expect(up.windowID == Int64(fixture.reference.windowID))
        #expect(up.at - down.at >= grabDelay - 0.000_001)
        #expect(up.at - down.at <= grabDelay + 0.011)
        #expect(fixture.unchangedGrabReads > 0)
        let observedAt = try #require(fixture.observedGrabs.first)
        #expect(observedAt >= down.at + grabDelay - 0.000_001)
        #expect(observedAt <= up.at)
        #expect(fixture.grabSleeps.allSatisfy { $0 > 0 && $0 <= 0.010_001 })
        #expect(fixture.asyncSleeps == [.milliseconds(120)])
        #expect(fixture.wakeups.isEmpty)
        #expect(fixture.isPlaced)
        fixture.expectRestored()
    }

    @Test(arguments: [false, true], [CGFloat(0), -2000])
    func delayedControlSettlingNeedsOneGestureNotAWakeup(hidden: Bool, originX: CGFloat) async throws {
        let fixture = NativeMoveFixture(hidden: hidden, originX: originX, grabDelay: 0, settleDelay: 0.5)

        try await fixture.run()

        #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        #expect(fixture.wakeups.isEmpty)
        let up = try #require(fixture.events.last)
        let firstRead = try #require(fixture.placementReads.first)
        let lastRead = try #require(fixture.placementReads.last)
        #expect(!firstRead.satisfied)
        #expect(lastRead.satisfied)
        #expect(fixture.placementReads.allSatisfy { $0.itemFrame == firstRead.itemFrame })
        #expect(firstRead.referenceFrame != lastRead.referenceFrame)
        #expect(fixture.now >= up.at + 0.5 - 0.000_001)
        #expect(fixture.now < up.at + 0.7)
        #expect(fixture.asyncSleeps.count > 1)
        #expect(fixture.asyncSleeps.first == .milliseconds(120))
        #expect(fixture.isPlaced)
        fixture.expectRestored()
    }

    @Test(arguments: [false, true])
    func delayedReleaseWaitsForTheItemToReturnToTheMenuBarRow(hidden: Bool) async throws {
        let fixture = NativeMoveFixture(hidden: hidden, grabDelay: 0, releaseDelay: 0.2)

        try await fixture.run()

        #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        #expect(fixture.wakeups.isEmpty)
        let up = try #require(fixture.events.first { $0.type == .leftMouseUp })
        let firstRead = try #require(fixture.placementReads.first)
        let lastRead = try #require(fixture.placementReads.last)
        #expect(firstRead.itemFrame == CGRect(x: 1511, y: 981, width: 22, height: 22))
        #expect(abs(firstRead.itemFrame.minY - fixture.reference.frame.minY) > 40)
        let expectedX = hidden
            ? fixture.reference.frame.minX - HiddenLayoutPlanner.hiddenMargin - fixture.item.frame.width
            : fixture.reference.frame.maxX + HiddenLayoutPlanner.shownMargin
        let expectedFrame = CGRect(x: expectedX, y: fixture.reference.frame.minY, width: 22, height: 22)
        #expect(lastRead.itemFrame == expectedFrame)
        #expect(fixture.itemFrame == expectedFrame)
        #expect(lastRead.referenceFrame == fixture.reference.frame)
        #expect(fixture.now - up.at >= 0.2 - 0.000_001)
        #expect(fixture.now - up.at < 0.3)
        #expect(fixture.asyncSleeps.count > 1)
        fixture.expectRestored()
    }

    @Test(arguments: [false, true])
    func permanentlyOffRowReleaseFailsWithoutWakeupOrAnotherGrab(hidden: Bool) async throws {
        let fixture = NativeMoveFixture(hidden: hidden, grabDelay: 0, releaseDelay: .infinity)

        await #expect(throws: WindowServerError.moveFailed(windowID: fixture.item.windowID)) {
            try await fixture.run()
        }

        #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        #expect(fixture.wakeups.isEmpty)
        let up = try #require(fixture.events.first { $0.type == .leftMouseUp })
        let grabbedFrame = CGRect(x: 1511, y: 981, width: 22, height: 22)
        #expect(fixture.itemFrame == grabbedFrame)
        #expect(abs(fixture.itemFrame.minY - fixture.reference.frame.minY) > 40)
        #expect(!fixture.placementReads.isEmpty)
        #expect(fixture.placementReads.allSatisfy {
            $0.itemFrame == grabbedFrame && $0.referenceFrame == fixture.reference.frame
        })
        #expect(fixture.now - up.at >= 1.12 - 0.000_001)
        #expect(fixture.now - up.at < 1.15)
        #expect(fixture.asyncSleeps.count > 1)
        fixture.expectRestored()
    }

    @Test(arguments: [false, true])
    func unusablePreGestureGeometryDoesNotPost(invalidReference: Bool) async {
        let fixture = NativeMoveFixture(hidden: false, grabDelay: 0)
        if invalidReference {
            fixture.referenceFrame.size.height = 41
        } else {
            fixture.itemFrame.origin = CGPoint(x: 1511, y: 981)
        }

        await #expect(throws: WindowServerError.moveFailed(windowID: fixture.item.windowID)) {
            try await fixture.run()
        }

        #expect(fixture.readCount > 0)
        #expect(fixture.events.isEmpty)
        #expect(fixture.wakeups.isEmpty)
        #expect(fixture.grabSleeps.isEmpty)
        #expect(fixture.asyncSleeps.isEmpty)
        #expect(fixture.now == 0)
        if !fixture.cursor.calls.isEmpty { fixture.expectRestored() }
    }

    @Test(arguments: [false, true])
    func satisfiedPlacementSkipsUnnecessaryWaits(alreadyPlaced: Bool) async throws {
        let fixture = NativeMoveFixture(grabDelay: 0)
        if alreadyPlaced {
            fixture.itemFrame.origin.x = fixture.referenceFrame.minX - fixture.itemFrame.width
        }

        try await fixture.run()

        #expect(fixture.events.map(\.type) == (alreadyPlaced ? [] : [.leftMouseDown, .leftMouseUp]))
        #expect(fixture.grabSleeps.isEmpty)
        #expect(fixture.asyncSleeps == (alreadyPlaced ? [] : [.milliseconds(120)]))
        #expect(abs(fixture.now - (alreadyPlaced ? 0 : 0.12)) < 0.000_001)
        #expect(fixture.wakeups.isEmpty)
        #expect(fixture.isPlaced)
        fixture.expectRestored()
    }

    @Test(arguments: [false, true])
    func stuckGrabOrPlacementExhaustsFiveBalancedAttempts(stuckGrab: Bool) async throws {
        let fixture = NativeMoveFixture(grabDelay: stuckGrab ? .infinity : 0, settleDelay: .infinity)

        await #expect(throws: WindowServerError.moveFailed(windowID: fixture.item.windowID)) {
            try await fixture.run()
        }

        #expect(fixture.events.map(\.type) == Array(repeating: [CGEventType.leftMouseDown, .leftMouseUp], count: 5).flatMap { $0 })
        #expect(fixture.wakeups == Array(repeating: [CGEventType.leftMouseDown, .leftMouseUp], count: 4).flatMap { $0 })
        #expect(!fixture.isPlaced)
        #expect(fixture.now < 8)
        let downs = fixture.events.filter { $0.type == .leftMouseDown }
        let ups = fixture.events.filter { $0.type == .leftMouseUp }
        if stuckGrab {
            #expect(fixture.observedGrabs.isEmpty)
            for (down, up) in zip(downs, ups) {
                #expect(up.at - down.at >= 0.25 - 0.000_001)
                #expect(up.at - down.at <= 0.261)
            }
        } else {
            #expect(fixture.observedGrabs.count >= 5)
            #expect(fixture.now >= 5)
            #expect(fixture.placementReads.allSatisfy { !$0.satisfied })
        }
        fixture.expectRestored()
    }

    @Test(arguments: [false, true])
    func interruptionDuringGrabReleasesBeforeRestoring(cancel: Bool) async {
        await Task {
            let fixture = NativeMoveFixture(grabDelay: 0.08)
            fixture.onGrabSleep = { [unowned fixture] in
                guard fixture.now >= 0.02 else { return }
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else {
                    fixture.cursor.session?["CGSSessionScreenIsLocked"] = true
                }
            }

            await #expect(throws: CancellationError.self) { try await fixture.run() }

            #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
            #expect(fixture.events.last?.balancingUp == true)
            #expect(fixture.now >= 0.02 && fixture.now < 0.08)
            #expect(fixture.asyncSleeps.isEmpty)
            #expect(fixture.wakeups.isEmpty)
            fixture.expectRestored(sessionLost: !cancel)
        }.value
    }

    @Test func cancellationAtPostDropPollingAwaitNeverWakesOrRetries() async {
        let started = AsyncGate()
        let release = AsyncGate()
        let task = Task {
            let fixture = NativeMoveFixture(grabDelay: 0, settleDelay: 0.5)
            fixture.onAsyncSleep = { [unowned fixture] in
                guard fixture.asyncSleeps.count == 2 else { return }
                await started.open()
                await release.wait()
            }

            await #expect(throws: CancellationError.self) { try await fixture.run() }
            // An erroneous early return must fail assertions instead of stranding the test's gate.
            await started.open()

            #expect(fixture.asyncSleeps.count == 2)
            #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
            #expect(fixture.wakeups.isEmpty)
            #expect(fixture.now < 0.5)
            fixture.expectRestored()
        }
        await started.wait()
        task.cancel()
        await release.open()
        await task.value
    }

    @Test func grabReadFailureReleasesBeforePropagatingOriginalError() async throws {
        let fixture = NativeMoveFixture(grabDelay: 0.08)
        fixture.failGrabRead = true

        await #expect(throws: fixture.readError) { try await fixture.run() }

        #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        let faultAt = try #require(fixture.faultObservedAt)
        #expect(faultAt >= 0.02 && faultAt < 0.08)
        #expect(fixture.events.last?.at == faultAt)
        #expect(fixture.events.last?.balancingUp == true)
        #expect(fixture.wakeups.isEmpty)
        #expect(fixture.asyncSleeps.isEmpty)
        fixture.expectRestored()
    }

    @Test(arguments: PostDropFault.allCases)
    func lostObservationDuringSettlingCannotReportSuccess(fault: PostDropFault) async throws {
        let fixture = NativeMoveFixture(grabDelay: 0, settleDelay: 0.5)
        fixture.postDropFault = fault
        let expectedError = fault == .readFailure
            ? fixture.readError : WindowServerError.moveFailed(windowID: fixture.item.windowID)

        await #expect(throws: expectedError) { try await fixture.run() }

        #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        #expect(fixture.wakeups.isEmpty)
        #expect(fixture.placementReads.first?.satisfied == false)
        let faultAt = try #require(fixture.faultObservedAt)
        #expect(faultAt >= 0.2 - 0.000_001 && faultAt < 0.5)
        fixture.expectRestored()
    }

    @Test(arguments: [false, true])
    func cancellationOrMissingPermissionBeforeStartEmitsNoInput(cancelled: Bool) async {
        await Task {
            let fixture = NativeMoveFixture()
            fixture.accessibilityGranted = cancelled
            if cancelled { withUnsafeCurrentTask { $0?.cancel() } }

            if cancelled {
                await #expect(throws: CancellationError.self) { try await fixture.run() }
            } else {
                await #expect(throws: WindowServerError.missingPermission(.accessibility)) {
                    try await fixture.run()
                }
            }

            #expect(fixture.readCount == 0)
            #expect(fixture.cursor.calls.isEmpty)
            #expect(fixture.events.isEmpty)
            #expect(fixture.wakeups.isEmpty)
            #expect(fixture.grabSleeps.isEmpty)
            #expect(fixture.asyncSleeps.isEmpty)
            #expect(fixture.now == 0)
        }.value
    }

    @Test(arguments: [false, true])
    func retryRefreshesBothReferenceAndItemGeometry(hidden: Bool) async throws {
        let fixture = NativeMoveFixture(hidden: hidden, grabDelay: 0)
        fixture.failedAttempts = 1
        let freshReference = fixture.reference.frame.offsetBy(dx: 100, dy: 0)
        let freshItem = fixture.item.frame.offsetBy(dx: 90, dy: 6)
        fixture.onWakeup = { [unowned fixture] in
            fixture.referenceFrame = freshReference
            fixture.itemFrame = freshItem
        }

        try await fixture.run()

        #expect(fixture.events.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(fixture.wakeups == [.leftMouseDown, .leftMouseUp])
        let drops = fixture.events.filter { $0.type == .leftMouseUp }
        #expect(drops.count == 2)
        let first = try #require(drops.first)
        let second = try #require(drops.last)
        let expectedX = hidden
            ? freshReference.minX - HiddenLayoutPlanner.hiddenMargin
            : freshReference.maxX + HiddenLayoutPlanner.shownMargin
        #expect(second.destination == CGPoint(x: expectedX, y: freshItem.midY))
        #expect(second.destination.x == first.destination.x + 100)
        #expect(second.windowID == Int64(fixture.reference.windowID))
        #expect(second.at - first.at >= 1)
        #expect(fixture.isPlaced)
        fixture.expectRestored()
    }
}

// Every native-effect hook is replaced; generated CGEvents are only inspected, never posted.
// Each fixture belongs to one awaited move task, including its cancellation and clock callbacks.
private final class NativeMoveFixture {
    struct Event {
        let type: CGEventType
        let at: TimeInterval
        let destination: CGPoint
        let windowID: Int64
        let balancingUp: Bool
    }

    struct PlacementRead {
        let itemFrame: CGRect
        let referenceFrame: CGRect
        let satisfied: Bool
    }

    let cursor = CursorFixture()
    let item: MenuBarItemSnapshot
    let reference: MenuBarItemSnapshot
    let hidden: Bool
    let originX: CGFloat
    let grabDelay: TimeInterval
    let settleDelay: TimeInterval
    let releaseDelay: TimeInterval
    let readError = WindowServerError.invalidServerResponse("scripted native-move observation failure")
    var itemFrame: CGRect
    var referenceFrame: CGRect
    var accessibilityGranted = true
    var failedAttempts = 0
    var failGrabRead = false
    var postDropFault: NativeMoveTests.PostDropFault?
    var onGrabSleep: (() -> Void)?
    var onAsyncSleep: (() async -> Void)?
    var onWakeup: (() -> Void)?
    private(set) var now: TimeInterval = 0
    private(set) var readCount = 0
    private(set) var events: [Event] = []
    private(set) var wakeups: [CGEventType] = []
    private(set) var grabSleeps: [TimeInterval] = []
    private(set) var asyncSleeps: [Duration] = []
    private(set) var unchangedGrabReads = 0
    private(set) var observedGrabs: [TimeInterval] = []
    private(set) var placementReads: [PlacementRead] = []
    private(set) var faultObservedAt: TimeInterval?
    private var downAt: TimeInterval?
    private var grabStartFrame: CGRect = .zero
    private var dropAt: TimeInterval?
    private var releasedItem: CGRect?
    private var releasesAt: TimeInterval = 0
    private var settledReference: CGRect?
    private var settlesAt: TimeInterval = 0

    init(
        hidden: Bool = true, originX: CGFloat = 0, grabDelay: TimeInterval = 0.06,
        settleDelay: TimeInterval = 0, releaseDelay: TimeInterval = 0
    ) {
        self.hidden = hidden
        self.originX = originX
        self.grabDelay = grabDelay
        self.settleDelay = settleDelay
        self.releaseDelay = releaseDelay
        item = MenuBarItemSnapshot(
            windowID: 75, ownerPID: 1811, ownerBundleID: "test.native-move",
            frame: CGRect(x: originX + (hidden ? 1100 : 900), y: 0, width: 22, height: 22)
        )
        reference = MenuBarItemSnapshot(
            windowID: hidden ? 91 : 90, ownerPID: 42, ownerBundleID: "Bar Keeper's Friend",
            title: hidden ? "BKFHidden" : "BKFAnchor",
            frame: CGRect(x: originX + (hidden ? 976 : 1000), y: 0, width: hidden ? 8 : 24, height: 22)
        )
        itemFrame = item.frame
        referenceFrame = reference.frame
    }

    var isPlaced: Bool {
        HiddenLayoutPlanner.isPlacementSatisfied(
            item: snapshot(item, frame: itemFrame), hidden: hidden,
            anchorMaxX: referenceFrame.maxX, dividerMinX: referenceFrame.minX
        )
    }

    func run() async throws {
        var controls = ItemControlStore()
        controls.setHidden(hidden, for: item)
        let request = try #require(HiddenLayoutPlanner.moves(
            for: [item], anchorMinX: originX + 1000, anchorMaxX: originX + 1024,
            dividerMinX: originX + 976, controls: controls
        ).first)
        let server = SystemWindowServer(
            readItems: { try self.read() },
            hasAccessibility: { self.accessibilityGranted },
            makeMoveCursor: { try self.cursor.makeCursor() },
            relayMove: { event, pid, _, cursor, balancingUp in
                self.relay(event, pid: pid, cursor: cursor, balancingUp: balancingUp)
            },
            postEvent: { event in
                #expect(event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == Int64(self.item.windowID))
                self.wakeups.append(event.type)
                self.cursor.calls.append(.post)
                if event.type == .leftMouseUp { self.onWakeup?() }
            },
            uptime: { self.now },
            sleepForGrab: { interval in
                self.grabSleeps.append(interval)
                self.advance(by: interval)
                self.onGrabSleep?()
            },
            sleep: { duration in
                try Task.checkCancellation()
                self.asyncSleeps.append(duration)
                let components = duration.components
                self.advance(by: Double(components.seconds) + Double(components.attoseconds) / 1e18)
                await self.onAsyncSleep?()
                try Task.checkCancellation()
            }
        )
        try await server.move(item: request.item, toX: request.targetX, relativeTo: reference.windowID)
    }

    private func read() throws -> [MenuBarItemSnapshot] {
        readCount += 1
        advance(by: 0)
        if let downAt {
            if failGrabRead, now - downAt >= 0.02 - 0.000_001 {
                faultObservedAt = now
                throw readError
            }
            if itemFrame == grabStartFrame {
                unchangedGrabReads += 1
            } else {
                observedGrabs.append(now)
            }
        }
        let currentItem = snapshot(item, frame: itemFrame)
        let currentReference = snapshot(reference, frame: referenceFrame)
        if let dropAt, downAt == nil {
            if let postDropFault, now - dropAt >= 0.2 - 0.000_001 {
                faultObservedAt = now
                switch postDropFault {
                case .missingItem: return [currentReference]
                case .missingReference: return [currentItem]
                case .readFailure: throw readError
                }
            }
            placementReads.append(PlacementRead(itemFrame: itemFrame, referenceFrame: referenceFrame, satisfied: isPlaced))
        }
        return [currentItem, currentReference]
    }

    private func relay(_ event: CGEvent, pid: pid_t, cursor: CursorConcealment, balancingUp: Bool) -> ScrombleRelay.Result {
        let permitted = cursor.canSubmitInput
        #expect(permitted || balancingUp)
        #expect(balancingUp == (event.type == .leftMouseUp))
        #expect(pid == item.ownerPID)
        #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(item.ownerPID))
        guard permitted || balancingUp else { return .init(interrupted: true) }
        advance(by: 0)
        events.append(Event(
            type: event.type, at: now, destination: event.location,
            windowID: event.getIntegerValueField(.mouseEventWindowUnderMousePointer), balancingUp: balancingUp
        ))
        self.cursor.calls.append(balancingUp ? .up : .down)
        if !balancingUp {
            #expect(downAt == nil)
            downAt = now
            dropAt = nil
            grabStartFrame = itemFrame
        } else if let downAt {
            if now - downAt >= grabDelay {
                releasedItem = CGRect(
                    x: hidden ? event.location.x - grabStartFrame.width : event.location.x,
                    y: event.location.y - grabStartFrame.height / 2,
                    width: grabStartFrame.width, height: grabStartFrame.height
                )
                releasesAt = now + releaseDelay
                settledReference = referenceFrame
                let attempt = events.filter { $0.type == .leftMouseDown }.count
                settlesAt = attempt <= failedAttempts ? .infinity : now + settleDelay
                // Reference animation and the owner's release observation complete independently.
                referenceFrame = referenceFrame.offsetBy(dx: hidden ? -24 : 24, dy: 0)
            } else {
                itemFrame = grabStartFrame
            }
            self.downAt = nil
            dropAt = now
            advance(by: 0)
        } else {
            Issue.record("A release requires a submitted grab")
        }
        return .init(submitted: true, delivered: true, interrupted: !permitted)
    }

    private func advance(by interval: TimeInterval) {
        now += interval
        if let downAt, now - downAt >= grabDelay {
            itemFrame = CGRect(x: originX + 1511, y: 981, width: grabStartFrame.width, height: grabStartFrame.height)
        }
        if let releasedItem, downAt == nil, now >= releasesAt {
            itemFrame = releasedItem
            self.releasedItem = nil
        }
        if let settledReference, now >= settlesAt {
            referenceFrame = settledReference
            self.settledReference = nil
        }
    }

    private func snapshot(_ template: MenuBarItemSnapshot, frame: CGRect) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: template.windowID, ownerPID: template.ownerPID,
            ownerBundleID: template.ownerBundleID, title: template.title, frame: frame
        )
    }

    func expectRestored(sessionLost: Bool = false) {
        #expect(Array(cursor.calls.prefix(3)) == [.position, .capability, .hide])
        #expect(cursor.calls.filter { $0 == .hide }.count == 1)
        #expect(cursor.calls.filter { $0 == .show }.count == 1)
        let warps = cursor.calls.compactMap { call -> CGPoint? in
            if case .warp(let point) = call { return point }
            return nil
        }
        #expect(warps == (sessionLost ? [] : [cursor.original]))
        let cleanup: [CursorFixture.Call] = sessionLost ? [.show] : [.warp(cursor.original), .show]
        #expect(Array(cursor.calls.suffix(cleanup.count)) == cleanup)
    }
}
