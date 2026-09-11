import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct HoverRevealStateMachineTests {
    typealias Machine = HoverRevealStateMachine

    @Test func disabledByDefault() {
        var machine = Machine()
        #expect(!machine.isEnabled)
        #expect(!machine.ownsPanel)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 10) == nil)
        #expect(machine.requestID == nil)
    }

    @Test func sustainedDwellRequestsExactlyOneRevealWithoutOwningAManualPanel() throws {
        var machine = Machine()
        machine.setEnabled(true)
        for now in [0, 0.05, 0.1, 0.199] {
            #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: now) == nil)
        }
        let effect = machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0.2)
        let id = try #require(machine.requestID)
        #expect(effect == .show(id))
        #expect(!machine.ownsPanel)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1) == nil)
        let beganReveal = machine.beginReveal(id, pointer: .anchor, panelVisible: false, canReveal: true)
        #expect(beganReveal)
        #expect(machine.ownsPanel)
        let beganAgain = machine.beginReveal(id, pointer: .anchor, panelVisible: false, canReveal: true)
        #expect(!beganAgain)
    }

    @Test(arguments: [Machine.PointerRegion.outside, .panel, .gap, .unavailable])
    func leavingAnchorCancelsDwell(pointer: Machine.PointerRegion) {
        var machine = Machine()
        machine.setEnabled(true)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0)
        machine.update(pointer: pointer, panelVisible: false, canReveal: true, now: 0.15)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1.199) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1.2) != nil)
    }

    @Test(arguments: [Machine.PointerRegion.anchor, .panel, .gap])
    func anchorPanelAndGapKeepOwnershipAndCancelAnExit(pointer: Machine.PointerRegion) throws {
        var machine = Machine()
        let id = try reveal(&machine)
        #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: 1) == nil)
        #expect(machine.update(pointer: pointer, panelVisible: true, canReveal: true, now: 1.39) == nil)
        #expect(machine.update(pointer: pointer, panelVisible: true, canReveal: true, now: 100) == nil)
        #expect(machine.requestID == id)
        #expect(machine.ownsPanel)
        #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: 101) == nil)
        #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: 101.399) == nil)
        #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: 101.4) == .hide)
    }

    @Test func exitGraceDoesNotResetAtEverySampleAndHidesOnlyOnce() throws {
        var machine = Machine()
        try reveal(&machine)
        for now in [1, 1.1, 1.2, 1.399] {
            #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: now) == nil)
        }
        #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: 1.4) == .hide)
        #expect(!machine.ownsPanel)
        #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: 2) == nil)
        #expect(machine.setEnabled(false) == nil)
    }

    @Test func existingManualPanelCannotBeClaimedOrHidden() {
        var machine = Machine()
        machine.setEnabled(true)
        for pointer in [Machine.PointerRegion.anchor, .panel, .gap, .outside] {
            #expect(machine.update(pointer: pointer, panelVisible: true, canReveal: true, now: 10) == nil)
        }
        #expect(machine.requestID == nil)
        #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: false, now: 20) == nil)
        #expect(machine.setEnabled(false) == nil)
    }

    @Test func manualInteractionCancelsDwellUntilAnObservedAnchorExit() {
        var machine = Machine()
        machine.setEnabled(true)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0)
        machine.relinquishForManualInteraction(pointer: .anchor)
        for now in [0.2, 1, 10] {
            #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: now) == nil)
        }
        machine.update(pointer: .unavailable, panelVisible: false, canReveal: false, now: 11)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 12) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 13) == nil)
        machine.update(pointer: .outside, panelVisible: false, canReveal: true, now: 14)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 15) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 15.2) != nil)
    }

    @Test func manualTakeoverDropsOwnershipWithoutHidingOrCompletingOldWork() throws {
        var machine = Machine()
        let id = try reveal(&machine)
        machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: 1)
        machine.relinquishForManualInteraction(pointer: .anchor)
        #expect(!machine.ownsPanel)
        #expect(machine.revealCompleted(id, pointer: .outside, panelVisible: true, canReveal: false, now: 2) == nil)
        #expect(machine.update(pointer: .outside, panelVisible: true, canReveal: true, now: 10) == nil)
        #expect(machine.setEnabled(false) == nil)
    }

    @Test func ineligiblePointerExcursionsCannotClearManualCloseSuppression() throws {
        var machine = Machine()
        try reveal(&machine)
        machine.relinquishForManualInteraction(pointer: .anchor)
        machine.update(pointer: .outside, panelVisible: false, canReveal: false, now: 1)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: false, now: 2)
        for now in [3, 3.2, 10] {
            #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: now) == nil)
        }
        #expect(machine.requestID == nil)
        machine.update(pointer: .outside, panelVisible: false, canReveal: true, now: 11)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 12)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 12.2) != nil)
    }

    @Test func manualInteractionAwayFromAnchorAllowsTheNextEntry() {
        var machine = Machine()
        machine.setEnabled(true)
        machine.relinquishForManualInteraction(pointer: .outside)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1.2) != nil)
    }

    @Test func disableDropsPendingRequestButClosesOnlyOwnedPresentation() throws {
        var machine = Machine()
        machine.setEnabled(true)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0.2)
        let pendingID = try #require(machine.requestID)
        #expect(machine.setEnabled(false) == nil)
        let beganReveal = machine.beginReveal(pendingID, pointer: .anchor, panelVisible: false, canReveal: true)
        #expect(!beganReveal)
        #expect(machine.requestID == nil)
        try reveal(&machine, at: 1)
        #expect(machine.setEnabled(false) == .hide)
        #expect(machine.setEnabled(false) == nil)
        #expect(!machine.ownsPanel)
    }

    @Test func disableAndReenableDoNotClearManualSuppression() {
        var machine = Machine()
        machine.setEnabled(true)
        machine.relinquishForManualInteraction(pointer: .anchor)
        machine.setEnabled(false)
        machine.setEnabled(true)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 10) == nil)
    }

    @Test func eligibilityLossCancelsDwellAndRecoveryRequiresAFreshDwell() {
        var machine = Machine()
        machine.setEnabled(true)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: false, now: 0.2) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1.199) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1.2) != nil)
    }

    @Test func eligibilityLossClosesOwnedPanelWithoutExitGrace() throws {
        var machine = Machine()
        try reveal(&machine)
        #expect(machine.update(pointer: .anchor, panelVisible: true, canReveal: false, now: 0.21) == .hide)
        #expect(!machine.ownsPanel)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1) == nil)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1.2) != nil)
    }

    @Test(arguments: [
        (Machine.PointerRegion.outside, false, true),
        (Machine.PointerRegion.anchor, false, false),
        (Machine.PointerRegion.anchor, true, true)
    ])
    func queuedRevealRechecksPointerEligibilityAndManualVisibility(
        pointer: Machine.PointerRegion, panelVisible: Bool, canReveal: Bool
    ) throws {
        var machine = Machine()
        machine.setEnabled(true)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0.2)
        let id = try #require(machine.requestID)
        let beganReveal = machine.beginReveal(
            id, pointer: pointer, panelVisible: panelVisible, canReveal: canReveal
        )
        #expect(!beganReveal)
        #expect(machine.requestID == nil)
        #expect(!machine.ownsPanel)
        #expect(machine.setEnabled(false) == nil)
    }

    @Test func staleBeginAndCompletionCannotAffectANewerRequest() throws {
        var machine = Machine()
        let oldID = try reveal(&machine)
        machine.relinquishForManualInteraction(pointer: .outside)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1.2)
        let newID = try #require(machine.requestID)
        #expect(newID != oldID)
        let beganOldReveal = machine.beginReveal(oldID, pointer: .anchor, panelVisible: false, canReveal: true)
        #expect(!beganOldReveal)
        #expect(machine.revealCompleted(oldID, pointer: .outside, panelVisible: true, canReveal: false, now: 2) == nil)
        #expect(machine.requestID == newID)
        let beganNewReveal = machine.beginReveal(newID, pointer: .anchor, panelVisible: false, canReveal: true)
        #expect(beganNewReveal)
        #expect(machine.revealCompleted(oldID, pointer: .outside, panelVisible: true, canReveal: false, now: 3) == nil)
        #expect(machine.requestID == newID)
        #expect(machine.ownsPanel)
    }

    @Test func pointerLeavingDuringAnUnfinishedShowCancelsOwnership() throws {
        var machine = Machine()
        machine.setEnabled(true)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0.2)
        let id = try #require(machine.requestID)
        let beganReveal = machine.beginReveal(id, pointer: .anchor, panelVisible: false, canReveal: true)
        #expect(beganReveal)
        #expect(machine.update(pointer: .outside, panelVisible: false, canReveal: true, now: 0.21) == nil)
        #expect(machine.requestID == nil)
        #expect(machine.revealCompleted(id, pointer: .anchor, panelVisible: true, canReveal: true, now: 1) == nil)
    }

    @Test(arguments: [false, true])
    func failedShowOrExternalDismissalDoesNotRetryUnderAStationaryPointer(showSucceeded: Bool) throws {
        var machine = Machine()
        machine.setEnabled(true)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 0.2)
        let id = try #require(machine.requestID)
        let beganReveal = machine.beginReveal(id, pointer: .anchor, panelVisible: false, canReveal: true)
        #expect(beganReveal)
        machine.revealCompleted(id, pointer: .anchor, panelVisible: showSucceeded, canReveal: true, now: 0.2)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 1)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 10) == nil)
        #expect(machine.requestID == nil)
        machine.update(pointer: .outside, panelVisible: false, canReveal: true, now: 11)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 12)
        #expect(machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: 12.2) != nil)
    }

    @Test(arguments: [CGPoint.zero, CGPoint(x: -1920, y: 0), CGPoint(x: 0, y: -1080), CGPoint(x: 0, y: 982)])
    func geometryUsesGlobalCoordinatesAndOnlyBridgesTheGap(offset: CGPoint) {
        let anchor = CGRect(x: 100, y: 100, width: 32, height: 24).offsetBy(dx: offset.x, dy: offset.y)
        let panel = CGRect(x: 40, y: 50, width: 92, height: 46).offsetBy(dx: offset.x, dy: offset.y)
        for (point, expected) in [
            (CGPoint(x: 116, y: 112), Machine.PointerRegion.anchor),
            (CGPoint(x: 116, y: 124), .anchor),
            (CGPoint(x: 132, y: 112), .anchor),
            (CGPoint(x: 60, y: 70), .panel),
            (CGPoint(x: 60, y: 96), .panel),
            (CGPoint(x: 116, y: 98), .gap),
            (CGPoint(x: 60, y: 98), .gap),
            (CGPoint(x: 60, y: 112), .outside),
            (CGPoint(x: 133, y: 98), .outside),
            (CGPoint(x: 116, y: 49), .outside)
        ] {
            #expect(Machine.region(
                at: CGPoint(x: point.x + offset.x, y: point.y + offset.y),
                anchorFrame: anchor, panelFrame: panel
            ) == expected)
        }
    }

    @Test func gapGeometryAlsoHandlesAPanelAboveTheAnchor() {
        let anchor = CGRect(x: 100, y: -124, width: 32, height: 24)
        let panel = CGRect(x: 40, y: -96, width: 92, height: 46)
        #expect(Machine.region(at: CGPoint(x: 116, y: -98), anchorFrame: anchor, panelFrame: panel) == .gap)
        #expect(Machine.region(at: CGPoint(x: 60, y: -112), anchorFrame: anchor, panelFrame: panel) == .outside)
    }

    @Test func absentInvalidOrUnrelatedGeometryCannotCreateABridge() {
        let anchor = CGRect(x: 100, y: 100, width: 32, height: 24)
        let panel = CGRect(x: 40, y: 50, width: 92, height: 46)
        let point = CGPoint(x: 116, y: 98)
        #expect(Machine.region(at: point, anchorFrame: anchor, panelFrame: nil) == .outside)
        #expect(Machine.region(at: point, anchorFrame: nil, panelFrame: panel) == .unavailable)
        for frame in [CGRect.zero, .null, .infinite, CGRect(x: 100, y: 100, width: CGFloat.nan, height: 24)] {
            #expect(Machine.region(at: point, anchorFrame: frame, panelFrame: panel) == .unavailable)
            #expect(Machine.region(at: point, anchorFrame: anchor, panelFrame: frame) == .outside)
        }
        #expect(Machine.region(at: CGPoint(x: CGFloat.nan, y: 112), anchorFrame: anchor, panelFrame: panel) == .unavailable)
        #expect(Machine.region(at: point, anchorFrame: anchor, panelFrame: panel.offsetBy(dx: 200, dy: 0)) == .outside)
        #expect(Machine.region(at: CGPoint(x: 90, y: 112), anchorFrame: anchor, panelFrame: panel.offsetBy(dx: 0, dy: 10)) == .outside)
    }

    @discardableResult
    private func reveal(_ machine: inout Machine, at now: Double = 0) throws -> UInt64 {
        machine.setEnabled(true)
        machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: now)
        let effect = machine.update(pointer: .anchor, panelVisible: false, canReveal: true, now: now + Machine.dwellDelay)
        let id = try #require(machine.requestID)
        #expect(effect == .show(id))
        let beganReveal = machine.beginReveal(id, pointer: .anchor, panelVisible: false, canReveal: true)
        #expect(beganReveal)
        #expect(machine.revealCompleted(
            id, pointer: .anchor, panelVisible: true, canReveal: true, now: now + Machine.dwellDelay
        ) == nil)
        return id
    }
}
