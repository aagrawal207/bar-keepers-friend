import Foundation

/// The three logical regions of the managed menu bar, ordered left-to-right on screen.
///
/// Visually (a notched MacBook menu bar):
///
///     [ alwaysHidden | hidden ]  ‹anchor›  [ visible items ]  ‹system clock›
///       ^ off-screen, secret      ^ collapses on demand        ^ never touched
///
/// `.alwaysHidden` exists only once some item carries that intent: its divider is created
/// lazily so a bar that never uses the tier keeps the two-control baseline exactly.
public enum MenuBarSection: String, CaseIterable, Sendable, Codable {
    /// Always shown. Sits to the right of the anchor control item.
    case visible

    /// Collapsed by default; revealed on click or hotkey. Between the anchor and the
    /// always-hidden divider.
    case hidden

    /// Revealed only by an explicit action. Left of the always-hidden divider.
    case alwaysHidden

    /// The two sections every install has; `.alwaysHidden` is added when its divider exists.
    public static let phase1: [MenuBarSection] = [.visible, .hidden]

    /// The saved intent that places an item in this section.
    public var placement: ItemPlacement {
        switch self {
        case .visible: return .shown
        case .hidden: return .hidden
        case .alwaysHidden: return .alwaysHidden
        }
    }
}

/// Saved per-item placement intent: the persistence counterpart of the geometric `MenuBarSection`.
/// Raw values are persisted through `ItemControlStore` set names, never renamed.
public enum ItemPlacement: String, CaseIterable, Sendable, Codable, Hashable {
    case shown
    case hidden
    case alwaysHidden

    /// The section an item with this intent belongs to once placed.
    public var section: MenuBarSection {
        switch self {
        case .shown: return .visible
        case .hidden: return .hidden
        case .alwaysHidden: return .alwaysHidden
        }
    }

    /// True for both tiers that leave the menu bar; existing Bool call sites map through this.
    public var isHidden: Bool { self != .shown }

    /// Bool-era intent mapping kept so `setHidden(true)` keeps meaning the ordinary hidden tier.
    public init(hidden: Bool) {
        self = hidden ? .hidden : .shown
    }
}
