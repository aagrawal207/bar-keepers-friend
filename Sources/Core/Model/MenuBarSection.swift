import Foundation

/// The three logical regions of the managed menu bar, ordered left-to-right on screen.
///
/// Visually (a notched MacBook menu bar):
///
///     [ alwaysHidden | hidden ]  ‹anchor›  [ visible items ]  ‹system clock›
///       ^ off-screen, secret      ^ collapses on demand        ^ never touched
///
/// In Phase 1 only `.visible` and `.hidden` exist; `.alwaysHidden` is introduced later
/// once the per-item control layer is in place, because Tahoe's nested sectioning is the
/// exact behavior that regressed in the wild (Ice issue #946).
public enum MenuBarSection: String, CaseIterable, Sendable, Codable {
    /// Always shown. Sits to the right of the anchor control item.
    case visible

    /// Collapsed by default; revealed on click or hotkey. Between the anchor and the
    /// always-hidden divider.
    case hidden

    /// Revealed only by an explicit action. Left of the always-hidden divider.
    case alwaysHidden

    /// Sections available in the current build. Phase 1 ships without `.alwaysHidden`.
    public static let phase1: [MenuBarSection] = [.visible, .hidden]
}
