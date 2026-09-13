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

    @Test func alwaysHiddenDividerMustOrderLeftOfTheHiddenDivider() {
        #expect(ControlItemOrder.repairedAlwaysHiddenDividerPosition(hiddenDivider: 380, alwaysHiddenDivider: 400) == nil)
        #expect(ControlItemOrder.repairedAlwaysHiddenDividerPosition(hiddenDivider: 380, alwaysHiddenDivider: 370) == 381)
        #expect(ControlItemOrder.repairedAlwaysHiddenDividerPosition(hiddenDivider: 380, alwaysHiddenDivider: 380) == 381)
    }

    @Test func chainRepairChecksTheAlwaysHiddenSlotAgainstTheRepairedHiddenSlot() {
        // Anchor 379, hidden divider drifted right (363), always-hidden at 375: repairing the hidden
        // divider to 380 must also push the always-hidden divider past it, not leave it at 375.
        let repaired = ControlItemOrder.repairedPositions(anchor: 379, hiddenDivider: 363, alwaysHiddenDivider: 375)
        #expect(repaired.hiddenDivider == 380)
        #expect(repaired.alwaysHiddenDivider == 381)
    }

    @Test func chainRepairLeavesACorrectChainAndAnAbsentAlwaysHiddenSlotAlone() {
        let correct = ControlItemOrder.repairedPositions(anchor: 363, hiddenDivider: 379, alwaysHiddenDivider: 390)
        #expect(correct.hiddenDivider == nil)
        #expect(correct.alwaysHiddenDivider == nil)
        let absent = ControlItemOrder.repairedPositions(anchor: 379, hiddenDivider: 363, alwaysHiddenDivider: nil)
        #expect(absent.hiddenDivider == 380)
        #expect(absent.alwaysHiddenDivider == nil)
        let onlyTierInverted = ControlItemOrder.repairedPositions(anchor: 363, hiddenDivider: 379, alwaysHiddenDivider: 370)
        #expect(onlyTierInverted.hiddenDivider == nil)
        #expect(onlyTierInverted.alwaysHiddenDivider == 380)
    }
}
