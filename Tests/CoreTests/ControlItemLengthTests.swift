import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct ControlItemLengthTests {

    @Test func expandedIsWiderThanScreenButBounded() {
        // Typical laptop width.
        let laptop = ControlItemLength.expanded(forScreenWidth: 1512)
        #expect(laptop > 1512)       // pushes items off-screen
        #expect(laptop <= 4000)      // never the catastrophic 10_000

        // Ultra-wide external display: still capped.
        let ultrawide = ControlItemLength.expanded(forScreenWidth: 5120)
        #expect(ultrawide == 4000)
    }

    @Test func expandedHasSafeFloorForTinyScreens() {
        let tiny = ControlItemLength.expanded(forScreenWidth: 100)
        #expect(tiny == 500)
    }

    @Test func expandedNeverReachesMemoryBlowupConstant() {
        // Regression guard for the documented multi-GB leak from huge lengths.
        for width in stride(from: CGFloat(800), through: 8000, by: 100) {
            #expect(ControlItemLength.expanded(forScreenWidth: width) < 10_000)
        }
    }
}
