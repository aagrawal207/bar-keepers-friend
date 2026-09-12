import AppKit
import BarKeepersFriendCore
import CoreWLAN
import IOKit.ps

/// Reads every fact the trigger conditions depend on. `now` is injected so tests and the minute
/// timer share one clock.
@MainActor
protocol TriggerEnvironmentProbe {
    func snapshot(now: Date) -> TriggerEnvironment
}

/// One OS change feed. `install` replaces any earlier handler; nothing is delivered after `remove()`.
@MainActor
protocol TriggerEventSource: AnyObject {
    func install(handler: @escaping @MainActor @Sendable () -> Void)
    func remove()
}

enum TriggerEventSourceKind: CaseIterable, Hashable, Sendable {
    case frontmostApp, screens, powerState, powerSources, wifi
}

/// Which feeds and timers a rule set needs. Disabled rules need none; deleting or disabling the
/// active rule is handled by the snapshot `update(rules:)` requests, not by a feed.
struct TriggerMonitoringPlan: Equatable, Sendable {
    var sources: Set<TriggerEventSourceKind> = []
    var pollsFallback = false
    var tracksMinutes = false

    static func plan(for rules: [TriggerRule]) -> TriggerMonitoringPlan {
        var plan = TriggerMonitoringPlan()
        for kind in Set(rules.filter(\.isEnabled).flatMap(\.conditionKinds)) {
            switch kind {
            case .frontmostApp:
                plan.sources.insert(.frontmostApp)
            case .externalDisplayConnected:
                plan.sources.insert(.screens)
            case .lowPowerMode:
                plan.sources.insert(.powerState)
            case .onBattery, .charging, .batteryBelow:
                plan.sources.insert(.powerSources)
                plan.pollsFallback = true
            case .wifiConnected:
                plan.sources.insert(.wifi)
                plan.pollsFallback = true
            case .timeOfDay:
                plan.tracksMinutes = true
            }
        }
        return plan
    }
}

