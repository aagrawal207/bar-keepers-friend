import AppKit
import BarKeepersFriendCore
import CoreGraphics
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LiveLayoutMonitorTests {
    private let settle = LiveLayoutPolicy.Configuration.default.settleDelay
    private let sample = LiveLayoutMonitor.pointerSampleInterval

    /// Yields until the check task has completed; bounded by iterations, never by wall-clock waits.
    private func awaitCheck(_ monitor: LiveLayoutMonitor) async -> Bool {
        for _ in 0..<200 {
            if !monitor.isCheckInFlight { return true }
            await Task.yield()
        }
        return !monitor.isCheckInFlight
    }

    // MARK: - Arming

    @Test func sourcesArmOnlyWhileEnabledAndTogglingIsIdempotent() {
        let fixture = LiveLayoutFixture()
        let monitor = fixture.makeMonitor()
        #expect(!monitor.isEnabled)
        #expect(fixture.installed.isEmpty)

        monitor.setEnabled(true)
        monitor.setEnabled(true)
        #expect(monitor.isEnabled)
        #expect(fixture.installed == Set(LiveLayoutEventKind.allCases))
        #expect(fixture.sources.values.allSatisfy { $0.installs == 1 })
        // Enabling arms feeds only: no timer, sample, or check without an event.
        #expect(fixture.timers.isEmpty)
        #expect(fixture.previews == 0)
        #expect(!monitor.isCheckPending)
        #expect(!monitor.isSamplingPointer)

        monitor.setEnabled(false)
        monitor.setEnabled(false)
        monitor.stop()
        #expect(!monitor.isEnabled)
        #expect(fixture.installed.isEmpty)
        #expect(fixture.sources.values.allSatisfy { $0.removes == 1 })
        #expect(fixture.timers.isEmpty)
    }

    @Test func eventsWhileDisabledAreIgnored() {
        let fixture = LiveLayoutFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        monitor.setEnabled(false)
        for source in fixture.sources.values { source.fire() }
        #expect(fixture.timers.isEmpty)
        #expect(!monitor.isCheckPending)
        #expect(fixture.previews == 0)
    }

    @Test func deinitReleasesTheSources() {
        let fixture = LiveLayoutFixture()
        var monitor: LiveLayoutMonitor? = fixture.makeMonitor()
        monitor?.setEnabled(true)
        fixture.sources[.appLaunched]!.fire()
        #expect(fixture.pending.count == 2)
        monitor = nil
        #expect(fixture.installed.isEmpty)
        #expect(fixture.pending.isEmpty)
    }

    // MARK: - Scheduling and sampling

    @Test(arguments: LiveLayoutEventKind.allCases)
    func aLayoutEventSchedulesTheSettleTimerAndSamplesOnlyWhilePending(kind: LiveLayoutEventKind) async {
        let fixture = LiveLayoutFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let start = fixture.time

        fixture.sources[kind]!.fire()
        #expect(fixture.timers.map(\.interval) == [settle, sample])
        #expect(monitor.isCheckPending)
        #expect(monitor.isSamplingPointer)
        #expect(monitor.scheduledCheckAt == start + settle)

        // A still pointer keeps the chain alive without touching the check timer.
        fixture.time += sample
        fixture.fire(1)
        #expect(fixture.timers.map(\.interval) == [settle, sample, sample])
        #expect(fixture.cancelled.isEmpty)
        #expect(monitor.scheduledCheckAt == start + settle)

        fixture.time = start + settle
        fixture.fire(0)
        #expect(monitor.isCheckInFlight)
        #expect(!monitor.isCheckPending)
        // The burst is consumed, so sampling stops with it.
        #expect(!monitor.isSamplingPointer)
        #expect(fixture.cancelled == [2])
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
        #expect(fixture.reconciles == 0)
        #expect(fixture.pending.isEmpty)
        #expect(monitor.scheduledCheckAt == nil)
    }

    @Test func aMovingPointerDefersTheCheckUntilItIsIdle() async {
        let fixture = LiveLayoutFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let start = fixture.time
        fixture.sources[.appLaunched]!.fire()

        let moveTime = start + 1.0
        fixture.time = moveTime
        fixture.pointer.x += 40
        fixture.fire(1)
        // The idle wait (0.8s from the move) now ends after the settle delay, so the timer moves.
        #expect(monitor.scheduledCheckAt == moveTime + 0.8)
        #expect(fixture.cancelled == [0])
        #expect(fixture.timers.count == 4)
        #expect(abs(fixture.timers[2].interval - 0.8) < 1e-9)
        #expect(fixture.timers[3].interval == sample)
        #expect(monitor.isSamplingPointer)

        // A cancelled timer that fires anyway must not start the check early.
        fixture.time = start + settle
        fixture.fire(0)
        #expect(!monitor.isCheckInFlight)
        #expect(monitor.isCheckPending)

        fixture.time = moveTime + 0.8
        fixture.fire(2)
        #expect(monitor.isCheckInFlight)
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
    }

    @Test func aRestlessPointerStillGetsACheckAtTheDeadline() async {
        let fixture = LiveLayoutFixture()
        let monitor = fixture.makeMonitor(configuration: .init(settleDelay: 1, pointerIdle: 1, minInterval: 5, maxDeferral: 3))
        monitor.setEnabled(true)
        let start = fixture.time
        fixture.sources[.appLaunched]!.fire()
        var samples = 0
        while !monitor.isCheckInFlight, samples < 20 {
            samples += 1
            fixture.time = start + Double(samples) * sample
            fixture.pointer.y += 1
            fixture.fire(fixture.pending.first { fixture.timers[$0].interval == sample }!)
            if !monitor.isCheckInFlight {
                #expect(monitor.scheduledCheckAt == min(max(start + 1, fixture.time + 1), start + 3))
            }
        }
        // Twelve samples reach the 3s deadline; the check starts on that sample despite the motion.
        #expect(samples == 12)
        #expect(fixture.time == start + 3)
        #expect(monitor.isCheckInFlight)
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
    }

    @Test func aBurstOfEventsCoalescesIntoOneCheck() async {
        let fixture = LiveLayoutFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let start = fixture.time
        let burst: [LiveLayoutEventKind] = [.appLaunched, .appLaunched, .appTerminated, .appTerminated, .appLaunched]
        for (index, kind) in burst.enumerated() {
            fixture.time = start + Double(index) * 0.2
            fixture.sources[kind]!.fire()
        }
        // Each event replaces the settle timer; sampling was armed once by the first event.
        #expect(fixture.timers.filter { $0.interval == settle }.count == burst.count)
        #expect(fixture.timers.filter { $0.interval == sample }.count == 1)
        #expect(fixture.pending.count == 2)
        #expect(monitor.scheduledCheckAt == start + 0.8 + settle)

        fixture.time = start + 0.8 + settle
        fixture.fire(fixture.pending.first { fixture.timers[$0].interval == settle }!)
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
        #expect(fixture.reconciles == 0)
        #expect(!monitor.isCheckPending)
    }

    // MARK: - Check outcomes

    @Test(arguments: [Int?.none, 0, 1, 4])
    func onlyAPositivePreviewRequestsExactlyOneReconcile(planned: Int?) async {
        let fixture = LiveLayoutFixture()
        fixture.previewResult = planned
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.sources[.appTerminated]!.fire()
        fixture.time += settle
        fixture.fire(0)
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
        #expect(fixture.reconciles == ((planned ?? 0) > 0 ? 1 : 0))
        #expect(!monitor.isCheckPending)
        #expect(fixture.pending.isEmpty)
    }

    @Test func checksAreRateLimitedByTheMinimumInterval() async {
        let fixture = LiveLayoutFixture()
        fixture.previewResult = 2
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let start = fixture.time
        fixture.sources[.appLaunched]!.fire()
        fixture.time = start + settle
        fixture.fire(0)
        #expect(await awaitCheck(monitor))
        #expect(fixture.reconciles == 1)
        let finished = fixture.time

        fixture.time = finished + 1
        fixture.sources[.appLaunched]!.fire()
        #expect(monitor.scheduledCheckAt == finished + 10)
        let next = fixture.pending.first { fixture.timers[$0].interval == 9 }
        #expect(next != nil)
        fixture.time = finished + 10
        if let next { fixture.fire(next) }
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 2)
        #expect(fixture.reconciles == 2)
    }

    @Test func eventsDuringAnInFlightCheckWaitForItAndCoalesceIntoOneFollowUp() async {
        let fixture = LiveLayoutFixture()
        fixture.previewResult = 1
        let gate = AsyncGate()
        fixture.previewGate = gate
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let start = fixture.time
        fixture.sources[.appLaunched]!.fire()
        fixture.time = start + settle
        fixture.fire(0)
        #expect(monitor.isCheckInFlight)

        fixture.time += 0.5
        fixture.sources[.appLaunched]!.fire()
        fixture.sources[.appTerminated]!.fire()
        // Pending again, but no second check may start while one is running.
        #expect(monitor.isCheckPending)
        #expect(monitor.scheduledCheckAt == nil)
        #expect(monitor.isSamplingPointer)
        #expect(fixture.pending.allSatisfy { fixture.timers[$0].interval == sample })

        fixture.time += 1
        await gate.open()
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
        #expect(fixture.reconciles == 1)
        // The follow-up honors the interval from this completion.
        #expect(monitor.scheduledCheckAt == fixture.time + 10)
        #expect(fixture.pending.contains { fixture.timers[$0].interval == 10 })
    }

    // MARK: - Interaction

    @Test func userInteractionHoldsTheCheckAndItsEndRestartsTheSettleWait() async {
        let fixture = LiveLayoutFixture()
        fixture.interacting = true
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let start = fixture.time
        fixture.sources[.appLaunched]!.fire()
        // Interaction is polled before the event is handled: only the deadline is scheduled, and
        // sampling runs so the end of the interaction is noticed.
        #expect(monitor.isCheckPending)
        #expect(monitor.scheduledCheckAt == start + 30)
        #expect(fixture.timers.map(\.interval) == [30, sample])

        fixture.time = start + 2
        fixture.fire(1)
        #expect(!monitor.isCheckInFlight)
        #expect(monitor.scheduledCheckAt == start + 30)
        #expect(monitor.isSamplingPointer)

        fixture.interacting = false
        let ended = start + 3
        fixture.time = ended
        fixture.fire(fixture.pending.first { fixture.timers[$0].interval == sample }!)
        // Time spent in the menu does not count: the settle wait starts over from its end.
        #expect(!monitor.isCheckInFlight)
        #expect(monitor.scheduledCheckAt == ended + settle)
        #expect(fixture.cancelled == [0])
        #expect(monitor.isSamplingPointer)

        fixture.time = ended + settle
        fixture.fire(fixture.pending.first { fixture.timers[$0].interval == settle }!)
        #expect(monitor.isCheckInFlight)
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
        #expect(fixture.reconciles == 0)
        #expect(!monitor.isSamplingPointer)
    }

    @Test func interactionStartingAfterSchedulingWaitsForTheDeadlineThenAbandonsTheBurst() async {
        let fixture = LiveLayoutFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let start = fixture.time
        fixture.sources[.appLaunched]!.fire()
        #expect(monitor.scheduledCheckAt == start + settle)

        fixture.interacting = true
        fixture.time = start + sample
        fixture.fire(1)
        #expect(monitor.scheduledCheckAt == start + 30)
        #expect(fixture.cancelled == [0])
        #expect(monitor.isCheckPending)
        #expect(monitor.isSamplingPointer)

        // The cancelled settle timer is inert; samples keep the chain alive without checking.
        fixture.time = start + settle
        fixture.fire(0)
        #expect(!monitor.isCheckInFlight)
        var sampled = 0
        while let next = fixture.pending.first(where: { fixture.timers[$0].interval == sample }), sampled < 4 {
            sampled += 1
            fixture.time += sample
            fixture.fire(next)
        }
        #expect(sampled == 4)
        #expect(monitor.isSamplingPointer)
        #expect(fixture.previews == 0)

        // At the deadline the burst is abandoned so the 4Hz sampler stops.
        fixture.time = start + 30
        fixture.fire(fixture.pending.first { fixture.timers[$0].interval != sample }!)
        #expect(!monitor.isCheckPending)
        #expect(!monitor.isSamplingPointer)
        #expect(monitor.scheduledCheckAt == nil)
        #expect(fixture.pending.isEmpty)
        #expect(fixture.previews == 0)

        // A later event re-arms once the user is done.
        fixture.interacting = false
        fixture.time = start + 40
        fixture.sources[.appTerminated]!.fire()
        #expect(monitor.isCheckPending)
        #expect(monitor.isSamplingPointer)
        #expect(monitor.scheduledCheckAt == start + 40 + settle)
        fixture.time = start + 40 + settle
        fixture.fire(fixture.pending.first { fixture.timers[$0].interval == settle }!)
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
    }

    @Test func aCheckFinishingDuringInteractionDefersPlacementUntilItEnds() async {
        let fixture = LiveLayoutFixture()
        fixture.previewResult = 2
        let gate = AsyncGate()
        fixture.previewGate = gate
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        let start = fixture.time
        fixture.sources[.appLaunched]!.fire()
        fixture.time = start + settle
        fixture.fire(0)
        #expect(monitor.isCheckInFlight)

        // The bar opens while the sweep is running; its result must not move items now.
        fixture.interacting = true
        let completed = start + 2
        fixture.time = completed
        await gate.open()
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 1)
        #expect(fixture.reconciles == 0)
        #expect(monitor.isCheckPending)
        #expect(monitor.isSamplingPointer)
        #expect(monitor.scheduledCheckAt == completed + 30)

        // Interaction ends: the wait restarts, the interval from the deferred check still applies.
        fixture.interacting = false
        fixture.time = completed + 3
        fixture.fire(fixture.pending.first { fixture.timers[$0].interval == sample }!)
        #expect(!monitor.isCheckInFlight)
        #expect(monitor.scheduledCheckAt == completed + 10)

        fixture.previewGate = nil
        fixture.time = completed + 10
        fixture.fire(fixture.pending.first { fixture.timers[$0].interval == 7 }!)
        #expect(monitor.isCheckInFlight)
        #expect(await awaitCheck(monitor))
        #expect(fixture.previews == 2)
        #expect(fixture.reconciles == 1)
        #expect(!monitor.isCheckPending)
    }

    @Test func aCheckFinishingDuringInteractionWithNothingToMoveNeedsNoFollowUp() async {
        let fixture = LiveLayoutFixture()
        fixture.previewResult = 0
        let gate = AsyncGate()
        fixture.previewGate = gate
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.sources[.appLaunched]!.fire()
        fixture.time += settle
        fixture.fire(0)
        fixture.interacting = true
        fixture.time += 1
        await gate.open()
        #expect(await awaitCheck(monitor))
        #expect(fixture.reconciles == 0)
        #expect(!monitor.isCheckPending)
        #expect(!monitor.isSamplingPointer)
        #expect(fixture.pending.isEmpty)
    }

    // MARK: - Stopping

    @Test func stopCancelsTimersSamplingAndSourcesAndForgetsThePendingBurst() {
        let fixture = LiveLayoutFixture()
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.sources[.appLaunched]!.fire()
        #expect(fixture.pending.count == 2)

        monitor.stop()
        #expect(fixture.pending.isEmpty)
        #expect(fixture.installed.isEmpty)
        #expect(!monitor.isCheckPending)
        #expect(!monitor.isSamplingPointer)
        #expect(monitor.scheduledCheckAt == nil)
        // Re-enabling starts clean: the old burst is gone until a new event arrives.
        monitor.setEnabled(true)
        #expect(!monitor.isCheckPending)
        #expect(fixture.pending.isEmpty)
        // Cancelled timers that fire late are inert.
        fixture.fire(0)
        fixture.fire(1)
        #expect(!monitor.isCheckInFlight)
        #expect(fixture.previews == 0)
    }

    @Test func stopDuringACheckDropsItsResultWithoutReconciling() async {
        let fixture = LiveLayoutFixture()
        fixture.previewResult = 3
        let gate = AsyncGate()
        fixture.previewGate = gate
        let monitor = fixture.makeMonitor()
        monitor.setEnabled(true)
        fixture.sources[.appLaunched]!.fire()
        fixture.time += settle
        fixture.fire(0)
        #expect(monitor.isCheckInFlight)

        monitor.stop()
        #expect(!monitor.isCheckInFlight)
        await gate.open()
        for _ in 0..<50 { await Task.yield() }
        // The sweep observed its cancellation, and its late result moved nothing.
        #expect(fixture.cancelledChecks == 1)
        #expect(fixture.previews == 1)
        #expect(fixture.reconciles == 0)
        #expect(fixture.pending.isEmpty)
        #expect(!monitor.isCheckPending)
    }
}

