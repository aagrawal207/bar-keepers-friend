import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct DisplayGeometryTests {

    // AppKit frames: bottom-left origin. The primary is the zero-origin screen.
    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func primaryHeightFindsTheZeroOriginScreen() {
        // A laptop (primary) with a wide external display to its right at a different height.
        let external = CGRect(x: 1512, y: 0, width: 3840, height: 2160)
        #expect(DisplayGeometry.primaryHeight(screenFrames: [primary, external]) == 982)
    }

    @Test func primaryHeightIgnoresArrayOrder() {
        // The regression: NSScreen.screens is NOT guaranteed to lead with the primary. The old code
        // used `screens.first`, so a non-primary-first arrangement gave the wrong primary height.
        let external = CGRect(x: -3840, y: 0, width: 3840, height: 2160) // to the LEFT of primary
        let firstIsNotPrimary = [external, primary]
        #expect(DisplayGeometry.primaryHeight(screenFrames: firstIsNotPrimary) == 982) // not 2160
    }

    @Test func primaryHeightIsNilWhenNoZeroOriginScreen() {
        // Transient reconfiguration: no zero-origin screen present → caller should no-op.
        let frames = [CGRect(x: 100, y: 100, width: 800, height: 600)]
        #expect(DisplayGeometry.primaryHeight(screenFrames: frames) == nil)
    }

    @Test func cgTopOfPrimaryIsZero() {
        #expect(DisplayGeometry.cgTopY(screenFrame: primary, primaryHeight: 982) == 0)
    }

    @Test func cgTopOfDisplayStackedBelowIsPositive() {
        // A display BELOW the primary: AppKit frame sits at negative y (its top edge maxY is at
        // y=0, its body extends down to -1080). In CG space its menu-bar top is at +982.
        let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080) // maxY = 0
        #expect(DisplayGeometry.cgTopY(screenFrame: below, primaryHeight: 982) == 982)
    }

    @Test func cgTopOfDisplayStackedAboveIsNegative() {
        // A display ABOVE the primary: its AppKit frame sits above (minY = 982), so maxY = 2062.
        // In CG space (where the primary's top is 0 and y grows down) its top is negative.
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080) // maxY = 2062
        #expect(DisplayGeometry.cgTopY(screenFrame: above, primaryHeight: 982) == -1080)
    }

    @Test func menuBarTopYResolvesPrimaryRegardlessOfOrder() {
        // End-to-end with the primary NOT first: the below-display's CG top must still be +982,
        // proving the primary is resolved by origin, not position. (This was the live bug.)
        let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let frames = [below, primary] // primary deliberately second
        #expect(DisplayGeometry.menuBarTopY(of: below, allScreenFrames: frames) == 982)
        #expect(DisplayGeometry.menuBarTopY(of: primary, allScreenFrames: frames) == 0)
    }

    @Test func menuBarTopYDefaultsToZeroWhenPrimaryUnresolvable() {
        let orphan = CGRect(x: 50, y: 50, width: 800, height: 600)
        #expect(DisplayGeometry.menuBarTopY(of: orphan, allScreenFrames: [orphan]) == 0)
    }
}
