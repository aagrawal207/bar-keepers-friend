import Foundation

/// User-facing settings, persisted as Codable JSON. Kept as a plain value type so a
/// round-trip through `encode` / `decode` is unit-testable and so defaults are explicit.
public struct Preferences: Equatable, Sendable, Codable {

    /// Whether the hidden section auto-recollapses after being revealed.
    public var autoRehide: Bool

    public static let autoRehideDelayRange: ClosedRange<TimeInterval> = 2...120

    /// Seconds before auto-rehide fires, kept finite and within `autoRehideDelayRange`.
    public var autoRehideDelay: TimeInterval {
        didSet { autoRehideDelay = Self.normalizedAutoRehideDelay(autoRehideDelay) }
    }

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

    /// On-screen positions of the control items, keyed by autosave name, mirroring AppKit's
    /// "NSStatusItem Preferred Position <name>" values.
    ///
    /// CURRENTLY UNUSED at runtime: the engine reads and rewrites those slots **directly** via
    /// `UserDefaults` under AppKit's own keys (see `CosmeticHideEngine.repairControlItemOrderIfNeeded`,
    /// which self-heals an inverted divider/anchor order on launch), and nothing reads or writes this
    /// field. It is retained in the schema because it is part of the Codable `Preferences` and the
    /// exported `LayoutConfig`, so dropping it would change the persisted/exported shape. The original
    /// intent — caching the slots here so they survive a deliberate status-item removal (which deletes
    /// AppKit's copy) — was superseded by the direct-UserDefaults + launch-repair approach and is not
    /// wired; revisit only with on-device verification (see AGENTS.md "Needs hardware verification").
    public var controlItemPositions: [String: Double]

    // MARK: - Global hotkey (toggle the floating bar)

    /// Whether the global keyboard shortcut to toggle the floating bar is active.
    public var enableGlobalHotkey: Bool

    /// The toggle-bar shortcut. `keyCode` is a virtual key code (`kVK_*`); `modifiers` is an
    /// `NSEvent.ModifierFlags` raw value (device-independent flags only). Default ⌥⌘B.
    public var toggleHotkey: HotkeyCombo

    /// User-chosen display nicknames for menu bar items, keyed by owning-app identity. Lets the
    /// user rename an item shown in the bar/Items list — valuable on Tahoe where the real title is
    /// often the generic "Item-0". Persisted with the rest of preferences.
    public var itemAliases: ItemAliasStore

    /// Per-item floating-bar presentation controls (suppress-from-bar / bar order), keyed by
    /// owning-app identity. Distinct from `itemAliases` so each store stays single-purpose.
    public var itemControls: ItemControlStore

    // MARK: - Floating bar behavior

    /// Dismiss the floating bar automatically when the pointer leaves it (Bartender-style).
    /// On by default — a quick-glance bar shouldn't linger once the user moves away.
    public var dismissBarOnMouseExit: Bool

    /// Hover reveal is opt-in and applies only to the floating bar, independently of auto-rehide.
    public var revealOnHover: Bool

    /// Scroll/swipe reveal is opt-in like hover and also applies only to the floating bar.
    public var revealOnScroll: Bool

    /// Named saved arrangements; applying one replaces `itemControls` only.
    public var presets: [LayoutPreset]

    /// Rules that apply a preset while their conditions hold, then restore the prior arrangement.
    public var triggers: [TriggerRule]

    /// Which trigger is active and the arrangement to restore when it deactivates.
    public var triggerState: TriggerRuntimeState

    /// Items combined behind one BKF-owned menu bar icon; grouped owners count as Hidden.
    public var itemGroups: [ItemGroup]

    /// Global NSStatusItemSpacing/SelectionPadding override shared by every app after relaunch.
    public var menuBarSpacing: MenuBarSpacing

    /// Device-local flag; the first-run walkthrough shows until it is completed or skipped.
    public var hasCompletedOnboarding: Bool


    /// Per-owner shortcuts that reveal and activate one item; the toggle shortcut always wins conflicts.
    public var itemHotkeys: [String: HotkeyCombo]

    /// Optional tint/shape overlay drawn behind the menu bar; `.none` draws nothing.
    public var menuBarStyle: MenuBarStyle

    /// User-defined menu bar items that run a small allowlisted action when clicked.
    public var widgets: [MenuBarWidget]

