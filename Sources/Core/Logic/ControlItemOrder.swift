import Foundation

/// Keeps the app's control items in the one order the hide mechanism depends on.
///
/// macOS lays the menu bar out right-to-left and persists each status item's slot under
/// `NSStatusItem Preferred Position <autosaveName>`, where a **higher** value sits **further
/// left**. Hiding works by expanding the (otherwise invisible) divider so everything to *its
/// left* is pushed off the screen edge — which only does the right thing while the divider sits
/// to the **left** of the always-visible anchor, and the always-hidden divider sits left of that.
///
/// The synthesized per-item moves drag third-party items across the anchor, and AppKit can
/// re-persist our items' slots as that churns. If their order ever flips (divider ends up
/// right of the anchor), the next launch expands the divider straight through the anchor and
/// shoves *it* off-screen — the user sees every other icon but loses our own. This is pure so
/// the rule can be unit-tested; the app reads the saved slots, applies it, and writes back.
public enum ControlItemOrder {

    /// Given the saved slot values for the anchor and the hidden divider, returns the slot the
    /// divider should be rewritten to if the pair is inverted, or `nil` if the order is already
    /// correct (divider strictly left of the anchor) and nothing needs changing.
    ///
    /// "Left of the anchor" means a strictly greater slot value. When inverted we park the
    /// divider just one unit left of the anchor: the divider is invisible and near-zero width
    /// when collapsed, so it only needs to *order* left of the anchor, and pinning it adjacent
    /// preserves the anchor's own placement among the other apps' items.
    public static func repairedDividerPosition(anchor: Double, divider: Double) -> Double? {
        divider > anchor ? nil : anchor + 1
    }

    /// Same rule one tier further left: the always-hidden divider must order strictly left of the
    /// hidden divider, or expanding it would push the hidden divider and the anchor off-screen.
    public static func repairedAlwaysHiddenDividerPosition(hiddenDivider: Double, alwaysHiddenDivider: Double) -> Double? {
        alwaysHiddenDivider > hiddenDivider ? nil : hiddenDivider + 1
    }

    /// Repairs both dividers in one pass. The always-hidden slot is checked against the hidden
    /// divider's REPAIRED slot, so a single inverted anchor cannot leave the chain half-fixed.
    public static func repairedPositions(
        anchor: Double, hiddenDivider: Double, alwaysHiddenDivider: Double?
    ) -> (hiddenDivider: Double?, alwaysHiddenDivider: Double?) {
        let repairedHidden = repairedDividerPosition(anchor: anchor, divider: hiddenDivider)
        guard let alwaysHiddenDivider else { return (repairedHidden, nil) }
        let effectiveHidden = repairedHidden ?? hiddenDivider
        return (
            repairedHidden,
            repairedAlwaysHiddenDividerPosition(hiddenDivider: effectiveHidden, alwaysHiddenDivider: alwaysHiddenDivider)
        )
    }
}
