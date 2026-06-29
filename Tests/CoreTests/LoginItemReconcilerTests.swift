import Testing
@testable import BarKeepersFriendCore

/// Unit tests for the pure launch-at-login reconcile decision. The `SMAppService` call itself
/// lives in the app target and isn't unit-tested; this covers the logic that was actually wrong
/// — deciding *whether* to re-register at startup and how to treat the approval-pending state.
@Suite struct LoginItemReconcilerTests {

    @Test func registersWhenDesiredButNotRegistered() {
        #expect(LoginItemReconciler.decide(desired: true, actual: .notRegistered) == .register)
    }

    @Test func registersWhenDesiredButServiceNotFound() {
        // notFound is the lost-registration case (e.g. after an OS update) — re-assert it.
        #expect(LoginItemReconciler.decide(desired: true, actual: .notFound) == .register)
    }

    @Test func noActionWhenDesiredAndAlreadyEnabled() {
        #expect(LoginItemReconciler.decide(desired: true, actual: .enabled) == .none)
    }

    @Test func unregistersWhenNotDesiredButEnabled() {
        #expect(LoginItemReconciler.decide(desired: false, actual: .enabled) == .unregister)
    }

    @Test func noActionWhenNotDesiredAndAlreadyOff() {
        #expect(LoginItemReconciler.decide(desired: false, actual: .notRegistered) == .none)
        #expect(LoginItemReconciler.decide(desired: false, actual: .notFound) == .none)
    }

    @Test func leavesApprovalPendingAlone() {
        // requiresApproval means the system already has our intent on file but the user must
        // approve (or has toggled it off) in System Settings. Re-registering every launch would
        // fight a deliberate user choice, so we never act on it either way.
        #expect(LoginItemReconciler.decide(desired: true, actual: .requiresApproval) == .none)
        #expect(LoginItemReconciler.decide(desired: false, actual: .requiresApproval) == .none)
    }
}
