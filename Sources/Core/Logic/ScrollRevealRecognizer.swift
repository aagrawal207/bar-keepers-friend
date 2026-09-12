import CoreGraphics
import Foundation

/// One scroll-wheel event reduced to what gesture recognition needs.
public struct ScrollSample: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// A wheel tick without gesture phases; runs of these are segmented by time gap.
        case none
        case began, changed, ended, cancelled
        /// Post-gesture inertia; never counts toward a threshold.
        case momentum
    }

    public var deltaX: Double
    public var deltaY: Double
    public var phase: Phase
    public var pointerInMenuBar: Bool
    public var time: TimeInterval

    public init(
        deltaX: Double = 0, deltaY: Double = 0, phase: Phase = .none,
        pointerInMenuBar: Bool, time: TimeInterval
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.phase = phase
        self.pointerInMenuBar = pointerInMenuBar
        self.time = time
    }
}

/// Turns scroll/swipe gestures over the menu bar into at most one reveal or hide per gesture.
public struct ScrollRevealRecognizer: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        case reveal, hide
    }

    private enum Status: Equatable, Sendable {
        case armed, fired, cancelled
    }

    private struct Gesture: Equatable, Sendable {
        var isPhased: Bool
        var status: Status
        var accumulatedX: Double = 0
        var accumulatedY: Double = 0
        var lastSampleTime: TimeInterval
    }

    public static let defaultThreshold: Double = 12
    public static let defaultCooldown: TimeInterval = 0.4
    public static let defaultWheelGap: TimeInterval = 0.3

    public let threshold: Double
    public let cooldown: TimeInterval
    public let wheelGap: TimeInterval
    /// True when deltas carry NSEvent's inverted convention: a two-finger swipe down is positive deltaY.
    /// False means the physical pull down arrives as negative deltaY; either way pulling down reveals.
    public var naturalScrolling: Bool

    private var gesture: Gesture?
    private var cooldownEnd: TimeInterval?

    public var isTrackingGesture: Bool { gesture != nil }

    public init(
        threshold: Double = Self.defaultThreshold,
        cooldown: TimeInterval = Self.defaultCooldown,
        wheelGap: TimeInterval = Self.defaultWheelGap,
        naturalScrolling: Bool = true
    ) {
        self.threshold = Self.sanitized(threshold, fallback: Self.defaultThreshold)
        self.cooldown = Self.sanitized(cooldown, fallback: Self.defaultCooldown)
        self.wheelGap = Self.sanitized(wheelGap, fallback: Self.defaultWheelGap)
        self.naturalScrolling = naturalScrolling
    }

    /// `time` is monotonic; the cooldown and wheel gap are measured against it, never wall-clock.
    @discardableResult
    public mutating func consume(_ sample: ScrollSample) -> Effect? {
        guard sample.phase != .momentum else { return nil }
        if beginsGesture(sample) {
            gesture = Gesture(
                isPhased: sample.phase != .none,
                status: sample.pointerInMenuBar ? .armed : .cancelled,
                lastSampleTime: sample.time
            )
        }
        guard var current = gesture else { return nil }
        current.lastSampleTime = sample.time
        if !sample.pointerInMenuBar, current.status == .armed { current.status = .cancelled }

        var effect: Effect?
        if current.status == .armed {
            current.accumulatedX += Self.finite(sample.deltaX)
            current.accumulatedY += Self.finite(sample.deltaY)
            if let candidate = candidateEffect(for: current) {
                // A gesture that outlasts the cooldown is deliberate, so suppression does not consume it.
                if cooldownEnd.map({ sample.time < $0 }) != true {
                    current.status = .fired
                    cooldownEnd = sample.time + cooldown
                    effect = candidate
                }
            }
        }
        let ended = sample.phase == .ended || sample.phase == .cancelled
        gesture = ended ? nil : current
        return effect
    }

    public mutating func reset() {
        gesture = nil
        cooldownEnd = nil
    }

    /// Inclusive edges: at a display's top edge AppKit reports y == maxY, which is still over the bar.
    public static func pointerIsInMenuBar(_ point: CGPoint, menuBarFrame: CGRect?) -> Bool {
        guard let frame = menuBarFrame, point.x.isFinite, point.y.isFinite,
              !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite, frame.maxX.isFinite, frame.maxY.isFinite
        else { return false }
        return point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }

    private func beginsGesture(_ sample: ScrollSample) -> Bool {
        switch sample.phase {
        case .began:
            return true
        case .changed:
            // A missed `began` must not swallow the whole gesture; phased input also ends a wheel run.
            return gesture.map { !$0.isPhased } ?? true
        case .none:
            // A phased gesture whose `ended` never arrived must not swallow later wheel ticks.
            guard let gesture else { return true }
            return sample.time - gesture.lastSampleTime > wheelGap
        case .ended, .cancelled, .momentum:
            return false
        }
    }

    private func candidateEffect(for gesture: Gesture) -> Effect? {
        let x = gesture.accumulatedX
        let y = gesture.accumulatedY
        guard max(abs(x), abs(y)) > threshold else { return nil }
        // Ties favor vertical: pull-down is the primary gesture, swipe-left its trackpad alias.
        let naturalReveal = abs(y) >= abs(x) ? y > 0 : x < 0
        return naturalReveal == naturalScrolling ? .reveal : .hide
    }

    private static func sanitized(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? max(0, value) : fallback
    }

    private static func finite(_ delta: Double) -> Double {
        delta.isFinite ? delta : 0
    }
}
