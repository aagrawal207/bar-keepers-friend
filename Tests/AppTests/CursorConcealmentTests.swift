import CoreGraphics
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CursorConcealmentTests {
    private enum TestFailure: Error { case gesture }
    enum Exit: CaseIterable, Sendable { case success, failure, cancellation }
    enum CapabilityFailure: CaseIterable, Sendable {
        case missingSymbols, missingMain, missingSetter, invalidConnection, rejected
    }
    enum SessionLoss: CaseIterable, Sendable {
        case unavailable, nonConsole, notLoggedIn, locked

        var session: [String: Any]? {
            guard self != .unavailable else { return nil }
            return [
                "kCGSSessionOnConsoleKey": self != .nonConsole,
                "kCGSessionLoginDoneKey": self != .notLoggedIn,
                "CGSSessionScreenIsLocked": self == .locked,
            ]
        }
    }

    @Test(arguments: [nil, false, true] as [Bool?], [nil, false, true] as [Bool?])
    func sessionParsingRequiresAnUnlockedLoggedInConsole(console: Bool?, loggedIn: Bool?) {
        for locked in [nil, false, true] as [Bool?] {
            var session: [String: Any] = [:]
            if let console { session["kCGSSessionOnConsoleKey"] = console }
            if let loggedIn { session["kCGSessionLoginDoneKey"] = loggedIn }
            if let locked { session["CGSSessionScreenIsLocked"] = locked }
            #expect(DesktopSession.canInteract(with: session) == (console == true && loggedIn == true && locked != true))
        }
    }

    @Test func unavailableOrMalformedSessionValuesFailClosed() {
        #expect(!DesktopSession.canInteract(with: nil))
        let keys = ["kCGSSessionOnConsoleKey", "kCGSessionLoginDoneKey", "CGSSessionScreenIsLocked"]
        for key in keys {
            for invalid in [NSNull(), "true", "false", NSNumber(value: 2)] as [Any] {
                var session: [String: Any] = [
                    "kCGSSessionOnConsoleKey": true,
                    "kCGSessionLoginDoneKey": true,
                    "CGSSessionScreenIsLocked": false,
                ]
                session[key] = invalid
                #expect(!DesktopSession.canInteract(with: session))
            }
        }
    }

    @Test(arguments: SessionLoss.allCases)
    func unusableSessionSkipsPositionCapabilityHideAndGesture(loss: SessionLoss) {
        let fixture = CursorFixture()
        fixture.session = loss.session
        #expect(throws: CancellationError.self) { try fixture.makeCursor() }
        #expect(fixture.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func sessionLossDuringSetupNeverHides(afterCapability: Bool) {
        let fixture = CursorFixture()
        if !afterCapability {
            fixture.onReadPosition = { [unowned fixture] in fixture.session = SessionLoss.locked.session }
        }
        #expect(throws: CancellationError.self) {
            try fixture.makeCursor { fixture.session = SessionLoss.locked.session }
        }
        #expect(fixture.calls == (afterCapability ? [.position, .capability] : [.position]))
    }

    @Test func missingRestorePointSkipsCapabilityHideAndGesture() throws {
        let fixture = CursorFixture()
        fixture.position = nil
        if let cursor = try fixture.makeCursor() {
            defer { cursor.restore() }
            fixture.calls.append(.post)
            Issue.record("A gesture must not start without a restore point")
        }
        #expect(fixture.calls == [.position])
    }

    @Test func sessionLossDuringFailedPositionReadIsCancellation() {
        let fixture = CursorFixture()
        fixture.position = nil
        fixture.onReadPosition = { [unowned fixture] in fixture.session = nil }
        #expect(throws: CancellationError.self) { try fixture.makeCursor() }
        #expect(fixture.calls == [.position])
    }

    @Test func cancelledScopeNeverStartsNativeWork() async {
        let fixture = CursorFixture()
        let task = Task { try fixture.makeCursor()?.restore() }
        task.cancel()
        switch await task.result {
        case .success:
            Issue.record("A cancelled caller must not begin cursor work")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(fixture.calls.isEmpty)
    }

    @Test(arguments: [CGError.success, .failure])
    func sessionLossDuringWarpIsCancellationRatherThanNativeFailure(result: CGError) throws {
        let fixture = CursorFixture()
        fixture.warpResults = [result]
        fixture.onWarp = { [unowned fixture] _ in fixture.session = SessionLoss.locked.session }
        let perform = {
            let cursor = try #require(try fixture.makeCursor())
            defer { cursor.restore() }
            #expect(throws: CancellationError.self) { try cursor.warp(to: fixture.target) }
            #expect(cursor.sessionLost)
        }
        try perform()
        #expect(fixture.calls == [.position, .capability, .hide, .warp(fixture.target), .show])
    }

    @Test(arguments: SessionLoss.allCases, [CGError.success, .failure])
    func sessionLossAfterBeginBlocksWarpsAndGesturesButBalancesHide(loss: SessionLoss, hideResult: CGError) throws {
        let fixture = CursorFixture()
        fixture.hideResult = hideResult
        let perform = {
            let cursor = try #require(try fixture.makeCursor())
            fixture.session = loss.session
            #expect(throws: CancellationError.self) { try cursor.warp(to: fixture.target) }
            #expect(throws: CancellationError.self) {
                try cursor.performGesture { fixture.calls.append(.post) }
            }
            #expect(cursor.sessionLost)
            cursor.restore()
            cursor.restore()
        }
        try perform()
        let expected: [CursorFixture.Call] = [.position, .capability, .hide]
        #expect(fixture.calls == expected + (hideResult == .success ? [.show] : []))
    }

    @Test func lockAfterWarpBlocksPostingAndUnlockDoesNotReviveAnOldScope() throws {
        let fixture = CursorFixture()
        let unlocked = fixture.session
        let perform = {
            let cursor = try #require(try fixture.makeCursor())
            defer { cursor.restore() }
            #expect(try cursor.warp(to: fixture.target))
            fixture.session = SessionLoss.locked.session
            #expect(throws: CancellationError.self) {
                try cursor.performGesture { fixture.calls.append(.post) }
            }
            fixture.session = unlocked
            #expect(throws: CancellationError.self) { try cursor.warp(to: fixture.target) }
            #expect(throws: CancellationError.self) {
                try cursor.performGesture { fixture.calls.append(.post) }
            }
        }
        try perform()
        #expect(fixture.calls == [.position, .capability, .hide, .warp(fixture.target), .show])
    }

    @Test func lockDuringDownFinishesThePairButBlocksTheNextGesture() throws {
        let fixture = CursorFixture()
        let perform = {
            let cursor = try #require(try fixture.makeCursor())
            defer { cursor.restore() }
            #expect(throws: CancellationError.self) {
                try cursor.performGesture {
                    fixture.calls.append(.down)
                    fixture.session = SessionLoss.locked.session
                    fixture.calls.append(.up)
                }
            }
            #expect(throws: CancellationError.self) {
                try cursor.performGesture { fixture.calls.append(.post) }
            }
        }
        try perform()
        #expect(fixture.calls == [.position, .capability, .hide, .down, .up, .show])
    }

    @Test(arguments: SessionLoss.allCases, [false, true])
    func sessionLossAcrossSuspensionStopsNextGestureButStillShows(loss: SessionLoss, cancel: Bool) async throws {
        let fixture = CursorFixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        let task = Task {
            let cursor = try #require(try fixture.makeCursor())
            defer { cursor.restore() }
            #expect(try cursor.performGesture { fixture.calls.append(.post) })
            await started.open()
            await finish.wait()
            try Task.checkCancellation()
            guard try cursor.performGesture({ fixture.calls.append(.post) }) else { throw TestFailure.gesture }
        }
        await started.wait()
        fixture.session = loss.session
        if cancel { task.cancel() }
        #expect(fixture.calls == [.position, .capability, .hide, .post])
        await finish.open()
        switch await task.result {
        case .success:
            Issue.record("No new gesture may start after session loss")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(fixture.calls == [.position, .capability, .hide, .post, .show])
    }

    @Test(arguments: Exit.allCases)
    func suspendedGestureRestoresOnSuccessThrowAndCancellation(exit: Exit) async throws {
        let fixture = CursorFixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        let task = Task {
            let cursor = try #require(try fixture.makeCursor())
            defer { cursor.restore() }
            #expect(try cursor.warp(to: fixture.target))
            #expect(try cursor.performGesture { fixture.calls.append(.post) })
            await started.open()
            await finish.wait()
            if exit == .failure { throw TestFailure.gesture }
            try Task.checkCancellation()
        }
        await started.wait()
        if exit == .cancellation { task.cancel() }
        #expect(fixture.calls == [.position, .capability, .hide, .warp(fixture.target), .post])
        await finish.open()
        switch await task.result {
        case .success:
            #expect(exit == .success)
        case .failure(let error):
            if exit == .failure {
                #expect(error is TestFailure)
            } else {
                #expect(exit == .cancellation)
                #expect(error is CancellationError)
            }
        }
        #expect(fixture.calls == [
            .position, .capability, .hide, .warp(fixture.target), .post,
            .warp(fixture.original), .show,
        ])
    }

    @Test(arguments: [false, true])
    func scopeDestructionAlsoRestoresOnSynchronousReturnAndThrow(throwFromGesture: Bool) throws {
        let fixture = CursorFixture()
        let perform = {
            let cursor = try #require(try fixture.makeCursor())
            try withExtendedLifetime(cursor) {
                #expect(try cursor.warp(to: fixture.target))
                #expect(try cursor.performGesture { fixture.calls.append(.post) })
                if throwFromGesture { throw TestFailure.gesture }
            }
        }
        if throwFromGesture {
            #expect(throws: TestFailure.self) { try perform() }
        } else {
            try perform()
        }
        #expect(fixture.calls == [
            .position, .capability, .hide, .warp(fixture.target), .post,
            .warp(fixture.original), .show,
        ])
    }

    @Test func failedInitialWarpSkipsPostButStillRestoresAndShows() throws {
        let fixture = CursorFixture()
        fixture.warpResults = [.failure, .success]
        let perform = {
            let cursor = try #require(try fixture.makeCursor())
            defer { cursor.restore() }
            guard try cursor.warp(to: fixture.target) else { throw TestFailure.gesture }
            #expect(try cursor.performGesture { fixture.calls.append(.post) })
        }
        #expect(throws: TestFailure.self) { try perform() }
        #expect(fixture.calls == [
            .position, .capability, .hide, .warp(fixture.target), .warp(fixture.original), .show,
        ])
    }

    @Test func failedHideRestoresPositionWithoutAnUnbalancedShow() throws {
        let fixture = CursorFixture()
        fixture.hideResult = .failure
        let perform = {
            let cursor = try #require(try fixture.makeCursor())
            defer { cursor.restore() }
            #expect(try cursor.warp(to: fixture.target))
            #expect(try cursor.performGesture { fixture.calls.append(.post) })
        }
        try perform()
        #expect(fixture.calls == [
            .position, .capability, .hide, .warp(fixture.target), .post, .warp(fixture.original),
        ])
    }

    @Test(arguments: [CGError.success, .failure], [CGError.success, .failure])
    func restoreIsIdempotentEvenIfWarpOrShowFails(warpResult: CGError, showResult: CGError) throws {
        let fixture = CursorFixture()
        fixture.warpResults = [.success, warpResult]
        fixture.showResult = showResult
        let perform = {
            let cursor = try #require(try fixture.makeCursor())
            #expect(try cursor.warp(to: fixture.target))
            #expect(try cursor.performGesture { fixture.calls.append(.post) })
            cursor.restore()
            cursor.restore()
            #expect(try cursor.warp(to: fixture.target) == false)
            #expect(try cursor.performGesture({ fixture.calls.append(.post) }) == false)
        }
        try perform()
        #expect(fixture.calls == [
            .position, .capability, .hide, .warp(fixture.target), .post,
            .warp(fixture.original), .show,
        ])
    }

    @Test(arguments: CapabilityFailure.allCases)
    func absentOrFailingCapabilityKeepsCursorScopeBestEffort(failure: CapabilityFailure) throws {
        let setterCalls = Mutex(0)
        let main: @Sendable () -> Int32 = { failure == .invalidConnection ? 0 : 41 }
        let setter: @Sendable (Int32, Int32, CFString, CFTypeRef) -> CGError = { caller, target, _, _ in
            #expect(caller == 41)
            #expect(target == caller)
            setterCalls.withLock { $0 += 1 }
            return .failure
        }
        let capability = BackgroundCursorCapability(
            mainConnectionID: failure == .missingSymbols || failure == .missingMain ? nil : main,
            setConnectionProperty: failure == .missingSymbols || failure == .missingSetter ? nil : setter
        )
        let fixture = CursorFixture()
        let perform = {
            let cursor = try #require(try fixture.makeCursor(enableBackground: capability.enable))
            defer { cursor.restore() }
            #expect(try cursor.warp(to: fixture.target))
            #expect(try cursor.performGesture { fixture.calls.append(.post) })
        }
        try perform()
        #expect(setterCalls.withLock { $0 } == (failure == .rejected ? 1 : 0))
        #expect(fixture.calls == [
            .position, .capability, .hide, .warp(fixture.target), .post,
            .warp(fixture.original), .show,
        ])
    }

    @Test func capabilityIsRetainedAndOnlySetsTheCurrentOwnConnectionOnce() throws {
        let connection = Mutex<Int32>(41)
        let configured = Mutex<[Int32]>([])
        let capability = BackgroundCursorCapability(
            mainConnectionID: { connection.withLock { $0 } },
            setConnectionProperty: { caller, target, key, value in
                #expect(target == caller)
                #expect(key as String == "SetsCursorInBackground")
                #expect(CFEqual(value, kCFBooleanTrue))
                configured.withLock { $0.append(caller) }
                return .success
            }
        )
        for _ in 0..<2 {
            let fixture = CursorFixture()
            let cursor = try #require(try fixture.makeCursor(enableBackground: capability.enable))
            cursor.restore()
        }
        #expect(configured.withLock { $0 } == [41])
        connection.withLock { $0 = 86 }
        capability.enable()
        capability.enable()
        #expect(configured.withLock { $0 } == [41, 86])
    }

    @Test func rejectedCapabilityCanRecoverOnTheSameConnection() {
        let attempts = Mutex(0)
        let capability = BackgroundCursorCapability(
            mainConnectionID: { 41 },
            setConnectionProperty: { _, _, _, _ in
                attempts.withLock {
                    $0 += 1
                    return $0 == 1 ? .failure : .success
                }
            }
        )
        capability.enable()
        capability.enable()
        capability.enable()
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func concurrentCapabilitySetupOnlySetsPropertyOnce() async {
        let attempts = Mutex(0)
        let capability = BackgroundCursorCapability(
            mainConnectionID: { 41 },
            setConnectionProperty: { _, _, _, _ in
                attempts.withLock { $0 += 1 }
                return .success
            }
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { capability.enable() } }
        }
        #expect(attempts.withLock { $0 } == 1)
    }
}

final class CursorFixture {
    enum Call: Equatable { case position, capability, hide, warp(CGPoint), post, down, up, show }

    let original = CGPoint(x: -84.25, y: 450.5)
    let target = CGPoint(x: 1032, y: 16.5)
    var session: [String: Any]? = ["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]
    var position: CGPoint? = CGPoint(x: -84.25, y: 450.5)
    var onReadPosition: (() -> Void)?
    var onWarp: ((CGPoint) -> Void)?
    var calls: [Call] = []
    var hideResult = CGError.success
    var showResult = CGError.success
    var warpResults: [CGError] = []

    func makeCursor(enableBackground: () -> Void = {}) throws -> CursorConcealment? {
        try CursorConcealment(
            canInteract: { DesktopSession.canInteract(with: self.session) },
            position: {
                self.calls.append(.position)
                self.onReadPosition?()
                return self.position
            },
            enableBackground: { self.calls.append(.capability); enableBackground() },
            hide: { self.calls.append(.hide); return self.hideResult },
            warp: {
                self.calls.append(.warp($0))
                self.onWarp?($0)
                return self.warpResults.isEmpty ? .success : self.warpResults.removeFirst()
            },
            show: { self.calls.append(.show); return self.showResult }
        )
    }
}
