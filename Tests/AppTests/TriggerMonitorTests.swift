import AppKit
import BarKeepersFriendCore
import CoreWLAN
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct TriggerMonitorTests {
    static let presetID = UUID()

    static func rule(_ name: String, _ conditions: [TriggerCondition], enabled: Bool = true) -> TriggerRule {
        TriggerRule(name: name, isEnabled: enabled, conditions: conditions, presetID: presetID)
    }

    static let batteryRule = rule("battery", [.onBattery])
    static let wifiRule = rule("wifi", [.wifiConnected(true)])
    static let appRule = rule("zoom", [.frontmostApp(bundleID: "us.zoom.xos")])
    static let displayRule = rule("display", [.externalDisplayConnected(true)])
    static let lowPowerRule = rule("low power", [.lowPowerMode])
    static let officeRule = rule("office", [.timeOfDay(startMinute: 540, endMinute: 1020, weekdays: [2, 3, 4, 5, 6])])

    // MARK: - Plan

    @Test(arguments: TriggerCondition.Kind.allCases)
    func planArmsExactlyTheFeedsEachConditionNeeds(kind: TriggerCondition.Kind) {
        let plan = TriggerMonitoringPlan.plan(for: [Self.rule("one", [TriggerCondition.defaultCondition(for: kind)])])
        let expectedSources: Set<TriggerEventSourceKind>
        switch kind {
        case .frontmostApp: expectedSources = [.frontmostApp]
        case .externalDisplayConnected: expectedSources = [.screens]
        case .lowPowerMode: expectedSources = [.powerState]
        case .onBattery, .charging, .batteryBelow: expectedSources = [.powerSources]
        case .wifiConnected: expectedSources = [.wifi]
        case .timeOfDay: expectedSources = []
        }
        #expect(plan.sources == expectedSources)
        #expect(plan.pollsFallback == [.onBattery, .charging, .batteryBelow, .wifiConnected].contains(kind))
        #expect(plan.tracksMinutes == (kind == .timeOfDay))
    }

    @Test func planIgnoresDisabledRulesAndUnionsEnabledOnes() {
        #expect(TriggerMonitoringPlan.plan(for: []) == TriggerMonitoringPlan())
        #expect(TriggerMonitoringPlan.plan(for: [Self.rule("off", [.wifiConnected(true), .timeOfDay(startMinute: 0, endMinute: 60, weekdays: [1])], enabled: false)]) == TriggerMonitoringPlan())
        let plan = TriggerMonitoringPlan.plan(for: [Self.appRule, Self.officeRule, Self.rule("off", [.onBattery], enabled: false)])
        #expect(plan == TriggerMonitoringPlan(sources: [.frontmostApp], pollsFallback: false, tracksMinutes: true))
    }

    // MARK: - Arming

    @Test func firstUpdateArmsOnlyNeededSourcesAndDeliversOneDebouncedSnapshot() {
        let fixture = TriggerMonitorFixture()
        let monitor = fixture.makeMonitor()
        #expect(!monitor.isMonitoring)
        monitor.update(rules: [Self.appRule, Self.rule("off", [.wifiConnected(true)], enabled: false)])
        #expect(monitor.isMonitoring)
        #expect(fixture.installed == [.frontmostApp])
        #expect(fixture.timers.map(\.interval) == [TriggerMonitor.debounceInterval])
        #expect(fixture.delivered.isEmpty)
        #expect(fixture.probe.snapshotDates.isEmpty)

        fixture.fire(0)
        #expect(fixture.delivered.count == 1)
        #expect(fixture.probe.snapshotDates == [fixture.time])
        #expect(fixture.delivered[0].now == fixture.time)
        #expect(fixture.delivered[0].frontmostBundleID == "com.apple.Safari")
        #expect(fixture.delivered[0].calendar == fixture.probe.calendar)
        #expect(fixture.timers.count == 1)
    }

    @Test func eventsWithinTheDebounceWindowCoalesceIntoOneSnapshot() {
        let fixture = TriggerMonitorFixture()
        let monitor = fixture.makeMonitor()
        monitor.update(rules: [Self.appRule, Self.displayRule])
        fixture.fire(0)
        #expect(fixture.delivered.count == 1)

        for _ in 0..<3 { fixture.sources[.frontmostApp]!.fire() }
        fixture.sources[.screens]!.fire()
        #expect(fixture.timers.count == 5)
        #expect(fixture.cancelled == [1, 2, 3])
        #expect(fixture.delivered.count == 1)

        fixture.time = fixture.time.addingTimeInterval(0.25)
        fixture.fire(4)
        #expect(fixture.delivered.count == 2)
        #expect(fixture.delivered[1].now == fixture.time)
        // A cancelled timer that fires anyway must not produce a second snapshot.
        fixture.fire(2)
        #expect(fixture.delivered.count == 2)
        #expect(fixture.probe.snapshotDates.count == 2)
    }

    @Test func unchangedRulesNeitherRearmNorDeliver() {
        let fixture = TriggerMonitorFixture()
        let monitor = fixture.makeMonitor()
        let rules = [Self.appRule, Self.batteryRule]
        monitor.update(rules: rules)
        #expect(fixture.timers.map(\.interval) == [TriggerMonitor.fallbackPollInterval, TriggerMonitor.debounceInterval])
        fixture.fire(1)
        let timerCount = fixture.timers.count
        monitor.update(rules: rules)
        monitor.update(rules: rules)
        #expect(fixture.timers.count == timerCount)
        #expect(fixture.sources[.frontmostApp]!.installs == 1)
        #expect(fixture.sources[.powerSources]!.installs == 1)
        #expect(fixture.delivered.count == 1)

        var renamed = rules
        renamed[0].name = "renamed"
        monitor.update(rules: renamed)
        #expect(fixture.sources[.frontmostApp]!.installs == 1)
        #expect(fixture.timers.count == timerCount + 1)
        fixture.fire(fixture.timers.count - 1)
        #expect(fixture.delivered.count == 2)
    }

    @Test func rearmingFollowsTheRuleSetWithoutReinstallingKeptSources() {
        let fixture = TriggerMonitorFixture()
        let monitor = fixture.makeMonitor()
        // Arming happens before the snapshot request, so the poll is scheduled before the debounce.
        monitor.update(rules: [Self.wifiRule, Self.batteryRule])
        #expect(fixture.installed == [.powerSources, .wifi])
        #expect(fixture.timers.map(\.interval) == [TriggerMonitor.fallbackPollInterval, TriggerMonitor.debounceInterval])
        #expect(monitor.plan.pollsFallback)

        monitor.update(rules: [Self.batteryRule])
        #expect(fixture.installed == [.powerSources])
        #expect(fixture.sources[.wifi]!.removes == 1)
        #expect(fixture.sources[.powerSources]!.installs == 1)
        // The poll stays armed for the battery rule; only the debounce is rescheduled.
        #expect(fixture.cancelled == [1])
        #expect(fixture.timers.map(\.interval) == [30, 0.25, 0.25])

        monitor.update(rules: [Self.lowPowerRule])
        #expect(fixture.installed == [.powerState])
        #expect(fixture.sources[.powerSources]!.removes == 1)
        #expect(fixture.cancelled == [1, 0, 2])
        #expect(!monitor.plan.pollsFallback)
        #expect(fixture.timers.map(\.interval) == [30, 0.25, 0.25, 0.25])

        monitor.update(rules: [Self.lowPowerRule, Self.wifiRule])
        #expect(fixture.installed == [.powerState, .wifi])
        #expect(fixture.sources[.wifi]!.installs == 2)
        #expect(fixture.timers.map(\.interval) == [30, 0.25, 0.25, 0.25, 30, 0.25])
        #expect(fixture.cancelled == [1, 0, 2, 3])

        monitor.update(rules: [])
        #expect(fixture.installed.isEmpty)
        #expect(monitor.plan == TriggerMonitoringPlan())
        #expect(monitor.isMonitoring)
        #expect(fixture.cancelled == [1, 0, 2, 3, 4, 5])
        #expect(fixture.pending == [6])
        #expect(fixture.timers[6].interval == TriggerMonitor.debounceInterval)
    }

    @Test func minuteTimerIsArmedOnlyWhileATimeRuleExistsAndRearmsAtEachBoundary() {
        let fixture = TriggerMonitorFixture()
        let boundary: TimeInterval = 800_000_040
        fixture.time = Date(timeIntervalSinceReferenceDate: boundary - 48)
        let monitor = fixture.makeMonitor()
        monitor.update(rules: [Self.appRule])
        #expect(fixture.timers.count == 1)

        monitor.update(rules: [Self.appRule, Self.officeRule])
        #expect(fixture.installed == [.frontmostApp])
        #expect(monitor.plan.tracksMinutes)
        #expect(fixture.timers.count == 3)
        #expect(abs(fixture.timers[1].interval - 48.05) < 0.001)
        #expect(fixture.timers[2].interval == TriggerMonitor.debounceInterval)
        #expect(fixture.cancelled == [0])
        fixture.fire(2)
        #expect(fixture.delivered.count == 1)

        fixture.time = Date(timeIntervalSinceReferenceDate: boundary + 0.05)
        fixture.fire(1)
        #expect(fixture.timers.count == 5)
        #expect(fixture.timers[3].interval == TriggerMonitor.debounceInterval)
        #expect(abs(fixture.timers[4].interval - 60) < 0.001)
        #expect(fixture.delivered.count == 1)
        fixture.fire(3)
        #expect(fixture.delivered.count == 2)
        #expect(fixture.delivered[1].now == fixture.time)

        monitor.update(rules: [Self.appRule])
        #expect(!monitor.plan.tracksMinutes)
        #expect(fixture.cancelled == [0, 4])
        #expect(fixture.pending == [5])
        #expect(fixture.timers[5].interval == TriggerMonitor.debounceInterval)

        #expect(TriggerMonitor.delayToNextMinute(from: Date(timeIntervalSinceReferenceDate: 120)) == 60.05)
        #expect(abs(TriggerMonitor.delayToNextMinute(from: Date(timeIntervalSinceReferenceDate: -7)) - 7.05) < 0.001)
        #expect(abs(TriggerMonitor.delayToNextMinute(from: Date(timeIntervalSinceReferenceDate: 179.9)) - 0.15) < 0.001)
    }

    @Test func fallbackPollRearmsWhileNeededAndSnapshotsThroughTheDebounce() {
        let fixture = TriggerMonitorFixture()
        let monitor = fixture.makeMonitor()
        monitor.update(rules: [Self.wifiRule])
        #expect(fixture.timers.map(\.interval) == [TriggerMonitor.fallbackPollInterval, TriggerMonitor.debounceInterval])
        fixture.fire(1)
        #expect(fixture.delivered.count == 1)

        fixture.fire(0)
        #expect(fixture.delivered.count == 1)
        #expect(fixture.timers.map(\.interval) == [30, 0.25, 0.25, 30])
        #expect(fixture.pending == [2, 3])
        fixture.fire(2)
        #expect(fixture.delivered.count == 2)
        #expect(fixture.sources[.wifi]!.installs == 1)
        #expect(fixture.pending == [3])
    }

    @Test func stopCancelsEverythingIgnoresLateCallbacksAndAllowsRearming() {
        let fixture = TriggerMonitorFixture()
        let monitor = fixture.makeMonitor()
        monitor.update(rules: [Self.appRule, Self.wifiRule, Self.officeRule])
        #expect(fixture.installed == [.frontmostApp, .wifi])
        #expect(fixture.pending.count == 3)
        let pendingBeforeStop = fixture.pending

        monitor.stop()
        monitor.stop()
        #expect(!monitor.isMonitoring)
        #expect(fixture.installed.isEmpty)
        #expect(Set(fixture.cancelled) == Set(pendingBeforeStop))
        #expect(monitor.plan == TriggerMonitoringPlan())
        for index in pendingBeforeStop { fixture.fire(index) }
        fixture.sources[.frontmostApp]!.fire()
        monitor.refresh()
        #expect(fixture.delivered.isEmpty)
        #expect(fixture.timers.count == 3)
        #expect(fixture.probe.snapshotDates.isEmpty)

        monitor.update(rules: [Self.appRule])
        #expect(fixture.installed == [.frontmostApp])
        #expect(fixture.sources[.frontmostApp]!.installs == 2)
        #expect(fixture.pending.map { fixture.timers[$0].interval } == [TriggerMonitor.debounceInterval])
        fixture.fire(fixture.timers.count - 1)
        #expect(fixture.delivered.count == 1)

        monitor.refresh()
        fixture.fire(fixture.timers.count - 1)
        #expect(fixture.delivered.count == 2)
    }

    @Test func releasingTheMonitorRemovesItsSourcesAndTimers() {
        let fixture = TriggerMonitorFixture()
        var monitor: TriggerMonitor? = fixture.makeMonitor()
        monitor?.update(rules: [Self.wifiRule])
        #expect(fixture.installed == [.wifi])
        monitor = nil
        #expect(fixture.installed.isEmpty)
        #expect(fixture.pending.isEmpty)
    }

    // MARK: - Probe facts

    @Test func powerFactsFollowIOKitDescriptions() {
        let battery: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: 1, kIOPSIsChargingKey: 1,
            kIOPSCurrentCapacityKey: 25, kIOPSMaxCapacityKey: 100, kIOPSPowerSourceStateKey: kIOPSACPowerValue
        ]
        let charging = PowerSourceFacts.parse(providingSourceType: kIOPSACPowerValue, sources: [battery])
        #expect(charging == PowerSourceFacts(isOnBattery: false, isCharging: true, batteryPercent: 25))

        var full = battery
        full[kIOPSIsChargingKey] = 0
        full[kIOPSCurrentCapacityKey] = 100
        #expect(PowerSourceFacts.parse(providingSourceType: kIOPSACPowerValue, sources: [full])
                == PowerSourceFacts(isOnBattery: false, isCharging: true, batteryPercent: 100))

        var draining = battery
        draining[kIOPSIsChargingKey] = false
        draining[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
        draining[kIOPSCurrentCapacityKey] = 4123
        draining[kIOPSMaxCapacityKey] = 5000
        #expect(PowerSourceFacts.parse(providingSourceType: kIOPSBatteryPowerValue, sources: [draining])
                == PowerSourceFacts(isOnBattery: true, isCharging: false, batteryPercent: 82))
        #expect(PowerSourceFacts.parse(providingSourceType: "UPS Power", sources: [draining]).isOnBattery == true)

        let desktop = PowerSourceFacts.parse(providingSourceType: kIOPSACPowerValue, sources: [])
        #expect(desktop == PowerSourceFacts(isOnBattery: false, isCharging: nil, batteryPercent: nil))
        #expect(PowerSourceFacts.parse(providingSourceType: nil, sources: []) == PowerSourceFacts())

        var absent = battery
        absent[kIOPSIsPresentKey] = 0
        #expect(PowerSourceFacts.parse(providingSourceType: kIOPSACPowerValue, sources: [absent]).isCharging == nil)
        var unknownCapacity = battery
        unknownCapacity[kIOPSMaxCapacityKey] = 0
        #expect(PowerSourceFacts.parse(providingSourceType: kIOPSACPowerValue, sources: [unknownCapacity]).batteryPercent == nil)
        let ups: [String: Any] = [kIOPSTypeKey: "UPS", kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 100]
        #expect(PowerSourceFacts.parse(providingSourceType: kIOPSACPowerValue, sources: [ups, battery]).batteryPercent == 25)
    }

    @Test func wifiAssociationIsInferredWithoutAnSSID() {
        #expect(!WiFiFacts.isConnected(powerOn: false, ssid: "Home", bssid: nil, mode: .station, rssi: -50, transmitRate: 100))
        #expect(WiFiFacts.isConnected(powerOn: true, ssid: "Home", bssid: nil, mode: .none, rssi: 0, transmitRate: 0))
        #expect(WiFiFacts.isConnected(powerOn: true, ssid: nil, bssid: "aa:bb", mode: .none, rssi: 0, transmitRate: 0))
        #expect(WiFiFacts.isConnected(powerOn: true, ssid: nil, bssid: nil, mode: .station, rssi: -49, transmitRate: 1729))
        #expect(WiFiFacts.isConnected(powerOn: true, ssid: nil, bssid: nil, mode: .station, rssi: 0, transmitRate: 6))
        #expect(!WiFiFacts.isConnected(powerOn: true, ssid: nil, bssid: nil, mode: .station, rssi: 0, transmitRate: 0))
        #expect(!WiFiFacts.isConnected(powerOn: true, ssid: nil, bssid: nil, mode: .none, rssi: -49, transmitRate: 100))
    }

    @Test func externalDisplayMeansAnyNonBuiltinScreen() {
        #expect(!DisplayFacts.hasExternalDisplay(displayIDs: [], isBuiltin: { _ in true }))
        #expect(!DisplayFacts.hasExternalDisplay(displayIDs: [1], isBuiltin: { _ in true }))
        #expect(DisplayFacts.hasExternalDisplay(displayIDs: [1, 7], isBuiltin: { $0 == 1 }))
        #expect(DisplayFacts.hasExternalDisplay(displayIDs: [7], isBuiltin: { $0 == 1 }))
    }
}

