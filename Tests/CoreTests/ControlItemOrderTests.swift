import Testing
@testable import BarKeepersFriendCore

@Suite struct ControlItemOrderTests {

    @Test func correctOrderNeedsNoRepair() {
        // Divider strictly left of the anchor (higher slot = further left) → already correct.
        #expect(ControlItemOrder.repairedDividerPosition(anchor: 363, divider: 379) == nil)
    }

    @Test func invertedOrderIsRepairedToJustLeftOfAnchor() {
        // The reported bug: divider (363) drifted to the RIGHT of the anchor (379). Expanding the
        // divider would then push the anchor itself off-screen. Repair parks it one unit left.
        #expect(ControlItemOrder.repairedDividerPosition(anchor: 379, divider: 363) == 380)
    }

    @Test func equalSlotsAreTreatedAsInverted() {
        // A tie doesn't guarantee the divider orders left, so nudge it strictly left to be safe.
        #expect(ControlItemOrder.repairedDividerPosition(anchor: 200, divider: 200) == 201)
    }
}
