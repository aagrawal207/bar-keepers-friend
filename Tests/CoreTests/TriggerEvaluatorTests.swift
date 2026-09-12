import Foundation
import Testing
import BarKeepersFriendCore

@Suite struct TriggerEvaluatorTests {
    // Asia/Kolkata (UTC+5:30) makes any UTC leak in weekday/minute math visible.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    // 2026-09-14 is a Monday.
    static func date(day: Int, hour: Int, minute: Int, calendar: Calendar = TriggerEvaluatorTests.calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    static func environment(
        isOnBattery: Bool? = nil, isCharging: Bool? = nil, batteryPercent: Int? = nil,
        lowPowerMode: Bool = false, wifiConnected: Bool? = nil, frontmostBundleID: String? = nil,
        externalDisplayConnected: Bool = false, now: Date = TriggerEvaluatorTests.date(day: 14, hour: 12, minute: 0),
        calendar: Calendar = TriggerEvaluatorTests.calendar
    ) -> TriggerEnvironment {
        TriggerEnvironment(
            isOnBattery: isOnBattery, isCharging: isCharging, batteryPercent: batteryPercent,
            lowPowerMode: lowPowerMode, wifiConnected: wifiConnected, frontmostBundleID: frontmostBundleID,
            externalDisplayConnected: externalDisplayConnected, now: now, calendar: calendar
        )
    }

    static let presetA = LayoutPreset(id: UUID(), name: "Focus", itemControls: ItemControlStore(hiddenInMenuBar: ["ACME"]))
    static let presetB = LayoutPreset(id: UUID(), name: "Meeting", itemControls: ItemControlStore(hiddenInMenuBar: ["ACME", "Maccy"]))
    static let presets = [presetA, presetB]
    static let userControls = ItemControlStore(shownInMenuBar: ["ACME"], barOrder: ["Maccy": 1])

    static func rule(
        _ name: String, _ conditions: [TriggerCondition], preset: LayoutPreset = TriggerEvaluatorTests.presetA, enabled: Bool = true
    ) -> TriggerRule {
        TriggerRule(name: name, isEnabled: enabled, conditions: conditions, presetID: preset.id)
    }

    // MARK: - Conditions

    @Test(arguments: [
        (TriggerCondition.onBattery, TriggerEvaluatorTests.environment(isOnBattery: true), true),
        (.onBattery, TriggerEvaluatorTests.environment(isOnBattery: false), false),
        (.onBattery, TriggerEvaluatorTests.environment(), false),
        (.charging, TriggerEvaluatorTests.environment(isCharging: true), true),
        (.charging, TriggerEvaluatorTests.environment(isCharging: false), false),
        (.charging, TriggerEvaluatorTests.environment(), false),
        (.batteryBelow(percent: 20), TriggerEvaluatorTests.environment(batteryPercent: 19), true),
        (.batteryBelow(percent: 20), TriggerEvaluatorTests.environment(batteryPercent: 20), false),
        (.batteryBelow(percent: 20), TriggerEvaluatorTests.environment(batteryPercent: 100), false),
        (.batteryBelow(percent: 20), TriggerEvaluatorTests.environment(), false),
        (.lowPowerMode, TriggerEvaluatorTests.environment(lowPowerMode: true), true),
        (.lowPowerMode, TriggerEvaluatorTests.environment(lowPowerMode: false), false),
        (.wifiConnected(true), TriggerEvaluatorTests.environment(wifiConnected: true), true),
        (.wifiConnected(true), TriggerEvaluatorTests.environment(wifiConnected: false), false),
        (.wifiConnected(true), TriggerEvaluatorTests.environment(), false),
        (.wifiConnected(false), TriggerEvaluatorTests.environment(wifiConnected: false), true),
        (.wifiConnected(false), TriggerEvaluatorTests.environment(wifiConnected: true), false),
        (.wifiConnected(false), TriggerEvaluatorTests.environment(), false),
        (.frontmostApp(bundleID: "com.apple.Safari"), TriggerEvaluatorTests.environment(frontmostBundleID: "com.apple.Safari"), true),
        (.frontmostApp(bundleID: "com.apple.safari"), TriggerEvaluatorTests.environment(frontmostBundleID: "com.apple.Safari"), true),
        (.frontmostApp(bundleID: "com.apple.Safari"), TriggerEvaluatorTests.environment(frontmostBundleID: "com.apple.Mail"), false),
        (.frontmostApp(bundleID: "com.apple.Safari"), TriggerEvaluatorTests.environment(), false),
        (.frontmostApp(bundleID: ""), TriggerEvaluatorTests.environment(frontmostBundleID: ""), false),
        (.externalDisplayConnected(true), TriggerEvaluatorTests.environment(externalDisplayConnected: true), true),
        (.externalDisplayConnected(true), TriggerEvaluatorTests.environment(externalDisplayConnected: false), false),
        (.externalDisplayConnected(false), TriggerEvaluatorTests.environment(externalDisplayConnected: false), true),
        (.externalDisplayConnected(false), TriggerEvaluatorTests.environment(externalDisplayConnected: true), false)
    ])
    func conditionsHoldOnlyForKnownMatchingFacts(condition: TriggerCondition, environment: TriggerEnvironment, expected: Bool) {
        #expect(condition.holds(in: environment) == expected)
    }

    @Test(arguments: [
        (14, 8, 59, false), (14, 9, 0, true), (14, 12, 30, true), (14, 16, 59, true), (14, 17, 0, false),
        (14, 23, 59, false), (18, 12, 0, true), (19, 12, 0, false), (13, 12, 0, false)
    ])
    func officeHoursHoldOnlyInsideTheRangeOnSelectedWeekdays(day: Int, hour: Int, minute: Int, expected: Bool) {
        let condition = TriggerCondition.timeOfDay(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: [2, 3, 4, 5, 6])
        #expect(condition.holds(in: Self.environment(now: Self.date(day: day, hour: hour, minute: minute))) == expected)
    }

    @Test(arguments: [
        (14, 21, 59, false), (14, 22, 0, true), (14, 23, 59, true),
        (15, 0, 0, true), (15, 1, 59, true), (15, 2, 0, false), (15, 22, 30, false),
        (14, 1, 0, false), (13, 23, 0, false)
    ])
    func wrappingRangeContinuesIntoTheMorningAfterASelectedDay(day: Int, hour: Int, minute: Int, expected: Bool) {
        let mondayNight = TriggerCondition.timeOfDay(startMinute: 22 * 60, endMinute: 2 * 60, weekdays: [2])
        #expect(mondayNight.holds(in: Self.environment(now: Self.date(day: day, hour: hour, minute: minute))) == expected)
    }

    @Test func wrappingRangeCrossesTheWeekBoundaryFromSaturdayIntoSunday() {
        let saturdayNight = TriggerCondition.timeOfDay(startMinute: 22 * 60, endMinute: 2 * 60, weekdays: [7])
        #expect(saturdayNight.holds(in: Self.environment(now: Self.date(day: 12, hour: 23, minute: 0))))
        #expect(saturdayNight.holds(in: Self.environment(now: Self.date(day: 13, hour: 1, minute: 0))))
        #expect(!saturdayNight.holds(in: Self.environment(now: Self.date(day: 12, hour: 1, minute: 0))))
        #expect(!saturdayNight.holds(in: Self.environment(now: Self.date(day: 13, hour: 2, minute: 0))))
        #expect(!saturdayNight.holds(in: Self.environment(now: Self.date(day: 13, hour: 23, minute: 0))))
    }

    @Test(arguments: [0, 9 * 60, 23 * 60 + 59])
    func equalStartAndEndMeansAllDayOnSelectedDaysOnly(minute: Int) {
        let allDaySunday = TriggerCondition.timeOfDay(startMinute: minute, endMinute: minute, weekdays: [1])
        for (hour, minute) in [(0, 0), (9, 0), (15, 45), (23, 59)] {
            #expect(allDaySunday.holds(in: Self.environment(now: Self.date(day: 13, hour: hour, minute: minute))))
            #expect(!allDaySunday.holds(in: Self.environment(now: Self.date(day: 14, hour: hour, minute: minute))))
        }
    }

    @Test func noValidWeekdaysNeverHoldsAndOutOfRangeValuesAreIgnored() {
        let noon = Self.environment(now: Self.date(day: 14, hour: 12, minute: 0))
        #expect(!TriggerCondition.timeOfDay(startMinute: 0, endMinute: 0, weekdays: []).holds(in: noon))
        #expect(!TriggerCondition.timeOfDay(startMinute: 0, endMinute: 0, weekdays: [0, 8, -3]).holds(in: noon))
        #expect(TriggerCondition.timeOfDay(startMinute: 0, endMinute: 0, weekdays: [0, 2, 8]).holds(in: noon))
        // Out-of-range minutes clamp to the day instead of disabling the rule.
        #expect(TriggerCondition.timeOfDay(startMinute: -50, endMinute: 5000, weekdays: [2]).holds(in: noon))
        #expect(!TriggerCondition.timeOfDay(startMinute: -50, endMinute: 5000, weekdays: [3]).holds(in: noon))
        #expect(!TriggerCondition.timeOfDayHolds(startMinute: 0, endMinute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7], weekday: 0, minuteOfDay: 10))
    }

    @Test func timeConditionsFollowTheEnvironmentCalendarTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 03:30 UTC is 09:00 in Kolkata and 05:30 in Berlin on the same Monday.
        let instant = Self.date(day: 14, hour: 3, minute: 30, calendar: utc)
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let office = TriggerCondition.timeOfDay(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: [2])

        #expect(office.holds(in: Self.environment(now: instant, calendar: Self.calendar)))
        #expect(!office.holds(in: Self.environment(now: instant, calendar: utc)))
        #expect(!office.holds(in: Self.environment(now: instant, calendar: berlin)))
        #expect(Self.environment(now: instant, calendar: Self.calendar).minuteOfDay == 9 * 60)
        #expect(Self.environment(now: instant, calendar: berlin).minuteOfDay == 5 * 60 + 30)

        // Sunday 22:00 in Los Angeles is already Monday 10:30 in Kolkata.
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sundayEvening = Self.date(day: 13, hour: 22, minute: 0, calendar: losAngeles)
        #expect(Self.environment(now: sundayEvening, calendar: losAngeles).weekday == 1)
        #expect(Self.environment(now: sundayEvening, calendar: Self.calendar).weekday == 2)
        #expect(office.holds(in: Self.environment(now: sundayEvening, calendar: Self.calendar)))
        #expect(!office.holds(in: Self.environment(now: sundayEvening, calendar: losAngeles)))
    }

