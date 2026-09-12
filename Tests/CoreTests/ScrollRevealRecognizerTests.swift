import CoreGraphics
import Foundation
import Testing
import BarKeepersFriendCore

@Suite struct ScrollRevealRecognizerTests {
    typealias Recognizer = ScrollRevealRecognizer
    typealias Phase = ScrollSample.Phase

    @Test func defaultsMatchTheDocumentedContract() {
        let recognizer = Recognizer()
        #expect(recognizer.threshold == 12)
        #expect(recognizer.cooldown == 0.4)
        #expect(recognizer.wheelGap == 0.3)
        #expect(recognizer.naturalScrolling)
        #expect(!recognizer.isTrackingGesture)
        #expect(Recognizer.defaultThreshold == 12)
        #expect(Recognizer.defaultCooldown == 0.4)
        #expect(Recognizer.defaultWheelGap == 0.3)
    }

    @Test func thresholdMustBeExceededAndFiresExactlyOncePerGesture() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.isTrackingGesture)
        #expect(recognizer.consume(sample(dy: 6, at: 0.01)) == nil)
        #expect(recognizer.consume(sample(dy: 6, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(dy: 0.5, at: 0.03)) == .reveal)
        #expect(recognizer.consume(sample(dy: 50, at: 0.04)) == nil)
        #expect(recognizer.consume(sample(dy: -80, at: 0.05)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 0.06)) == nil)
        #expect(!recognizer.isTrackingGesture)
    }

    @Test func accumulationRestartsWithEachGesture() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 8, at: 0.01)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(.began, at: 1)) == nil)
        #expect(recognizer.consume(sample(dy: 8, at: 1.01)) == nil)
        #expect(recognizer.consume(sample(dy: 8, at: 1.02)) == .reveal)
    }

    @Test(arguments: [true, false])
    func directionMappingFollowsTheDeltaConvention(natural: Bool) {
        // The physical pull-down or swipe-left reveals in both conventions; the flag only
        // states which sign NSEvent used for it.
        let pullDown: Double = natural ? 20 : -20
        let swipeLeft: Double = natural ? -20 : 20
        #expect(gesture(dy: pullDown, natural: natural) == .reveal)
        #expect(gesture(dy: -pullDown, natural: natural) == .hide)
        #expect(gesture(dx: swipeLeft, natural: natural) == .reveal)
        #expect(gesture(dx: -swipeLeft, natural: natural) == .hide)
    }

    @Test func dominantAxisDecidesAndTiesFavorVertical() {
        #expect(gesture(dx: 20, dy: 13) == .hide)
        #expect(gesture(dx: -20, dy: 13) == .reveal)
        #expect(gesture(dx: 13, dy: 20) == .reveal)
        #expect(gesture(dx: 13, dy: -20) == .hide)
        #expect(gesture(dx: -15, dy: -15) == .hide)
        #expect(gesture(dx: 15, dy: 15) == .reveal)
    }

    @Test func naturalScrollingCanChangeBetweenGestures() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 20, at: 0.01)) == .reveal)
        #expect(recognizer.consume(sample(.ended, at: 0.02)) == nil)
        recognizer.naturalScrolling = false
        #expect(recognizer.consume(sample(.began, at: 1)) == nil)
        #expect(recognizer.consume(sample(dy: 20, at: 1.01)) == .hide)
        #expect(recognizer.consume(sample(.ended, at: 1.02)) == nil)
    }

    @Test func momentumSamplesNeverCountOrDisturbTiming() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 5, at: 0.01)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(.momentum, dy: 100, at: 0.03)) == nil)
        #expect(recognizer.consume(sample(.momentum, dy: 100, at: 0.5)) == nil)
        #expect(!recognizer.isTrackingGesture)

        #expect(recognizer.consume(sample(.none, dy: 10, at: 2)) == nil)
        #expect(recognizer.consume(sample(.momentum, dy: 100, at: 2.2)) == nil)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 2.25)) == .reveal)
    }

    @Test func leavingTheMenuBarCancelsTheRestOfTheGesture() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 8, at: 0.01)) == nil)
        #expect(recognizer.consume(sample(dy: 8, inBar: false, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(dy: 50, at: 0.03)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 0.04)) == nil)
        #expect(!recognizer.isTrackingGesture)
        #expect(recognizer.consume(sample(.began, at: 1)) == nil)
        #expect(recognizer.consume(sample(dy: 20, at: 1.01)) == .reveal)
    }

    @Test func gestureStartedOutsideTheMenuBarNeverFires() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, inBar: false, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 50, at: 0.01)) == nil)
        #expect(recognizer.consume(sample(dy: 50, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 0.03)) == nil)
        #expect(!recognizer.isTrackingGesture)
    }

    @Test func wheelTicksOutsideTheMenuBarProduceNothing() {
        var recognizer = Recognizer()
        for time in [0, 0.05, 0.1, 0.15] {
            #expect(recognizer.consume(sample(.none, dy: 10, inBar: false, at: time)) == nil)
        }
        #expect(recognizer.consume(sample(.none, dy: -10, inBar: false, at: 0.2)) == nil)
    }

    @Test func cooldownSuppressesEffectsUntilItsEndInclusive() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 20, at: 0.1)) == .reveal)
        #expect(recognizer.consume(sample(.ended, at: 0.11)) == nil)

        #expect(recognizer.consume(sample(.began, at: 0.2)) == nil)
        #expect(recognizer.consume(sample(dy: -20, at: 0.25)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 0.3)) == nil)

        #expect(recognizer.consume(sample(.began, at: 0.4)) == nil)
        #expect(recognizer.consume(sample(dy: -20, at: 0.499)) == nil)
        #expect(recognizer.consume(sample(dy: 0, at: 0.5)) == .hide)
        #expect(recognizer.consume(sample(.ended, at: 0.51)) == nil)
    }

    @Test func shortGestureInsideTheCooldownIsDroppedNotDeferred() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 20, at: 0.01)) == .reveal)
        #expect(recognizer.consume(sample(.ended, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(.began, at: 0.1)) == nil)
        #expect(recognizer.consume(sample(dy: -20, at: 0.15)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 0.2)) == nil)
        #expect(recognizer.consume(sample(.began, at: 1)) == nil)
        #expect(recognizer.consume(sample(dy: -20, at: 1.01)) == .hide)
    }

    @Test func deliberateGestureOutlastingTheCooldownFiresOnce() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 20, at: 0.01)) == .reveal)
        #expect(recognizer.consume(sample(.ended, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(.began, at: 0.1)) == nil)
        #expect(recognizer.consume(sample(dy: -20, at: 0.2)) == nil)
        #expect(recognizer.consume(sample(dy: -1, at: 0.45)) == .hide)
        #expect(recognizer.consume(sample(dy: -20, at: 0.5)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 0.6)) == nil)
    }

    @Test func wheelRunsAreSegmentedByAGapLongerThanTheWheelGap() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.none, dy: 10, at: 0)) == nil)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 0.3)) == .reveal)
        #expect(recognizer.isTrackingGesture)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 0.35)) == nil)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 0.6)) == nil)

        #expect(recognizer.consume(sample(.none, dy: 10, at: 1)) == nil)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 1.301)) == nil)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 1.4)) == .reveal)
    }

    @Test func wheelTicksAccumulateOnlyWithinTheGap() {
        var recognizer = Recognizer()
        for time in [0, 0.31, 0.62, 0.93] {
            #expect(recognizer.consume(sample(.none, dy: 10, at: time)) == nil)
        }
    }

    @Test func phasedInputEndsAWheelRunAndAMissedBeganStillCounts() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.none, dy: 10, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 10, at: 0.05)) == nil)
        #expect(recognizer.consume(sample(dy: 5, at: 0.1)) == .reveal)
        #expect(recognizer.consume(sample(.ended, at: 0.15)) == nil)
        #expect(!recognizer.isTrackingGesture)
    }

    @Test func staleUnendedPhasedGestureDoesNotSwallowLaterWheelTicks() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 20, at: 0.01)) == .reveal)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 5)) == nil)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 5.05)) == .reveal)
        #expect(recognizer.consume(sample(.none, dy: 10, at: 5.1)) == nil)
    }

    @Test(arguments: [Phase.ended, .cancelled])
    func endedAndCancelledCloseTheGestureAndFinalDeltasCount(closing: Phase) {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(closing, dy: 50, at: 0)) == nil)
        #expect(!recognizer.isTrackingGesture)
        #expect(recognizer.consume(sample(.began, at: 1)) == nil)
        #expect(recognizer.consume(sample(dy: 8, at: 1.01)) == nil)
        #expect(recognizer.consume(sample(closing, dy: 8, at: 1.02)) == .reveal)
        #expect(!recognizer.isTrackingGesture)
        #expect(recognizer.consume(sample(dy: 50, at: 1.03)) == nil)
        #expect(recognizer.consume(sample(.ended, at: 1.04)) == nil)
    }

    @Test func resetClearsGestureAndCooldown() {
        var recognizer = Recognizer()
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dy: 8, at: 0.01)) == nil)
        recognizer.reset()
        #expect(!recognizer.isTrackingGesture)
        #expect(recognizer == Recognizer())
        #expect(recognizer.consume(sample(dy: 8, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(dy: 8, at: 0.03)) == .reveal)
        recognizer.reset()
        #expect(recognizer.consume(sample(.began, at: 0.04)) == nil)
        #expect(recognizer.consume(sample(dy: -20, at: 0.05)) == .hide)
    }

    @Test func equatableStateReflectsInputHistoryAndConfiguration() {
        var first = Recognizer()
        var second = Recognizer()
        #expect(first == second)
        let shared = [sample(.began, at: 0), sample(dy: 20, at: 0.01)]
        for input in shared {
            #expect(first.consume(input) == second.consume(input))
        }
        #expect(first == second)
        #expect(second.consume(sample(.ended, at: 0.02)) == nil)
        #expect(first != second)
        #expect(first.consume(sample(.ended, at: 0.02)) == nil)
        #expect(first == second)
        #expect(Recognizer(threshold: 20) != Recognizer())
        #expect(Recognizer(naturalScrolling: false) != Recognizer())
    }

    @Test func nonFiniteConfigurationAndDeltasAreSanitized() {
        var recognizer = Recognizer(threshold: .nan, cooldown: .infinity, wheelGap: -1)
        #expect(recognizer.threshold == 12)
        #expect(recognizer.cooldown == 0.4)
        #expect(recognizer.wheelGap == 0)
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        #expect(recognizer.consume(sample(dx: .infinity, dy: .nan, at: 0.01)) == nil)
        #expect(recognizer.consume(sample(dy: -.infinity, at: 0.02)) == nil)
        #expect(recognizer.consume(sample(dy: 13, at: 0.03)) == .reveal)
    }

    @Test(arguments: [CGPoint.zero, CGPoint(x: -1920, y: 0), CGPoint(x: 0, y: -1080), CGPoint(x: 0, y: 982)])
    func pointerIsInMenuBarUsesInclusiveEdgesInGlobalCoordinates(offset: CGPoint) {
        let frame = CGRect(x: 0, y: 958, width: 1512, height: 24).offsetBy(dx: offset.x, dy: offset.y)
        for (point, expected) in [
            (CGPoint(x: 100, y: 970), true),
            (CGPoint(x: 100, y: 982), true),
            (CGPoint(x: 0, y: 958), true),
            (CGPoint(x: 1512, y: 982), true),
            (CGPoint(x: 100, y: 957.9), false),
            (CGPoint(x: 100, y: 982.1), false),
            (CGPoint(x: -0.1, y: 970), false),
            (CGPoint(x: 1512.1, y: 970), false),
            (CGPoint(x: 100, y: 500), false)
        ] {
            let shifted = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
            #expect(Recognizer.pointerIsInMenuBar(shifted, menuBarFrame: frame) == expected, "\(point)")
        }
    }

    @Test func pointerIsInMenuBarRejectsAbsentOrInvalidGeometry() {
        let point = CGPoint(x: 100, y: 970)
        #expect(!Recognizer.pointerIsInMenuBar(point, menuBarFrame: nil))
        for frame in [
            CGRect.zero, .null, .infinite,
            CGRect(x: 0, y: 958, width: CGFloat.nan, height: 24),
            CGRect(x: 0, y: 958, width: 1512, height: 0),
            CGRect(x: CGFloat.infinity, y: 958, width: 1512, height: 24)
        ] {
            #expect(!Recognizer.pointerIsInMenuBar(point, menuBarFrame: frame), "\(frame)")
        }
        let frame = CGRect(x: 0, y: 958, width: 1512, height: 24)
        #expect(!Recognizer.pointerIsInMenuBar(CGPoint(x: CGFloat.nan, y: 970), menuBarFrame: frame))
        #expect(!Recognizer.pointerIsInMenuBar(CGPoint(x: 100, y: CGFloat.infinity), menuBarFrame: frame))
    }

    private func sample(
        _ phase: Phase = .changed, dx: Double = 0, dy: Double = 0, inBar: Bool = true,
        at time: TimeInterval
    ) -> ScrollSample {
        ScrollSample(deltaX: dx, deltaY: dy, phase: phase, pointerInMenuBar: inBar, time: time)
    }

    /// One complete phased gesture on a fresh recognizer; the single `changed` carries the deltas.
    private func gesture(dx: Double = 0, dy: Double = 0, natural: Bool = true) -> Recognizer.Effect? {
        var recognizer = Recognizer(naturalScrolling: natural)
        #expect(recognizer.consume(sample(.began, at: 0)) == nil)
        let effect = recognizer.consume(sample(dx: dx, dy: dy, at: 0.01))
        #expect(recognizer.consume(sample(.ended, at: 0.02)) == nil)
        #expect(!recognizer.isTrackingGesture)
        return effect
    }
}
