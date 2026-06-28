import CoreGraphics
import Foundation

/// Matches menu bar *extras* (Accessibility elements, each with a known left-edge x from
/// `kAXPosition`) to status-item windows (each with a `frame.minX`). Shared by attribution
/// (which labels items with their owning app) and activation (which presses the element), so
/// the two paths can never disagree about which extra belongs to which item — a divergence
/// here previously caused activation to press the wrong item, or nothing at all.
///
/// Matching is by **left edge** and **nearest-wins**: items can sit only ~3 pt apart, so
/// "first within tolerance" would pick the wrong neighbour. Pure and unit-tested; no AX or
/// window-server access.
public enum MenuBarExtraMatcher {

    /// Default x tolerance (points). The AX element's left edge aligns with the window's
    /// `frame.minX` to within a few points; 12 absorbs sub-pixel and rounding drift while
    /// staying well inside the ~24 pt spacing between distinct items.
    public static let tolerance: CGFloat = 12

    /// Returns the `value` of the candidate whose `leftEdge` is nearest `targetMinX`, provided
    /// it is within `tolerance`. Considers the entire candidate set before choosing, so the
    /// global nearest wins (not the first in array order).
    public static func nearest<Value>(
        to targetMinX: CGFloat,
        among candidates: [(leftEdge: CGFloat, value: Value)],
        tolerance: CGFloat = tolerance
    ) -> Value? {
        guard let best = candidates.min(by: {
            abs($0.leftEdge - targetMinX) < abs($1.leftEdge - targetMinX)
        }), abs(best.leftEdge - targetMinX) <= tolerance else {
            return nil
        }
        return best.value
    }

    /// Assigns each target (a status-item left edge) to at most one extra, 1:1, so two items
    /// near the same extra can't both claim it (which produced duplicate names).
    ///
    /// Uses a **globally minimum-distance** matching, not per-target greedy. The old input-order
    /// greedy could let an earlier target grab an extra a later target needed more, forcing the
    /// later one onto a worse (but still in-tolerance) extra — swapping two neighbours' labels and
    /// activation targets. Example: targets [105, 100] vs extras [100, 110] greedily yields
    /// [0, 1] (total distance 15); the optimal is [1, 0] (total 5). We achieve the optimum for the
    /// small N here by enumerating every in-tolerance (distance, target, extra) pair, sorting by
    /// distance ascending (deterministic tie-break on target then extra index), and claiming the
    /// closest available pair first.
    ///
    /// Returns, per input target index, the index into `extraLeftEdges` it claimed, or `nil`
    /// if none was free within tolerance. Apps with several extras (Control Center exposes
    /// Wi-Fi, Battery, …) are handled naturally: each distinct extra is claimed by its own
    /// nearest item.
    public static func assignGreedy(
        targetMinXs: [CGFloat],
        extraLeftEdges: [CGFloat],
        tolerance: CGFloat = tolerance
    ) -> [Int?] {
        // All candidate pairings within tolerance.
        var pairs: [(distance: CGFloat, target: Int, extra: Int)] = []
        for (t, target) in targetMinXs.enumerated() {
            for (e, edge) in extraLeftEdges.enumerated() {
                let distance = abs(edge - target)
                if distance <= tolerance {
                    pairs.append((distance, t, e))
                }
            }
        }
        // Closest pair first; deterministic ties so the result never depends on enumeration luck.
        pairs.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.target != $1.target { return $0.target < $1.target }
            return $0.extra < $1.extra
        }

        var result = [Int?](repeating: nil, count: targetMinXs.count)
        var claimedTargets = Set<Int>()
        var claimedExtras = Set<Int>()
        for pair in pairs {
            guard !claimedTargets.contains(pair.target), !claimedExtras.contains(pair.extra) else { continue }
            result[pair.target] = pair.extra
            claimedTargets.insert(pair.target)
            claimedExtras.insert(pair.extra)
        }
        return result
    }
}