    @Test func rulesRequireEveryConditionAndAtLeastOne() {
        let environment = Self.environment(isOnBattery: true, wifiConnected: false)
        #expect(Self.rule("both", [.onBattery, .wifiConnected(false)]).holds(in: environment))
        #expect(!Self.rule("one fails", [.onBattery, .wifiConnected(true)]).holds(in: environment))
        #expect(!Self.rule("unknown", [.onBattery, .charging]).holds(in: environment))
        #expect(!Self.rule("empty", []).holds(in: environment))
        #expect(Self.rule("kinds", [.onBattery, .wifiConnected(true), .wifiConnected(false)]).conditionKinds == [.onBattery, .wifiConnected])
    }

    // MARK: - Matching

    @Test func firstEnabledHoldingRuleWithAnExistingPresetWins() {
        let environment = Self.environment(isOnBattery: true, isCharging: false, lowPowerMode: true)
        let disabled = Self.rule("disabled", [.onBattery], enabled: false)
        let orphan = Self.rule("orphan", [.onBattery], preset: LayoutPreset(id: UUID(), name: "Gone", itemControls: ItemControlStore()))
        let notHolding = Self.rule("charging", [.charging])
        let second = Self.rule("second", [.onBattery, .lowPowerMode], preset: Self.presetB)
        let third = Self.rule("third", [.onBattery])
        let rules = [disabled, orphan, notHolding, second, third]

        #expect(TriggerEvaluator.matchingRule(rules: rules, presets: Self.presets, environment: environment)?.id == second.id)
        #expect(TriggerEvaluator.matchingRule(rules: rules, presets: [Self.presetA], environment: environment)?.id == third.id)
        #expect(TriggerEvaluator.matchingRule(rules: rules, presets: [], environment: environment) == nil)
        #expect(TriggerEvaluator.matchingRule(rules: [disabled, notHolding], presets: Self.presets, environment: environment) == nil)
        #expect(TriggerEvaluator.matchingRule(rules: [], presets: Self.presets, environment: environment) == nil)
    }