    /// Whether a notch-clipped reveal may temporarily tuck shown items to make room (reflow/activation).
    public var notchOverflow: NotchOverflowMode

    /// Menu bar symbol and app artwork theme; the installed Finder icon is never rewritten.
    public var appIcon: AppIconChoice

    public init(
        autoRehide: Bool = true,
        autoRehideDelay: TimeInterval = 15,
        launchAtLogin: Bool = false,
        useFloatingBar: Bool = true,
        floatingBarStyle: FloatingBarStyle = .horizontal,
        useAXActivation: Bool = false,
        controlItemPositions: [String: Double] = [:],
        enableGlobalHotkey: Bool = true,
        toggleHotkey: HotkeyCombo = .defaultToggle,
        itemAliases: ItemAliasStore = ItemAliasStore(),
        itemControls: ItemControlStore = ItemControlStore(),
        dismissBarOnMouseExit: Bool = true,
        revealOnHover: Bool = false,
        revealOnScroll: Bool = false,
        presets: [LayoutPreset] = [],
        triggers: [TriggerRule] = [],
        triggerState: TriggerRuntimeState = TriggerRuntimeState(),
        itemGroups: [ItemGroup] = [],
        menuBarSpacing: MenuBarSpacing = .systemDefault,
        hasCompletedOnboarding: Bool = false,
        itemHotkeys: [String: HotkeyCombo] = [:],
        menuBarStyle: MenuBarStyle = .none,
        widgets: [MenuBarWidget] = [],
        notchOverflow: NotchOverflowMode = .never,
        appIcon: AppIconChoice = .default
    ) {
        self.autoRehide = autoRehide
        self.autoRehideDelay = Self.normalizedAutoRehideDelay(autoRehideDelay)
        self.launchAtLogin = launchAtLogin
        self.useFloatingBar = useFloatingBar
        self.floatingBarStyle = floatingBarStyle
        self.useAXActivation = useAXActivation
        self.controlItemPositions = controlItemPositions
        self.enableGlobalHotkey = enableGlobalHotkey
        self.toggleHotkey = toggleHotkey
        self.itemAliases = itemAliases
        self.itemControls = itemControls
        self.dismissBarOnMouseExit = dismissBarOnMouseExit
        self.revealOnHover = revealOnHover
        self.revealOnScroll = revealOnScroll
        self.presets = PresetLibrary.normalized(presets)
        self.triggers = triggers
        self.triggerState = triggerState
        self.itemGroups = ItemGroupLibrary.normalized(itemGroups)
        self.menuBarSpacing = menuBarSpacing
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.itemHotkeys = itemHotkeys
        self.menuBarStyle = menuBarStyle.normalized()
        self.widgets = WidgetLibrary.normalized(widgets)
        self.notchOverflow = notchOverflow
        self.appIcon = appIcon
    }

    public static let `default` = Preferences()

    private static func normalizedAutoRehideDelay(_ delay: TimeInterval) -> TimeInterval {
        // Nonfinite values must not reach timer arithmetic or the Settings integer conversion.
        guard delay.isFinite else { return 15 }
        return min(max(delay, autoRehideDelayRange.lowerBound), autoRehideDelayRange.upperBound)
    }

    // Explicit keys so renaming a Swift property never silently drops stored data.
    enum CodingKeys: String, CodingKey {
        case autoRehide
        case autoRehideDelay
        case launchAtLogin
        case useFloatingBar
        case floatingBarStyle
        case useAXActivation
        case controlItemPositions
        case enableGlobalHotkey
        case toggleHotkey
        case itemAliases
        case itemControls
        case dismissBarOnMouseExit
        case revealOnHover
        case revealOnScroll
        case presets
        case triggers
        case triggerState
        case itemGroups
        case menuBarSpacing
        case hasCompletedOnboarding
        case itemHotkeys
        case menuBarStyle
        case widgets
        case notchOverflow
        case appIcon
    }

