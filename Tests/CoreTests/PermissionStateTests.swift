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
}
