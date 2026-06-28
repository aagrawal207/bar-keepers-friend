import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct MenuBarItemSnapshotTests {

    private func item(x: CGFloat, w: CGFloat = 24) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: 1, ownerPID: 1, frame: CGRect(x: x, y: 0, width: w, height: 22))
    }

    @Test func onScreenItemIsClickable() {
        #expect(item(x: 500).isClickableOnScreen())
        #expect(item(x: 0).isClickableOnScreen())
    }

    @Test func offScreenItemIsNotClickable() {
        // Pushed off-screen left by the hidden divider — must be revealed before a click.
        #expect(!item(x: -200).isClickableOnScreen())
    }

    @Test func zeroWidthItemIsNotClickable() {
        #expect(!item(x: 100, w: 0).isClickableOnScreen())
    }

    @Test func clickableIsRelativeToTheItemsDisplay() {
        // A display 1440pt wide sitting LEFT of the primary occupies global x in [-1440, 0). An
        // item revealed there has minX < 0 but is fully on-screen FOR ITS DISPLAY, so it must be
        // clickable. The old absolute `minX >= 0` test rejected it, killing activation on that
        // display. An item pushed left of that display's own edge is still off-screen.
        #expect(item(x: -1200).isClickableOnScreen(displayMinX: -1440))   // on its display
        #expect(item(x: -1440).isClickableOnScreen(displayMinX: -1440))   // exactly at the edge
        #expect(!item(x: -1500).isClickableOnScreen(displayMinX: -1440))  // pushed off its display
        // The primary / single-display default is unchanged.
        #expect(item(x: 500).isClickableOnScreen())
        #expect(!item(x: -200).isClickableOnScreen())
    }

    @Test func attributedFillsOwner() {
        let attributed = item(x: 100).attributed(bundleID: "com.example.App", pid: 42)
        #expect(attributed.ownerBundleID == "com.example.App")
        #expect(attributed.ownerPID == 42)
    }
}
