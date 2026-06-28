import AppKit
import BarKeepersFriendCore
import SwiftUI

/// The SwiftUI content of the fuzzy-search panel: a Spotlight-like text field over a scrolling
/// list of the hidden menu bar items, filtered live by `SearchRanker`.
///
/// This is a plain value-type `View` driven entirely by its inputs and closures — the controller
/// owns presentation (the panel) and activation, so the view only knows how to render rows and
/// report intent (activate this id / dismiss). The mutable bits that are genuinely local to the
/// UI — the query text, which row is highlighted, and the text-field focus — live here as
/// `@State`/`@FocusState` because they have no meaning outside an on-screen panel and don't need
/// to survive a hide/show. Each show builds a fresh `SearchView`, so they reset naturally.
///
/// Styling mirrors `FloatingBarView` (`.ultraThinMaterial` in a continuous rounded rectangle with
/// a faint white stroke) so search and the bar read as the same surface over the translucent
/// Tahoe menu bar.
struct SearchView: View {
    /// The full item set to search over, in display order. The controller passes
    /// `itemsProvider?() ?? []` here; an empty query shows all of these.
    let items: [FloatingBarItem]
    /// Activates the chosen item by window id, then dismisses. Wired by the controller to
    /// `onActivate` + `hide()`. Only ever called for an enabled (activatable) row.
    let onActivate: (CGWindowID) -> Void
    /// Dismisses without activating (Esc, or losing key). Wired to the controller's `hide()`.
    let onCancel: () -> Void

    /// The live query. Empty means "show everything" (matching `SearchRanker`'s contract).
    @State private var query = ""
    /// Index into the currently visible `results` of the highlighted row, or nil when there are
    /// no results. Kept as an index (not an id) so arrow-key movement is a simple clamp, and it's
    /// re-derived whenever the result set changes so it can never point past the end.
    @State private var selection = 0
    /// Drives focusing the text field the instant the panel appears — without this the borderless
    /// panel shows a field the user has to click before typing, which defeats a keyboard-first
    /// launcher.
    @FocusState private var fieldFocused: Bool

    /// Icon glyphs are square; 18pt matches the floating bar's row icons for visual parity.
    private let iconSide: CGFloat = 18
    /// Fixed panel width; tall enough for ~8 rows before the list scrolls (see `maxListHeight`).
    private let panelWidth: CGFloat = 360
    private let rowHeight: CGFloat = 30
    private let maxVisibleRows = 8

    /// The filtered, ranked rows for the current query. Computed each render: the item set is
    /// small (the hidden menu bar items) and `SearchRanker` is pure, so caching would add state to
    /// keep in sync for no real gain. Ranks over the snapshots, then maps each match back to its
    /// `FloatingBarItem` by window id so we keep the captured icon and disabled state.
    private var results: [FloatingBarItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Let search match a user's custom alias too. Rebuild a small alias store from the items'
        // own aliases (each item already carries the alias resolved for its owner) so the ranker —
        // which matches over title/owner/alias — can find an item by its nickname.
        var aliases = ItemAliasStore()
        for item in items where item.alias?.isEmpty == false {
            aliases.setAlias(item.alias, for: item.snapshot)
        }
        return SearchRanker.rank(items: items.map(\.snapshot), query: query, aliases: aliases)
            .compactMap { byID[$0.item.windowID] }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !results.isEmpty {
                Divider().opacity(0.5)
                resultsList
            } else {
                noMatches
            }
        }
        .frame(width: panelWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .onAppear {
            fieldFocused = true
            // Land the highlight on the first ENABLED row at open time, not blindly on index 0:
            // if the first hidden item previously failed to activate it's disabled, and a default
            // selection of 0 would render no highlight and make the first Return a silent no-op.
            selectTopEnabled()
        }
        // On every query change the list is RE-RANKED best-first, so reset the highlight to the
        // new top-ranked enabled row rather than clamping the stale index — otherwise Return could
        // fire a lower-ranked result the highlight lagged onto as the user typed.
        .onChange(of: query) { selectTopEnabled() }
    }

    // MARK: - Pieces

    private var searchField: some View {
        TextField("Search menu bar items", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .focused($fieldFocused)
            .padding(.horizontal, 14)
            .frame(height: 40)
            // Return activates the highlighted row; Esc dismisses. Wiring these on the field (the
            // only focusable control) keeps the whole panel keyboard-driven without an explicit
            // first responder dance.
            .onSubmit(activateSelection)
            .onKeyPress(.escape) {
                onCancel()
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
                return .handled
            }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { activate(item) }
                    }
                }
                .padding(4)
            }
            .frame(height: listHeight)
            // Keep the highlighted row visible as the arrows walk past the fold.
            .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
        }
    }

    private func row(_ item: FloatingBarItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSide, height: iconSide)
            Text(item.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        // Disabled items (activation failed via both paths) read dimmed and never highlight, so
        // the user isn't invited to select something that can't open.
        .opacity(item.isDisabled ? 0.4 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected && !item.isDisabled ? Color.accentColor.opacity(0.25) : .clear)
        )
    }

    private var noMatches: some View {
        Text(items.isEmpty ? "No hidden items" : "No matches")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
    }

    // MARK: - Layout

    /// The list's height: the natural height of the rows, capped at `maxVisibleRows` so a long
    /// list scrolls rather than growing the panel off-screen.
    private var listHeight: CGFloat {
        let rows = min(results.count, maxVisibleRows)
        // +8 for the LazyVStack's 4pt padding top and bottom.
        return CGFloat(rows) * rowHeight + 8
    }

    // MARK: - Selection

    /// Moves the highlight, skipping over disabled rows so Return always lands on something
    /// activatable. Clamps at the ends rather than wrapping (a launcher list shouldn't loop).
    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        var index = selection
        repeat {
            let next = index + delta
            guard next >= 0, next < results.count else { return } // hit an end; stay put
            index = next
        } while results[index].isDisabled
        selection = index
    }

    /// Sets `selection` to the top-ranked ENABLED row (falling back to 0 when none is enabled or
    /// the list is empty). Used at open time and after every re-rank, so Return always activates
    /// the current best activatable match rather than a stale or disabled row.
    private func selectTopEnabled() {
        selection = results.firstIndex(where: { !$0.isDisabled }) ?? 0
    }

    private func activateSelection() {
        guard results.indices.contains(selection) else { return }
        activate(results[selection])
    }

    /// Activates a row unless it's disabled (a disabled row can't open, so a click on it is a
    /// no-op rather than a dismissal that loses the user's query).
    private func activate(_ item: FloatingBarItem) {
        guard !item.isDisabled else { return }
        onActivate(item.id)
    }
}
