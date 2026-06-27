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
    /// near the same extra can't both claim it (which produced duplicate names). Each target,
    /// in input order, claims its nearest still-unclaimed extra within `tolerance`; an extra
    /// once claimed is unavailable to later targets.
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
        var claimed = Set<Int>()
        return targetMinXs.map { target in
            var bestIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (index, edge) in extraLeftEdges.enumerated() where !claimed.contains(index) {
                let distance = abs(edge - target)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            if let bestIndex, bestDistance <= tolerance {
                claimed.insert(bestIndex)
                return bestIndex
            }
            return nil
        }
    }
}