@MainActor
private final class FakeTriggerSource: TriggerEventSource {
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
private final class FakeTriggerProbe: TriggerEnvironmentProbe {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()
    private(set) var snapshotDates: [Date] = []

    func snapshot(now: Date) -> TriggerEnvironment {
        snapshotDates.append(now)
        return TriggerEnvironment(isOnBattery: true, frontmostBundleID: "com.apple.Safari", now: now, calendar: calendar)
    }
}

@MainActor
private final class TriggerMonitorFixture {
    var time = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let probe = FakeTriggerProbe()
    let sources: [TriggerEventSourceKind: FakeTriggerSource] = Dictionary(
        uniqueKeysWithValues: TriggerEventSourceKind.allCases.map { ($0, FakeTriggerSource()) }
    )
    private(set) var timers: [(interval: TimeInterval, tick: @MainActor @Sendable () -> Void)] = []
    private(set) var cancelled: [Int] = []
    private(set) var fired: [Int] = []
    private(set) var delivered: [TriggerEnvironment] = []

    var installed: Set<TriggerEventSourceKind> { Set(sources.filter { $0.value.isInstalled }.map(\.key)) }
    var pending: [Int] { timers.indices.filter { !cancelled.contains($0) && !fired.contains($0) } }

    func makeMonitor() -> TriggerMonitor {
        let monitor = TriggerMonitor(
            probe: probe,
            sources: sources,
            now: { self.time },
            scheduleTimer: { interval, tick in
                let index = self.timers.count
                self.timers.append((interval, tick))
                return { self.cancelled.append(index) }
            }
        )
        monitor.onEnvironmentChanged = { self.delivered.append($0) }
        return monitor
    }

    func fire(_ index: Int) {
        fired.append(index)
        timers[index].tick()
    }
}
