import BarKeepersFriendCore
import CoreGraphics
import Testing

struct ItemOrderPlannerTests {
    @Test func everySixItemPermutationUsesMinimalWrongSideMoves() {
        let desired: [CGWindowID] = [1, 2, 3, 4, 5, 6]
        for current in permutations(desired) {
            var live = current
            let moves = ItemOrderPlanner.moves(current: current, desired: desired)
            for move in moves {
                let index = live.firstIndex(of: move.windowID)!
                let referenceIndex = live.firstIndex(of: move.referenceID)!
                #expect(move.before ? index > referenceIndex : index < referenceIndex)
                live.remove(at: index)
                live.insert(move.windowID, at: live.firstIndex(of: move.referenceID)! + (move.before ? 0 : 1))
            }
            #expect(live == desired, "Failed order: \(current)")
            // Enumerating subsets is an independent lower bound on the number of moved items.
            let kept = (0..<(1 << current.count)).map { mask in
                current.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            }.filter { $0 == $0.sorted() }.map(\.count).max()!
            #expect(moves.count == current.count - kept, "Nonminimal order: \(current)")
        }
    }

    @Test func absentDuplicateAndAlreadyOrderedIDsDoNotCreateGestures() {
        #expect(ItemOrderPlanner.moves(current: [], desired: [1]).isEmpty)
        #expect(ItemOrderPlanner.moves(current: [1, 2, 3], desired: [1, 1, 2, 99, 3]).isEmpty)
        let moves = ItemOrderPlanner.moves(current: [1, 2, 2, 3, 4], desired: [4, 1, 2, 77])
        #expect(moves.count == 1)
        #expect(moves.first?.windowID == 4 && moves.first?.referenceID == 1 && moves.first?.before == true)
    }

    private func permutations(_ items: [CGWindowID]) -> [[CGWindowID]] {
        guard !items.isEmpty else { return [[]] }
        return items.indices.flatMap { index in
            var remaining = items
            let item = remaining.remove(at: index)
            return permutations(remaining).map { [item] + $0 }
        }
    }
}
