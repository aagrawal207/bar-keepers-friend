import Foundation

// MARK: - Conditions

/// One environmental fact a trigger rule waits for. All of a rule's conditions must hold.
public enum TriggerCondition: Hashable, Codable, Sendable {
    case onBattery
    case charging
    case batteryBelow(percent: Int)
    case lowPowerMode
    case wifiConnected(Bool)
    case frontmostApp(bundleID: String)
    case externalDisplayConnected(Bool)
    /// `weekdays` uses Calendar numbering (1 = Sunday ... 7 = Saturday). A range whose end is
    /// before its start wraps past midnight; equal start and end means the whole day.
    case timeOfDay(startMinute: Int, endMinute: Int, weekdays: Set<Int>)

    public static let minutesPerDay = 24 * 60
    public static let minuteRange = 0...(minutesPerDay - 1)
    public static let percentRange = 1...100
    public static let weekdayRange = 1...7

    /// Persisted discriminator. The raw values are on-disk keys; never rename them.
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        case onBattery
        case charging
        case batteryBelow
        case lowPowerMode
        case wifiConnected
        case frontmostApp
        case externalDisplayConnected
        case timeOfDay

        public var displayName: String {
            switch self {
            case .onBattery: return "On battery"
            case .charging: return "Charging"
            case .batteryBelow: return "Battery below"
            case .lowPowerMode: return "Low Power Mode"
            case .wifiConnected: return "Wi-Fi"
            case .frontmostApp: return "Frontmost app"
            case .externalDisplayConnected: return "External display"
            case .timeOfDay: return "Time of day"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .onBattery: return .onBattery
        case .charging: return .charging
        case .batteryBelow: return .batteryBelow
        case .lowPowerMode: return .lowPowerMode
        case .wifiConnected: return .wifiConnected
        case .frontmostApp: return .frontmostApp
        case .externalDisplayConnected: return .externalDisplayConnected
        case .timeOfDay: return .timeOfDay
        }
    }

    /// A sensible starting value for a freshly added condition of `kind`.
    public static func defaultCondition(for kind: Kind) -> TriggerCondition {
        switch kind {
        case .onBattery: return .onBattery
        case .charging: return .charging
        case .batteryBelow: return .batteryBelow(percent: 20)
        case .lowPowerMode: return .lowPowerMode
        case .wifiConnected: return .wifiConnected(true)
        case .frontmostApp: return .frontmostApp(bundleID: "")
        case .externalDisplayConnected: return .externalDisplayConnected(true)
        case .timeOfDay: return .timeOfDay(startMinute: 9 * 60, endMinute: 17 * 60, weekdays: [2, 3, 4, 5, 6])
        }
    }

    /// Short human-readable summary for lists and previews. Bundle identifiers are shown raw;
    /// Core has no way to resolve app names.
    public var displayText: String {
        switch self {
        case .onBattery:
            return "On battery power"
        case .charging:
            return "Charging"
        case let .batteryBelow(percent):
            return "Battery below \(percent)%"
        case .lowPowerMode:
            return "Low Power Mode on"
        case let .wifiConnected(connected):
            return connected ? "Wi-Fi connected" : "Wi-Fi not connected"
        case let .frontmostApp(bundleID):
            return bundleID.isEmpty ? "Frontmost app is not set" : "Frontmost app is \(bundleID)"
        case let .externalDisplayConnected(connected):
            return connected ? "External display connected" : "No external display"
        case let .timeOfDay(start, end, weekdays):
            let days = Self.weekdaysText(weekdays)
            if start == end { return "\(days), all day" }
            return "\(days), \(Self.clockText(start))\u{2013}\(Self.clockText(end))"
        }
    }

