import AppKit
import BarKeepersFriendCore

/// State for the first-run walkthrough. Every side effect (permission probing, System Settings
/// deep links, completion) is injected so the flow can be exercised without prompting the user.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Sendable {
        case welcome, layoutMode, permissions, done

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .layoutMode: return "Layout Mode"
            case .permissions: return "Permissions"
            case .done: return "All Set"
            }
        }
    }

    private(set) var step: Step = .welcome
    private(set) var permissions = PermissionState()
    private(set) var isCompleted = false

    /// Runs exactly once, whether the user finishes, skips, or closes the window.
    @ObservationIgnored var onComplete: @MainActor () -> Void
    /// Opens the app's own Settings (Items tab); always preceded by `onComplete`.
    @ObservationIgnored var onOpenSettings: @MainActor () -> Void
    /// Presenter hook that runs before `onComplete`, so the window is already gone when the host
    /// persists completion and possibly releases the presenter. Independent of when `onComplete` is set.
    @ObservationIgnored var onWillComplete: @MainActor () -> Void = {}
    private let permissionProbe: PermissionProbe
    private let requestAccessibility: @MainActor () -> Void
    private let openScreenRecording: @MainActor () -> Void
    private let pollInterval: Duration
    private let sleep: @MainActor (Duration) async throws -> Void

    init(
        permissionProbe: PermissionProbe = SystemPermissionProbe(),
        pollInterval: Duration = .seconds(2),
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        requestAccessibility: @escaping @MainActor () -> Void = { AccessibilityPermission.requestAndOpenSettings() },
        openScreenRecording: @escaping @MainActor () -> Void = { ScreenRecordingPermission.openSettings() },
        onOpenSettings: @escaping @MainActor () -> Void = {},
        onComplete: @escaping @MainActor () -> Void = {}
    ) {
        self.permissionProbe = permissionProbe
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.requestAccessibility = requestAccessibility
        self.openScreenRecording = openScreenRecording
        self.onOpenSettings = onOpenSettings
        self.onComplete = onComplete
    }

    // MARK: - Navigation

    var canGoBack: Bool { step != .welcome }
    var isLastStep: Bool { step == .done }
    var stepNumber: Int { step.rawValue + 1 }
    static var stepCount: Int { Step.allCases.count }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        move(to: following)
    }

    func back() {
        guard let preceding = Step(rawValue: step.rawValue - 1) else { return }
        move(to: preceding)
    }

    /// Continue on every step but the last, where the same button finishes the walkthrough.
    func performPrimaryAction() {
        if isLastStep { complete() } else { next() }
    }

    private func move(to newStep: Step) {
        step = newStep
        // Probing before the first render avoids a one-frame "Not granted" flash on granted rows.
        if newStep == .permissions { refreshPermissions() }
    }

    // MARK: - Permissions

    func status(of permission: Permission) -> PermissionStatus {
        permissions.status(of: permission)
    }

    func refreshPermissions() {
        permissions.refresh(using: permissionProbe)
    }

    /// Owned by the permissions step's `.task`, so leaving the step cancels the polling.
    func pollPermissions() async {
        while !Task.isCancelled {
            guard (try? await sleep(pollInterval)) != nil, !Task.isCancelled else { return }
            refreshPermissions()
        }
    }

    func openSystemSettings(for permission: Permission) {
        switch permission {
        case .accessibility: requestAccessibility()
        case .screenRecording: openScreenRecording()
        }
    }

    // MARK: - Completion

    func complete() {
        guard !isCompleted else { return }
        isCompleted = true
        onWillComplete()
        onComplete()
    }

    /// Completion runs first so the host can persist and dismiss before Settings takes focus.
    func finishAndOpenSettings() {
        complete()
        onOpenSettings()
    }
}
