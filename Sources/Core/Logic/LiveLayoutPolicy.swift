import Foundation

/// Decides when Live mode may run a placement check (an Accessibility sweep): only after an app
/// launches or quits, once the burst settles and the pointer is idle, at most once per `minInterval`.
public struct LiveLayoutPolicy: Equatable, Sendable {

    public struct Configuration: Equatable, Sendable {
        /// Quiet time after the last app event before a check may run.
        public var settleDelay: TimeInterval
        /// Pointer stillness required before a check, so a resulting move does not fight the user.
        public var pointerIdle: TimeInterval
        /// Minimum spacing between checks; each one is an Accessibility sweep of every app.
        public var minInterval: TimeInterval
        /// A never-settling burst or a restless pointer defers a check at most this long; an
        /// interaction lasting this long abandons the burst instead.
        public var maxDeferral: TimeInterval

        public init(
            settleDelay: TimeInterval = 1.5,
            pointerIdle: TimeInterval = 0.8,
            minInterval: TimeInterval = 10,
            maxDeferral: TimeInterval = 30
        ) {
            self.settleDelay = Self.sanitized(settleDelay)
            self.pointerIdle = Self.sanitized(pointerIdle)
            self.minInterval = Self.sanitized(minInterval)
            self.maxDeferral = Self.sanitized(maxDeferral)
        }

        public static let `default` = Configuration()

        /// Negative or non-finite delays would schedule in the past or poison every comparison.
        private static func sanitized(_ value: TimeInterval) -> TimeInterval {
            value.isFinite && value > 0 ? value : 0
        }
    }

    public enum Event: Equatable, Sendable {
        case appLaunched
        case appTerminated
        /// The pointer position differed from the previous sample.
        case pointerMoved
        /// The floating bar or a menu is open; a check must wait until this is reported false.
        case userInteracting(Bool)
        /// A scheduled time arrived (or any other moment worth re-evaluating).
        case tick
        /// The check started by `.runCheck` completed; events that arrived meanwhile are re-evaluated.
        case checkFinished
        /// The check found work but the user was interacting; the burst is kept so it reruns afterwards.
        case checkDeferred
    }

    public enum Effect: Equatable, Sendable {
        /// Re-evaluate at this time; replaces any earlier schedule.
        case scheduleCheck(at: TimeInterval)
        /// Run one check now. The caller must report `.checkFinished` or `.checkDeferred` afterwards.
        case runCheck
    }

    public let configuration: Configuration

    /// Start of the current burst, or of the wait since interaction ended; bounds it via `maxDeferral`.
    private var pendingSince: TimeInterval?
    private var lastEventAt: TimeInterval?
    private var lastPointerMoveAt: TimeInterval?
    private var interacting = false
    private var lastCheckFinishedAt: TimeInterval?
    private var checkInFlight = false

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Whether an app event is waiting for a check. Pointer sampling is only useful then.
    public var isPending: Bool { pendingSince != nil }
    public var isCheckInFlight: Bool { checkInFlight }
    public var isUserInteracting: Bool { interacting }

    /// `now` is the caller's monotonic clock. A `nil` effect means nothing needs to be scheduled:
    /// either no check is pending, or it waits for `.checkFinished`/`.checkDeferred`.
    public mutating func handle(_ event: Event, now: TimeInterval) -> Effect? {
        switch event {
        case .appLaunched, .appTerminated:
            if pendingSince == nil { pendingSince = now }
            lastEventAt = now
        case .pointerMoved:
            lastPointerMoveAt = now
        case .userInteracting(let flag):
            // Time spent in a menu must not count as settling or idling, nor spend the deadline.
            if interacting, !flag, pendingSince != nil {
                pendingSince = now
                lastEventAt = now
                lastPointerMoveAt = now
            }
            interacting = flag
        case .tick:
            break
        case .checkFinished, .checkDeferred:
            // A stray completion after reset must not delay the next check by minInterval.
            guard checkInFlight else { break }
            checkInFlight = false
            lastCheckFinishedAt = now
            if event == .checkDeferred, pendingSince == nil {
                pendingSince = now
                lastEventAt = now
            }
        }
        return evaluate(now: now)
    }

    /// Forgets every burst, pointer sample, and check; used when Live mode is turned off.
    public mutating func reset() {
        self = LiveLayoutPolicy(configuration: configuration)
    }

    private mutating func evaluate(now: TimeInterval) -> Effect? {
        guard let pendingSince, let lastEventAt, !checkInFlight else { return nil }
        let deadline = pendingSince + configuration.maxDeferral
        if interacting {
            // A long interaction abandons the burst so sampling stops; the next app event starts anew.
            guard now < deadline else {
                clearBurst()
                return nil
            }
            return .scheduleCheck(at: deadline)
        }
        var softGate = lastEventAt + configuration.settleDelay
        if let lastPointerMoveAt {
            softGate = max(softGate, lastPointerMoveAt + configuration.pointerIdle)
        }
        // Settle and pointer gates are heuristics and bow to the deadline; the rate limit does not.
        var runAt = min(softGate, deadline)
        if let lastCheckFinishedAt {
            runAt = max(runAt, lastCheckFinishedAt + configuration.minInterval)
        }
        guard now >= runAt else { return .scheduleCheck(at: runAt) }
        clearBurst()
        checkInFlight = true
        return .runCheck
    }

    private mutating func clearBurst() {
        pendingSince = nil
        lastEventAt = nil
    }
}
