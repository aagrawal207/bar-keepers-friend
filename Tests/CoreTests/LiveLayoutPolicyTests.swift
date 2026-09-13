import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct LiveLayoutPolicyTests {
    typealias Policy = LiveLayoutPolicy

    /// Runs one burst to completion so later tests can focus on what follows a check.
    private func runFirstCheck(_ policy: inout Policy, at start: TimeInterval, finishedAt: TimeInterval) {
        #expect(policy.handle(.appLaunched, now: start) == .scheduleCheck(at: start + 1.5))
        #expect(policy.handle(.tick, now: start + 1.5) == .runCheck)
        #expect(policy.isCheckInFlight)
        #expect(policy.handle(.checkFinished, now: finishedAt) == nil)
        #expect(!policy.isCheckInFlight)
        #expect(!policy.isPending)
    }

    @Test func nothingHappensWithoutAnAppEvent() {
        var policy = Policy()
        #expect(policy.handle(.tick, now: 0) == nil)
        #expect(policy.handle(.pointerMoved, now: 1) == nil)
        #expect(policy.handle(.userInteracting(true), now: 2) == nil)
        #expect(policy.handle(.userInteracting(false), now: 3) == nil)
        #expect(policy.handle(.checkFinished, now: 4) == nil)
        #expect(policy.handle(.checkDeferred, now: 4.5) == nil)
        #expect(!policy.isPending)
        #expect(!policy.isCheckInFlight)
        // A stray completion must not count as a real check and rate-limit the first burst.
        #expect(policy.handle(.appLaunched, now: 5) == .scheduleCheck(at: 6.5))
    }

    @Test(arguments: [Policy.Event.appLaunched, .appTerminated])
    func eachAppEventSchedulesACheckAfterTheSettleDelay(event: Policy.Event) {
        var policy = Policy()
        #expect(policy.handle(event, now: 10) == .scheduleCheck(at: 11.5))
        #expect(policy.isPending)
        #expect(policy.handle(.tick, now: 11.49) == .scheduleCheck(at: 11.5))
        #expect(policy.handle(.tick, now: 11.5) == .runCheck)
        #expect(!policy.isPending)
        #expect(policy.isCheckInFlight)
    }

    @Test func aLaunchBurstCoalescesIntoOneCheckAfterTheLastEventSettles() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.appLaunched, now: 0.3) == .scheduleCheck(at: 1.8))
        #expect(policy.handle(.appTerminated, now: 0.9) == .scheduleCheck(at: 2.4))
        #expect(policy.handle(.tick, now: 1.5) == .scheduleCheck(at: 2.4))
        #expect(policy.handle(.tick, now: 1.8) == .scheduleCheck(at: 2.4))
        #expect(policy.handle(.tick, now: 2.4) == .runCheck)
        // The burst was consumed: a tick after the run schedules nothing new.
        #expect(policy.handle(.tick, now: 2.5) == nil)
    }

    @Test func aRecentPointerMoveDefersTheCheckUntilThePointerIsIdle() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.pointerMoved, now: 1.0) == .scheduleCheck(at: 1.8))
        #expect(policy.handle(.pointerMoved, now: 1.7) == .scheduleCheck(at: 2.5))
        #expect(policy.handle(.tick, now: 1.8) == .scheduleCheck(at: 2.5))
        #expect(policy.handle(.tick, now: 2.5) == .runCheck)
    }

    @Test func anOldPointerMoveDoesNotDelayALaterBurst() {
        var policy = Policy()
        #expect(policy.handle(.pointerMoved, now: 0) == nil)
        #expect(policy.handle(.appLaunched, now: 5) == .scheduleCheck(at: 6.5))
        #expect(policy.handle(.tick, now: 6.5) == .runCheck)
    }

    @Test func aRestlessPointerRunsTheCheckAtTheDeferralDeadline() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        var now: TimeInterval = 0.5
        while now < 29.9 {
            // The pointer gate waits 0.8s after each move but never past the 30s deadline.
            let expected = min(max(1.5, now + 0.8), 30)
            #expect(policy.handle(.pointerMoved, now: now) == .scheduleCheck(at: expected))
            now += 0.5
        }
        #expect(policy.handle(.pointerMoved, now: 29.9) == .scheduleCheck(at: 30))
        #expect(policy.handle(.tick, now: 29.99) == .scheduleCheck(at: 30))
        #expect(policy.handle(.tick, now: 30) == .runCheck)
    }

    @Test func aBurstThatNeverSettlesRunsTheCheckAtTheDeferralDeadline() {
        var policy = Policy()
        var now: TimeInterval = 0
        while now <= 29 {
            #expect(policy.handle(.appLaunched, now: now) == .scheduleCheck(at: min(now + 1.5, 30)))
            now += 1
        }
        #expect(policy.handle(.appLaunched, now: 30) == .runCheck)
    }

    // MARK: - Interaction

    @Test func interactionBlocksTheCheckAndSchedulesOnlyTheDeadline() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.userInteracting(true), now: 0.5) == .scheduleCheck(at: 30))
        #expect(policy.isUserInteracting)
        #expect(policy.isPending)
        // Nothing but the deadline is scheduled while a bar or menu is open.
        #expect(policy.handle(.tick, now: 1.5) == .scheduleCheck(at: 30))
        #expect(policy.handle(.appLaunched, now: 2) == .scheduleCheck(at: 30))
        #expect(policy.handle(.pointerMoved, now: 3) == .scheduleCheck(at: 30))
        #expect(policy.handle(.tick, now: 29.9) == .scheduleCheck(at: 30))
        #expect(policy.isPending)
        #expect(!policy.isCheckInFlight)
    }

    @Test func endingInteractionRestartsEveryGateInsteadOfRunningAtOnce() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.userInteracting(true), now: 0.5) == .scheduleCheck(at: 30))
        // Twenty seconds in a menu spent neither the settle delay, the idle wait, nor the deadline.
        #expect(policy.handle(.userInteracting(false), now: 20) == .scheduleCheck(at: 21.5))
        #expect(!policy.isUserInteracting)
        #expect(policy.handle(.tick, now: 20.5) == .scheduleCheck(at: 21.5))
        let lastMove: TimeInterval = 21.25
        #expect(policy.handle(.pointerMoved, now: lastMove) == .scheduleCheck(at: lastMove + 0.8))
        #expect(policy.handle(.tick, now: lastMove + 0.8) == .runCheck)
    }

    @Test func theDeadlineAfterInteractionIsMeasuredFromItsEnd() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.userInteracting(true), now: 1) == .scheduleCheck(at: 30))
        #expect(policy.handle(.userInteracting(false), now: 25) == .scheduleCheck(at: 26.5))
        var now: TimeInterval = 25.5
        while now < 55 {
            #expect(policy.handle(.pointerMoved, now: now) == .scheduleCheck(at: min(max(26.5, now + 0.8), 55)))
            now += 0.5
        }
        #expect(policy.handle(.tick, now: 55) == .runCheck)
    }

    @Test func aLongInteractionAbandonsTheBurstUntilTheNextAppEvent() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.userInteracting(true), now: 1) == .scheduleCheck(at: 30))
        #expect(policy.handle(.tick, now: 29.9) == .scheduleCheck(at: 30))
        // At the deadline the burst is dropped so the caller can stop sampling the pointer.
        #expect(policy.handle(.tick, now: 30) == nil)
        #expect(!policy.isPending)
        #expect(policy.isUserInteracting)
        #expect(policy.handle(.pointerMoved, now: 31) == nil)
        #expect(policy.handle(.userInteracting(false), now: 40) == nil)
        #expect(!policy.isPending)
        #expect(policy.handle(.tick, now: 41) == nil)
        // No check ever ran, so a new burst is not rate limited.
        #expect(policy.handle(.appTerminated, now: 42) == .scheduleCheck(at: 43.5))
        #expect(policy.handle(.tick, now: 43.5) == .runCheck)
    }

    @Test func anEventArrivingLateInAnInteractionIsAbandonedAtTheSameDeadline() {
        var policy = Policy()
        #expect(policy.handle(.userInteracting(true), now: 0) == nil)
        #expect(policy.handle(.appLaunched, now: 5) == .scheduleCheck(at: 35))
        #expect(policy.handle(.appLaunched, now: 34) == .scheduleCheck(at: 35))
        #expect(policy.handle(.tick, now: 35) == nil)
        #expect(!policy.isPending)
    }

    @Test func endingInteractionBeforeTheSettleDelayReschedulesInsteadOfRunning() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.userInteracting(true), now: 0.25) == .scheduleCheck(at: 30))
        #expect(policy.handle(.userInteracting(false), now: 0.5) == .scheduleCheck(at: 2))
        // A repeated "not interacting" report is not a new interaction end and restarts nothing.
        #expect(policy.handle(.userInteracting(false), now: 0.75) == .scheduleCheck(at: 2))
        #expect(policy.handle(.tick, now: 2) == .runCheck)
    }

    @Test func interactionReportsWithoutAPendingBurstChangeNothing() {
        var policy = Policy()
        #expect(policy.handle(.userInteracting(true), now: 0) == nil)
        #expect(policy.handle(.userInteracting(false), now: 100) == nil)
        #expect(!policy.isPending)
        #expect(policy.handle(.appLaunched, now: 101) == .scheduleCheck(at: 102.5))
    }

    // MARK: - Rate limiting and checks

    @Test func checksAreSpacedByTheMinimumIntervalFromTheLastCompletion() {
        var policy = Policy()
        runFirstCheck(&policy, at: 0, finishedAt: 2)
        #expect(policy.handle(.appLaunched, now: 3) == .scheduleCheck(at: 12))
        #expect(policy.handle(.tick, now: 4.5) == .scheduleCheck(at: 12))
        #expect(policy.handle(.appLaunched, now: 11) == .scheduleCheck(at: 12.5))
        #expect(policy.handle(.tick, now: 12.5) == .runCheck)
    }

    @Test func theMinimumIntervalIsNotShortenedByTheDeferralDeadline() {
        var policy = Policy(configuration: .init(settleDelay: 1, pointerIdle: 1, minInterval: 60, maxDeferral: 5))
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1))
        #expect(policy.handle(.tick, now: 1) == .runCheck)
        #expect(policy.handle(.checkFinished, now: 1) == nil)
        #expect(policy.handle(.appLaunched, now: 2) == .scheduleCheck(at: 61))
        #expect(policy.handle(.tick, now: 7) == .scheduleCheck(at: 61))
        #expect(policy.handle(.tick, now: 61) == .runCheck)
    }

    @Test func eventsDuringACheckWaitForItToFinishAndThenCoalesce() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.tick, now: 1.5) == .runCheck)
        #expect(policy.handle(.appLaunched, now: 2) == nil)
        #expect(policy.handle(.appTerminated, now: 2.5) == nil)
        #expect(policy.handle(.tick, now: 4) == nil)
        #expect(policy.handle(.pointerMoved, now: 4.5) == nil)
        #expect(policy.isPending)
        #expect(policy.isCheckInFlight)
        // Only one check runs at a time; the follow-up honors the interval from this completion.
        #expect(policy.handle(.checkFinished, now: 5) == .scheduleCheck(at: 15))
        #expect(!policy.isCheckInFlight)
        #expect(policy.handle(.tick, now: 15) == .runCheck)
        #expect(!policy.isPending)
    }

    @Test func aFinishedCheckWithNothingPendingSchedulesNothing() {
        var policy = Policy()
        runFirstCheck(&policy, at: 0, finishedAt: 3)
        #expect(policy.handle(.tick, now: 20) == nil)
        #expect(policy.handle(.pointerMoved, now: 21) == nil)
    }

    @Test func aDeferredCheckKeepsABurstAndRerunsAfterInteractionEndsAndTheInterval() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.tick, now: 1.5) == .runCheck)
        #expect(policy.handle(.userInteracting(true), now: 2) == nil)
        // The sweep found work but could not apply it; the burst restarts at completion.
        #expect(policy.handle(.checkDeferred, now: 3) == .scheduleCheck(at: 33))
        #expect(!policy.isCheckInFlight)
        #expect(policy.isPending)
        #expect(policy.handle(.userInteracting(false), now: 5) == .scheduleCheck(at: 13))
        #expect(policy.handle(.tick, now: 13) == .runCheck)
        #expect(policy.handle(.checkFinished, now: 14) == nil)
        #expect(!policy.isPending)
    }

    @Test func aDeferredCheckWithoutInteractionWaitsForTheInterval() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.tick, now: 1.5) == .runCheck)
        #expect(policy.handle(.checkDeferred, now: 2) == .scheduleCheck(at: 12))
        #expect(policy.handle(.tick, now: 12) == .runCheck)
    }

    @Test func aDeferredCheckKeepsAnEarlierBurstThatArrivedDuringTheSweep() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.tick, now: 1.5) == .runCheck)
        #expect(policy.handle(.appLaunched, now: 2) == nil)
        #expect(policy.handle(.checkDeferred, now: 3) == .scheduleCheck(at: 13))
        #expect(policy.handle(.tick, now: 13) == .runCheck)
    }

    @Test func aDeferredCheckIsAbandonedLikeAnyBurstWhenInteractionOutlastsTheDeadline() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.tick, now: 1.5) == .runCheck)
        #expect(policy.handle(.userInteracting(true), now: 2) == nil)
        #expect(policy.handle(.checkDeferred, now: 3) == .scheduleCheck(at: 33))
        #expect(policy.handle(.tick, now: 33) == nil)
        #expect(!policy.isPending)
        #expect(policy.handle(.userInteracting(false), now: 40) == nil)
    }

    // MARK: - Reset and equality

    @Test func resetForgetsBurstsInteractionAndRateLimiting() {
        var policy = Policy()
        runFirstCheck(&policy, at: 0, finishedAt: 2)
        #expect(policy.handle(.appLaunched, now: 3) == .scheduleCheck(at: 12))
        #expect(policy.handle(.userInteracting(true), now: 3.5) == .scheduleCheck(at: 33))
        policy.reset()
        #expect(policy == Policy())
        #expect(!policy.isPending)
        #expect(!policy.isCheckInFlight)
        #expect(!policy.isUserInteracting)
        #expect(policy.handle(.tick, now: 4) == nil)
        #expect(policy.handle(.appLaunched, now: 5) == .scheduleCheck(at: 6.5))
    }

    @Test func resetDuringACheckClearsTheInFlightGuard() {
        var policy = Policy()
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 1.5))
        #expect(policy.handle(.tick, now: 1.5) == .runCheck)
        policy.reset()
        #expect(!policy.isCheckInFlight)
        #expect(policy.handle(.appLaunched, now: 2) == .scheduleCheck(at: 3.5))
        #expect(policy.handle(.tick, now: 3.5) == .runCheck)
    }

    @Test func resetKeepsTheConfiguration() {
        let configuration = Policy.Configuration(settleDelay: 2, pointerIdle: 1, minInterval: 20, maxDeferral: 40)
        var policy = Policy(configuration: configuration)
        _ = policy.handle(.appLaunched, now: 0)
        policy.reset()
        #expect(policy.configuration == configuration)
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 2))
    }

    @Test func policiesFedTheSameEventsAreEqualAndDivergeOnState() {
        var first = Policy()
        var second = Policy()
        #expect(first == second)
        _ = first.handle(.appLaunched, now: 1)
        #expect(first != second)
        _ = second.handle(.appTerminated, now: 1)
        #expect(first == second)
        _ = first.handle(.pointerMoved, now: 1.2)
        #expect(first != second)
        _ = second.handle(.pointerMoved, now: 1.2)
        #expect(first == second)
        #expect(Policy(configuration: .init(settleDelay: 3)) != Policy())
    }

    // MARK: - Configuration

    @Test func configurationDefaultsMatchTheDocumentedValues() {
        let configuration = Policy.Configuration.default
        #expect(configuration.settleDelay == 1.5)
        #expect(configuration.pointerIdle == 0.8)
        #expect(configuration.minInterval == 10)
        #expect(configuration.maxDeferral == 30)
        #expect(Policy().configuration == configuration)
    }

    @Test func configurationRejectsNegativeAndNonFiniteDelays() {
        let configuration = Policy.Configuration(
            settleDelay: -1, pointerIdle: .nan, minInterval: -.infinity, maxDeferral: .infinity
        )
        #expect(configuration == .init(settleDelay: 0, pointerIdle: 0, minInterval: 0, maxDeferral: 0))
        var policy = Policy(configuration: configuration)
        #expect(policy.handle(.appLaunched, now: 7) == .runCheck)
    }

    @Test func customDelaysDriveEveryGate() {
        var policy = Policy(configuration: .init(settleDelay: 0.5, pointerIdle: 2, minInterval: 3, maxDeferral: 4))
        #expect(policy.handle(.appLaunched, now: 0) == .scheduleCheck(at: 0.5))
        #expect(policy.handle(.pointerMoved, now: 0.2) == .scheduleCheck(at: 2.2))
        #expect(policy.handle(.pointerMoved, now: 2.1) == .scheduleCheck(at: 4))
        #expect(policy.handle(.tick, now: 4) == .runCheck)
        #expect(policy.handle(.checkFinished, now: 4.2) == nil)
        #expect(policy.handle(.appTerminated, now: 4.3) == .scheduleCheck(at: 7.2))
        #expect(policy.handle(.tick, now: 7.2) == .runCheck)
    }
}