    public static func clockText(_ minuteOfDay: Int) -> String {
        let minute = min(max(minuteOfDay, minuteRange.lowerBound), minuteRange.upperBound)
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    public static let weekdayShortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    public static func weekdaysText(_ weekdays: Set<Int>) -> String {
        let days = weekdays.filter(weekdayRange.contains).sorted()
        switch days {
        case []: return "No days selected"
        case [1, 2, 3, 4, 5, 6, 7]: return "Every day"
        case [2, 3, 4, 5, 6]: return "Weekdays"
        case [1, 7]: return "Weekends"
        default: return days.map { weekdayShortNames[$0 - 1] }.joined(separator: ", ")
        }
    }

    // MARK: Evaluation

    /// Unknown (`nil`) facts never satisfy a condition, so a rule cannot fire on a guess.
    public func holds(in environment: TriggerEnvironment) -> Bool {
        switch self {
        case .onBattery:
            return environment.isOnBattery == true
        case .charging:
            return environment.isCharging == true
        case let .batteryBelow(percent):
            guard let level = environment.batteryPercent else { return false }
            return level < percent
        case .lowPowerMode:
            return environment.lowPowerMode
        case let .wifiConnected(connected):
            return environment.wifiConnected == connected
        case let .frontmostApp(bundleID):
            guard let frontmost = environment.frontmostBundleID, !bundleID.isEmpty else { return false }
            return frontmost.caseInsensitiveCompare(bundleID) == .orderedSame
        case let .externalDisplayConnected(connected):
            return environment.externalDisplayConnected == connected
        case let .timeOfDay(start, end, weekdays):
            return Self.timeOfDayHolds(
                startMinute: start, endMinute: end, weekdays: weekdays,
                weekday: environment.weekday, minuteOfDay: environment.minuteOfDay
            )
        }
    }

    /// End is exclusive. A wrapping range covers `start` to midnight on a selected day plus
    /// midnight to `end` on the following day, so a Monday night rule still holds at 01:00 Tuesday.
    public static func timeOfDayHolds(
        startMinute: Int, endMinute: Int, weekdays: Set<Int>, weekday: Int, minuteOfDay: Int
    ) -> Bool {
        let days = weekdays.filter(weekdayRange.contains)
        guard !days.isEmpty, weekdayRange.contains(weekday) else { return false }
        let start = min(max(startMinute, minuteRange.lowerBound), minuteRange.upperBound)
        let end = min(max(endMinute, minuteRange.lowerBound), minuteRange.upperBound)
        let today = days.contains(weekday)
        if start == end { return today }
        if start < end { return today && minuteOfDay >= start && minuteOfDay < end }
        let yesterday = days.contains((weekday + 5) % 7 + 1)
        return (today && minuteOfDay >= start) || (yesterday && minuteOfDay < end)
    }

    // MARK: Codable

    // On-disk key names; renaming a Swift label must not change these.
    enum CodingKeys: String, CodingKey {
        case type
        case percent
        case connected
        case bundleID
        case startMinute
        case endMinute
        case weekdays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: rawType) else {
            throw TriggerConditionDecodingError.unknownType(rawType)
        }
        switch kind {
        case .onBattery:
            self = .onBattery
        case .charging:
            self = .charging
        case .batteryBelow:
            self = .batteryBelow(percent: try container.decode(Int.self, forKey: .percent))
        case .lowPowerMode:
            self = .lowPowerMode
        case .wifiConnected:
            self = .wifiConnected(try container.decode(Bool.self, forKey: .connected))
        case .frontmostApp:
            self = .frontmostApp(bundleID: try container.decode(String.self, forKey: .bundleID))
        case .externalDisplayConnected:
            self = .externalDisplayConnected(try container.decode(Bool.self, forKey: .connected))
        case .timeOfDay:
            self = .timeOfDay(
                startMinute: try container.decode(Int.self, forKey: .startMinute),
                endMinute: try container.decode(Int.self, forKey: .endMinute),
                weekdays: Set(try container.decode([Int].self, forKey: .weekdays))
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .onBattery, .charging, .lowPowerMode:
            break
        case let .batteryBelow(percent):
            try container.encode(percent, forKey: .percent)
        case let .wifiConnected(connected), let .externalDisplayConnected(connected):
            try container.encode(connected, forKey: .connected)
        case let .frontmostApp(bundleID):
            try container.encode(bundleID, forKey: .bundleID)
        case let .timeOfDay(start, end, weekdays):
            try container.encode(start, forKey: .startMinute)
            try container.encode(end, forKey: .endMinute)
            // Sorted so an unchanged rule re-exports byte-identically.
            try container.encode(weekdays.sorted(), forKey: .weekdays)
        }
    }
}

/// Thrown for a `type` this build does not know, so a lossy array decoder can drop just that rule
/// instead of failing the whole preferences file.
public enum TriggerConditionDecodingError: Error, Equatable, Sendable {
    case unknownType(String)
}

// MARK: - Rules

/// Applies the preset `presetID` while every condition holds. Rules are evaluated in array order;
/// the first enabled match wins.
public struct TriggerRule: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var conditions: [TriggerCondition]
    public var presetID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        conditions: [TriggerCondition],
        presetID: UUID
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.presetID = presetID
    }

    /// A rule with no conditions never holds; vacuous truth would pin a preset forever.
    public func holds(in environment: TriggerEnvironment) -> Bool {
        !conditions.isEmpty && conditions.allSatisfy { $0.holds(in: environment) }
    }

    public var conditionKinds: Set<TriggerCondition.Kind> {
        Set(conditions.map(\.kind))
    }

    /// One line for lists: every condition's `displayText` joined, since all of them must hold.
    public var conditionsSummary: String {
        conditions.isEmpty ? "No conditions" : conditions.map(\.displayText).joined(separator: " and ")
    }

    public func validationIssue(presetExists: Bool) -> TriggerRuleValidationIssue? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        if !presetExists { return .missingPreset }
        if conditions.isEmpty { return .noConditions }
        for condition in conditions {
            switch condition {
            case let .batteryBelow(percent) where !TriggerCondition.percentRange.contains(percent):
                return .invalidPercent
            case let .frontmostApp(bundleID) where bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                return .emptyBundleID
            case let .timeOfDay(start, end, weekdays):
                if weekdays.filter(TriggerCondition.weekdayRange.contains).isEmpty { return .noWeekdays }
                if !TriggerCondition.minuteRange.contains(start) || !TriggerCondition.minuteRange.contains(end) {
                    return .invalidTime
                }
            default:
                break
            }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case conditions
        case presetID
    }

    /// `presetID` and every condition must decode; the rest fall back so a partially edited rule
    /// still loads. A rule whose conditions are unreadable is dropped by `LossyArray`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        conditions = try container.decodeIfPresent([TriggerCondition].self, forKey: .conditions) ?? []
        presetID = try container.decode(UUID.self, forKey: .presetID)
    }

    /// Decodes `[TriggerRule]` keeping every readable element, so one rule written by a newer build
    /// cannot take the rest of the user's rules down with it.
    public struct LossyArray: Decodable, Sendable {
        public var rules: [TriggerRule]

        public init(rules: [TriggerRule]) {
            self.rules = rules
        }

        public init(from decoder: Decoder) throws {
            rules = try [Element](from: decoder).compactMap(\.rule)
        }

        private struct Element: Decodable {
            let rule: TriggerRule?

            init(from decoder: Decoder) throws {
                rule = try? TriggerRule(from: decoder)
            }
        }
    }
}

