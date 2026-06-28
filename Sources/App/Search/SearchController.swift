import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Owns the fuzzy-search panel: a small floating window with a text field that filters the
/// hidden menu bar items (by `SearchRanker`) and activates the chosen one — the same activation
/// path as clicking a mirrored icon in the floating bar.
///
/// AGENT: implement the panel here. The public surface below is fixed — the coordinator sets
/// `itemsProvider` / `onActivate` and calls `toggle()` / `hide()`. Do not change the signatures.
@MainActor
final class SearchController {
    /// Supplies the current hidden items to search over. Set by the coordinator to the floating
    /// bar's `currentItems()` so search and the bar always agree on the item set.
    var itemsProvider: (() -> [FloatingBarItem])?
    /// Activates the chosen item by window id. Set by the coordinator to the floating bar's
    /// `activate(windowID:)`.
    var onActivate: ((CGWindowID) -> Void)?

    private(set) var isVisible = false

    /// Shows the panel if hidden, hides it if shown. Returns the new visibility.
    @discardableResult
    func toggle() -> Bool {
        // AGENT: present/dismiss a KeyablePanel hosting the SwiftUI search view; focus the field
        // on show. Use SearchRanker.rank(items:query:) for filtering. Selecting a result calls
        // onActivate(windowID) then hide(). Esc hides without activating.
        isVisible.toggle()
        return isVisible
    }

    func hide() {
        // AGENT: orderOut the panel; set isVisible = false.
        isVisible = false
    }
}
