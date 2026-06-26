import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct SectionClassifierTests {

    private func item(id: CGWindowID, midX: CGFloat) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id,
            ownerPID: 1,
            frame: CGRect(x: midX - 10, y: 0, width: 20, height: 22)
        )
    }

    @Test func itemRightOfAnchorIsVisible() {
        let dividers = SectionClassifier.DividerPositions(anchorMidX: 1000)
        #expect(SectionClassifier.section(forItemMidX: 1200, dividers: dividers) == .visible)
    }

    @Test func itemLeftOfAnchorWithNoHiddenDividerIsHidden() {
        let dividers = SectionClassifier.DividerPositions(anchorMidX: 1000)
        #expect(SectionClassifier.section(forItemMidX: 800, dividers: dividers) == .hidden)
    }

    @Test func itemBetweenHiddenDividerAndAnchorIsHidden() {
        let dividers = SectionClassifier.DividerPositions(
            anchorMidX: 1000,
            hiddenDividerMidX: 600
        )
        #expect(SectionClassifier.section(forItemMidX: 800, dividers: dividers) == .hidden)
    }

    @Test func itemLeftOfAlwaysHiddenDividerIsAlwaysHidden() {
        let dividers = SectionClassifier.DividerPositions(
            anchorMidX: 1000,
            hiddenDividerMidX: 600,
            alwaysHiddenDividerMidX: 300
        )
        #expect(SectionClassifier.section(forItemMidX: 200, dividers: dividers) == .alwaysHidden)
        #expect(SectionClassifier.section(forItemMidX: 450, dividers: dividers) == .hidden)
    }

    @Test func classifyBatchAssignsEachWindow() {
        let dividers = SectionClassifier.DividerPositions(anchorMidX: 1000, hiddenDividerMidX: 600)
        let items = [item(id: 1, midX: 1200), item(id: 2, midX: 800), item(id: 3, midX: 400)]
        let result = SectionClassifier.classify(items: items, dividers: dividers)
        #expect(result[1] == .visible)
        #expect(result[2] == .hidden)
        #expect(result[3] == .hidden)
    }

    @Test func itemsInSectionAreOrderedLeftToRight() {
        let dividers = SectionClassifier.DividerPositions(anchorMidX: 1000)
        let items = [item(id: 1, midX: 1400), item(id: 2, midX: 1100), item(id: 3, midX: 1250)]
        let visible = SectionClassifier.items(in: .visible, from: items, dividers: dividers)
        #expect(visible.map(\.windowID) == [2, 3, 1])
    }
}
