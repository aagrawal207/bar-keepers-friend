import ApplicationServices
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AXActivatorTests {
    @Test(arguments: [false, true])
    func interruptionRemainsTerminalAfterUnlockAcrossAwait(knownPID: Bool) async {
        let interactive = Mutex(true)
        let sweeps = Mutex(0)
        let presses = Mutex(0)
        await #expect(throws: CancellationError.self) {
            try await AXActivator.activate(
                pid: knownPID ? 41 : 0, canInteract: { interactive.withLock { $0 } }, isTrusted: { true },
                runningPIDs: { sweeps.withLock { $0 += 1 }; return [41, 42] },
                press: { pids, timeout in
                    presses.withLock { $0 += 1 }
                    #expect(pids == (knownPID ? [41] : [41, 42]))
                    #expect(timeout == (knownPID ? 0.5 : 1.5))
                    #expect(!Task.isCancelled)
                    interactive.withLock { $0 = false }
                    let outcome = AXActivator.performActions(
                        on: 1, windowID: 1, canInteract: { interactive.withLock { $0 } },
                        performAction: { _, _ in Issue.record("Unexpected AX action"); return .success },
                        pressableChild: { _ in Issue.record("Unexpected child lookup"); return nil }
                    )
                    #expect(outcome == .interrupted)
                    // The detached worker observes the lock; its caller only sees the unlocked desktop.
                    interactive.withLock { $0 = true }
                    return outcome
                }
            )
        }
        #expect(!Task.isCancelled)
        #expect(interactive.withLock { $0 })
        #expect(presses.withLock { $0 } == 1)
        #expect(sweeps.withLock { $0 } == (knownPID ? 0 : 1))
    }

    @Test(arguments: 0...4, [false, true])
    func sessionLossStopsRemainingParentAndChildActions(afterAction: Int, actionAccepted: Bool) {
        var interactive = afterAction != 0
        var actions: [String] = []
        var childLookups = 0
        let outcome = AXActivator.performActions(
            on: "parent", windowID: 1,
            canInteract: {
                DesktopSession.canInteract(with: [
                    "kCGSSessionOnConsoleKey": true,
                    "kCGSessionLoginDoneKey": true,
                    "CGSSessionScreenIsLocked": !interactive
                ])
            },
            performAction: { element, action in
                actions.append("\(element).\(action)")
                if actions.count == afterAction { interactive = false }
                return actions.count == afterAction && actionAccepted ? .success : .actionUnsupported
            },
            pressableChild: { _ in childLookups += 1; return "child" }
        )

        #expect(outcome == .interrupted)
        #expect(actions == Array(["parent.AXPress", "parent.AXShowMenu", "child.AXPress", "child.AXShowMenu"].prefix(afterAction)))
        #expect(childLookups == (afterAction >= 3 ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func interruptionDuringChildLookupIsNotAnUnsupportedAction(childFound: Bool) {
        var interactive = true
        var actions: [String] = []
        let outcome = AXActivator.performActions(
            on: "parent", windowID: 1, canInteract: { interactive },
            performAction: { element, action in actions.append("\(element).\(action)"); return .actionUnsupported },
            pressableChild: { _ in interactive = false; return childFound ? "child" : nil }
        )

        #expect(outcome == .interrupted)
        #expect(actions == ["parent.AXPress", "parent.AXShowMenu"])
    }

    @Test(arguments: 0...4)
    func actionOrderingAndAcceptanceAreUnchanged(acceptedAction: Int) {
        var actions: [String] = []
        var childLookups = 0
        let outcome = AXActivator.performActions(
            on: "parent", windowID: 1, canInteract: { true },
            performAction: { element, action in
                actions.append("\(element).\(action)")
                return actions.count == acceptedAction ? .success : .actionUnsupported
            },
            pressableChild: { _ in childLookups += 1; return "child" }
        )

        #expect(outcome == (acceptedAction == 0 ? .matchedNoAction : .pressed))
        let count = acceptedAction == 0 ? 4 : acceptedAction
        #expect(actions == Array(["parent.AXPress", "parent.AXShowMenu", "child.AXPress", "child.AXShowMenu"].prefix(count)))
        #expect(childLookups == (count >= 3 ? 1 : 0))
    }

    @Test(arguments: [AXActivator.PressOutcome.pressed, .matchedNoAction, .noMatch])
    func onlyAGenuineFastPathMissStartsTheBroaderSweep(fastOutcome: AXActivator.PressOutcome) async throws {
        let sweeps = Mutex(0)
        let calls = Mutex<[([pid_t], Float)]>([])
        let activated = try await AXActivator.activate(
            pid: 41, canInteract: { true }, isTrusted: { true },
            runningPIDs: { sweeps.withLock { $0 += 1 }; return [41, 42] },
            press: { pids, timeout in
                calls.withLock { $0.append((pids, timeout)) }
                return pids == [41] ? fastOutcome : .pressed
            }
        )

        #expect(activated == (fastOutcome != .matchedNoAction))
        #expect(sweeps.withLock { $0 } == (fastOutcome == .noMatch ? 1 : 0))
        #expect(calls.withLock { $0.map { $0.0 } } == (fastOutcome == .noMatch ? [[41], [41, 42]] : [[41]]))
        #expect(calls.withLock { $0.map { $0.1 } } == (fastOutcome == .noMatch ? [0.5, 1.5] : [0.5]))
    }

    @Test(arguments: [false, true])
    func sessionLossWhileReadingRunningAppsPreventsTheSweep(knownPID: Bool) async {
        let interactive = Mutex(true)
        let presses = Mutex(0)
        await #expect(throws: CancellationError.self) {
            try await AXActivator.activate(
                pid: knownPID ? 41 : 0, canInteract: { interactive.withLock { $0 } }, isTrusted: { true },
                runningPIDs: { interactive.withLock { $0 = false }; return [41, 42] },
                press: { _, _ in presses.withLock { $0 += 1 }; return .noMatch }
            )
        }
        #expect(presses.withLock { $0 } == (knownPID ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func entryRefusalDoesNotRunAXOrEnumerateApps(interactive: Bool) async throws {
        let trustChecks = Mutex(0)
        func activate() async throws -> Bool {
            try await AXActivator.activate(
                pid: 41, canInteract: { interactive },
                isTrusted: { trustChecks.withLock { $0 += 1 }; return false },
                runningPIDs: { Issue.record("Unexpected app enumeration"); return [] },
                press: { _, _ in Issue.record("Unexpected AX work"); return .pressed }
            )
        }

        if interactive {
            #expect(try await activate() == false)
        } else {
            await #expect(throws: CancellationError.self) { try await activate() }
        }
        #expect(trustChecks.withLock { $0 } == (interactive ? 1 : 0))
    }

    @Test func callerCancellationReachesTheDetachedActionSequence() async {
        let started = AsyncGate()
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await AXActivator.activate(
                pid: 41, canInteract: { true }, isTrusted: { true },
                runningPIDs: { Issue.record("Unexpected app enumeration"); return [] },
                press: { _, _ in
                    Task { await started.open() }
                    #expect(release.wait(timeout: .now() + 5) == .success)
                    #expect(Task.isCancelled)
                    return AXActivator.performActions(
                        on: 1, windowID: 1, canInteract: { true },
                        performAction: { _, _ in Issue.record("Unexpected AX action"); return .success },
                        pressableChild: { _ in Issue.record("Unexpected child lookup"); return nil }
                    )
                }
            )
        }
        await started.wait()
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
