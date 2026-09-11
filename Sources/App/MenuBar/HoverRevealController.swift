import AppKit
import BarKeepersFriendCore

@MainActor
final class HoverRevealController {
    typealias TimerScheduler = @MainActor (
        TimeInterval, @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void

    private let anchorFrame: @MainActor () -> CGRect?
    private let panelFrame: @MainActor () -> CGRect?
    private let isPanelVisible: @MainActor () -> Bool
    private let canReveal: @MainActor () -> Bool
    private let showPanel: @MainActor () async -> Void
    private let hidePanel: @MainActor () -> Void
    private let pointerLocation: @MainActor () -> CGPoint
    private let isMouseButtonPressed: @MainActor () -> Bool
    private let now: @MainActor () -> TimeInterval
    private let scheduleTimer: TimerScheduler
    private var cancelTimer: (@MainActor () -> Void)?
    private var timerGeneration: UInt64 = 0
    private var machine = HoverRevealStateMachine()
    private var pendingShowID: UInt64?
    private(set) var pendingShowTask: Task<Void, Never>?

    var ownsPanel: Bool { machine.ownsPanel }

    /// `showPanel` must honor task cancellation before presenting, including after its own awaits.
    /// Getters use AppKit screen coordinates; `scheduleTimer` returns its cancellation closure.
    init(
        anchorFrame: @escaping @MainActor () -> CGRect?,
        panelFrame: @escaping @MainActor () -> CGRect?,
        isPanelVisible: @escaping @MainActor () -> Bool,
        canReveal: @escaping @MainActor () -> Bool,
        showPanel: @escaping @MainActor () async -> Void,
        hidePanel: @escaping @MainActor () -> Void,
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        isMouseButtonPressed: @escaping @MainActor () -> Bool = { NSEvent.pressedMouseButtons != 0 },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduleTimer: TimerScheduler? = nil
    ) {
        self.anchorFrame = anchorFrame
        self.panelFrame = panelFrame
        self.isPanelVisible = isPanelVisible
        self.canReveal = canReveal
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.pointerLocation = pointerLocation
        self.isMouseButtonPressed = isMouseButtonPressed
        self.now = now
        self.scheduleTimer = scheduleTimer ?? Self.schedulePollingTimer
    }

    isolated deinit { stop() }

    func setEnabled(_ enabled: Bool) {
        guard enabled != machine.isEnabled else { return }
        guard enabled else { stop(); return }
        machine.setEnabled(true)
        DebugLog.log("hover: monitoring enabled")
        timerGeneration &+= 1
        let generation = timerGeneration
        cancelTimer = scheduleTimer(0.05) { [weak self] in
            guard let self, self.machine.isEnabled, self.timerGeneration == generation else { return }
            self.updatePointer(self.pointerLocation())
        }
        updatePointer(pointerLocation())
    }

    func relinquishForManualInteraction() {
        if machine.ownsPanel || pendingShowID != nil { DebugLog.log("hover: relinquished to manual interaction") }
        let visible = isPanelVisible()
        machine.relinquishForManualInteraction(pointer: region(at: pointerLocation(), panelVisible: visible))
        apply(nil)
    }

    func stop() {
        if machine.isEnabled { DebugLog.log("hover: monitoring disabled") }
        timerGeneration &+= 1
        let cancel = cancelTimer
        cancelTimer = nil
        cancel?()
        apply(machine.setEnabled(false))
    }

    func updatePointer(_ point: CGPoint) {
        guard machine.isEnabled else { return }
        let visible = isPanelVisible()
        apply(machine.update(
            pointer: region(at: point, panelVisible: visible), panelVisible: visible,
            canReveal: canReveal() && (visible || !isMouseButtonPressed()), now: now()
        ))
    }

    private func region(at point: CGPoint, panelVisible: Bool) -> HoverRevealStateMachine.PointerRegion {
        HoverRevealStateMachine.region(
            at: point, anchorFrame: anchorFrame(), panelFrame: panelVisible ? panelFrame() : nil
        )
    }

    private func apply(_ effect: HoverRevealStateMachine.Effect?) {
        if pendingShowID != machine.requestID {
            pendingShowTask?.cancel()
            pendingShowTask = nil
            pendingShowID = nil
        }
        switch effect {
        case let .show(id):
            pendingShowID = id
            let show = showPanel
            pendingShowTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, self?.beginShow(id) == true else { return }
                await show()
                self?.finishShow(id)
            }
        case .hide:
            if isPanelVisible() {
                DebugLog.log("hover: closing owned panel")
                hidePanel()
            }
        case nil:
            break
        }
    }

    private func beginShow(_ id: UInt64) -> Bool {
        guard pendingShowID == id else { return false }
        let visible = isPanelVisible()
        let shouldShow = machine.beginReveal(
            id, pointer: region(at: pointerLocation(), panelVisible: visible),
            panelVisible: visible, canReveal: canReveal() && !isMouseButtonPressed()
        )
        apply(nil)
        return shouldShow
    }

    private func finishShow(_ id: UInt64) {
        guard pendingShowID == id else { return }
        pendingShowTask = nil
        pendingShowID = nil
        let visible = isPanelVisible()
        DebugLog.log("hover: presentation visible=\(visible)")
        apply(machine.revealCompleted(
            id, pointer: region(at: pointerLocation(), panelVisible: visible), panelVisible: visible,
            canReveal: canReveal(), now: now()
        ))
    }

    private static func schedulePollingTimer(
        interval: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
