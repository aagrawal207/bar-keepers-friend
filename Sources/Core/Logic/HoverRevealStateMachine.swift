import CoreGraphics
import Foundation

public struct HoverRevealStateMachine: Equatable, Sendable {
    public enum PointerRegion: Equatable, Sendable {
        case anchor, panel, gap, outside, unavailable
    }

    public enum Effect: Equatable, Sendable {
        case show(UInt64)
        case hide
    }

    private enum State: Equatable, Sendable {
        case idle
        case dwelling(deadline: TimeInterval)
        case requested(UInt64)
        case owned(id: UInt64, awaitingCompletion: Bool, hideDeadline: TimeInterval?)
    }

    public static let dwellDelay: TimeInterval = 0.2
    public static let exitGrace: TimeInterval = 0.4

    public private(set) var isEnabled = false
    private var state: State = .idle
    private var nextRequestID: UInt64 = 0
    private var suppressedUntilAnchorExit = false

    public var requestID: UInt64? {
        switch state {
        case let .requested(id), let .owned(id, _, _): return id
        case .idle, .dwelling: return nil
        }
    }

    public var ownsPanel: Bool {
        if case .owned = state { return true }
        return false
    }

    public init() {}

    @discardableResult
    public mutating func setEnabled(_ enabled: Bool) -> Effect? {
        guard enabled != isEnabled else { return nil }
        isEnabled = enabled
        guard !enabled else { return nil }
        let effect: Effect? = ownsPanel ? .hide : nil
        state = .idle
        return effect
    }

    public mutating func relinquishForManualInteraction(pointer: PointerRegion) {
        state = .idle
        suppressedUntilAnchorExit = pointer == .anchor || pointer == .unavailable
    }

    /// `now` is monotonic; wall-clock changes must not shorten a dwell or an exit grace.
    @discardableResult
    public mutating func update(
        pointer: PointerRegion, panelVisible: Bool, canReveal: Bool, now: TimeInterval
    ) -> Effect? {
        guard isEnabled else { return nil }
        guard canReveal else {
            let effect: Effect? = ownsPanel ? .hide : nil
            state = .idle
            return effect
        }
        // Native placement can move the pointer temporarily; it must not undo a manual close.
        if pointer != .anchor && pointer != .unavailable { suppressedUntilAnchorExit = false }

        switch state {
        case let .owned(id, awaitingCompletion, hideDeadline):
            guard panelVisible else {
                if !awaitingCompletion || pointer != .anchor {
                    state = .idle
                    suppressedUntilAnchorExit = pointer == .anchor || pointer == .unavailable
                }
                return nil
            }
            if pointer == .anchor || pointer == .panel || pointer == .gap {
                state = .owned(id: id, awaitingCompletion: awaitingCompletion, hideDeadline: nil)
            } else if let hideDeadline, now >= hideDeadline {
                state = .idle
                return .hide
            } else {
                state = .owned(
                    id: id, awaitingCompletion: awaitingCompletion,
                    hideDeadline: hideDeadline ?? now + Self.exitGrace
                )
            }

        case .requested:
            if panelVisible {
                relinquishForManualInteraction(pointer: pointer)
            } else if pointer != .anchor {
                state = .idle
            }

        case .idle, .dwelling:
            guard pointer == .anchor, !panelVisible, !suppressedUntilAnchorExit else {
                state = .idle
                return nil
            }
            if case let .dwelling(deadline) = state {
                guard now >= deadline else { return nil }
                nextRequestID &+= 1
                state = .requested(nextRequestID)
                return .show(nextRequestID)
            }
            state = .dwelling(deadline: now + Self.dwellDelay)
        }
        return nil
    }

    /// A queued request is not ownership: a manual bar may appear before its task starts.
    public mutating func beginReveal(
        _ id: UInt64, pointer: PointerRegion, panelVisible: Bool, canReveal: Bool
    ) -> Bool {
        guard case let .requested(currentID) = state, currentID == id else { return false }
        guard isEnabled, canReveal, pointer == .anchor, !panelVisible else {
            state = .idle
            if panelVisible { relinquishForManualInteraction(pointer: pointer) }
            return false
        }
        state = .owned(id: id, awaitingCompletion: true, hideDeadline: nil)
        return true
    }

    @discardableResult
    public mutating func revealCompleted(
        _ id: UInt64, pointer: PointerRegion, panelVisible: Bool, canReveal: Bool,
        now: TimeInterval
    ) -> Effect? {
        guard case let .owned(currentID, true, hideDeadline) = state, currentID == id else { return nil }
        state = .owned(id: id, awaitingCompletion: false, hideDeadline: hideDeadline)
        return update(pointer: pointer, panelVisible: panelVisible, canReveal: canReveal, now: now)
    }

    /// Frames and points share global AppKit coordinates, including negative display origins.
    public static func region(
        at point: CGPoint, anchorFrame: CGRect?, panelFrame: CGRect?
    ) -> PointerRegion {
        guard point.x.isFinite, point.y.isFinite else { return .unavailable }
        func usable(_ frame: CGRect?) -> CGRect? {
            // Core Graphics' infinite-rectangle sentinel has finite coordinate values.
            guard let frame, !frame.isInfinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width > 0, frame.size.height > 0,
                  frame.maxX.isFinite, frame.maxY.isFinite else { return nil }
            return frame
        }
        let anchor = usable(anchorFrame)
        let panel = usable(panelFrame)
        // The screen's top edge is a valid pointer position over a status item.
        func contains(_ frame: CGRect?) -> Bool {
            guard let frame else { return false }
            return point.x >= frame.minX && point.x <= frame.maxX
                && point.y >= frame.minY && point.y <= frame.maxY
        }
        if contains(anchor) { return .anchor }
        if contains(panel) { return .panel }
        guard let anchor else { return .unavailable }
        guard let panel, anchor.maxX >= panel.minX, panel.maxX >= anchor.minX else { return .outside }

        // Only the strip between facing edges is a bridge, not the whole bounding box.
        let gapMinY: CGFloat
        let gapMaxY: CGFloat
        if panel.maxY <= anchor.minY {
            gapMinY = panel.maxY
            gapMaxY = anchor.minY
        } else if anchor.maxY <= panel.minY {
            gapMinY = anchor.maxY
            gapMaxY = panel.minY
        } else {
            return .outside
        }
        return point.x >= min(anchor.minX, panel.minX) && point.x <= max(anchor.maxX, panel.maxX)
            && point.y >= gapMinY && point.y <= gapMaxY ? .gap : .outside
    }
}