// MARK: - Placement preview

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HiddenItemControllerPreviewTests {
    private let anchorWindowID: CGWindowID = 90
    private let dividerWindowID: CGWindowID = 91
    private let alwaysHiddenWindowID: CGWindowID = 92
    private let display: ClosedRange<CGFloat> = 0...1512

    private func item(
        _ id: CGWindowID, x: CGFloat, width: CGFloat = 22, owner: String? = nil, title: String? = nil
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id, ownerPID: 1, ownerBundleID: owner ?? "test.app.\(id)", title: title,
            frame: CGRect(x: x, y: 0, width: width, height: 22)
        )
    }
    private var controlItems: [MenuBarItemSnapshot] {
        [
            item(anchorWindowID, x: 1000, width: 24, title: "BKFAnchor"),
            item(dividerWindowID, x: 976, width: 8, title: "BKFHidden"),
        ]
    }
    /// Two items right of the anchor with Hidden intent, one satisfied Shown item.
    private var items: [MenuBarItemSnapshot] {
        [item(1, x: 1130), item(2, x: 1160), item(3, x: 1200)]
    }
    private var controls: ItemControlStore {
        ItemControlStore(hiddenInMenuBar: ["test.app.1", "test.app.2"], shownInMenuBar: ["test.app.3"])
    }

    private func preview(
        _ server: WindowServer, controls: ItemControlStore? = nil, controlItemWindowIDs: Set<CGWindowID> = [],
        alwaysHiddenDividerWindowID: CGWindowID? = nil, displayXRange: ClosedRange<CGFloat>? = nil,
        attribute: @escaping ([MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot] = { $0 }
    ) async -> Int? {
        let controller = HiddenItemController(windowServer: server, attribute: attribute)
        controller.controlItemWindowIDs = controlItemWindowIDs
        return await controller.previewMoves(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID,
            alwaysHiddenDividerWindowID: alwaysHiddenDividerWindowID, controls: controls ?? self.controls,
            displayXRange: displayXRange
        )
    }

    @Test func previewCountsThePlannedMovesWithoutMovingAnything() async {
        let server = FakeWindowServer(items: items + controlItems)
        let before = server.items
        var attributedBatches = 0
        let planned = await preview(server) { snapshots in
            attributedBatches += 1
            return snapshots
        }
        #expect(planned == 2)
        #expect(attributedBatches == 1)
        #expect(server.moveRequests.isEmpty)
        #expect(server.clickedWindowIDs.isEmpty)
        #expect(server.items == before)

        // The real reconcile plans exactly what the preview predicted.
        let controller = HiddenItemController(windowServer: server)
        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )
        #expect(result.planned == 2)
        #expect(result.allSucceeded)
        #expect(await preview(server) == 0)
    }

    @Test func satisfiedPlacementAndAbsentIntentPreviewAsZero() async {
        let server = FakeWindowServer(items: items + controlItems)
        #expect(await preview(server, controls: ItemControlStore()) == 0)
        #expect(await preview(server, controls: ItemControlStore(shownInMenuBar: ["test.app.1", "test.app.3"])) == 0)
        #expect(server.moveRequests.isEmpty)
    }

    @Test func excludedControlWindowIDsAreLeftOutLikeReconcile() async {
        let server = FakeWindowServer(items: items + controlItems)
        #expect(await preview(server, controlItemWindowIDs: [1]) == 1)
        #expect(await preview(server, controlItemWindowIDs: [1, 2]) == 0)
    }

    @Test func previewUsesTheAttributedOwnerForIntentLookup() async {
        let server = FakeWindowServer(items: items + controlItems)
        let controls = ItemControlStore(hiddenInMenuBar: ["real.owner"])
        let planned = await preview(server, controls: controls) { snapshots in
            snapshots.map { $0.windowID == 3 ? $0.attributed(bundleID: "real.owner", pid: 42) : $0 }
        }
        #expect(planned == 1)
    }

    @Test(arguments: [WindowServerError.invalidServerResponse("unavailable"), .missingPermission(.screenRecording)])
    func enumerationFailureReturnsNil(error: WindowServerError) async {
        let server = FakeWindowServer(items: items + controlItems)
        server.enumerationError = error
        #expect(await preview(server) == nil)
    }

    @Test func missingOrInvertedControlsReturnNil() async {
        let missingAnchor = FakeWindowServer(items: items + [controlItems[1]])
        #expect(await preview(missingAnchor) == nil)
        let inverted = FakeWindowServer(items: items + [
            item(anchorWindowID, x: 900, width: 24, title: "BKFAnchor"),
            item(dividerWindowID, x: 976, width: 8, title: "BKFHidden"),
        ])
        #expect(await preview(inverted) == nil)
    }

    @Test func geometryChangingDuringBothAttributionAttemptsReturnsNil() async {
        let server = ShiftingWindowServer(items: items + controlItems, shiftingWindowID: 3)
        #expect(await preview(server) == nil)
        // One initial read plus one re-read per attribution attempt; no third attempt is made.
        #expect(server.readCount == 3)
    }

    @Test func cancellationReturnsNilBeforeAttributing() async {
        let server = FakeWindowServer(items: items + controlItems)
        let attribution = AttributionRecorder()
        let controller = HiddenItemController(windowServer: server) { attribution.record($0) }
        let task = Task { @MainActor in
            await controller.previewMoves(
                anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
            )
        }
        task.cancel()
        #expect(await task.value == nil)
        #expect(attribution.batches == 0)
        #expect(server.moveRequests.isEmpty)
    }

    @Test(arguments: [false, true])
    func expandedDividersOnAWideVisibleSectionStillPreview(withTier: Bool) async {
        // A collapsed section keeps its dividers expanded to display width + 200, so their midpoints
        // sit far off-display when the visible section is wide; the preview never reveals first.
        let expandedWidth = display.upperBound - display.lowerBound + 200
        let anchor = item(anchorWindowID, x: 700, width: 24, title: "BKFAnchor")
        let divider = item(dividerWindowID, x: 700 - expandedWidth, width: expandedWidth, title: "BKFHidden")
        let tier = item(alwaysHiddenWindowID, x: divider.frame.minX - expandedWidth, width: expandedWidth, title: "BKFAlwaysHidden")
        #expect(!display.contains(divider.frame.midX))
        let server = FakeWindowServer(items: [
            item(1, x: 800), item(2, x: 830), item(3, x: 1200), anchor, divider,
        ] + (withTier ? [tier] : []))

        let planned = await preview(
            server, alwaysHiddenDividerWindowID: withTier ? alwaysHiddenWindowID : nil, displayXRange: display
        )
        #expect(planned == 2)
        #expect(server.moveRequests.isEmpty)
        // Moves run after a reveal, so the mover still treats an expanded divider as unreadable.
        let controller = HiddenItemController(windowServer: server)
        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID,
            alwaysHiddenDividerWindowID: withTier ? alwaysHiddenWindowID : nil, controls: controls, displayXRange: display
        )
        #expect(result.observationFailed)
        #expect(server.moveRequests.isEmpty)
    }

    @Test func alwaysHiddenIntentIsPreviewedAgainstItsDividerWhenPresent() async {
        let tier = item(alwaysHiddenWindowID, x: 600, width: 8, title: "BKFAlwaysHidden")
        let server = FakeWindowServer(items: [item(1, x: 1130), item(2, x: 300), item(3, x: 700)] + controlItems + [tier])
        let controls = ItemControlStore(hiddenInMenuBar: ["test.app.2", "test.app.3"], alwaysHiddenInMenuBar: ["test.app.1"])

        #expect(await preview(server, controls: controls, alwaysHiddenDividerWindowID: alwaysHiddenWindowID) == 2)
        // Without the tier's divider the intent degrades to Hidden and the tucked item already satisfies it.
        #expect(await preview(server, controls: controls) == 1)
        #expect(server.moveRequests.isEmpty)
    }

    @Test(arguments: ["missing", "rightOfHiddenDivider"])
    func aMissingOrMisplacedAlwaysHiddenDividerPreviewsAsNil(problem: String) async {
        let extras = problem == "missing" ? [] : [item(alwaysHiddenWindowID, x: 990, width: 8, title: "BKFAlwaysHidden")]
        let server = FakeWindowServer(items: items + controlItems + extras)
        #expect(await preview(server, alwaysHiddenDividerWindowID: alwaysHiddenWindowID) == nil)
        #expect(await preview(server) == 2)
    }
}