/// Watches only the OS facts the enabled rules use and hands a debounced `TriggerEnvironment` to
/// `onEnvironmentChanged`. Pure decisions stay in `TriggerEvaluator`; this class owns no rule state.
@MainActor
final class TriggerMonitor {
    typealias TimerScheduler = @MainActor (
        TimeInterval, @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void

    static let debounceInterval: TimeInterval = 0.25
    /// Battery percentage and Wi-Fi association do not always post a notification; a slow poll
    /// while such a rule exists bounds the staleness without a permanent timer.
    static let fallbackPollInterval: TimeInterval = 30

    var onEnvironmentChanged: (@MainActor (TriggerEnvironment) -> Void)?

    private let probe: TriggerEnvironmentProbe
    private let sources: [TriggerEventSourceKind: TriggerEventSource]
    private let now: @MainActor () -> Date
    private let scheduleTimer: TimerScheduler

    /// `nil` before the first `update(rules:)` and after `stop()`, so either re-arms and re-snapshots.
    private var rules: [TriggerRule]?
    private(set) var plan = TriggerMonitoringPlan()
    private var armedSources: Set<TriggerEventSourceKind> = []
    private var cancelDebounce: (@MainActor () -> Void)?
    private var cancelPoll: (@MainActor () -> Void)?
    private var cancelMinute: (@MainActor () -> Void)?
    private var debounceGeneration: UInt64 = 0
    private var pollGeneration: UInt64 = 0
    private var minuteGeneration: UInt64 = 0

    var isMonitoring: Bool { rules != nil }

    /// `scheduleTimer` is one-shot and returns its cancellation closure.
    init(
        probe: TriggerEnvironmentProbe,
        sources: [TriggerEventSourceKind: TriggerEventSource],
        now: @escaping @MainActor () -> Date = { Date() },
        scheduleTimer: TimerScheduler? = nil
    ) {
        self.probe = probe
        self.sources = sources
        self.now = now
        self.scheduleTimer = scheduleTimer ?? Self.scheduleOneShotTimer
    }

    /// The production wiring: IOKit power sources, CoreWLAN events, workspace and screen notifications.
    static func system() -> TriggerMonitor {
        TriggerMonitor(
            probe: SystemTriggerEnvironmentProbe(),
            sources: [
                .frontmostApp: NotificationTriggerSource(
                    center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didActivateApplicationNotification
                ),
                .screens: NotificationTriggerSource(
                    center: .default, name: NSApplication.didChangeScreenParametersNotification
                ),
                .powerState: NotificationTriggerSource(center: .default, name: .NSProcessInfoPowerStateDidChange),
                .powerSources: PowerSourcesTriggerSource(),
                .wifi: WiFiEventTriggerSource()
            ]
        )
    }

    isolated deinit { stop() }

    /// Arms only the feeds the enabled rules need. A changed rule set (and the first call) also
    /// requests a fresh snapshot so the evaluator can react to the edit itself.
    func update(rules newRules: [TriggerRule]) {
        let changed = rules != newRules
        rules = newRules
        apply(TriggerMonitoringPlan.plan(for: newRules))
        if changed { requestSnapshot() }
    }

    /// Asks for one debounced snapshot without changing what is armed. Inert while stopped.
    func refresh() {
        guard rules != nil else { return }
        requestSnapshot()
    }

    func stop() {
        guard rules != nil || cancelDebounce != nil else { return }
        rules = nil
        debounceGeneration &+= 1
        pollGeneration &+= 1
        minuteGeneration &+= 1
        for cancel in [cancelDebounce, cancelPoll, cancelMinute] { cancel?() }
        cancelDebounce = nil
        cancelPoll = nil
        cancelMinute = nil
        for kind in armedSources { sources[kind]?.remove() }
        armedSources = []
        plan = TriggerMonitoringPlan()
        DebugLog.log("triggers: monitoring stopped")
    }

    // MARK: - Arming

    private func apply(_ newPlan: TriggerMonitoringPlan) {
        for kind in TriggerEventSourceKind.allCases {
            let needed = newPlan.sources.contains(kind)
            if needed, !armedSources.contains(kind), let source = sources[kind] {
                source.install { [weak self] in self?.requestSnapshot() }
                armedSources.insert(kind)
            } else if !needed, armedSources.contains(kind) {
                sources[kind]?.remove()
                armedSources.remove(kind)
            }
        }
        if newPlan.pollsFallback, cancelPoll == nil {
            armPoll()
        } else if !newPlan.pollsFallback, let cancel = cancelPoll {
            pollGeneration &+= 1
            cancelPoll = nil
            cancel()
        }
        if newPlan.tracksMinutes, cancelMinute == nil {
            armMinuteTimer()
        } else if !newPlan.tracksMinutes, let cancel = cancelMinute {
            minuteGeneration &+= 1
            cancelMinute = nil
            cancel()
        }
        if newPlan != plan {
            plan = newPlan
            DebugLog.log(
                "triggers: monitoring sources=\(newPlan.sources.map { "\($0)" }.sorted()) "
                    + "poll=\(newPlan.pollsFallback) minutes=\(newPlan.tracksMinutes)"
            )
        }
    }

    private func armPoll() {
        pollGeneration &+= 1
        let generation = pollGeneration
        cancelPoll = scheduleTimer(Self.fallbackPollInterval) { [weak self] in
            guard let self, self.pollGeneration == generation else { return }
            self.cancelPoll = nil
            self.requestSnapshot()
            if self.plan.pollsFallback { self.armPoll() }
        }
    }

    private func armMinuteTimer() {
        minuteGeneration &+= 1
        let generation = minuteGeneration
        cancelMinute = scheduleTimer(Self.delayToNextMinute(from: now())) { [weak self] in
            guard let self, self.minuteGeneration == generation else { return }
            self.cancelMinute = nil
            self.requestSnapshot()
            if self.plan.tracksMinutes { self.armMinuteTimer() }
        }
    }

    /// Seconds until just after the next wall-clock minute boundary. Every time zone offset is a
    /// whole number of minutes, so boundaries in reference-date seconds are local boundaries too.
    static func delayToNextMinute(from date: Date) -> TimeInterval {
        let seconds = date.timeIntervalSinceReferenceDate
        let intoMinute = (seconds.truncatingRemainder(dividingBy: 60) + 60).truncatingRemainder(dividingBy: 60)
        return (60 - intoMinute) + 0.05
    }

    // MARK: - Delivery

    private func requestSnapshot() {
        debounceGeneration &+= 1
        let generation = debounceGeneration
        cancelDebounce?()
        cancelDebounce = scheduleTimer(Self.debounceInterval) { [weak self] in
            guard let self, self.debounceGeneration == generation else { return }
            self.cancelDebounce = nil
            self.deliver()
        }
    }

    private func deliver() {
        guard rules != nil else { return }
        let environment = probe.snapshot(now: now())
        DebugLog.log(
            "triggers: environment battery=\(environment.isOnBattery.map { "\($0)" } ?? "?") "
                + "charging=\(environment.isCharging.map { "\($0)" } ?? "?") "
                + "percent=\(environment.batteryPercent.map { "\($0)" } ?? "?") "
                + "lowPower=\(environment.lowPowerMode) wifi=\(environment.wifiConnected.map { "\($0)" } ?? "?") "
                + "frontmost=\(environment.frontmostBundleID ?? "?") external=\(environment.externalDisplayConnected) "
                + "weekday=\(environment.weekday) minute=\(environment.minuteOfDay)"
        )
        onEnvironmentChanged?(environment)
    }

    private static func scheduleOneShotTimer(
        interval: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { tick() }
        }
        // A minute rule may start a few seconds late; the poll may drift more. Both save wakeups.
        timer.tolerance = min(interval * 0.1, 1)
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

// MARK: - Sources

/// Forwards one notification name from a center. The block is delivered on the main queue.
@MainActor
final class NotificationTriggerSource: TriggerEventSource {
    private let center: NotificationCenter
    private let name: Notification.Name
    private var token: NSObjectProtocol?

    init(center: NotificationCenter, name: Notification.Name) {
        self.center = center
        self.name = name
    }

    isolated deinit { remove() }

    func install(handler: @escaping @MainActor @Sendable () -> Void) {
        remove()
        token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    func remove() {
        if let token { center.removeObserver(token) }
        token = nil
    }
}

/// IOKit power-source changes (adapter plugged or unplugged, capacity steps) via a run loop source
/// on the main run loop, so the C callback always lands on the main actor.
@MainActor
final class PowerSourcesTriggerSource: TriggerEventSource {
    private final class HandlerBox {
        let handler: @MainActor @Sendable () -> Void
        init(handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }
    }

    private var runLoopSource: CFRunLoopSource?
    private var box: HandlerBox?

    isolated deinit { remove() }

    func install(handler: @escaping @MainActor @Sendable () -> Void) {
        remove()
        let box = HandlerBox(handler: handler)
        self.box = box
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let box = Unmanaged<HandlerBox>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { box.handler() }
        }, context)?.takeRetainedValue() else {
            DebugLog.log("triggers: power source notifications unavailable; relying on the fallback poll")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    func remove() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        runLoopSource = nil
        box = nil
    }
}

/// CoreWLAN link, SSID, and power events. `CWWiFiClient.shared()` is process-wide and BKF has no
/// other Wi-Fi observer, so this source owns its delegate slot.
@MainActor
final class WiFiEventTriggerSource: TriggerEventSource {
    private var delegate: Delegate?

    isolated deinit { remove() }

    func install(handler: @escaping @MainActor @Sendable () -> Void) {
        remove()
        let delegate = Delegate(notify: handler)
        self.delegate = delegate
        let client = CWWiFiClient.shared()
        client.delegate = delegate
        for event in [CWEventType.linkDidChange, .ssidDidChange, .powerDidChange] {
            do {
                try client.startMonitoringEvent(with: event)
            } catch {
                DebugLog.log("triggers: wifi event \(event.rawValue) unavailable: \(error)")
            }
        }
    }

    func remove() {
        guard let delegate else { return }
        let client = CWWiFiClient.shared()
        try? client.stopMonitoringAllEvents()
        if client.delegate === delegate { client.delegate = nil }
        self.delegate = nil
    }

    /// Callbacks arrive on CoreWLAN's queue; each becomes one main-actor hop.
    private final class Delegate: NSObject, CWEventDelegate {
        private let notify: @MainActor @Sendable () -> Void

        init(notify: @escaping @MainActor @Sendable () -> Void) {
            self.notify = notify
        }

        func linkDidChangeForWiFiInterface(withName interfaceName: String) { forward() }
        func ssidDidChangeForWiFiInterface(withName interfaceName: String) { forward() }
        func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { forward() }

        private func forward() {
            let notify = notify
            Task { @MainActor in notify() }
        }
    }
}

// MARK: - Probe

/// Reads live facts from IOKit, CoreWLAN, ProcessInfo, NSWorkspace, and NSScreen. Unreadable facts
/// stay `nil`, which no condition satisfies.
@MainActor
struct SystemTriggerEnvironmentProbe: TriggerEnvironmentProbe {
    func snapshot(now: Date) -> TriggerEnvironment {
        let power = PowerSourceFacts.read()
        return TriggerEnvironment(
            isOnBattery: power.isOnBattery,
            isCharging: power.isCharging,
            batteryPercent: power.batteryPercent,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            wifiConnected: WiFiFacts.read(),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            externalDisplayConnected: DisplayFacts.hasExternalDisplay(),
            now: now,
            calendar: .current
        )
    }
}

struct PowerSourceFacts: Equatable, Sendable {
    var isOnBattery: Bool?
    var isCharging: Bool?
    var batteryPercent: Int?

    static func read() -> PowerSourceFacts {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerSourceFacts() }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let sources = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
        return parse(providingSourceType: providing, sources: sources)
    }

    /// Battery facts come from the first present internal battery. "Charging" means drawing from
    /// external power even with a full battery, which is what a user means by a charging Mac.
    static func parse(providingSourceType: String?, sources: [[String: Any]]) -> PowerSourceFacts {
        var facts = PowerSourceFacts()
        if let providing = providingSourceType {
            facts.isOnBattery = providing != kIOPSACPowerValue
        }
        let battery = sources.first {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && isTrue($0[kIOPSIsPresentKey], default: true)
        }
        guard let battery else { return facts }
        facts.isCharging = isTrue(battery[kIOPSIsChargingKey], default: false)
            || battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        if let current = number(battery[kIOPSCurrentCapacityKey]),
           let maximum = number(battery[kIOPSMaxCapacityKey]), maximum > 0 {
            facts.batteryPercent = min(100, max(0, Int((current / maximum * 100).rounded())))
        }
        return facts
    }

    private static func isTrue(_ value: Any?, default fallback: Bool) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? Int { return number != 0 }
        return fallback
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
}

enum WiFiFacts {
    /// `nil` when the Mac has no Wi-Fi interface.
    static func read() -> Bool? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        return isConnected(
            powerOn: interface.powerOn(), ssid: interface.ssid(), bssid: interface.bssid(),
            mode: interface.interfaceMode(), rssi: interface.rssiValue(), transmitRate: interface.transmitRate()
        )
    }

    /// Without Location permission macOS returns a nil SSID and BSSID even while associated, so
    /// association is also inferred from station mode with a signal or a transmit rate.
    static func isConnected(
        powerOn: Bool, ssid: String?, bssid: String?, mode: CWInterfaceMode, rssi: Int, transmitRate: Double
    ) -> Bool {
        guard powerOn else { return false }
        if ssid != nil || bssid != nil { return true }
        return mode == .station && (rssi != 0 || transmitRate > 0)
    }
}

enum DisplayFacts {
    @MainActor
    static func hasExternalDisplay() -> Bool {
        let ids = NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        return hasExternalDisplay(displayIDs: ids, isBuiltin: { CGDisplayIsBuiltin($0) != 0 })
    }

    static func hasExternalDisplay(displayIDs: [CGDirectDisplayID], isBuiltin: (CGDirectDisplayID) -> Bool) -> Bool {
        displayIDs.contains { !isBuiltin($0) }
    }
}
