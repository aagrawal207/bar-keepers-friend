import Foundation

/// Ranks menu bar items against a search query for the (Phase 4) search panel.
///
/// Pure and deterministic: a query plus a list of items always yields the same ordered
/// result, so ranking quality is locked down by unit tests rather than eyeballing.
public enum SearchRanker {

    public struct Match: Equatable, Sendable {
        public let item: MenuBarItemSnapshot
        public let score: Int
        public init(item: MenuBarItemSnapshot, score: Int) {
            self.item = item
            self.score = score
        }
    }

    /// Returns items matching `query`, best first. An empty query returns everything in
    /// the input order (score 0). Matching is case-insensitive over the item title, the
    /// user's chosen alias (if any), and — as a fallback — its owner bundle id.
    ///
    /// `aliases` is defaulted to an empty store so existing callers (which pass only
    /// `items:` and `query:`) keep compiling unchanged. When supplied, an item's alias is
    /// just another haystack, which matters most on Tahoe where the real title is often a
    /// useless `"Item-0"` placeholder — the alias is the only name worth searching.
    public static func rank(
        items: [MenuBarItemSnapshot],
        query: String,
        aliases: ItemAliasStore = ItemAliasStore()
    ) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return items.map { Match(item: $0, score: 0) }
        }
        let needle = trimmed.lowercased()

        return items
            .compactMap { item -> Match? in
                // Alias and title are both strong, user-/system-facing names, so an alias
                // match ranks just as highly as a title match (same scoring, the max wins).
                // The bundle id stays a weaker fallback because it's a developer string.
                let haystacks = [item.title, aliases.alias(for: item), item.ownerBundleID]
                    .compactMap { $0?.lowercased() }
                guard let best = haystacks.map({ score(needle: needle, haystack: $0) }).max(),
                      best > 0 else {
                    return nil
                }
                return Match(item: item, score: best)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Stable tiebreak: earlier title alphabetically, then window id.
                let lt = lhs.item.title ?? ""
                let rt = rhs.item.title ?? ""
                if lt != rt { return lt < rt }
                return lhs.item.windowID < rhs.item.windowID
            }
    }

    /// A small scoring function: exact match > prefix > word-boundary > subsequence.
    static func score(needle: String, haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        if haystack == needle { return 100 }
        if haystack.hasPrefix(needle) { return 75 }
        if haystack.contains(" " + needle) { return 60 }
        if haystack.contains(needle) { return 40 }
        return isSubsequence(needle, of: haystack) ? 20 : 0
    }

    /// Whether `needle` appears in `haystack` as an ordered (not necessarily contiguous)
    /// subsequence — the classic fuzzy-match test.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var matched = false
            while let next = iterator.next() {
                if next == character {
                    matched = true
                    break
                }
            }
            if !matched { return false }
        }
        return true
    }
}
