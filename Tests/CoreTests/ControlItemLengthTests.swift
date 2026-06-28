import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct ControlItemLengthTests {

    @Test func expandedAlwaysExceedsTheScreenItMustClear() {
        // The core invariant: the divider has to be WIDER than its display, or the leftmost hidden
        // items aren't pushed off-screen and hide partially fails. This must hold for every
        // supported display — laptop through 5K/6K/ultrawide. (Regression for the old 4000 cap,
        // which made the divider NARROWER than a wide display and silently broke hiding there.)
        for width in [CGFloat(1512), 2560, 3840, 5120, 6016] {
            #expect(ControlItemLength.expanded(forScreenWidth: width) > width)
        }
    }

    @Test func expandedHasSafeFloorForTinyScreens() {
        let tiny = ControlItemLength.expanded(forScreenWidth: 100)
        #expect(tiny == 500)
    }

    @Test func expandedNeverReachesMemoryBlowupConstant() {
        // Regression guard for the documented multi-GB leak from huge lengths: the result must stay
        // clear of the ~10000 window-server blowup regime across the full bound range.
        for width in stride(from: CGFloat(800), through: 9000, by: 100) {
            #expect(ControlItemLength.expanded(forScreenWidth: width) < 10_000)
        }
    }

    @Test func expandedIsBackstoppedForAPathologicalWidth() {
        // The ceiling only binds for an absurd width no real display reaches; verify the backstop
        // still clamps below the blowup regime there.
        #expect(ControlItemLength.expanded(forScreenWidth: 50_000) == 9000)
    }
}
