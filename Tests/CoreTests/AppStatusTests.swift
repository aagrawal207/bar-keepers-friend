import Testing
@testable import BarKeepersFriendCore

/// Unit tests for the pure `AppStatus` derivation that drives the anchor menu's status line.
@Suite struct AppStatusTests {

    @Test func idleIsReady() {
        #expect(AppStatus.derive(moving: false, capturing: false, updateAvailable: false) == .ready)
    }

    @Test func movingShowsWorking() {
        #expect(AppStatus.derive(moving: true, capturing: false, updateAvailable: false) == .working)
    }

    @Test func capturingShowsCollecting() {
        #expect(AppStatus.derive(moving: false, capturing: true, updateAvailable: false) == .collecting)
    }

    @Test func updateAvailableWinsOverBusyStates() {
        // A standing fact the user should act on outranks the transient busy states.
        #expect(AppStatus.derive(moving: true, capturing: true, updateAvailable: true) == .updateAvailable)
    }

    @Test func movingOutranksCapturing() {
        // A reconcile runs inside a capture sequence, so both flags can be true at once; "Working"
        // (the move) is the more informative of the two to surface.
        #expect(AppStatus.derive(moving: true, capturing: true, updateAvailable: false) == .working)
    }

    @Test func everyStatusHasANonEmptyLabel() {
        let all: [AppStatus] = [.ready, .working, .collecting, .updateAvailable]
        for status in all {
            #expect(!status.label.isEmpty)
        }
        // Spot-check the user-facing wording so a careless rename is caught.
        #expect(AppStatus.ready.label == "Ready")
        #expect(AppStatus.updateAvailable.label == "Update available")
    }
}
