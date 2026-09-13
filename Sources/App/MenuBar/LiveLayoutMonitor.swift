import AppKit
import BarKeepersFriendCore

enum LiveLayoutEventKind: CaseIterable, Hashable, Sendable {
    case appLaunched, appTerminated
}

/// Live mode: previews the planner after apps launch or quit and requests background placement only
/// when items are out of place. Timing is `LiveLayoutPolicy`'s; pointer sampling runs only while pending.
@MainActor
final class LiveLayoutMonitor {
    typealias TimerScheduler = TriggerMonitor.TimerScheduler

    static let pointerSampleInterval: TimeInterval = 0.25

    private let sources: [LiveLayoutEventKind: TriggerEventSource]
    private let pointerLocation: @MainActor () -> CGPoint
    private let isUserInteracting: @MainActor () -> Bool
    private let previewMoves: @MainActor () async -> Int?
    private let requestReconcile: @MainActor () -> Void
    private let now: @MainActor () -> TimeInterval
    private let scheduleTimer: TimerScheduler

    private(set) var policy: LiveLayoutPolicy
    private(set) var isEnabled = false
    private var armedSources: Set<LiveLayoutEventKind> = []
    private var cancelCheckTimer: (@MainActor () -> Void)?
    private(set) var scheduledCheckAt: TimeInterval?
    private var checkTimerGeneration: UInt64 = 0
    private var cancelSampleTimer: (@MainActor () -> Void)?
    private var sampleGeneration: UInt64 = 0
    private var lastPointerLocation: CGPoint?
    private var checkTask: Task<Void, Never>?
    private var checkGeneration: UInt64 = 0

    var isCheckPending: Bool { policy.isPending }
    var isSamplingPointer: Bool { cancelSampleTimer != nil }
    var isCheckInFlight: Bool { checkTask != nil }

    /// `scheduleTimer` is one-shot and returns its cancellation closure; `now` must be monotonic.
    init(
        configuration: LiveLayoutPolicy.Configuration = .default,
        sources: [LiveLayoutEventKind: TriggerEventSource],
        pointerLocation: @escaping @MainActor () -> CGPoint,
        isUserInteracting: @escaping @MainActor () -> Bool,
        previewMoves: @escaping @MainActor () async -> Int?,
        requestReconcile: @escaping @MainActor () -> Void,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduleTimer: TimerScheduler? = nil
    ) {
        self.policy = LiveLayoutPolicy(configuration: configuration)
        self.sources = sources
        self.pointerLocation = pointerLocation
        self.isUserInteracting = isUserInteracting
        self.previewMoves = previewMoves
        self.requestReconcile = requestReconcile
        self.now = now
        self.scheduleTimer = scheduleTimer ?? Self.scheduleOneShotTimer
    }

    /// Production wiring: workspace launch/termination notifications and the real pointer. Display
    /// changes are left out because the engine already re-applies placement on them.
    static func system(
        isUserInteracting: @escaping @MainActor () -> Bool,
        previewMoves: @escaping @MainActor () async -> Int?,
        requestReconcile: @escaping @MainActor () -> Void
    ) -> LiveLayoutMonitor {
        let workspace = NSWorkspace.shared.notificationCenter
        return LiveLayoutMonitor(
            sources: [
                .appLaunched: NotificationTriggerSource(center: workspace, name: NSWorkspace.didLaunchApplicationNotification),
                .appTerminated: NotificationTriggerSource(center: workspace, name: NSWorkspace.didTerminateApplicationNotification),
            ],
            pointerLocation: { NSEvent.mouseLocation },
            isUserInteracting: isUserInteracting,
            previewMoves: previewMoves,
            requestReconcile: requestReconcile
        )
    }

    isolated deinit { stop() }

