import ApplicationServices
import BarKeepersFriendCore
import CoreGraphics

/// The real `PermissionProbe`: reports live TCC status for the two permissions the Pro layer
/// uses. The pure `PermissionState` machine (in Core) consumes this and handles lapse detection,
/// so this type stays a thin, dependency-free reader — exactly what makes the state logic testable
/// against a fake instead of real prompts.
///
/// Neither permission gates the cosmetic baseline; both only enable Pro features (moving/clicking
/// items needs Accessibility, mirroring icon images needs Screen Recording). So the probe never
/// reports `.notDetermined` as a blocker — it just tells the UI what to surface.
struct SystemPermissionProbe: PermissionProbe {
    func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            // AXIsProcessTrusted is a clean boolean: granted or not. There's no public way to
            // distinguish "denied" from "never asked", so a non-granted result reads as `.denied`
            // and the state machine promotes it to `.lapsed` if it was granted before.
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            // CGPreflightScreenCaptureAccess reflects launch-time grant state without prompting.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }
}