@MainActor
private final class AttributionRecorder {
    private(set) var batches = 0

    func record(_ snapshots: [MenuBarItemSnapshot]) -> [MenuBarItemSnapshot] {
        batches += 1
        return snapshots
    }
}

// MARK: - Fakes

@MainActor
private final class FakeLiveSource: TriggerEventSource {
    private(set) var installs = 0
    private(set) var removes = 0
    private var handler: (@MainActor @Sendable () -> Void)?

    var isInstalled: Bool { handler != nil }

    func install(handler: @escaping @MainActor @Sendable () -> Void) {
        installs += 1
        self.handler = handler
    }

    func remove() {
        removes += 1
        handler = nil
    }

    func fire() { handler?() }
}

@MainActor
private final class LiveLayoutFixture {
    var time: TimeInterval = 1_000
    var pointer = CGPoint(x: 400, y: 300)
    var interacting = false
    var previewResult: Int? = 0
    /// When set, each preview waits here so a test can observe an in-flight check.
    var previewGate: AsyncGate?
    private(set) var previews = 0
    private(set) var cancelledChecks = 0
    private(set) var reconciles = 0
    let sources: [LiveLayoutEventKind: FakeLiveSource] = Dictionary(
        uniqueKeysWithValues: LiveLayoutEventKind.allCases.map { ($0, FakeLiveSource()) }
    )
    private(set) var timers: [(interval: TimeInterval, tick: @MainActor @Sendable () -> Void)] = []
    private(set) var cancelled: [Int] = []
    private(set) var fired: [Int] = []