public enum TriggerRuleValidationIssue: Equatable, Sendable {
    case emptyName
    case missingPreset
    case noConditions
    case invalidPercent
    case emptyBundleID
    case noWeekdays
    case invalidTime

    public var message: String {
        switch self {
        case .emptyName: return "Enter a name for this rule."
        case .missingPreset: return "Choose a preset to apply."
        case .noConditions: return "Add at least one condition."
        case .invalidPercent: return "Battery percentage must be between 1 and 100."
        case .emptyBundleID: return "Enter the app's bundle identifier."
        case .noWeekdays: return "Select at least one day."
        case .invalidTime: return "Times must fall within one day."
        }
    }
}

/// Pure edits to a rule list, so a Settings action is one array in, one array out, one save.
public enum TriggerRuleLibrary {
    public static let maxRules = 50

    /// Replaces the rule with the same id in place, or appends a new one (names are trimmed).
    /// Unchanged when the list is full and the rule is new.
    public static func upserting(_ rule: TriggerRule, in rules: [TriggerRule]) -> [TriggerRule] {
        var saved = rule
        saved.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) {
            updated[index] = saved
        } else if updated.count < maxRules {
            updated.append(saved)
        }
        return updated
    }

    public static func removing(id: UUID, from rules: [TriggerRule]) -> [TriggerRule] {
        rules.filter { $0.id != id }
    }

    /// Unchanged when `id` is unknown.
    public static func settingEnabled(_ enabled: Bool, id: UUID, in rules: [TriggerRule]) -> [TriggerRule] {
        rules.map { rule in
            guard rule.id == id else { return rule }
            var updated = rule
            updated.isEnabled = enabled
            return updated
        }
    }
}

// MARK: - Environment

/// A point-in-time snapshot of everything conditions can depend on. `nil` means the fact could
/// not be read; conditions treat that as not holding.
public struct TriggerEnvironment: Hashable, Sendable {
    public var isOnBattery: Bool?
    public var isCharging: Bool?
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    public var wifiConnected: Bool?
    public var frontmostBundleID: String?
    public var externalDisplayConnected: Bool
    public var now: Date
    /// Supplies the time zone and weekday numbering, so evaluation is reproducible anywhere.
    public var calendar: Calendar

