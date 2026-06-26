import CoreGraphics
import Foundation

/// Classifies menu bar items into sections purely by comparing their horizontal position
/// against the app's control-item dividers.
///
/// This mirrors how the real managers work: an item's section is *not* read from any
/// ownership or title attribute — it is derived geometrically from where the item sits
/// relative to the dividers. That makes the whole thing a pure function of frames, and
/// therefore trivially unit-testable.
///
/// Coordinate convention: macOS lays the menu bar out right-to-left, so a *larger* `midX`
/// is further to the right. Sections from left to right are:
/// `.alwaysHidden` < alwaysHiddenDivider < `.hidden` < anchor < `.visible`.
public enum SectionClassifier {

    /// The x-positions of the dividers, in screen coordinates.
    public struct DividerPositions: Equatable, Sendable {
        /// Midpoint of the always-visible anchor.
        public let anchorMidX: CGFloat
        /// Midpoint of the hidden-section divider, if present.
        public let hiddenDividerMidX: CGFloat?
        /// Midpoint of the always-hidden divider, if present.
        public let alwaysHiddenDividerMidX: CGFloat?

        public init(
            anchorMidX: CGFloat,
            hiddenDividerMidX: CGFloat? = nil,
            alwaysHiddenDividerMidX: CGFloat? = nil
        ) {
            self.anchorMidX = anchorMidX
            self.hiddenDividerMidX = hiddenDividerMidX
            self.alwaysHiddenDividerMidX = alwaysHiddenDividerMidX
        }
    }

    /// Returns the section a single item belongs to, given the current divider layout.
    public static func section(
        forItemMidX itemMidX: CGFloat,
        dividers: DividerPositions
    ) -> MenuBarSection {
        // Right of the anchor → always visible.
        if itemMidX > dividers.anchorMidX {
            return .visible
        }

        // Between the hidden divider and the anchor → hidden.
        if let hidden = dividers.hiddenDividerMidX {
            if itemMidX > hidden {
                return .hidden
            }
            // Left of the hidden divider. If there is an always-hidden divider and the
            // item is left of it, it's always-hidden; otherwise still hidden.
            if let alwaysHidden = dividers.alwaysHiddenDividerMidX, itemMidX <= alwaysHidden {
                return .alwaysHidden
            }
            return .hidden
        }

        // No hidden divider configured: everything left of the anchor is hidden.
        return .hidden
    }

    /// Classifies a batch of items, returning a section for each by window id.
    /// Items belonging to the app's own control items should be filtered out by the
    /// caller before classification.
    public static func classify(
        items: [MenuBarItemSnapshot],
        dividers: DividerPositions
    ) -> [CGWindowID: MenuBarSection] {
        var result: [CGWindowID: MenuBarSection] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            result[item.windowID] = section(forItemMidX: item.midX, dividers: dividers)
        }
        return result
    }

    /// Returns the items in a given section, ordered left-to-right (ascending `midX`).
    public static func items(
        in section: MenuBarSection,
        from items: [MenuBarItemSnapshot],
        dividers: DividerPositions
    ) -> [MenuBarItemSnapshot] {
        items
            .filter { self.section(forItemMidX: $0.midX, dividers: dividers) == section }
            .sorted { $0.midX < $1.midX }
    }
}
