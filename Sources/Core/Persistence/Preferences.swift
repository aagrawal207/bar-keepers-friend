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

    /// Try Accessibility press (AXPress) before the synthesized click. Off by default: most
    /// status items advertise AXPress but don't implement it (returns ActionUnsupported), so
    /// trying it first only adds latency. Kept as a compatibility escape hatch for items that
    /// genuinely open via AXShowMenu.
    public var useAXActivation: Bool

    /// Persisted on-screen positions of the control items, keyed by autosave name. This
    /// mirrors the values AppKit stores under "NSStatusItem Preferred Position <name>";
    /// we cache them ourselves because removing a status item deletes AppKit's copy.
    public var controlItemPositions: [String: Double]

    // MARK: - Global hotkey (toggle the floating bar)

    /// Whether the global keyboard shortcut to toggle the floating bar is active.
    public var enableGlobalHotkey: Bool

    /// The toggle-bar shortcut. `keyCode` is a virtual key code (`kVK_*`); `modifiers` is an
    /// `NSEvent.ModifierFlags` raw value (device-independent flags only). Default ⌥⌘B.
    public var toggleHotkey: HotkeyCombo

    // MARK: - Search

    /// Whether the fuzzy search panel (and its shortcut) is enabled.
    public var enableSearch: Bool

    /// The shortcut that opens the search panel. Default ⌥⌘F.
    public var searchHotkey: HotkeyCombo

    /// User-chosen searchable aliases for menu bar items, keyed by owning-app identity. Lets the
    /// user find an item by a nickname — valuable on Tahoe where the real title is often the
    /// generic "Item-0". Persisted with the rest of preferences.
    public var itemAliases: ItemAliasStore

    // MARK: - Hover to reveal

    /// Reveal the floating bar when the pointer hovers over the menu bar anchor, without a
    /// click (Bartender-style). Off by default — opt-in, since it can surprise users.
    public var hoverToReveal: Bool

    /// Seconds the pointer must dwell over the anchor before the bar reveals on hover.
    public var hoverRevealDelay: TimeInterval

    // MARK: - Floating bar behavior

    /// Dismiss the floating bar automatically when the pointer leaves it (Bartender-style).
    /// On by default — a quick-glance bar shouldn't linger once the user moves away.
    public var dismissBarOnMouseExit: Bool

    public init(
        autoRehide: Bool = true,
        autoRehideDelay: TimeInterval = 15,
        showSectionDividers: Bool = false,
        launchAtLogin: Bool = false,
        useFloatingBar: Bool = true,
        floatingBarStyle: FloatingBarStyle = .horizontal,
        useAXActivation: Bool = false,
        controlItemPositions: [String: Double] = [:],
        enableGlobalHotkey: Bool = true,
        toggleHotkey: HotkeyCombo = .defaultToggle,
        enableSearch: Bool = true,
        searchHotkey: HotkeyCombo = .defaultSearch,
        itemAliases: ItemAliasStore = ItemAliasStore(),
        hoverToReveal: Bool = false,
        hoverRevealDelay: TimeInterval = 0.25,
        dismissBarOnMouseExit: Bool = true
    ) {
        self.autoRehide = autoRehide
        self.autoRehideDelay = autoRehideDelay
        self.showSectionDividers = showSectionDividers
        self.launchAtLogin = launchAtLogin
        self.useFloatingBar = useFloatingBar
        self.floatingBarStyle = floatingBarStyle
        self.useAXActivation = useAXActivation
        self.controlItemPositions = controlItemPositions
        self.enableGlobalHotkey = enableGlobalHotkey
        self.toggleHotkey = toggleHotkey
        self.enableSearch = enableSearch
        self.searchHotkey = searchHotkey
        self.itemAliases = itemAliases
        self.hoverToReveal = hoverToReveal
        self.hoverRevealDelay = hoverRevealDelay
        self.dismissBarOnMouseExit = dismissBarOnMouseExit
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
        case useAXActivation
        case controlItemPositions
        case enableGlobalHotkey
        case toggleHotkey
        case enableSearch
        case searchHotkey
        case itemAliases
        case hoverToReveal
        case hoverRevealDelay
        case dismissBarOnMouseExit
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
        useAXActivation = try container.decodeIfPresent(Bool.self, forKey: .useAXActivation) ?? d.useAXActivation
        controlItemPositions = try container.decodeIfPresent([String: Double].self, forKey: .controlItemPositions) ?? d.controlItemPositions
        enableGlobalHotkey = try container.decodeIfPresent(Bool.self, forKey: .enableGlobalHotkey) ?? d.enableGlobalHotkey
        toggleHotkey = try container.decodeIfPresent(HotkeyCombo.self, forKey: .toggleHotkey) ?? d.toggleHotkey
        enableSearch = try container.decodeIfPresent(Bool.self, forKey: .enableSearch) ?? d.enableSearch
        searchHotkey = try container.decodeIfPresent(HotkeyCombo.self, forKey: .searchHotkey) ?? d.searchHotkey
        itemAliases = try container.decodeIfPresent(ItemAliasStore.self, forKey: .itemAliases) ?? d.itemAliases
        hoverToReveal = try container.decodeIfPresent(Bool.self, forKey: .hoverToReveal) ?? d.hoverToReveal
        hoverRevealDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .hoverRevealDelay) ?? d.hoverRevealDelay
        dismissBarOnMouseExit = try container.decodeIfPresent(Bool.self, forKey: .dismissBarOnMouseExit) ?? d.dismissBarOnMouseExit
    }
}

/// A keyboard shortcut as a virtual key code plus device-independent modifier flags. Kept in
/// Core as a pure value type so the hotkey registration (Carbon) and the recorder UI agree on
/// one representation, and so it round-trips through Codable for persistence and layout export.
public struct HotkeyCombo: Equatable, Sendable, Codable, Hashable {
    /// A `kVK_*` virtual key code (e.g. `kVK_ANSI_B == 11`).
    public var keyCode: Int
    /// `NSEvent.ModifierFlags` raw value, masked to the device-independent flags
    /// (command/option/control/shift). Stored as `UInt` so it's Codable and platform-agnostic.
    public var modifiers: UInt

    public init(keyCode: Int, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Whether this combo is a usable shortcut (a key plus at least one modifier). A bare key
    /// with no modifiers would clash with normal typing, so it's treated as "unset".
    public var isValid: Bool { keyCode >= 0 && modifiers != 0 }

    // Device-independent modifier raw values (mirror of NSEvent.ModifierFlags, kept here so
    // Core doesn't import AppKit): shift 1<<17, control 1<<18, option 1<<19, command 1<<20.
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20

    /// Default toggle-bar shortcut: ⌥⌘B (kVK_ANSI_B = 11).
    public static let defaultToggle = HotkeyCombo(keyCode: 11, modifiers: command | option)
    /// Default search shortcut: ⌥⌘F (kVK_ANSI_F = 3).
    public static let defaultSearch = HotkeyCombo(keyCode: 3, modifiers: command | option)
}
