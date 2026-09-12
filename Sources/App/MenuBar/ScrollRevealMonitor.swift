import AppKit
import BarKeepersFriendCore

/// A scroll-wheel event copied out of NSEvent so recognition can be driven without one.
struct ScrollWheelEvent: Equatable, Sendable {
    var scrollingDeltaX: CGFloat
    var scrollingDeltaY: CGFloat
    var hasPreciseScrollingDeltas: Bool
    var phase: NSEvent.Phase
    var momentumPhase: NSEvent.Phase
    var isDirectionInvertedFromDevice: Bool
    /// Pointer position in global AppKit coordinates when the event was observed.
    var location: CGPoint

    init(
        scrollingDeltaX: CGFloat = 0, scrollingDeltaY: CGFloat = 0,
        hasPreciseScrollingDeltas: Bool = true,
        phase: NSEvent.Phase = [], momentumPhase: NSEvent.Phase = [],
        isDirectionInvertedFromDevice: Bool = true, location: CGPoint
    ) {
        self.scrollingDeltaX = scrollingDeltaX
        self.scrollingDeltaY = scrollingDeltaY
        self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.isDirectionInvertedFromDevice = isDirectionInvertedFromDevice
        self.location = location
    }

    @MainActor
    init(_ event: NSEvent, location: CGPoint) {
        self.init(
            scrollingDeltaX: event.scrollingDeltaX, scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase, momentumPhase: event.momentumPhase,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice,
            location: location
        )
    }
}

@MainActor
protocol ScrollEventSource: AnyObject {
    /// Replaces any earlier handler; nothing is delivered after `remove()`.
    func install(handler: @escaping @MainActor (ScrollWheelEvent) -> Void)
    func remove()
}

/// Mouse-class global monitors need no Accessibility trust (only key monitors do). The local
/// monitor covers events sent to BKF's own windows, which the global monitor never sees.
@MainActor
final class NSEventScrollSource: ScrollEventSource {
    enum Scope: Sendable {
        case global, local
    }

    let scope: Scope
    private var monitor: Any?

    init(scope: Scope) {
        self.scope = scope
    }

    isolated deinit { remove() }

    func install(handler: @escaping @MainActor (ScrollWheelEvent) -> Void) {
        remove()
        switch scope {
        case .global:
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
                handler(ScrollWheelEvent(event, location: NSEvent.mouseLocation))
            }
        case .local:
            // Observation only: returning the event keeps normal dispatch intact.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                handler(ScrollWheelEvent(event, location: NSEvent.mouseLocation))
                return event
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Feeds observed scroll-wheel events to a `ScrollRevealRecognizer` and dispatches its effects.
/// Event-driven only: the cooldown and wheel gap are evaluated as samples arrive, never by timer.
@MainActor
final class ScrollRevealMonitor {
    /// Points per line for devices without precise deltas, matching NSScrollView's default line scroll.
    static let lineHeight: CGFloat = 10

    private let menuBarFrame: @MainActor (CGPoint) -> CGRect?
    private let onReveal: @MainActor () -> Void
    private let onHide: @MainActor () -> Void
    private let now: @MainActor () -> TimeInterval
    let sources: [any ScrollEventSource]
    private var recognizer: ScrollRevealRecognizer
    private var generation: UInt64 = 0
    private(set) var isEnabled = false

    /// `menuBarFrame` returns the menu bar strip of the display containing the point, in global
    /// AppKit coordinates, or nil when that display has no menu bar.
    init(
        menuBarFrame: @escaping @MainActor (CGPoint) -> CGRect?,
        onReveal: @escaping @MainActor () -> Void,
        onHide: @escaping @MainActor () -> Void,
        recognizer: ScrollRevealRecognizer = ScrollRevealRecognizer(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sources: [any ScrollEventSource]? = nil
    ) {
        self.menuBarFrame = menuBarFrame
        self.onReveal = onReveal
        self.onHide = onHide
        self.recognizer = recognizer
        self.now = now
        self.sources = sources ?? [NSEventScrollSource(scope: .global), NSEventScrollSource(scope: .local)]
    }

    isolated deinit { stop() }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        guard enabled else { stop(); return }
        isEnabled = true
        recognizer.reset()
        generation &+= 1
        let generation = generation
        DebugLog.log("scroll: monitoring enabled")
        for source in sources {
            source.install { [weak self] event in
                guard let self, self.isEnabled, self.generation == generation else { return }
                self.handle(event)
            }
        }
    }

    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        generation &+= 1
        for source in sources { source.remove() }
        recognizer.reset()
        DebugLog.log("scroll: monitoring disabled")
    }

    func handle(_ event: ScrollWheelEvent) {
        guard isEnabled else { return }
        let phase = Self.samplePhase(phase: event.phase, momentumPhase: event.momentumPhase)
        let inMenuBar = phase != .momentum && ScrollRevealRecognizer.pointerIsInMenuBar(
            event.location, menuBarFrame: menuBarFrame(event.location)
        )
        // Each event states its own sign convention; the recognizer maps both to "pull down reveals".
        recognizer.naturalScrolling = event.isDirectionInvertedFromDevice
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : Self.lineHeight
        let effect = recognizer.consume(ScrollSample(
            deltaX: Double(event.scrollingDeltaX * scale),
            deltaY: Double(event.scrollingDeltaY * scale),
            phase: phase, pointerInMenuBar: inMenuBar, time: now()
        ))
        switch effect {
        case .reveal:
            DebugLog.log("scroll: reveal")
            onReveal()
        case .hide:
            DebugLog.log("scroll: hide")
            onHide()
        case nil:
            break
        }
    }

    /// Momentum wins over `phase`, which is empty during inertia; `mayBegin` opens the gesture early
    /// so a following `cancelled` closes it cleanly.
    static func samplePhase(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> ScrollSample.Phase {
        guard momentumPhase.isEmpty else { return .momentum }
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        return .none
    }
}
