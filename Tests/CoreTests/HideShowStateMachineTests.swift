import Testing
@testable import BarKeepersFriendCore

@Suite struct HideShowStateMachineTests {

    @Test func hiddenSectionStartsCollapsed() {
        let machine = HideShowStateMachine()
        #expect(machine.visibility(of: .hidden) == .collapsed)
    }

    @Test func visibleSectionIsAlwaysShown() {
        var machine = HideShowStateMachine()
        #expect(machine.visibility(of: .visible) == .shown)
        // Toggling .visible is a no-op and emits no intents.
        #expect(machine.apply(.toggle(.visible)).isEmpty)
        #expect(machine.visibility(of: .visible) == .shown)
    }

    @Test func toggleFlipsHiddenAndEmitsOneIntent() {
        var machine = HideShowStateMachine()
        let shown = machine.apply(.toggle(.hidden))
        #expect(shown == [.init(section: .hidden, visibility: .shown)])
        #expect(machine.visibility(of: .hidden) == .shown)

        let hidden = machine.apply(.toggle(.hidden))
        #expect(hidden == [.init(section: .hidden, visibility: .collapsed)])
        #expect(machine.visibility(of: .hidden) == .collapsed)
    }

    @Test func redundantTransitionEmitsNoIntent() {
        var machine = HideShowStateMachine()
        // Already collapsed; hiding again should change nothing.
        #expect(machine.apply(.hide(.hidden)).isEmpty)
        _ = machine.apply(.show(.hidden))
        // Already shown; showing again is a no-op.
        #expect(machine.apply(.show(.hidden)).isEmpty)
    }

    @Test func autoRehideCollapsesConfiguredSections() {
        var machine = HideShowStateMachine(autoRehideSections: [.hidden])
        _ = machine.apply(.show(.hidden))
        let intents = machine.apply(.autoRehide)
        #expect(intents == [.init(section: .hidden, visibility: .collapsed)])
        #expect(machine.visibility(of: .hidden) == .collapsed)
    }

    @Test func autoRehideDoesNothingWhenNotConfigured() {
        var machine = HideShowStateMachine(autoRehideSections: [])
        _ = machine.apply(.show(.hidden))
        #expect(machine.apply(.autoRehide).isEmpty)
        #expect(machine.visibility(of: .hidden) == .shown)
    }

    @Test func screenParametersChangeRecollapsesEverything() {
        var machine = HideShowStateMachine()
        _ = machine.apply(.show(.hidden))
        let intents = machine.apply(.screenParametersChanged)
        #expect(intents.contains(.init(section: .hidden, visibility: .collapsed)))
        #expect(machine.visibility(of: .hidden) == .collapsed)
    }
}
