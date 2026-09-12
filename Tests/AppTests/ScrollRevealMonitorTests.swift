import AppKit
import BarKeepersFriendCore
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ScrollRevealMonitorTests {
    enum Source: CaseIterable, Sendable {
        case global, local
    }

    @Test func constructedDisabledInstallsNothingAndIgnoresDirectEvents() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        #expect(!monitor.isEnabled)
        #expect(fixture.global.installCount == 0)
        #expect(fixture.local.installCount == 0)
        #expect(fixture.global.removeCount == 0)
        #expect(fixture.local.removeCount == 0)
        fixture.swipe(.global, dy: 20, startingAt: 0)
        monitor.handle(fixture.event(dy: 20, phase: .changed))
        #expect(fixture.reveals == 0)
        #expect(fixture.hides == 0)
        #expect(fixture.frameQueries.isEmpty)
    }

    @Test func defaultSourcesAreOneGlobalAndOneLocalNSEventMonitor() {
        let monitor = ScrollRevealMonitor(menuBarFrame: { _ in nil }, onReveal: {}, onHide: {})
        let scopes = monitor.sources.map { ($0 as? NSEventScrollSource)?.scope }
        #expect(scopes == [.global, .local])
        #expect(!monitor.isEnabled)
    }

    @Test func enableInstallsExactlyOneHandlerPerSourceAndIsIdempotent() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        monitor.setEnabled(true)
        #expect(monitor.isEnabled)
        #expect(fixture.global.installCount == 1)
        #expect(fixture.local.installCount == 1)
        #expect(fixture.global.isInstalled)
        #expect(fixture.local.isInstalled)
        #expect(fixture.global.removeCount == 0)
        #expect(fixture.local.removeCount == 0)
    }

    @Test(arguments: [false, true])
    func disableOrStopRemovesEveryHandlerOnceAndIgnoresLateDeliveries(useStop: Bool) {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let stale = fixture.global.handler
        if useStop { monitor.stop() } else { monitor.setEnabled(false) }
        if useStop { monitor.stop() } else { monitor.setEnabled(false) }
        monitor.stop()
        #expect(!monitor.isEnabled)
        #expect(fixture.global.removeCount == 1)
        #expect(fixture.local.removeCount == 1)
        #expect(!fixture.global.isInstalled)
        #expect(!fixture.local.isInstalled)

        fixture.swipe(.global, dy: 20, startingAt: 1)
        fixture.swipe(.local, dy: 20, startingAt: 2)
        fixture.replay(fixture.gesture(dy: 20, startingAt: 3), into: stale)
        #expect(fixture.reveals == 0)
        #expect(fixture.hides == 0)
    }

    @Test(arguments: Source.allCases)
    func pullDownRevealsAndPushUpHidesThroughEitherSource(source: Source) {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.swipe(source, dy: 20, startingAt: 0)
        #expect(fixture.reveals == 1)
        #expect(fixture.hides == 0)
        fixture.swipe(source, dy: -20, startingAt: 1)
        #expect(fixture.reveals == 1)
        #expect(fixture.hides == 1)
        #expect(fixture.frameQueries.allSatisfy { $0 == fixture.overBar })
    }

    @Test func swipeLeftRevealsAndSwipeRightHides() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.swipe(.global, dx: -20, startingAt: 0)
        #expect(fixture.reveals == 1)
        fixture.swipe(.global, dx: 20, startingAt: 1)
        #expect(fixture.hides == 1)
    }

    @Test func eachEventSuppliesItsOwnDirectionConvention() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        // A mouse with natural scrolling off reports the same physical pull-down as negative deltaY.
        fixture.swipe(.global, dy: -20, inverted: false, startingAt: 0)
        #expect(fixture.reveals == 1)
        #expect(fixture.hides == 0)
        fixture.swipe(.global, dy: 20, inverted: false, startingAt: 1)
        #expect(fixture.hides == 1)
        fixture.swipe(.global, dx: 20, inverted: false, startingAt: 2)
        #expect(fixture.reveals == 2)
        fixture.swipe(.global, dy: 20, inverted: true, startingAt: 3)
        #expect(fixture.reveals == 3)
        #expect(fixture.hides == 1)
    }

    @Test func reEnableAfterStopInstallsFreshHandlersAndDelivers() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        monitor.stop()
        monitor.setEnabled(true)
        #expect(monitor.isEnabled)
        #expect(fixture.global.installCount == 2)
        #expect(fixture.local.installCount == 2)
        #expect(fixture.global.removeCount == 1)
        #expect(fixture.local.removeCount == 1)
        fixture.swipe(.local, dy: 20, startingAt: 5)
        #expect(fixture.reveals == 1)
    }

    @Test func staleHandlerFromAnEarlierSessionCannotActAfterReEnable() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let stale = fixture.global.handler
        monitor.stop()
        monitor.setEnabled(true)
        fixture.replay(fixture.gesture(dy: 20, startingAt: 0), into: stale)
        #expect(fixture.reveals == 0)
        fixture.swipe(.global, dy: 20, startingAt: 1)
        #expect(fixture.reveals == 1)
    }

    @Test func gestureInProgressAtEnableTimeStartsCleanAfterDisable() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.global.emit(fixture.event(phase: .began))
        fixture.global.emit(fixture.event(dy: 8, phase: .changed))
        monitor.setEnabled(false)
        monitor.setEnabled(true)
        fixture.global.emit(fixture.event(dy: 8, phase: .changed))
        #expect(fixture.reveals == 0)
        fixture.global.emit(fixture.event(dy: 8, phase: .changed))
        #expect(fixture.reveals == 1)
    }

    @Test func pointerOutsideTheMenuBarOrWithoutAMenuBarProducesNothing() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let belowBar = CGPoint(x: 700, y: 500)
        fixture.swipe(.global, dy: 20, at: belowBar, startingAt: 0)
        fixture.swipe(.local, dy: -20, at: belowBar, startingAt: 1)
        #expect(fixture.frameQueries.last == belowBar)
        fixture.menuBar = nil
        fixture.swipe(.global, dy: 20, startingAt: 2)
        #expect(fixture.frameQueries.last == fixture.overBar)
        #expect(fixture.reveals == 0)
        #expect(fixture.hides == 0)
    }

    @Test func leavingTheMenuBarMidGestureCancelsTheRestOfIt() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.global.emit(fixture.event(phase: .began))
        fixture.global.emit(fixture.event(dy: 8, phase: .changed))
        fixture.global.emit(fixture.event(dy: 8, phase: .changed, at: CGPoint(x: 700, y: 500)))
        fixture.global.emit(fixture.event(dy: 50, phase: .changed))
        fixture.global.emit(fixture.event(phase: .ended))
        #expect(fixture.reveals == 0)
        fixture.swipe(.global, dy: 20, startingAt: 1)
        #expect(fixture.reveals == 1)
    }

    @Test func lineBasedWheelTicksAreScaledAndSegmentedWithoutPhases() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.tick(.global, lines: 1, at: 0)
        #expect(fixture.reveals == 0)
        fixture.tick(.global, lines: 1, at: 0.1)
        #expect(fixture.reveals == 1)
        fixture.tick(.global, lines: 1, at: 0.15)
        fixture.tick(.global, lines: 1, at: 0.2)
        #expect(fixture.reveals == 1)

        fixture.tick(.global, lines: -1, at: 1)
        #expect(fixture.hides == 0)
        fixture.tick(.global, lines: -1, at: 1.1)
        #expect(fixture.hides == 1)
        fixture.tick(.global, lines: -1, at: 2)
        fixture.tick(.global, lines: -1, at: 2.5)
        #expect(fixture.hides == 1)
    }

    @Test func momentumEventsAreIgnoredWithoutQueryingTheMenuBar() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.swipe(.global, dy: 5, startingAt: 0)
        let queries = fixture.frameQueries.count
        for (momentum, time) in [(NSEvent.Phase.began, 0.03), (.changed, 0.04), (.changed, 0.05), (.ended, 0.06)] {
            fixture.time = time
            fixture.global.emit(fixture.event(dy: 100, momentumPhase: momentum))
        }
        #expect(fixture.reveals == 0)
        #expect(fixture.hides == 0)
        #expect(fixture.frameQueries.count == queries)
    }

    @Test func cooldownUsesTheInjectedClock() {
        let fixture = ScrollFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.swipe(.global, dy: 20, startingAt: 0)
        #expect(fixture.reveals == 1)
        fixture.swipe(.global, dy: -20, startingAt: 0.1)
        #expect(fixture.hides == 0)
        // The reveal fired at 0.01, so a gesture ending at 0.40 is still inside the 400ms cooldown.
        fixture.swipe(.global, dy: -20, startingAt: 0.38)
        #expect(fixture.hides == 0)
        fixture.swipe(.global, dy: -20, startingAt: 0.41)
        #expect(fixture.hides == 1)
    }

    @Test func samplePhaseMappingPrefersMomentumAndTreatsMayBeginAsBegan() {
        typealias Map = (NSEvent.Phase, NSEvent.Phase, ScrollSample.Phase)
        let cases: [Map] = [
            ([], [], .none),
            (.began, [], .began),
            (.mayBegin, [], .began),
            (.changed, [], .changed),
            (.stationary, [], .changed),
            (.ended, [], .ended),
            (.cancelled, [], .cancelled),
            ([], .began, .momentum),
            ([], .changed, .momentum),
            ([], .ended, .momentum),
            (.changed, .began, .momentum)
        ]
        for (phase, momentum, expected) in cases {
            #expect(ScrollRevealMonitor.samplePhase(phase: phase, momentumPhase: momentum) == expected)
        }
    }

    @Test func teardownRemovesHandlersAndLateDeliveriesReachNothing() {
        let fixture = ScrollFixture()
        var monitor: ScrollRevealMonitor? = fixture.makeMonitor()
        weak let weakMonitor = monitor
        monitor?.setEnabled(true)
        let stale = fixture.global.handler
        monitor = nil
        #expect(weakMonitor == nil)
        #expect(fixture.global.removeCount == 1)
        #expect(fixture.local.removeCount == 1)
        #expect(!fixture.global.isInstalled)
        fixture.replay(fixture.gesture(dy: 20, startingAt: 1), into: stale)
        #expect(fixture.reveals == 0)
        #expect(fixture.frameQueries.isEmpty)
    }

    @Test func neverEnabledSourcesTolerateRemoveAndTeardown() {
        var source: NSEventScrollSource? = NSEventScrollSource(scope: .local)
        source?.remove()
        source?.remove()
        source = nil
        var monitor: ScrollRevealMonitor? = ScrollRevealMonitor(menuBarFrame: { _ in nil }, onReveal: {}, onHide: {})
        weak let weakMonitor = monitor
        monitor?.stop()
        monitor = nil
        #expect(weakMonitor == nil)
    }
}