    /// Keeps every readable element so one corrupt entry cannot reset the whole store.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// Decodes leniently: any missing key falls back to its default, so adding a new
    /// preference never fails to load an older saved file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.default
        autoRehide = try container.decodeIfPresent(Bool.self, forKey: .autoRehide) ?? d.autoRehide
        autoRehideDelay = Self.normalizedAutoRehideDelay(
            try container.decodeIfPresent(TimeInterval.self, forKey: .autoRehideDelay) ?? d.autoRehideDelay
        )
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        useFloatingBar = try container.decodeIfPresent(Bool.self, forKey: .useFloatingBar) ?? d.useFloatingBar
        floatingBarStyle = try container.decodeIfPresent(FloatingBarStyle.self, forKey: .floatingBarStyle) ?? d.floatingBarStyle
        useAXActivation = try container.decodeIfPresent(Bool.self, forKey: .useAXActivation) ?? d.useAXActivation
        controlItemPositions = try container.decodeIfPresent([String: Double].self, forKey: .controlItemPositions) ?? d.controlItemPositions
        enableGlobalHotkey = try container.decodeIfPresent(Bool.self, forKey: .enableGlobalHotkey) ?? d.enableGlobalHotkey
        toggleHotkey = try container.decodeIfPresent(HotkeyCombo.self, forKey: .toggleHotkey) ?? d.toggleHotkey
        itemAliases = try container.decodeIfPresent(ItemAliasStore.self, forKey: .itemAliases) ?? d.itemAliases
        itemControls = try container.decodeIfPresent(ItemControlStore.self, forKey: .itemControls) ?? d.itemControls
        dismissBarOnMouseExit = try container.decodeIfPresent(Bool.self, forKey: .dismissBarOnMouseExit) ?? d.dismissBarOnMouseExit
        revealOnHover = try container.decodeIfPresent(Bool.self, forKey: .revealOnHover) ?? false
        revealOnScroll = try container.decodeIfPresent(Bool.self, forKey: .revealOnScroll) ?? false
        let rawPresets = (try? container.decodeIfPresent([Lossy<LayoutPreset>].self, forKey: .presets)) ?? nil
        presets = PresetLibrary.normalized((rawPresets ?? []).compactMap(\.value))
        let rawTriggers = (try? container.decodeIfPresent(TriggerRule.LossyArray.self, forKey: .triggers)) ?? nil
        triggers = rawTriggers?.rules ?? []
        triggerState = ((try? container.decodeIfPresent(TriggerRuntimeState.self, forKey: .triggerState)) ?? nil)
            ?? TriggerRuntimeState()
        let rawGroups = (try? container.decodeIfPresent([Lossy<ItemGroup>].self, forKey: .itemGroups)) ?? nil
        itemGroups = ItemGroupLibrary.normalized((rawGroups ?? []).compactMap(\.value))
        menuBarSpacing = ((try? container.decodeIfPresent(MenuBarSpacing.self, forKey: .menuBarSpacing)) ?? nil)
            ?? d.menuBarSpacing
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        itemHotkeys = ((try? container.decodeIfPresent([String: HotkeyCombo].self, forKey: .itemHotkeys)) ?? nil) ?? [:]
        menuBarStyle = (((try? container.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle)) ?? nil) ?? .none).normalized()
        let rawWidgets = (try? container.decodeIfPresent([Lossy<MenuBarWidget>].self, forKey: .widgets)) ?? nil
        widgets = WidgetLibrary.normalized((rawWidgets ?? []).compactMap(\.value))
        notchOverflow = ((try? container.decodeIfPresent(NotchOverflowMode.self, forKey: .notchOverflow)) ?? nil) ?? .never
        appIcon = ((try? container.decodeIfPresent(AppIconChoice.self, forKey: .appIcon)) ?? nil) ?? .default
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
    ///
    /// The upper bound matters for safety, not just sanity: a virtual key code is a 16-bit value,
    /// and the Carbon registration does a *trapping* `UInt32(keyCode)`. A corrupt or hostile
    /// persisted/imported `keyCode` outside `0...0xFFFF` would crash the app on every launch (the
    /// registration runs at startup). Treating an out-of-range code as "unset" makes the combo
    /// simply not register — matching the hotkey layer's "skip an unusable combo, never fatal"
    /// contract — instead of trapping.
    public var isValid: Bool { keyCode >= 0 && keyCode <= 0xFFFF && modifiers != 0 }

    // Device-independent modifier raw values (mirror of NSEvent.ModifierFlags, kept here so
    // Core doesn't import AppKit): shift 1<<17, control 1<<18, option 1<<19, command 1<<20.
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20

    /// Default toggle-bar shortcut: ⌥⌘B (kVK_ANSI_B = 11).
    public static let defaultToggle = HotkeyCombo(keyCode: 11, modifiers: command | option)
}