    // MARK: - Step transitions

    @Test func activationCapturesBaselineAppliesPresetAndIsIdempotent() {
        let rule = Self.rule("battery", [.onBattery])
        let environment = Self.environment(isOnBattery: true)
        let first = TriggerEvaluator.step(
            state: TriggerRuntimeState(), rules: [rule], presets: Self.presets,
            environment: environment, currentControls: Self.userControls
        )
        #expect(first.state == TriggerRuntimeState(activeRuleID: rule.id, baselineControls: Self.userControls))
        #expect(first.controls == Self.presetA.itemControls)

        let second = TriggerEvaluator.step(
            state: first.state, rules: [rule], presets: Self.presets,
            environment: environment, currentControls: Self.presetA.itemControls
        )
        #expect(second.state == first.state)
        #expect(second.controls == nil)

        // A later environment reading that still matches is also a no-op.
        let later = TriggerEvaluator.step(
            state: second.state, rules: [rule], presets: Self.presets,
            environment: Self.environment(isOnBattery: true, batteryPercent: 42, now: Self.date(day: 14, hour: 13, minute: 0)),
            currentControls: Self.presetA.itemControls
        )
        #expect(later.state == first.state)
        #expect(later.controls == nil)
    }

    @Test func nothingHappensWhileNoRuleHoldsAndNothingIsActive() {
        let rule = Self.rule("battery", [.onBattery])
        for environment in [Self.environment(isOnBattery: false), Self.environment()] {
            let result = TriggerEvaluator.step(
                state: TriggerRuntimeState(), rules: [rule], presets: Self.presets,
                environment: environment, currentControls: Self.userControls
            )
            #expect(result.state == TriggerRuntimeState())
            #expect(result.controls == nil)
        }
        let noRules = TriggerEvaluator.step(
            state: TriggerRuntimeState(), rules: [], presets: [],
            environment: Self.environment(isOnBattery: true), currentControls: Self.userControls
        )
        #expect(noRules.state == TriggerRuntimeState())
        #expect(noRules.controls == nil)
    }

