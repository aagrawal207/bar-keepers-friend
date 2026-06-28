import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct MenuBarExtraMatcherTests {

    // MARK: - nearest(to:among:)

    @Test func nearestSelectsByLeftEdge() {
        // Target left edge 960 should pick the 960 candidate over the 992 one.
        let candidates: [(leftEdge: CGFloat, value: String)] = [(960, "a"), (992, "b")]
        #expect(MenuBarExtraMatcher.nearest(to: 960, among: candidates) == "a")
    }

    @Test func nearestWinsResolvesThreePtPair() {
        // Items 1094 and 1097 are only 3pt apart; nearest-wins must pick the true closest,
        // not the first within tolerance.
        let candidates: [(leftEdge: CGFloat, value: String)] = [(1094, "left"), (1097, "right")]
        #expect(MenuBarExtraMatcher.nearest(to: 1097, among: candidates) == "right")
        #expect(MenuBarExtraMatcher.nearest(to: 1094, among: candidates) == "left")
    }

    @Test func nearestReturnsNilBeyondTolerance() {
        let candidates: [(leftEdge: CGFloat, value: String)] = [(900, "a")]
        #expect(MenuBarExtraMatcher.nearest(to: 913, among: candidates) == nil) // 13 > 12
    }

    @Test func nearestConsidersWholeListNotFirst() {
        // The nearer candidate appears later in the array; it must still win.
        let candidates: [(leftEdge: CGFloat, value: String)] = [(1050, "far"), (1002, "near")]
        #expect(MenuBarExtraMatcher.nearest(to: 1000, among: candidates) == "near")
    }

    @Test func nearestHandlesEmptyCandidates() {
        let candidates: [(leftEdge: CGFloat, value: String)] = []
        #expect(MenuBarExtraMatcher.nearest(to: 100, among: candidates) == nil)
    }

    @Test func nearestAmongManyPicksTrueClosest() {
        // Guards the child-press path: among several pressable children of a Control Center
        // group, the one nearest the clicked position must win — never just the first.
        let candidates: [(leftEdge: CGFloat, value: String)] = [
            (1000, "a"), (1030, "b"), (1058, "c"), (1090, "d"),
        ]
        #expect(MenuBarExtraMatcher.nearest(to: 1060, among: candidates) == "c")
    }

    @Test func nearestAtExactToleranceBoundaryMatches() {
        let candidates: [(leftEdge: CGFloat, value: String)] = [(1000, "a")]
        // Exactly `tolerance` away is still a match (inclusive bound).
        #expect(MenuBarExtraMatcher.nearest(to: 1000 + MenuBarExtraMatcher.tolerance, among: candidates) == "a")
    }

    // MARK: - assignGreedy

    @Test func greedyDoesNotDoubleClaimOneExtra() {
        // Two items near a single extra: only one claims it, the other gets nil.
        let assignment = MenuBarExtraMatcher.assignGreedy(
            targetMinXs: [100, 104],
            extraLeftEdges: [102]
        )
        #expect(assignment == [0, nil])
    }

    @Test func greedyMatchesDistinctExtrasOneToOne() {
        let assignment = MenuBarExtraMatcher.assignGreedy(
            targetMinXs: [100, 200],
            extraLeftEdges: [101, 199]
        )
        #expect(assignment == [0, 1])
    }

    @Test func greedyThreePtPairClaimsNearestEach() {
        // Two items at 1094 and 1097, two extras at 1094 and 1097: each claims its own.
        let assignment = MenuBarExtraMatcher.assignGreedy(
            targetMinXs: [1094, 1097],
            extraLeftEdges: [1094, 1097]
        )
        #expect(assignment == [0, 1])
    }

    @Test func greedyLeavesUnmatchedItemNil() {
        let assignment = MenuBarExtraMatcher.assignGreedy(
            targetMinXs: [100, 500],
            extraLeftEdges: [101]
        )
        #expect(assignment == [0, nil])
    }

    @Test func greedyResolvesNearEquidistantInversionOptimally() {
        // Regression: input-order greedy would let target 105 grab extra 100 (the first it sees
        // at equal distance), forcing target 100 onto extra 110 — swapping the two and producing
        // total distance 15. The globally-optimal 1:1 matching is [1, 0] (105->110, 100->100;
        // total 5), which keeps each item on its true-nearest extra.
        let assignment = MenuBarExtraMatcher.assignGreedy(
            targetMinXs: [105, 100],
            extraLeftEdges: [100, 110]
        )
        #expect(assignment == [1, 0])
    }

    @Test func greedyAssignmentIsOrderIndependent() {
        // The matching must be the same regardless of how targets are ordered in the array,
        // since it is now distance-globally-optimal rather than first-come.
        let a = MenuBarExtraMatcher.assignGreedy(targetMinXs: [100, 105], extraLeftEdges: [100, 110])
        #expect(a == [0, 1]) // 100->100 (0), 105->110 (5): total 5, the optimum
    }

    @Test func greedyClosestPairWinsContestedExtra() {
        // Two targets contest extra at 200; the closer one (201) must win it and the farther
        // one (210) fall to its next-best free extra (208), not the reverse.
        let assignment = MenuBarExtraMatcher.assignGreedy(
            targetMinXs: [210, 201],
            extraLeftEdges: [200, 208]
        )
        #expect(assignment == [1, 0]) // 210->208 (2), 201->200 (1)
    }
}