    public init(
        isOnBattery: Bool? = nil,
        isCharging: Bool? = nil,
        batteryPercent: Int? = nil,
        lowPowerMode: Bool = false,
        wifiConnected: Bool? = nil,
        frontmostBundleID: String? = nil,
        externalDisplayConnected: Bool = false,
        now: Date,
        calendar: Calendar
    ) {
        self.isOnBattery = isOnBattery
        self.isCharging = isCharging
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.wifiConnected = wifiConnected
        self.frontmostBundleID = frontmostBundleID
        self.externalDisplayConnected = externalDisplayConnected
        self.now = now
        self.calendar = calendar
    }

    /// Calendar weekday of `now` (1 = Sunday ... 7 = Saturday) in `calendar`'s time zone.
    public var weekday: Int {
        calendar.component(.weekday, from: now)
    }

    /// Minutes since local midnight in `calendar`'s time zone.
    public var minuteOfDay: Int {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

// MARK: - Runtime state

/// What the evaluator has done so far: which rule currently owns the arrangement and what to put
/// back once no rule holds. Persisted so a restart mid-trigger still restores the baseline.
public struct TriggerRuntimeState: Hashable, Codable, Sendable {
    public var activeRuleID: UUID?
    public var baselineControls: ItemControlStore?

    public init(activeRuleID: UUID? = nil, baselineControls: ItemControlStore? = nil) {
        self.activeRuleID = activeRuleID
        self.baselineControls = baselineControls
    }

    public var isActive: Bool { activeRuleID != nil }

    enum CodingKeys: String, CodingKey {
        case activeRuleID
        case baselineControls
    }

    /// Never fails on field contents: a corrupt runtime state must not take Preferences down.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeRuleID = (try? container.decodeIfPresent(UUID.self, forKey: .activeRuleID)) ?? nil
        baselineControls = (try? container.decodeIfPresent(ItemControlStore.self, forKey: .baselineControls)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(activeRuleID, forKey: .activeRuleID)
        try container.encodeIfPresent(baselineControls, forKey: .baselineControls)
    }

    // ItemControlStore is Equatable but not necessarily Hashable; hash its components directly.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(activeRuleID)
        hasher.combine(baselineControls?.hiddenInMenuBar)
        hasher.combine(baselineControls?.shownInMenuBar)
        hasher.combine(baselineControls?.suppressedFromBar)
        hasher.combine(baselineControls?.barOrder)
    }
}

// MARK: - Evaluator

/// Pure decision logic. Callers apply the returned controls and persist the returned state.
public enum TriggerEvaluator {

    /// The first enabled rule, in array order, whose conditions all hold. A rule pointing at a
    /// deleted preset is skipped as if disabled.
    public static func matchingRule(
        rules: [TriggerRule],
        presets: [LayoutPreset],
        environment: TriggerEnvironment
    ) -> TriggerRule? {
        let presetIDs = Set(presets.map(\.id))
        return rules.first { rule in
            rule.isEnabled && presetIDs.contains(rule.presetID) && rule.holds(in: environment)
        }
    }

    /// Advances the state for one reading. Returns the controls to apply, or `nil` when nothing changes;
    /// the baseline is captured once at first activation and kept across switches for the final restore.
    public static func step(
        state: TriggerRuntimeState,
        rules: [TriggerRule],
        presets: [LayoutPreset],
        environment: TriggerEnvironment,
        currentControls: ItemControlStore
    ) -> (state: TriggerRuntimeState, controls: ItemControlStore?) {
        if let match = matchingRule(rules: rules, presets: presets, environment: environment),
           let preset = presets.first(where: { $0.id == match.presetID }) {
            guard state.activeRuleID != match.id else { return (state, nil) }
            var next = state
            next.activeRuleID = match.id
            if next.baselineControls == nil { next.baselineControls = currentControls }
            return (next, differing(preset.itemControls, from: currentControls))
        }
        guard state.activeRuleID != nil || state.baselineControls != nil else { return (state, nil) }
        let restored = state.baselineControls.flatMap { differing($0, from: currentControls) }
        return (TriggerRuntimeState(), restored)
    }

    private static func differing(_ controls: ItemControlStore, from current: ItemControlStore) -> ItemControlStore? {
        controls == current ? nil : controls
    }
}