    var installed: Set<LiveLayoutEventKind> { Set(sources.filter { $0.value.isInstalled }.map(\.key)) }
    var pending: [Int] { timers.indices.filter { !cancelled.contains($0) && !fired.contains($0) } }

    func makeMonitor(configuration: LiveLayoutPolicy.Configuration = .default) -> LiveLayoutMonitor {
        LiveLayoutMonitor(
            configuration: configuration,
            sources: sources,
            pointerLocation: { self.pointer },
            isUserInteracting: { self.interacting },
            previewMoves: {
                self.previews += 1
                if let gate = self.previewGate { await gate.wait() }
                if Task.isCancelled { self.cancelledChecks += 1 }
                return self.previewResult
            },
            requestReconcile: { self.reconciles += 1 },
            now: { self.time },
            scheduleTimer: { interval, tick in
                let index = self.timers.count
                self.timers.append((interval, tick))
                return { self.cancelled.append(index) }
            }
        )
    }

    func fire(_ index: Int) {
        fired.append(index)
        timers[index].tick()
    }
}

/// Returns a different frame for one window on every read after the first, so attribution never
/// matches the geometry it was computed against.
private final class ShiftingWindowServer: WindowServer, @unchecked Sendable {
    private let base: [MenuBarItemSnapshot]
    private let shiftingWindowID: CGWindowID
    private(set) var readCount = 0

    init(items: [MenuBarItemSnapshot], shiftingWindowID: CGWindowID) {
        base = items
        self.shiftingWindowID = shiftingWindowID
    }

    var canSynthesizeClicks: Bool { true }

    func menuBarItems() throws -> [MenuBarItemSnapshot] {
        readCount += 1
        let shift = CGFloat(readCount) * 30
        return base.map { item in
            guard item.windowID == shiftingWindowID else { return item }
            return MenuBarItemSnapshot(
                windowID: item.windowID, ownerPID: item.ownerPID, ownerBundleID: item.ownerBundleID, title: item.title,
                frame: item.frame.offsetBy(dx: shift, dy: 0)
            )
        }
    }

    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        CGRect(x: 0, y: 0, width: 1440, height: 24)
    }

    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        Issue.record("A preview must never move an item.")
    }

    func click(item: MenuBarItemSnapshot) throws {
        Issue.record("A preview must never click an item.")
    }
}
