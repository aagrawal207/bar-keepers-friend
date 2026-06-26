import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct SearchRankerTests {

    private func item(id: CGWindowID, title: String?, bundle: String? = nil) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id,
            ownerPID: 1,
            ownerBundleID: bundle,
            title: title,
            frame: CGRect(x: 0, y: 0, width: 20, height: 22)
        )
    }

    @Test func emptyQueryReturnsAllInOrder() {
        let items = [item(id: 1, title: "Wi-Fi"), item(id: 2, title: "Battery")]
        let result = SearchRanker.rank(items: items, query: "  ")
        #expect(result.map(\.item.windowID) == [1, 2])
    }

    @Test func exactMatchOutranksPrefixOutranksSubsequence() {
        let items = [
            item(id: 1, title: "Battery"),       // subsequence of "bty"? no — test below
            item(id: 2, title: "bt"),            // exact for "bt"
            item(id: 3, title: "btSomething"),   // prefix for "bt"
        ]
        let result = SearchRanker.rank(items: items, query: "bt")
        #expect(result.first?.item.windowID == 2)
        #expect(result.map(\.item.windowID).prefix(2) == [2, 3])
    }

    @Test func nonMatchingItemsAreExcluded() {
        let items = [item(id: 1, title: "Wi-Fi"), item(id: 2, title: "Bluetooth")]
        let result = SearchRanker.rank(items: items, query: "zzz")
        #expect(result.isEmpty)
    }

    @Test func matchesAgainstBundleIDWhenTitleMisses() {
        let items = [item(id: 1, title: "Now Playing", bundle: "com.apple.mediaremote")]
        let result = SearchRanker.rank(items: items, query: "mediaremote")
        #expect(result.first?.item.windowID == 1)
    }

    @Test func caseInsensitive() {
        let items = [item(id: 1, title: "Dropbox")]
        #expect(SearchRanker.rank(items: items, query: "DROPBOX").first?.item.windowID == 1)
    }

    @Test func subsequenceMatching() {
        #expect(SearchRanker.isSubsequence("dbx", of: "dropbox"))
        #expect(!SearchRanker.isSubsequence("xbd", of: "dropbox"))
    }

    @Test func scoreOrdering() {
        #expect(SearchRanker.score(needle: "wifi", haystack: "wifi") == 100)
        #expect(SearchRanker.score(needle: "wi", haystack: "wifi") == 75)
        #expect(SearchRanker.score(needle: "fi", haystack: "wifi") == 40)
        #expect(SearchRanker.score(needle: "wf", haystack: "wifi") == 20)
        #expect(SearchRanker.score(needle: "zz", haystack: "wifi") == 0)
    }
}
