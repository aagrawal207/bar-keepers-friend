import CoreGraphics

/// Minimal item-relative moves between two orders. Every reference is on the opposite side of its item.
public enum ItemOrderPlanner {
    public struct Move: Equatable, Sendable {
        public let windowID: CGWindowID
        public let referenceID: CGWindowID
        public let before: Bool
    }

    public static func moves(current: [CGWindowID], desired: [CGWindowID]) -> [Move] {
        var seen: Set<CGWindowID> = []
        let available = Set(current)
        let desired = desired.filter { available.contains($0) && seen.insert($0).inserted }
        let ranks = Dictionary(uniqueKeysWithValues: desired.enumerated().map { ($0.element, $0.offset) })
        seen.removeAll()
        var live = current.filter { ranks[$0] != nil && seen.insert($0).inserted }
        guard live != desired else { return [] }

        // The longest increasing subsequence stays put; each other item needs at most one gesture.
        var sequences: [[CGWindowID]] = []
        for (index, id) in live.enumerated() {
            var sequence: [CGWindowID] = []
            for previous in 0..<index where ranks[live[previous]]! < ranks[id]! {
                if sequences[previous].count > sequence.count { sequence = sequences[previous] }
            }
            sequences.append(sequence + [id])
        }
        let kept = Set(sequences.max { $0.count < $1.count } ?? [])
        var result: [Move] = []
        var previous: CGWindowID?
        for id in desired {
            defer { previous = id }
            guard !kept.contains(id), let index = live.firstIndex(of: id) else { continue }
            let insertion = previous.flatMap { live.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            guard index != insertion else { continue }
            let reference: CGWindowID
            let before: Bool
            if index < insertion, let previous {
                reference = previous
                before = false
            } else {
                reference = live[insertion]
                before = true
            }
            result.append(Move(windowID: id, referenceID: reference, before: before))
            live.remove(at: index)
            let referenceIndex = live.firstIndex(of: reference)!
            live.insert(id, at: referenceIndex + (before ? 0 : 1))
        }
        return result
    }
}
