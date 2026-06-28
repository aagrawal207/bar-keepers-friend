import Testing
@testable import BarKeepersFriendCore

@Suite struct PermissionStateTests {

    /// A scriptable probe returning whatever statuses the test sets.
    private final class StubProbe: PermissionProbe, @unchecked Sendable {
        var statuses: [Permission: PermissionStatus]
        init(_ statuses: [Permission: PermissionStatus]) { self.statuses = statuses }
        func status(of permission: Permission) -> PermissionStatus {
            statuses[permission] ?? .notDetermined
        }
    }

    @Test func coreRunsWithoutAnyPermissions() {
        // Both permissions are optional, so the core app is always usable.
        let state = PermissionState()
        #expect(state.canRunCore)
    }

    @Test func refreshReflectsProbe() {
        var state = PermissionState()
        let probe = StubProbe([.accessibility: .granted, .screenRecording: .denied])
        state.refresh(using: probe)
        #expect(state.status(of: .accessibility) == .granted)
        #expect(state.status(of: .screenRecording) == .denied)
    }

    @Test func previouslyGrantedThenUngrantedBecomesLapsed() {
        var state = PermissionState()
        let probe = StubProbe([.screenRecording: .granted])
        state.refresh(using: probe)
        #expect(state.status(of: .screenRecording) == .granted)

        // The recurring Sequoia/Tahoe re-prompt: probe now reports not-granted.
        probe.statuses[.screenRecording] = .notDetermined
        state.refresh(using: probe)
        #expect(state.status(of: .screenRecording) == .lapsed)
    }

    @Test func deepLinkURLsAreCorrect() {
        #expect(Permission.accessibility.settingsURLString.contains("Privacy_Accessibility"))
        #expect(Permission.screenRecording.settingsURLString.contains("Privacy_ScreenCapture"))
    }

    @Test func accessibilityGrantThenDenyBecomesLapsed() {
        // The Permissions UI relies on this for BOTH permissions: a grant that later reads as
        // denied (the recurring Tahoe re-prompt, or the user revoking it) must surface as
        // `.lapsed` so the row shows "Needs re-approval" rather than a bare "Not granted".
        var state = PermissionState()
        let probe = StubProbe([.accessibility: .granted])
        state.refresh(using: probe)
        #expect(state.status(of: .accessibility) == .granted)

        probe.statuses[.accessibility] = .denied
        state.refresh(using: probe)
        #expect(state.status(of: .accessibility) == .lapsed)
    }

    @Test func freshDenyStaysDeniedNotLapsed() {
        // A permission never granted in this session reads as plain denied, not lapsed — the UI
        // shows "Not granted", not the alarming "Needs re-approval".
        var state = PermissionState()
        state.refresh(using: StubProbe([.accessibility: .denied, .screenRecording: .denied]))
        #expect(state.status(of: .accessibility) == .denied)
        #expect(state.status(of: .screenRecording) == .denied)
    }

    @Test func coreStillRunsRegardlessOfOptionalPermissionState() {
        // Both permissions are optional, so even with everything denied the core app is usable —
        // the Permissions UI must never present itself as blocking.
        var state = PermissionState()
        state.refresh(using: StubProbe([.accessibility: .denied, .screenRecording: .denied]))
        #expect(state.canRunCore)
    }
}
