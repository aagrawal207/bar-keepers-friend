import CoreGraphics
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ScrombleRelayTests {
    enum InterruptionPoint: CaseIterable, Sendable {
        case beforeTrigger, beforeEcho, timeout, fallback, afterDelivery, betweenLegs

        var submittedDown: Bool { self != .beforeTrigger && self != .timeout }
    }

    private func makeRelay(canSubmit: @escaping () -> Bool, balancingUp: Bool = false) -> ScrombleRelay {
        let relay = ScrombleRelay(canSubmit: canSubmit, balancingUp: balancingUp)
        relay.realTag = 41
        relay.nullTag = 42
        return relay
    }

    @Test func delayedTriggerCannotSubmitAfterInterruptionEvenIfSessionRecovers() {
        var allowed = true
        var sends: [String] = []
        let relay = makeRelay(canSubmit: { allowed })
        let result = relay.perform(run: {
            allowed = false
            #expect(relay.handleTrigger(tag: relay.nullTag, disable: {}, send: { sends.append("down") }))
            #expect(!relay.shouldContinue)
            allowed = true
            #expect(relay.handleTrigger(tag: relay.nullTag, disable: {}, send: { sends.append("late down") }))
            relay.handleEcho(tag: relay.realTag, disable: {}, send: { sends.append("owner") })
        }, fallback: { sends.append("fallback") })
        #expect(result == ScrombleRelay.Result(submitted: false, delivered: false, interrupted: true))
        #expect(sends.isEmpty)
    }

    @Test func interruptionWhileWaitingSuppressesFallbackAndSealsLateCallbacks() {
        var allowed = true
        var sends: [String] = []
        let relay = makeRelay(canSubmit: { allowed })
        let result = relay.perform(run: { allowed = false }, fallback: { sends.append("fallback") })
        allowed = true
        #expect(relay.handleTrigger(tag: relay.nullTag, disable: {}, send: { sends.append("late down") }))
        relay.handleEcho(tag: relay.realTag, disable: {}, send: { sends.append("late owner") })
        #expect(relay.perform(run: { sends.append("rerun") }, fallback: { sends.append("retry") }) == result)
        #expect(result == ScrombleRelay.Result(submitted: false, delivered: false, interrupted: true))
        #expect(sends.isEmpty)
    }

    @Test func interruptedEchoDoesNotForwardOrDuplicateAnAlreadySubmittedDown() {
        var allowed = true
        var sends: [String] = []
        let relay = makeRelay(canSubmit: { allowed })
        let result = relay.perform(run: {
            #expect(relay.handleTrigger(tag: relay.nullTag, disable: {}, send: { sends.append("down") }))
            allowed = false
            relay.handleEcho(tag: relay.realTag, disable: {}, send: { sends.append("owner") })
        }, fallback: { sends.append("fallback") })
        #expect(result == ScrombleRelay.Result(submitted: true, delivered: false, interrupted: true))
        #expect(sends == ["down"])
    }

    @Test(arguments: [false, true])
    func callbackRechecksAfterDisablingItsTap(beforeEcho: Bool) {
        var allowed = true
        var sends: [String] = []
        let relay = makeRelay(canSubmit: { allowed })
        let result = relay.perform(run: {
            #expect(relay.handleTrigger(
                tag: relay.nullTag, disable: { if !beforeEcho { allowed = false } },
                send: { sends.append("down") }
            ))
            relay.handleEcho(tag: relay.realTag, disable: { allowed = false }, send: { sends.append("owner") })
        }, fallback: { sends.append("fallback") })
        #expect(result.interrupted)
        #expect(sends == (beforeEcho ? ["down"] : []))
    }

    @Test func missingEchoDoesNotTurnTimeoutIntoADuplicateDown() {
        var sends: [String] = []
        let relay = makeRelay(canSubmit: { true })
        let result = relay.perform(run: {
            for _ in 0..<2 {
                let handled = relay.handleTrigger(tag: relay.nullTag, disable: {}, send: {
                    #expect(relay.result.submitted)
                    sends.append("down")
                })
                #expect(handled)
            }
        }, fallback: { sends.append("fallback") })
        #expect(result == ScrombleRelay.Result(submitted: true, delivered: false, interrupted: false))
        #expect(sends == ["down"])
    }

    @Test func onlyMatchingSubmittedEventsAreForwardedAndOnlyOnce() {
        var calls: [String] = []
        let relay = makeRelay(canSubmit: { true })
        let result = relay.perform(run: {
            #expect(!relay.handleTrigger(tag: 100, disable: { calls.append("wrong disable") }, send: { calls.append("wrong down") }))
            relay.handleEcho(tag: relay.realTag, disable: {}, send: { calls.append("early echo") })
            #expect(relay.handleTrigger(tag: relay.nullTag, disable: { calls.append("disable trigger") }, send: { calls.append("down") }))
            relay.handleEcho(tag: 100, disable: { calls.append("wrong disable") }, send: { calls.append("wrong echo") })
            for _ in 0..<2 {
                relay.handleEcho(tag: relay.realTag, disable: { calls.append("disable echo") }, send: { calls.append("owner") })
            }
        }, fallback: { calls.append("fallback") })
        #expect(result == ScrombleRelay.Result(submitted: true, delivered: true, interrupted: false))
        #expect(calls == ["disable trigger", "down", "disable echo", "owner"])
    }

    @Test func fallbackMarksSubmissionAndClosesCallbacksBeforeSending() {
        var sends: [String] = []
        let relay = makeRelay(canSubmit: { true })
        let result = relay.perform(run: {}, fallback: {
            #expect(relay.result.submitted)
            sends.append("fallback")
            #expect(relay.handleTrigger(tag: relay.nullTag, disable: {}, send: { sends.append("late down") }))
            relay.handleEcho(tag: relay.realTag, disable: {}, send: { sends.append("late owner") })
        })
        #expect(result == ScrombleRelay.Result(submitted: true, delivered: false, interrupted: false))
        #expect(sends == ["fallback"])
    }

    @Test func balancingUpCanStillSubmitAndForwardAfterInterruption() {
        var sends: [String] = []
        let relay = makeRelay(canSubmit: { false }, balancingUp: true)
        let result = relay.perform(run: {
            #expect(relay.shouldContinue)
            #expect(relay.handleTrigger(tag: relay.nullTag, disable: {}, send: { sends.append("up") }))
            relay.handleEcho(tag: relay.realTag, disable: {}, send: { sends.append("owner up") })
        }, fallback: { sends.append("fallback up") })
        #expect(result == ScrombleRelay.Result(submitted: true, delivered: true, interrupted: true))
        #expect(sends == ["up", "owner up"])
    }

    @Test(arguments: [false, true])
    func onlyABalancingUpCanUseFallbackAfterInterruption(balancingUp: Bool) {
        var ran = false
        var submitted = false
        let relay = makeRelay(canSubmit: { false }, balancingUp: balancingUp)
        let result = relay.perform(run: { ran = true }, fallback: { submitted = true })
        #expect(ran == balancingUp)
        #expect(submitted == balancingUp)
        #expect(result == ScrombleRelay.Result(submitted: balancingUp, delivered: false, interrupted: true))
    }

    @Test(arguments: InterruptionPoint.allCases)
    func movePairCancelsOnlyAfterReleasingAnySubmittedDown(point: InterruptionPoint) throws {
        let fixture = CursorFixture()
        let cursor = try #require(try fixture.makeCursor())
        defer { cursor.restore() }
        let source = try #require(CGEventSource(stateID: .privateState))
        var legs: [CGEventType] = []
        var submitted: [CGEventType] = []
        var forwarded: [CGEventType] = []
        #expect(throws: CancellationError.self) {
            try cursor.performGesture {
                try SystemWindowServer().postMoveGesture(
                    source: source, windowID: 75, pid: 1811, targetWindowID: 90,
                    destination: fixture.target, cursor: cursor,
                    waitForGrab: { true },
                    relay: { event, pid, timeout, cursor, balancingUp in
                        legs.append(event.type)
                        #expect(pid == 1811)
                        #expect(timeout == 0.1)
                        #expect(balancingUp == (event.type == .leftMouseUp))
                        let relay = makeRelay(canSubmit: { cursor.canSubmitInput }, balancingUp: balancingUp)
                        let result = relay.perform(run: {
                            if !balancingUp {
                                if point == .fallback { return }
                                if point == .beforeTrigger || point == .timeout {
                                    fixture.session?["CGSSessionScreenIsLocked"] = true
                                }
                                if point == .timeout { return }
                            }
                            #expect(relay.handleTrigger(tag: relay.nullTag, disable: {}, send: { submitted.append(event.type) }))
                            if !balancingUp, point == .beforeEcho {
                                fixture.session?["CGSSessionScreenIsLocked"] = true
                            }
                            relay.handleEcho(tag: relay.realTag, disable: {}, send: { forwarded.append(event.type) })
                            if !balancingUp, point == .afterDelivery {
                                fixture.session?["CGSSessionScreenIsLocked"] = true
                            }
                        }, fallback: {
                            submitted.append(event.type)
                            if !balancingUp, point == .fallback {
                                fixture.session?["CGSSessionScreenIsLocked"] = true
                            }
                        })
                        if !balancingUp, point == .betweenLegs {
                            fixture.session?["CGSSessionScreenIsLocked"] = true
                        }
                        return result
                    }
                )
            }
        }
        #expect(legs == (point.submittedDown ? [.leftMouseDown, .leftMouseUp] : [.leftMouseDown]))
        #expect(submitted == (point.submittedDown ? [.leftMouseDown, .leftMouseUp] : []))
        let expectedForwarded: [CGEventType] = point == .afterDelivery || point == .betweenLegs
            ? [.leftMouseDown, .leftMouseUp] : (point.submittedDown ? [.leftMouseUp] : [])
        #expect(forwarded == expectedForwarded)
        #expect(cursor.sessionLost)
        #expect(throws: CancellationError.self) {
            try cursor.performGesture { fixture.calls.append(.post) }
        }
        cursor.restore()
        cursor.restore()
        #expect(fixture.calls == [.position, .capability, .hide, .show])
    }

    @Test func taskCancellationAfterDownStillReleasesAndRestoresPointer() async {
        let fixture = CursorFixture()
        var submitted: [CGEventType] = []
        var forwarded: [CGEventType] = []
        let task = Task {
            let cursor = try #require(try fixture.makeCursor())
            defer { cursor.restore() }
            let source = try #require(CGEventSource(stateID: .privateState))
            _ = try cursor.performGesture {
                try SystemWindowServer().postMoveGesture(
                    source: source, windowID: 75, pid: 1811, targetWindowID: 90,
                    destination: fixture.target, cursor: cursor,
                    waitForGrab: { true },
                    relay: { event, _, _, cursor, balancingUp in
                        let relay = makeRelay(canSubmit: { cursor.canSubmitInput }, balancingUp: balancingUp)
                        return relay.perform(run: {
                            #expect(relay.handleTrigger(tag: relay.nullTag, disable: {}, send: {
                                submitted.append(event.type)
                                if !balancingUp { withUnsafeCurrentTask { $0?.cancel() } }
                            }))
                            relay.handleEcho(tag: relay.realTag, disable: {}, send: { forwarded.append(event.type) })
                        }, fallback: { submitted.append(event.type) })
                    }
                )
            }
        }
        switch await task.result {
        case .success:
            Issue.record("Task interruption must propagate after balancing the pair")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(submitted == [.leftMouseDown, .leftMouseUp])
        #expect(forwarded == [.leftMouseUp])
        #expect(fixture.calls == [.position, .capability, .hide, .warp(fixture.original), .show])
    }
}