    @Test func switchingRulesKeepsTheOriginalBaselineAndAppliesTheNewPreset() {
        let batteryRule = Self.rule("battery", [.onBattery])
        let meetingRule = Self.rule("meeting", [.frontmostApp(bundleID: "us.zoom.xos")], preset: Self.presetB)
        let rules = [meetingRule, batteryRule]
        let active = TriggerRuntimeState(activeRuleID: batteryRule.id, baselineControls: Self.userControls)

        let switched = TriggerEvaluator.step(
            state: active, rules: rules, presets: Self.presets,
            environment: Self.environment(isOnBattery: true, frontmostBundleID: "us.zoom.xos"),
            currentControls: Self.presetA.itemControls
        )
        #expect(switched.state == TriggerRuntimeState(activeRuleID: meetingRule.id, baselineControls: Self.userControls))
        #expect(switched.controls == Self.presetB.itemControls)

        let back = TriggerEvaluator.step(
            state: switched.state, rules: rules, presets: Self.presets,
            environment: Self.environment(isOnBattery: true, frontmostBundleID: "com.apple.Safari"),
            currentControls: Self.presetB.itemControls
        )
        #expect(back.state == active)
        #expect(back.controls == Self.presetA.itemControls)

        let released = TriggerEvaluator.step(
            state: back.state, rules: rules, presets: Self.presets,
            environment: Self.environment(isOnBattery: false), currentControls: Self.presetA.itemControls
        )
        #expect(released.state == TriggerRuntimeState())
        #expect(released.controls == Self.userControls)
    }

    @Test func deactivationRestoresTheBaselineOnceAndClearsState() {
        let rule = Self.rule("battery", [.onBattery])
        let active = TriggerRuntimeState(activeRuleID: rule.id, baselineControls: Self.userControls)
        let restored = TriggerEvaluator.step(
            state: active, rules: [rule], presets: Self.presets,
            environment: Self.environment(isOnBattery: false), currentControls: Self.presetA.itemControls
        )
        #expect(restored.state == TriggerRuntimeState())
        #expect(restored.controls == Self.userControls)

        let again = TriggerEvaluator.step(
            state: restored.state, rules: [rule], presets: Self.presets,
            environment: Self.environment(isOnBattery: false), currentControls: Self.userControls
        )
        #expect(again.state == TriggerRuntimeState())
        #expect(again.controls == nil)
    }

    enum Removal: Sendable, CaseIterable {
        case ruleDeleted, presetDeleted, ruleDisabled, allRulesDeleted
    }

