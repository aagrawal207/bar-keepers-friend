import AppKit
import BarKeepersFriendCore
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HoverRevealControllerTests {
    enum Invalidation: CaseIterable, Equatable, Sendable {
        case pointer, eligibility, manualPanel
    }

    @Test func pollingIsOptInIdempotentAndStopsWithoutReadingThePointer() {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(false)
        controller.updatePointer(fixture.pointer)
        #expect(fixture.intervals.isEmpty)
        #expect(fixture.pointerReads == 0)

        controller.setEnabled(true)
        controller.setEnabled(true)
        #expect(fixture.intervals == [0.05])
        #expect(fixture.pointerReads == 1)
        controller.stop()
        controller.stop()
        fixture.tick(at: 10)
        controller.updatePointer(fixture.pointer)
        #expect(fixture.cancelledTimers == [0])
        #expect(fixture.pointerReads == 1)
        #expect(fixture.showCalls == 0)
        #expect(fixture.hideCalls == 0)
    }

    @Test func dwellAndExitGraceUseTheInjectedClock() async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(true)
        for time in [0.05, 0.1, 0.199] { fixture.tick(at: time) }
        #expect(controller.pendingShowTask == nil)
        fixture.tick(at: 0.2)
        let task = try #require(controller.pendingShowTask)
        await task.value
        #expect(fixture.showCalls == 1)
        #expect(fixture.visible)
        #expect(controller.ownsPanel)

        for time in [1, 1.1, 1.2, 1.399] {
            fixture.tick(at: time, pointer: CGPoint(x: 10, y: 30))
            #expect(fixture.visible)
        }
        fixture.tick(at: 1.4)
        fixture.tick(at: 10)
        #expect(!fixture.visible)
        #expect(fixture.hideCalls == 1)
        #expect(!controller.ownsPanel)
    }

    @Test(arguments: [CGPoint(x: 10, y: 30), CGPoint(x: 116, y: 98), CGPoint(x: 60, y: 70)])
    func leavingBeforeDwellCancelsEvenWhenAHiddenPanelHasAFrame(point: CGPoint) async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.pointer = point
        fixture.time = 0.19
        controller.updatePointer(point)
        fixture.tick(at: 1)
        #expect(controller.pendingShowTask == nil)
        #expect(fixture.showCalls == 0)
        fixture.tick(at: 2, pointer: CGPoint(x: 116, y: 112))
        fixture.tick(at: 2.199)
        #expect(controller.pendingShowTask == nil)
        fixture.tick(at: 2.2)
        await (try #require(controller.pendingShowTask)).value
        #expect(fixture.showCalls == 1)
    }

    @Test(arguments: Invalidation.allCases)
    func queuedShowRechecksLiveInputsBeforeCallingThePresenter(change: Invalidation) async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.2)
        let task = try #require(controller.pendingShowTask)
        switch change {
        case .pointer: fixture.pointer = CGPoint(x: 10, y: 30)
        case .eligibility: fixture.eligible = false
        case .manualPanel: fixture.visible = true
        }
        await task.value
        #expect(fixture.showCalls == 0)
        #expect(fixture.hideCalls == 0)
        #expect(!controller.ownsPanel)
        #expect(controller.pendingShowTask == nil)
        #expect(fixture.visible == (change == .manualPanel))
    }

    @Test(arguments: [CGPoint(x: 116, y: 112), CGPoint(x: 60, y: 70), CGPoint(x: 116, y: 98)])
    func reentryIntoAnchorPanelOrGapCancelsHide(point: CGPoint) async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        try await fixture.reveal(controller)
        fixture.tick(at: 1, pointer: CGPoint(x: 10, y: 30))
        fixture.tick(at: 1.399, pointer: point)
        fixture.tick(at: 100)
        #expect(fixture.visible)
        #expect(fixture.hideCalls == 0)
        fixture.tick(at: 101, pointer: CGPoint(x: 10, y: 30))
        fixture.tick(at: 101.399)
        #expect(fixture.visible)
        fixture.tick(at: 101.4)
        #expect(fixture.hideCalls == 1)
    }

    @Test(arguments: [false, true])
    func manualPanelIsUntouchedWhetherItPrecedesOrInterruptsDwell(visibleInitially: Bool) {
        let fixture = HoverFixture()
        fixture.visible = visibleInitially
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.visible = true
        fixture.tick(at: 1)
        fixture.tick(at: 2, pointer: CGPoint(x: 60, y: 70))
        fixture.tick(at: 3, pointer: CGPoint(x: 10, y: 30))
        fixture.eligible = false
        fixture.tick(at: 4)
        controller.setEnabled(false)
        #expect(fixture.visible)
        #expect(fixture.showCalls == 0)
        #expect(fixture.hideCalls == 0)
        #expect(!controller.ownsPanel)
    }

    @Test(arguments: [false, true])
    func heldMousePressBlocksDwellAndQueuedShowsWithoutWinningAgainstTheClick(queueShow: Bool) async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(true)
        if queueShow { fixture.tick(at: 0.2) }
        let task = controller.pendingShowTask
        fixture.mouseButtonPressed = true
        if queueShow { await task?.value } else { fixture.tick(at: 1) }
        #expect(fixture.showCalls == 0)
        #expect(controller.pendingShowTask == nil)
        fixture.mouseButtonPressed = false
        controller.relinquishForManualInteraction()
        fixture.visible = true
        fixture.tick(at: 2)
        controller.stop()
        #expect(fixture.visible)
        #expect(fixture.hideCalls == 0)
    }

    @Test func pressingAnItemDoesNotDismissAnAlreadyOpenHoverPanel() async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        try await fixture.reveal(controller)
        fixture.mouseButtonPressed = true
        fixture.tick(at: 1, pointer: CGPoint(x: 60, y: 70))
        fixture.tick(at: 10)
        #expect(fixture.visible)
        #expect(controller.ownsPanel)
        #expect(fixture.hideCalls == 0)
    }

    @Test func manualCloseCancelsDwellAndSuppressesReopeningUntilAnchorExit() async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.1)
        controller.relinquishForManualInteraction()
        fixture.visible = true
        fixture.tick(at: 1)
        fixture.visible = false
        fixture.tick(at: 2)
        fixture.tick(at: 5)
        #expect(controller.pendingShowTask == nil)
        let anchor = fixture.anchor
        fixture.anchor = nil
        fixture.tick(at: 6)
        fixture.anchor = anchor
        fixture.tick(at: 7)
        fixture.tick(at: 8)
        #expect(fixture.showCalls == 0)
        #expect(fixture.hideCalls == 0)

        fixture.tick(at: 9, pointer: CGPoint(x: 10, y: 30))
        fixture.tick(at: 10, pointer: CGPoint(x: 116, y: 112))
        fixture.tick(at: 10.2)
        await (try #require(controller.pendingShowTask)).value
        #expect(fixture.showCalls == 1)
    }

    @Test func manualTakeoverCancelsExitGraceWithoutHidingThePanel() async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        try await fixture.reveal(controller)
        fixture.tick(at: 1, pointer: CGPoint(x: 10, y: 30))
        fixture.pointer = CGPoint(x: 116, y: 112)
        controller.relinquishForManualInteraction()
        fixture.tick(at: 3)
        fixture.tick(at: 4, pointer: CGPoint(x: 10, y: 30))
        controller.setEnabled(false)
        #expect(fixture.visible)
        #expect(fixture.hideCalls == 0)
        #expect(!controller.ownsPanel)
    }

    @Test func syntheticPointerExcursionDuringIneligibilityDoesNotReopenAManuallyClosedBar() async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        try await fixture.reveal(controller)
        controller.relinquishForManualInteraction()
        fixture.visible = false
        fixture.eligible = false
        fixture.tick(at: 1, pointer: CGPoint(x: 10, y: 30))
        fixture.tick(at: 2, pointer: CGPoint(x: 116, y: 112))
        fixture.eligible = true
        for time in [3, 3.2, 10] { fixture.tick(at: time) }
        #expect(fixture.showCalls == 1)
        #expect(controller.pendingShowTask == nil)
        #expect(!fixture.visible)
        fixture.tick(at: 11, pointer: CGPoint(x: 10, y: 30))
        fixture.tick(at: 12, pointer: CGPoint(x: 116, y: 112))
        fixture.tick(at: 12.2)
        await (try #require(controller.pendingShowTask)).value
        #expect(fixture.showCalls == 2)
        #expect(fixture.visible)
    }

    @Test func manualInteractionCancelsAQueuedShow() async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.2)
        let task = try #require(controller.pendingShowTask)
        controller.relinquishForManualInteraction()
        fixture.visible = true
        await task.value
        #expect(task.isCancelled)
        #expect(fixture.showCalls == 0)
        #expect(fixture.hideCalls == 0)
        fixture.visible = false
        fixture.tick(at: 1)
        fixture.tick(at: 10)
        #expect(controller.pendingShowTask == nil)
    }

    @Test(arguments: [false, true])
    func disablingCancelsDwellOrQueuedShowAndCanRestart(queueShow: Bool) async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: queueShow ? 0.2 : 0.1)
        let task = controller.pendingShowTask
        controller.setEnabled(false)
        fixture.tick(at: 10)
        await task?.value
        #expect(fixture.showCalls == 0)
        #expect(fixture.hideCalls == 0)
        #expect(fixture.cancelledTimers == [0])
        controller.setEnabled(true)
        fixture.tick(at: 10.199)
        #expect(controller.pendingShowTask == nil)
        fixture.tick(at: 10.2)
        await (try #require(controller.pendingShowTask)).value
        #expect(fixture.visible)
        #expect(fixture.intervals == [0.05, 0.05])
    }

    @Test func disablingAnOpenHoverPanelClosesItExactlyOnce() async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        try await fixture.reveal(controller)
        controller.setEnabled(false)
        controller.setEnabled(false)
        controller.stop()
        fixture.tick(at: 10)
        #expect(!fixture.visible)
        #expect(fixture.hideCalls == 1)
        #expect(fixture.showCalls == 1)
        #expect(fixture.cancelledTimers == [0])
    }

    @Test(arguments: [false, true])
    func eligibilityLossCancelsDwellOrClosesHoverAndRecoveryDwells(panelWasOpen: Bool) async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        if panelWasOpen {
            try await fixture.reveal(controller)
        } else {
            controller.setEnabled(true)
            fixture.tick(at: 0.199)
        }
        fixture.eligible = false
        fixture.tick(at: 1)
        #expect(!fixture.visible)
        #expect(fixture.hideCalls == (panelWasOpen ? 1 : 0))
        #expect(controller.pendingShowTask == nil)
        fixture.eligible = true
        fixture.tick(at: 2)
        fixture.tick(at: 2.199)
        #expect(controller.pendingShowTask == nil)
        fixture.tick(at: 2.2)
        await (try #require(controller.pendingShowTask)).value
        #expect(fixture.visible)
        #expect(fixture.showCalls == (panelWasOpen ? 2 : 1))
    }

    @Test func lateTimerCallbackCannotActInANewerMonitoringSession() async throws {
        let fixture = HoverFixture()
        let controller = fixture.makeController()
        controller.setEnabled(true)
        controller.stop()
        fixture.time = 1
        controller.setEnabled(true)
        let reads = fixture.pointerReads
        fixture.tick(at: 2, timer: 0)
        #expect(fixture.pointerReads == reads)
        #expect(controller.pendingShowTask == nil)
        fixture.tick(at: 2, timer: 1)
        await (try #require(controller.pendingShowTask)).value
        #expect(fixture.visible)
        #expect(fixture.showCalls == 1)
    }

    @Test(arguments: [false, true])
    func disableOrStopCancelsAnAwaitingShowWithoutLateReopening(useStop: Bool) async throws {
        let fixture = HoverFixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        fixture.onShow = { [weak fixture] in
            await started.open()
            await finish.wait()
            guard !Task.isCancelled else { return }
            fixture?.visible = true
        }
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.2)
        let task = try #require(controller.pendingShowTask)
        await started.wait()
        if useStop { controller.stop() } else { controller.setEnabled(false) }
        #expect(task.isCancelled)
        #expect(!controller.ownsPanel)
        await finish.open()
        await task.value
        #expect(!fixture.visible)
        #expect(fixture.hideCalls == 0)
        #expect(fixture.cancelledTimers == [0])
    }

    @Test(arguments: [false, true])
    func lateShowCompletionCannotOverrideManualVisibility(manualVisible: Bool) async throws {
        let fixture = HoverFixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        fixture.onShow = { [weak fixture] in
            fixture?.visible = true
            await started.open()
            await finish.wait()
        }
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.2)
        let task = try #require(controller.pendingShowTask)
        await started.wait()
        controller.relinquishForManualInteraction()
        fixture.visible = manualVisible
        fixture.eligible = false
        fixture.pointer = CGPoint(x: 10, y: 30)
        await finish.open()
        await task.value
        fixture.tick(at: 10)
        controller.stop()
        #expect(task.isCancelled)
        #expect(fixture.visible == manualVisible)
        #expect(fixture.hideCalls == 0)
        #expect(!controller.ownsPanel)
    }

    @Test(arguments: [false, true])
    func supersededCompletionCannotClearOrCancelANewerShow(loseEligibility: Bool) async throws {
        let fixture = HoverFixture()
        let firstStarted = AsyncGate()
        let finishFirst = AsyncGate()
        let secondStarted = AsyncGate()
        let finishSecond = AsyncGate()
        fixture.onShow = { [weak fixture] in
            if fixture?.showCalls == 1 {
                await firstStarted.open()
                await finishFirst.wait()
            } else {
                await secondStarted.open()
                await finishSecond.wait()
            }
            guard !Task.isCancelled else { return }
            fixture?.visible = true
        }
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.2)
        let first = try #require(controller.pendingShowTask)
        await firstStarted.wait()
        if loseEligibility {
            fixture.eligible = false
            fixture.tick(at: 0.3)
        } else {
            fixture.tick(at: 0.3, pointer: CGPoint(x: 10, y: 30))
        }
        fixture.eligible = true
        fixture.tick(at: 1, pointer: CGPoint(x: 116, y: 112))
        fixture.tick(at: 1.2)
        let second = try #require(controller.pendingShowTask)
        await secondStarted.wait()
        await finishFirst.open()
        await first.value
        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        #expect(controller.pendingShowTask != nil)
        #expect(controller.ownsPanel)
        #expect(fixture.hideCalls == 0)
        await finishSecond.open()
        await second.value
        #expect(fixture.visible)
        #expect(fixture.showCalls == 2)
        #expect(controller.pendingShowTask == nil)
    }

    @Test(arguments: [false, true])
    func completionRechecksPointerAndEligibilityWithoutWaitingForAnotherPoll(loseEligibility: Bool) async throws {
        let fixture = HoverFixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        fixture.onShow = { [weak fixture] in
            await started.open()
            await finish.wait()
            guard !Task.isCancelled else { return }
            fixture?.visible = true
        }
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.2)
        let task = try #require(controller.pendingShowTask)
        await started.wait()
        fixture.time = 1
        if loseEligibility { fixture.eligible = false } else { fixture.pointer = CGPoint(x: 10, y: 30) }
        await finish.open()
        await task.value
        if !loseEligibility {
            #expect(fixture.visible)
            fixture.tick(at: 1.399)
            #expect(fixture.visible)
            fixture.tick(at: 1.4)
        }
        #expect(!fixture.visible)
        #expect(fixture.hideCalls == 1)
    }

    @Test(arguments: [false, true])
    func showCompletionDoesNotRestartOrInvalidateExitGrace(completeDuringGrace: Bool) async throws {
        let fixture = HoverFixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        fixture.onShow = { [weak fixture] in
            fixture?.visible = true
            await started.open()
            await finish.wait()
        }
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.2)
        let task = try #require(controller.pendingShowTask)
        await started.wait()
        fixture.tick(at: 1, pointer: CGPoint(x: 10, y: 30))
        if completeDuringGrace {
            fixture.time = 1.2
            await finish.open()
            await task.value
        }
        fixture.tick(at: 1.399)
        #expect(fixture.visible)
        fixture.tick(at: 1.4)
        #expect(!fixture.visible)
        #expect(task.isCancelled == !completeDuringGrace)
        fixture.visible = true
        await finish.open()
        await task.value
        #expect(fixture.visible)
        #expect(fixture.hideCalls == 1)
        #expect(!controller.ownsPanel)
    }

    @Test func failedShowDoesNotRetryUntilPointerLeavesAndReenters() async throws {
        let fixture = HoverFixture()
        fixture.onShow = {}
        let controller = fixture.makeController()
        controller.setEnabled(true)
        fixture.tick(at: 0.2)
        await (try #require(controller.pendingShowTask)).value
        fixture.tick(at: 1)
        fixture.tick(at: 10)
        #expect(fixture.showCalls == 1)
        #expect(controller.pendingShowTask == nil)
        #expect(!controller.ownsPanel)
        fixture.onShow = nil
        fixture.tick(at: 11, pointer: CGPoint(x: 10, y: 30))
        fixture.tick(at: 12, pointer: CGPoint(x: 116, y: 112))
        fixture.tick(at: 12.2)
        await (try #require(controller.pendingShowTask)).value
        #expect(fixture.visible)
        #expect(fixture.showCalls == 2)
    }

    @Test(arguments: [false, true])
    func teardownInvalidatesMonitoringAndOnlyClosesOwnedPanels(hoverOwned: Bool) async throws {
        let fixture = HoverFixture()
        var controller: HoverRevealController? = fixture.makeController()
        weak let weakController = controller
        if hoverOwned {
            try await fixture.reveal(try #require(controller))
        } else {
            fixture.visible = true
            controller?.setEnabled(true)
        }
        let reads = fixture.pointerReads
        controller = nil
        #expect(weakController == nil)
        #expect(fixture.cancelledTimers == [0])
        #expect(fixture.hideCalls == (hoverOwned ? 1 : 0))
        #expect(fixture.visible == !hoverOwned)
        fixture.tick(at: 10)
        #expect(fixture.pointerReads == reads)
    }

    @Test func suspendedShowDoesNotRetainControllerOrOutliveTeardown() async throws {
        let fixture = HoverFixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        fixture.onShow = { [weak fixture] in
            await started.open()
            await finish.wait()
            guard !Task.isCancelled else { return }
            fixture?.visible = true
        }
        var controller: HoverRevealController? = fixture.makeController()
        weak let weakController = controller
        controller?.setEnabled(true)
        fixture.tick(at: 0.2)
        let task = try #require(controller?.pendingShowTask)
        await started.wait()
        controller = nil
        #expect(weakController == nil)
        #expect(task.isCancelled)
        #expect(fixture.cancelledTimers == [0])
        await finish.open()
        await task.value
        #expect(!fixture.visible)
        #expect(fixture.hideCalls == 0)
    }

    @Test(arguments: [CGPoint(x: -1920, y: 0), CGPoint(x: 0, y: -1080), CGPoint(x: 0, y: 982)])
    func anchorToPanelTransitWorksOnNegativeAndStackedDisplays(offset: CGPoint) async throws {
        let fixture = HoverFixture()
        fixture.anchor = fixture.anchor?.offsetBy(dx: offset.x, dy: offset.y)
        fixture.panel = fixture.panel?.offsetBy(dx: offset.x, dy: offset.y)
        fixture.pointer = CGPoint(x: 116 + offset.x, y: 112 + offset.y)
        let controller = fixture.makeController()
        try await fixture.reveal(controller)
        fixture.tick(at: 1, pointer: CGPoint(x: 116 + offset.x, y: 98 + offset.y))
        fixture.tick(at: 2, pointer: CGPoint(x: 60 + offset.x, y: 70 + offset.y))
        fixture.tick(at: 100)
        #expect(fixture.visible)
        #expect(fixture.hideCalls == 0)
    }
}

@MainActor
private final class HoverFixture {
    var time: TimeInterval = 0
    var pointer = CGPoint(x: 116, y: 112)
    var anchor: CGRect? = CGRect(x: 100, y: 100, width: 32, height: 24)
    var panel: CGRect? = CGRect(x: 40, y: 50, width: 92, height: 46)
    var visible = false
    var eligible = true
    var mouseButtonPressed = false
    var showCalls = 0
    var hideCalls = 0
    var pointerReads = 0
    var intervals: [TimeInterval] = []
    var cancelledTimers: [Int] = []
    var onShow: (@MainActor () async -> Void)?
    private var ticks: [@MainActor @Sendable () -> Void] = []

    func makeController() -> HoverRevealController {
        HoverRevealController(
            anchorFrame: { self.anchor }, panelFrame: { self.panel },
            isPanelVisible: { self.visible }, canReveal: { self.eligible },
            showPanel: {
                self.showCalls += 1
                if let onShow = self.onShow { await onShow() } else { self.visible = true }
            },
            hidePanel: { self.hideCalls += 1; self.visible = false },
            pointerLocation: { self.pointerReads += 1; return self.pointer },
            isMouseButtonPressed: { self.mouseButtonPressed },
            now: { self.time },
            scheduleTimer: { interval, tick in
                let index = self.ticks.count
                self.ticks.append(tick)
                self.intervals.append(interval)
                return { self.cancelledTimers.append(index) }
            }
        )
    }

    func tick(at time: TimeInterval, pointer: CGPoint? = nil, timer: Int? = nil) {
        self.time = time
        if let pointer { self.pointer = pointer }
        ticks[timer ?? ticks.count - 1]()
    }

    func reveal(_ controller: HoverRevealController) async throws {
        controller.setEnabled(true)
        tick(at: time + HoverRevealStateMachine.dwellDelay)
        await (try #require(controller.pendingShowTask)).value
        #expect(visible)
        #expect(controller.ownsPanel)
    }
}
