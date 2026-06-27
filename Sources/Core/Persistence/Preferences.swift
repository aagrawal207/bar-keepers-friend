import Foundation

/// User-facing settings, persisted as Codable JSON. Kept as a plain value type so a
/// round-trip through `encode` / `decode` is unit-testable and so defaults are explicit.
public struct Preferences: Equatable, Sendable, Codable {

    /// Whether the hidden section auto-recollapses after being revealed.
    public var autoRehide: Bool

    /// Seconds before auto-rehide fires (when `autoRehide` is on).
    public var autoRehideDelay: TimeInterval

    /// Show a small glyph for each divider so the user can see the boundaries.
    public var showSectionDividers: Bool

    /// Launch the app at login.
    public var launchAtLogin: Bool

    /// When revealing hidden items, show them in a floating bar below the menu bar instead
    /// of expanding them back into the (possibly too-narrow) menu bar.
    public var useFloatingBar: Bool

    /// The floating bar's presentation.
    public var floatingBarStyle: FloatingBarStyle

    /// Persisted on-screen positions of the control items, keyed by autosave name. This
    /// mirrors the values AppKit stores under "NSStatusItem Preferred Position <name>";
    /// we cache them ourselves because removing a status item deletes AppKit's copy.
    public var controlItemPositions: [String: Double]

    public init(
        autoRehide: Bool = true,
        autoRehideDelay: TimeInterval = 15,
        showSectionDividers: Bool = false,
        launchAtLogin: Bool = false,
        useFloatingBar: Bool = true,
        floatingBarStyle: FloatingBarStyle = .horizontal,
        controlItemPositions: [String: Double] = [:]
    ) {
        self.autoRehide = autoRehide
        self.autoRehideDelay = autoRehideDelay
        self.showSectionDividers = showSectionDividers
        self.launchAtLogin = launchAtLogin
        self.useFloatingBar = useFloatingBar
        self.floatingBarStyle = floatingBarStyle
        self.controlItemPositions = controlItemPositions
    }

    public static let `default` = Preferences()

    // Explicit keys so renaming a Swift property never silently drops stored data.
    enum CodingKeys: String, CodingKey {
        case autoRehide
        case autoRehideDelay
        case showSectionDividers
        case launchAtLogin
        case useFloatingBar
        case floatingBarStyle
        case controlItemPositions
    }

    /// Decodes leniently: any missing key falls back to its default, so adding a new
    /// preference never fails to load an older saved file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.default
        autoRehide = try container.decodeIfPresent(Bool.self, forKey: .autoRehide) ?? d.autoRehide
        autoRehideDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .autoRehideDelay) ?? d.autoRehideDelay
        showSectionDividers = try container.decodeIfPresent(Bool.self, forKey: .showSectionDividers) ?? d.showSectionDividers
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        useFloatingBar = try container.decodeIfPresent(Bool.self, forKey: .useFloatingBar) ?? d.useFloatingBar
        floatingBarStyle = try container.decodeIfPresent(FloatingBarStyle.self, forKey: .floatingBarStyle) ?? d.floatingBarStyle
        controlItemPositions = try container.decodeIfPresent([String: Double].self, forKey: .controlItemPositions) ?? d.controlItemPositions
    }
}