    @Test(arguments: Removal.allCases)
    func removingTheActiveRuleOrItsPresetRestoresTheBaseline(removal: Removal) {
        var rule = Self.rule("battery", [.onBattery])
        let active = TriggerRuntimeState(activeRuleID: rule.id, baselineControls: Self.userControls)
        var rules = [rule]
        var presets = Self.presets
        switch removal {
        case .ruleDeleted: rules = [Self.rule("other", [.charging])]
        case .presetDeleted: presets = [Self.presetB]
        case .ruleDisabled: rule.isEnabled = false; rules = [rule]
        case .allRulesDeleted: rules = []
        }
        let result = TriggerEvaluator.step(
            state: active, rules: rules, presets: presets,
            environment: Self.environment(isOnBattery: true), currentControls: Self.presetA.itemControls
        )
        #expect(result.state == TriggerRuntimeState())
        #expect(result.controls == Self.userControls)
    }

    @Test func deletingTheActiveRuleWhileAnotherHoldsSwitchesWithoutLosingTheBaseline() {
        let batteryRule = Self.rule("battery", [.onBattery])
        let powerRule = Self.rule("power", [.lowPowerMode], preset: Self.presetB)
        let active = TriggerRuntimeState(activeRuleID: batteryRule.id, baselineControls: Self.userControls)
        let result = TriggerEvaluator.step(
            state: active, rules: [powerRule], presets: Self.presets,
            environment: Self.environment(isOnBattery: true, lowPowerMode: true),
            currentControls: Self.presetA.itemControls
        )
        #expect(result.state == TriggerRuntimeState(activeRuleID: powerRule.id, baselineControls: Self.userControls))
        #expect(result.controls == Self.presetB.itemControls)
    }

    @Test func controlsEqualToTheCurrentArrangementAreNeverReturned() {
        let rule = Self.rule("battery", [.onBattery])
        let activation = TriggerEvaluator.step(
            state: TriggerRuntimeState(), rules: [rule], presets: Self.presets,
            environment: Self.environment(isOnBattery: true), currentControls: Self.presetA.itemControls
        )
        #expect(activation.state == TriggerRuntimeState(activeRuleID: rule.id, baselineControls: Self.presetA.itemControls))
        #expect(activation.controls == nil)

        let manuallyRestored = TriggerRuntimeState(activeRuleID: rule.id, baselineControls: Self.userControls)
        let release = TriggerEvaluator.step(
            state: manuallyRestored, rules: [rule], presets: Self.presets,
            environment: Self.environment(isOnBattery: false), currentControls: Self.userControls
        )
        #expect(release.state == TriggerRuntimeState())
        #expect(release.controls == nil)
    }

    @Test func partialStateIsRepairedWithoutInventingControls() {
        let rule = Self.rule("battery", [.onBattery])
        let baselineOnly = TriggerRuntimeState(activeRuleID: nil, baselineControls: Self.userControls)
        let restored = TriggerEvaluator.step(
            state: baselineOnly, rules: [rule], presets: Self.presets,
            environment: Self.environment(isOnBattery: false), currentControls: Self.presetA.itemControls
        )
        #expect(restored.state == TriggerRuntimeState())
        #expect(restored.controls == Self.userControls)

        let idOnly = TriggerRuntimeState(activeRuleID: UUID(), baselineControls: nil)
        let cleared = TriggerEvaluator.step(
            state: idOnly, rules: [rule], presets: Self.presets,
            environment: Self.environment(isOnBattery: false), currentControls: Self.userControls
        )
        #expect(cleared.state == TriggerRuntimeState())
        #expect(cleared.controls == nil)

        // A baseline-only state that now matches a rule keeps that baseline for the later restore.
        let adopted = TriggerEvaluator.step(
            state: baselineOnly, rules: [rule], presets: Self.presets,
            environment: Self.environment(isOnBattery: true), currentControls: ItemControlStore()
        )
        #expect(adopted.state == TriggerRuntimeState(activeRuleID: rule.id, baselineControls: Self.userControls))
        #expect(adopted.controls == Self.presetA.itemControls)
    }

    // MARK: - Codable

    static let everyCondition: [TriggerCondition] = [
        .onBattery, .charging, .batteryBelow(percent: 35), .lowPowerMode, .wifiConnected(false),
        .frontmostApp(bundleID: "com.apple.Safari"), .externalDisplayConnected(true),
        .timeOfDay(startMinute: 22 * 60, endMinute: 90, weekdays: [7, 1, 3])
    ]