@MainActor
private final class FakeScrollSource: ScrollEventSource {
    private(set) var installCount = 0
    private(set) var removeCount = 0
    private(set) var handler: (@MainActor (ScrollWheelEvent) -> Void)?

    var isInstalled: Bool { handler != nil }

    func install(handler: @escaping @MainActor (ScrollWheelEvent) -> Void) {
        installCount += 1
        self.handler = handler
    }

    func remove() {
        removeCount += 1
        handler = nil
    }

    func emit(_ event: ScrollWheelEvent) {
        handler?(event)
    }
}

@MainActor
private final class ScrollFixture {
    let overBar = CGPoint(x: 700, y: 970)
    var time: TimeInterval = 0
    var menuBar: CGRect? = CGRect(x: 0, y: 958, width: 1512, height: 24)
    var frameQueries: [CGPoint] = []
    var reveals = 0
    var hides = 0
    let global = FakeScrollSource()
    let local = FakeScrollSource()

    func makeMonitor() -> ScrollRevealMonitor {
        ScrollRevealMonitor(
            menuBarFrame: { point in
                self.frameQueries.append(point)
                return self.menuBar
            },
            onReveal: { self.reveals += 1 },
            onHide: { self.hides += 1 },
            now: { self.time },
            sources: [global, local]
        )
    }

