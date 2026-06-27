import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct MenuBarItemSnapshotTests {

    private func item(x: CGFloat, w: CGFloat = 24) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: 1, ownerPID: 1, frame: CGRect(x: x, y: 0, width: w, height: 22))
    }

    @Test func onScreenItemIsClickable() {
        #expect(item(x: 500).isClickableOnScreen)
        #expect(item(x: 0).isClickableOnScreen)
    }

    @Test func offScreenItemIsNotClickable() {
        // Pushed off-screen left by the hidden divider — must be revealed before a click.
        #expect(!item(x: -200).isClickableOnScreen)
    }

    @Test func zeroWidthItemIsNotClickable() {
        #expect(!item(x: 100, w: 0).isClickableOnScreen)
    }

    @Test func attributedFillsOwner() {
        let attributed = item(x: 100).attributed(bundleID: "com.example.App", pid: 42)
        #expect(attributed.ownerBundleID == "com.example.App")
        #expect(attributed.ownerPID == 42)
    }
}