    @Test func rulesStateAndEveryConditionRoundTrip() throws {
        let rule = TriggerRule(
            id: UUID(), name: "Everything", isEnabled: false, conditions: Self.everyCondition, presetID: Self.presetB.id
        )
        let decodedRule = try JSONDecoder().decode(TriggerRule.self, from: JSONEncoder().encode(rule))
        #expect(decodedRule == rule)

        let state = TriggerRuntimeState(activeRuleID: rule.id, baselineControls: Self.userControls)
        let decodedState = try JSONDecoder().decode(TriggerRuntimeState.self, from: JSONEncoder().encode(state))
        #expect(decodedState == state)
        #expect(decodedState.hashValue == state.hashValue)
        let empty = try JSONDecoder().decode(TriggerRuntimeState.self, from: JSONEncoder().encode(TriggerRuntimeState()))
        #expect(empty == TriggerRuntimeState())
        #expect(!empty.isActive)
        #expect(state.isActive)
    }

    @Test func jsonKeysAndTypeNamesAreStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let rule = TriggerRule(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "Keys", isEnabled: true,
            conditions: Self.everyCondition, presetID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(rule)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "isEnabled", "conditions", "presetID"])
        #expect(object["id"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(object["presetID"] as? String == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let conditions = try #require(object["conditions"] as? [[String: Any]])
        #expect(conditions.map { $0["type"] as? String } == [
            "onBattery", "charging", "batteryBelow", "lowPowerMode", "wifiConnected",
            "frontmostApp", "externalDisplayConnected", "timeOfDay"
        ])
        #expect(Set(conditions[0].keys) == ["type"])
        #expect(conditions[2]["percent"] as? Int == 35)
        #expect(conditions[4]["connected"] as? Bool == false)
        #expect(conditions[5]["bundleID"] as? String == "com.apple.Safari")
        #expect(conditions[6]["connected"] as? Bool == true)
        #expect(Set(conditions[7].keys) == ["type", "startMinute", "endMinute", "weekdays"])
        #expect(conditions[7]["startMinute"] as? Int == 1320)
        #expect(conditions[7]["endMinute"] as? Int == 90)
        #expect(conditions[7]["weekdays"] as? [Int] == [1, 3, 7])

        let state = TriggerRuntimeState(activeRuleID: rule.id, baselineControls: ItemControlStore(hiddenInMenuBar: ["ACME"]))
        let stateObject = try #require(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        #expect(Set(stateObject.keys) == ["activeRuleID", "baselineControls"])
        let baseline = try #require(stateObject["baselineControls"] as? [String: Any])
        #expect(baseline["hiddenInMenuBar"] as? [String] == ["ACME"])
        let emptyObject = try #require(JSONSerialization.jsonObject(with: encoder.encode(TriggerRuntimeState())) as? [String: Any])
        #expect(emptyObject.isEmpty)
    }

    @Test func weekdaysEncodeSortedRegardlessOfInsertionOrder() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let ascending = try encoder.encode(TriggerCondition.timeOfDay(startMinute: 0, endMinute: 60, weekdays: Set([1, 4, 6])))
        let descending = try encoder.encode(TriggerCondition.timeOfDay(startMinute: 0, endMinute: 60, weekdays: Set([6, 4, 1])))
        #expect(ascending == descending)
    }

    @Test func unknownConditionTypeThrowsADedicatedError() throws {
        let json = Data(#"{"type":"teleport","distance":3}"#.utf8)
        #expect(throws: TriggerConditionDecodingError.unknownType("teleport")) {
            try JSONDecoder().decode(TriggerCondition.self, from: json)
        }
        let missingParameter = Data(#"{"type":"batteryBelow"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TriggerCondition.self, from: missingParameter)
        }
    }

    @Test func lossyArrayDropsOnlyUnreadableRules() throws {
        let good = Self.rule("good", [.onBattery])
        let alsoGood = Self.rule("also good", [.timeOfDay(startMinute: 60, endMinute: 120, weekdays: [1, 2])], preset: Self.presetB)
        let encoder = JSONEncoder()
        let goodJSON = String(decoding: try encoder.encode(good), as: UTF8.self)
        let alsoGoodJSON = String(decoding: try encoder.encode(alsoGood), as: UTF8.self)
        let unknownCondition = #"{"id":"\#(UUID().uuidString)","name":"future","isEnabled":true,"conditions":[{"type":"onBattery"},{"type":"teleport"}],"presetID":"\#(Self.presetA.id.uuidString)"}"#
        let missingPreset = #"{"id":"\#(UUID().uuidString)","name":"no preset","isEnabled":true,"conditions":[{"type":"onBattery"}]}"#
        let json = Data("[\(goodJSON), \(unknownCondition), 7, \(missingPreset), \(alsoGoodJSON)]".utf8)

        let lossy = try JSONDecoder().decode(TriggerRule.LossyArray.self, from: json)
        #expect(lossy.rules == [good, alsoGood])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([TriggerRule].self, from: json)
        }
        #expect(try JSONDecoder().decode(TriggerRule.LossyArray.self, from: Data("[]".utf8)).rules.isEmpty)
    }

    @Test func rulesDecodeLenientlyExceptForThePresetAndConditions() throws {
        let minimal = Data(#"{"presetID":"\#(Self.presetA.id.uuidString)"}"#.utf8)
        let decoded = try JSONDecoder().decode(TriggerRule.self, from: minimal)
        #expect(decoded.name == "")
        #expect(decoded.isEnabled)
        #expect(decoded.conditions.isEmpty)
        #expect(decoded.presetID == Self.presetA.id)
        #expect(decoded.validationIssue(presetExists: true) == .emptyName)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TriggerRule.self, from: Data(#"{"name":"no preset"}"#.utf8))
        }
    }

    @Test func runtimeStateDecodesCorruptFieldsAsEmpty() throws {
        let corrupt = Data(#"{"activeRuleID":"not-a-uuid","baselineControls":"nope"}"#.utf8)
        #expect(try JSONDecoder().decode(TriggerRuntimeState.self, from: corrupt) == TriggerRuntimeState())
        #expect(try JSONDecoder().decode(TriggerRuntimeState.self, from: Data("{}".utf8)) == TriggerRuntimeState())
        let partial = Data(#"{"baselineControls":{"hiddenInMenuBar":["ACME"]}}"#.utf8)
        let decoded = try JSONDecoder().decode(TriggerRuntimeState.self, from: partial)
        #expect(decoded.activeRuleID == nil)
        #expect(decoded.baselineControls == ItemControlStore(hiddenInMenuBar: ["ACME"]))
    }

    // MARK: - Validation and display

    @Test func validationReportsTheFirstBlockingIssue() {
        let valid = Self.rule("ok", [.onBattery, .timeOfDay(startMinute: 0, endMinute: 60, weekdays: [1])])
        #expect(valid.validationIssue(presetExists: true) == nil)
        #expect(valid.validationIssue(presetExists: false) == .missingPreset)
        #expect(Self.rule("  ", [.onBattery]).validationIssue(presetExists: true) == .emptyName)
        #expect(Self.rule("none", []).validationIssue(presetExists: true) == .noConditions)
        #expect(Self.rule("pct", [.batteryBelow(percent: 0)]).validationIssue(presetExists: true) == .invalidPercent)
        #expect(Self.rule("pct", [.batteryBelow(percent: 101)]).validationIssue(presetExists: true) == .invalidPercent)
        #expect(Self.rule("app", [.frontmostApp(bundleID: " ")]).validationIssue(presetExists: true) == .emptyBundleID)
        #expect(Self.rule("days", [.timeOfDay(startMinute: 0, endMinute: 60, weekdays: [9])]).validationIssue(presetExists: true) == .noWeekdays)
        #expect(Self.rule("time", [.timeOfDay(startMinute: 0, endMinute: 1440, weekdays: [1])]).validationIssue(presetExists: true) == .invalidTime)
        #expect(Self.rule("order", [.onBattery, .frontmostApp(bundleID: ""), .batteryBelow(percent: 500)]).validationIssue(presetExists: true) == .emptyBundleID)
        for issue in [TriggerRuleValidationIssue.emptyName, .missingPreset, .noConditions, .invalidPercent, .emptyBundleID, .noWeekdays, .invalidTime] {
            #expect(!issue.message.isEmpty)
        }
    }

    @Test func displayTextSummarizesEachCondition() {
        #expect(TriggerCondition.onBattery.displayText == "On battery power")
        #expect(TriggerCondition.charging.displayText == "Charging")
        #expect(TriggerCondition.batteryBelow(percent: 20).displayText == "Battery below 20%")
        #expect(TriggerCondition.lowPowerMode.displayText == "Low Power Mode on")
        #expect(TriggerCondition.wifiConnected(true).displayText == "Wi-Fi connected")
        #expect(TriggerCondition.wifiConnected(false).displayText == "Wi-Fi not connected")
        #expect(TriggerCondition.frontmostApp(bundleID: "us.zoom.xos").displayText == "Frontmost app is us.zoom.xos")
        #expect(TriggerCondition.frontmostApp(bundleID: "").displayText == "Frontmost app is not set")
        #expect(TriggerCondition.externalDisplayConnected(true).displayText == "External display connected")
        #expect(TriggerCondition.externalDisplayConnected(false).displayText == "No external display")
        #expect(TriggerCondition.timeOfDay(startMinute: 9 * 60, endMinute: 17 * 60 + 5, weekdays: [2, 3, 4, 5, 6]).displayText == "Weekdays, 09:00\u{2013}17:05")
        #expect(TriggerCondition.timeOfDay(startMinute: 22 * 60, endMinute: 6 * 60, weekdays: [1, 2, 3, 4, 5, 6, 7]).displayText == "Every day, 22:00\u{2013}06:00")
        #expect(TriggerCondition.timeOfDay(startMinute: 0, endMinute: 0, weekdays: [7, 1]).displayText == "Weekends, all day")
        #expect(TriggerCondition.timeOfDay(startMinute: 0, endMinute: 30, weekdays: [3, 1, 9]).displayText == "Sun, Tue, 00:00\u{2013}00:30")
        #expect(TriggerCondition.timeOfDay(startMinute: 0, endMinute: 30, weekdays: []).displayText == "No days selected, 00:00\u{2013}00:30")
        for kind in TriggerCondition.Kind.allCases {
            #expect(TriggerCondition.defaultCondition(for: kind).kind == kind)
            #expect(!kind.displayName.isEmpty)
        }
        #expect(TriggerCondition.defaultCondition(for: .timeOfDay) == .timeOfDay(startMinute: 540, endMinute: 1020, weekdays: [2, 3, 4, 5, 6]))
    }

    @Test func conditionsSummaryJoinsEveryConditionInOrder() {
        #expect(Self.rule("none", []).conditionsSummary == "No conditions")
        #expect(Self.rule("one", [.onBattery]).conditionsSummary == "On battery power")
        #expect(Self.rule("two", [.wifiConnected(false), .batteryBelow(percent: 30)]).conditionsSummary
                == "Wi-Fi not connected and Battery below 30%")
    }

    // MARK: - Library

    @Test func upsertingReplacesInPlaceAppendsTrimmedAndRespectsTheCap() {
        let first = Self.rule("first", [.onBattery])
        let second = Self.rule("second", [.charging], preset: Self.presetB)
        var renamed = first
        renamed.name = "  renamed  "
        renamed.isEnabled = false

        let replaced = TriggerRuleLibrary.upserting(renamed, in: [first, second])
        #expect(replaced.map(\.id) == [first.id, second.id])
        #expect(replaced[0].name == "renamed")
        #expect(!replaced[0].isEnabled)
        #expect(replaced[1] == second)

        let appended = TriggerRuleLibrary.upserting(Self.rule(" new ", [.lowPowerMode]), in: [first])
        #expect(appended.count == 2)
        #expect(appended[1].name == "new")
        #expect(appended[1].conditions == [.lowPowerMode])

        let full = (0..<TriggerRuleLibrary.maxRules).map { Self.rule("rule \($0)", [.onBattery]) }
        #expect(TriggerRuleLibrary.upserting(Self.rule("overflow", [.onBattery]), in: full) == full)
        let editedFull = TriggerRuleLibrary.upserting(renamed, in: [first] + full.dropFirst())
        #expect(editedFull.count == full.count)
        #expect(editedFull[0].name == "renamed")
    }

    @Test func removingAndEnablingTouchOnlyTheAddressedRule() {
        let first = Self.rule("first", [.onBattery])
        let second = Self.rule("second", [.charging], preset: Self.presetB)
        #expect(TriggerRuleLibrary.removing(id: first.id, from: [first, second]) == [second])
        #expect(TriggerRuleLibrary.removing(id: UUID(), from: [first, second]) == [first, second])

        let disabled = TriggerRuleLibrary.settingEnabled(false, id: second.id, in: [first, second])
        #expect(disabled[0] == first)
        #expect(disabled[1].id == second.id)
        #expect(!disabled[1].isEnabled)
        #expect(TriggerRuleLibrary.settingEnabled(true, id: second.id, in: disabled) == [first, second])
        #expect(TriggerRuleLibrary.settingEnabled(false, id: UUID(), in: [first, second]) == [first, second])
    }
}
