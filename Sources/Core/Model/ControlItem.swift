import CoreGraphics
import Foundation

/// One of the app's *own* status items, used as a movable boundary between sections.
///
/// The hide mechanism rests entirely on these: by setting a divider's width to a large
/// value the items to its left are pushed off the screen edge; reverting to the natural
/// width reveals them again. The control items are the only status items this app owns,
/// and the only ones it ever resizes.
public struct ControlItem: Equatable, Sendable {
    /// Stable identity for a control item, also used as its `NSStatusItem.autosaveName`
    /// so AppKit persists its on-screen position across launches.
    public enum Identifier: String, CaseIterable, Sendable {
        /// Always-visible anchor; the boundary between `.hidden` (left) and `.visible` (right).
        case anchor = "BKFAnchor"
        /// Divider whose expansion hides the `.hidden` section.
        case hiddenDivider = "BKFHidden"
        /// Divider for the `.alwaysHidden` section (introduced after Phase 1).
        case alwaysHiddenDivider = "BKFAlwaysHidden"
    }

    public let identifier: Identifier

    /// Whether this divider is currently expanded (hiding the items to its left).
    public var isExpanded: Bool

    public init(identifier: Identifier, isExpanded: Bool = false) {
        self.identifier = identifier
        self.isExpanded = isExpanded
    }
}

/// Width values for a control item's status item.
///
/// The expanded value is deliberately **bounded**. A well-known footgun in this app class
/// is setting the length to a huge constant (Ice uses 10,000): on recent macOS that causes
/// multi-gigabyte memory growth in the window server. We size expansion to just past the
/// widest plausible menu bar instead.
public enum ControlItemLength {
    /// The natural, content-sized width (maps to `NSStatusItem.variableLength`).
    public static let standard: CGFloat = -1 // sentinel: caller substitutes variableLength

    /// A small fixed width used for a visible divider glyph.
    public static let collapsed: CGFloat = 24

    /// Computes a safe expanded width for a screen of the given width.
    ///
    /// The hide mechanism works by making the divider *wider than the display* so every item to
    /// its left is pushed off the screen edge. The operating value is therefore `screenWidth + 200`
    /// — it tracks the actual display, with a small fixed 200pt overhang that is itself memory-safe.
    ///
    /// Bounded to `[500, 9000]`. The 500 floor guarantees we clear a tiny bar. The 9000 ceiling is
    /// a *backstop* against a pathological `screenWidth`, NOT the normal value: for every real
    /// display the result is `screenWidth + 200` (e.g. 1712 on a laptop, 6216 on a Pro Display XDR),
    /// well under the ceiling. The previous 4000 ceiling was a latent bug — on a display wider than
    /// ~3800pt (5K/6K/ultrawide) it clamped the divider *narrower than the screen*, so the leftmost
    /// hidden items were never pushed off and hide silently, partially failed. 9000 clears the
    /// widest real logical display (a 57"/8K panel at 1x is ≈7680pt) while staying clear of the
    /// ~10000 window-server memory-blowup regime (the footgun Ice's literal 10000 hits).
    public static func expanded(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        let target = screenWidth + 200
        return min(max(target, 500), 9000)
    }
}