    func source(_ source: ScrollRevealMonitorTests.Source) -> FakeScrollSource {
        source == .global ? global : local
    }

    func event(
        dx: CGFloat = 0, dy: CGFloat = 0, precise: Bool = true,
        phase: NSEvent.Phase = [], momentumPhase: NSEvent.Phase = [],
        inverted: Bool = true, at location: CGPoint? = nil
    ) -> ScrollWheelEvent {
        ScrollWheelEvent(
            scrollingDeltaX: dx, scrollingDeltaY: dy, hasPreciseScrollingDeltas: precise,
            phase: phase, momentumPhase: momentumPhase,
            isDirectionInvertedFromDevice: inverted, location: location ?? overBar
        )
    }

    /// A complete trackpad gesture whose single `changed` event carries the deltas.
    func gesture(
        dx: CGFloat = 0, dy: CGFloat = 0, at location: CGPoint? = nil, inverted: Bool = true,
        startingAt start: TimeInterval
    ) -> [(TimeInterval, ScrollWheelEvent)] {
        [
            (start, event(phase: .began, inverted: inverted, at: location)),
            (start + 0.01, event(dx: dx, dy: dy, phase: .changed, inverted: inverted, at: location)),
            (start + 0.02, event(phase: .ended, inverted: inverted, at: location))
        ]
    }

    func swipe(
        _ source: ScrollRevealMonitorTests.Source, dx: CGFloat = 0, dy: CGFloat = 0,
        at location: CGPoint? = nil, inverted: Bool = true, startingAt start: TimeInterval
    ) {
        let target = self.source(source)
        replay(gesture(dx: dx, dy: dy, at: location, inverted: inverted, startingAt: start), into: target.handler)
    }

    /// One notched mouse-wheel event: no phases, line-based deltas.
    func tick(_ source: ScrollRevealMonitorTests.Source, lines: CGFloat, at time: TimeInterval) {
        self.time = time
        self.source(source).emit(event(dy: lines, precise: false))
    }

    func replay(_ events: [(TimeInterval, ScrollWheelEvent)], into handler: (@MainActor (ScrollWheelEvent) -> Void)?) {
        for (time, event) in events {
            self.time = time
            handler?(event)
        }
    }
}