    /// Enabling arms the feeds without running a check; only a later event can start one.
    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard !isEnabled else { return }
        isEnabled = true
        for kind in LiveLayoutEventKind.allCases {
            guard let source = sources[kind] else { continue }
            source.install { [weak self] in self?.observe(Self.event(for: kind)) }
            armedSources.insert(kind)
        }
        DebugLog.log("live layout: monitoring started")
    }

    /// Drops pending, scheduled, and in-flight work; a check already running cannot request placement.
    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        for kind in armedSources { sources[kind]?.remove() }
        armedSources = []
        clearCheckTimer()
        stopSampling()
        checkGeneration &+= 1
        checkTask?.cancel()
        checkTask = nil
        policy.reset()
        DebugLog.log("live layout: monitoring stopped")
    }

    private static func event(for kind: LiveLayoutEventKind) -> LiveLayoutPolicy.Event {
        switch kind {
        case .appLaunched: return .appLaunched
        case .appTerminated: return .appTerminated
        }
    }

    // MARK: - Policy driving

    private func observe(_ event: LiveLayoutPolicy.Event) {
        guard isEnabled else { return }
        syncInteraction()
        handle(event)
    }

    /// Interaction is polled, not pushed, so it is refreshed before every decision and sample.
    private func syncInteraction() {
        let interacting = isUserInteracting()
        guard interacting != policy.isUserInteracting else { return }
        handle(.userInteracting(interacting))
    }

    private func handle(_ event: LiveLayoutPolicy.Event) {
        let time = now()
        switch policy.handle(event, now: time) {
        case .scheduleCheck(let at)?:
            armCheckTimer(at: at, now: time)
        case .runCheck?:
            clearCheckTimer()
            startCheck()
        case nil:
            // Nothing is scheduled: no burst is pending or a check is running; an event or completion follows.
            clearCheckTimer()
        }
        updateSampling()
    }

    // MARK: - Check timer

    private func armCheckTimer(at: TimeInterval, now: TimeInterval) {
        if cancelCheckTimer != nil, scheduledCheckAt == at { return }
        clearCheckTimer()
        checkTimerGeneration &+= 1
        let generation = checkTimerGeneration
        scheduledCheckAt = at
        cancelCheckTimer = scheduleTimer(max(0, at - now)) { [weak self] in
            guard let self, self.checkTimerGeneration == generation else { return }
            self.cancelCheckTimer = nil
            self.scheduledCheckAt = nil
            self.observe(.tick)
        }
    }

    private func clearCheckTimer() {
        scheduledCheckAt = nil
        guard let cancel = cancelCheckTimer else { return }
        checkTimerGeneration &+= 1
        cancelCheckTimer = nil
        cancel()
    }

    // MARK: - Pointer sampling

    private func updateSampling() {
        guard isEnabled, policy.isPending else {
            stopSampling()
            return
        }
        // The baseline is taken when the burst starts so the first sample can already detect motion.
        if lastPointerLocation == nil { lastPointerLocation = pointerLocation() }
        if cancelSampleTimer == nil { armSampleTimer() }
    }

    private func armSampleTimer() {
        sampleGeneration &+= 1
        let generation = sampleGeneration
        cancelSampleTimer = scheduleTimer(Self.pointerSampleInterval) { [weak self] in
            guard let self, self.sampleGeneration == generation else { return }
            self.cancelSampleTimer = nil
            self.sample()
            // A sample that changed nothing bypasses `handle`, so keep the chain alive here.
            if self.isEnabled, self.policy.isPending, self.cancelSampleTimer == nil { self.armSampleTimer() }
        }
    }

    private func sample() {
        guard isEnabled else { return }
        syncInteraction()
        guard policy.isPending else { return }
        let location = pointerLocation()
        let moved = lastPointerLocation.map { $0 != location } ?? false
        lastPointerLocation = location
        if moved { handle(.pointerMoved) }
    }

    private func stopSampling() {
        lastPointerLocation = nil
        guard let cancel = cancelSampleTimer else { return }
        sampleGeneration &+= 1
        cancelSampleTimer = nil
        cancel()
    }

    // MARK: - Checks

    private func startCheck() {
        guard checkTask == nil else {
            DebugLog.log("live layout: check requested while one is still running; ignoring")
            return
        }
        checkGeneration &+= 1
        let generation = checkGeneration
        DebugLog.log("live layout: checking saved placement")
        checkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let planned = await self.previewMoves()
            // A stop() during the sweep must not let this stale result move anything.
            guard self.checkGeneration == generation else { return }
            self.checkTask = nil
            switch planned {
            case let count? where count > 0:
                // The sweep can outlast a bar or menu opening; placement must wait for it to end.
                guard !self.isUserInteracting() else {
                    DebugLog.log("live layout: \(count) item(s) out of place, but the user is interacting; deferring")
                    self.observe(.checkDeferred)
                    return
                }
                DebugLog.log("live layout: \(count) item(s) out of place; requesting placement")
                self.requestReconcile()
            case let count?:
                DebugLog.log("live layout: saved placement holds (plan=\(count))")
            case nil:
                DebugLog.log("live layout: placement could not be previewed; waiting for the next event")
            }
            self.observe(.checkFinished)
        }
    }

    private static func scheduleOneShotTimer(
        interval: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { tick() }
        }
        // Neither the settle wait nor the 4Hz sample needs exact wakeups; tolerance saves power.
        timer.tolerance = min(interval * 0.1, 1)
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
