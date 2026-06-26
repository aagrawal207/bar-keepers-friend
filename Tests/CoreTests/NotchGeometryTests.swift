import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct NotchGeometryTests {

    /// A 14" MacBook-style notched display: two usable areas flanking a central notch.
    private func notched() -> NotchGeometry {
        NotchGeometry(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            leftArea: CGRect(x: 0, y: 957, width: 700, height: 25),
            rightArea: CGRect(x: 812, y: 957, width: 700, height: 25)
        )
    }

    private func notchless() -> NotchGeometry {
        NotchGeometry(
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            leftArea: nil,
            rightArea: nil
        )
    }

    @Test func detectsNotchPresence() {
        #expect(notched().hasNotch)
        #expect(!notchless().hasNotch)
    }

    @Test func notchRangeSpansBetweenAreas() {
        let range = notched().notchXRange
        #expect(range == 700...812)
    }

    @Test func notchlessDisplayHasNoRange() {
        #expect(notchless().notchXRange == nil)
    }

    @Test func detectsItemUnderNotch() {
        let geometry = notched()
        #expect(geometry.isUnderNotch(midX: 756))   // dead center of the notch
        #expect(!geometry.isUnderNotch(midX: 350))  // left area
        #expect(!geometry.isUnderNotch(midX: 1200)) // right area
    }

    @Test func safePlacementPushesOutOfNotchToNearestEdge() {
        let geometry = notched()
        // Closer to the left edge (700) than the right (812).
        #expect(geometry.safePlacement(desiredMidX: 720) == 700)
        // Closer to the right edge.
        #expect(geometry.safePlacement(desiredMidX: 800) == 812)
    }

    @Test func safePlacementLeavesValidPositionsUnchanged() {
        let geometry = notched()
        #expect(geometry.safePlacement(desiredMidX: 350) == 350)
        #expect(geometry.safePlacement(desiredMidX: 1200) == 1200)
    }

    @Test func safePlacementIsAlwaysOutsideNotch() {
        // Property-style: no desired position should ever resolve to inside the notch.
        let geometry = notched()
        for x in stride(from: CGFloat(680), through: 830, by: 1) {
            let placed = geometry.safePlacement(desiredMidX: x)
            #expect(!geometry.isUnderNotch(midX: placed))
        }
    }
}
