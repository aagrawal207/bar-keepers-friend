import CoreGraphics
import Foundation

/// The single seam between the app and the private window-server APIs.
///
/// Every call that would touch the undocumented `CGS*` / SkyLight symbols, or synthesize
/// CGEvents into other processes, goes through this protocol. Higher layers depend only on
/// the protocol, so they are tested against `FakeWindowServer`. The real implementation
/// (Phase 2+) lives in the app target's bridging module and is the *only* place private
/// symbols are declared — its return values are validated and feed the compatibility-mode
/// kill-switch.
public protocol WindowServer: Sendable {

    /// Enumerates the status-item windows currently on the menu bar, across the relevant
    /// display/space. May return an empty array; callers must treat empty / nonsensical
    /// results as a signal to degrade rather than crash.
    func menuBarItems() throws -> [MenuBarItemSnapshot]

    /// The frame of the system menu bar on the display containing the given point.
    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect

    /// Physically moves a status item so its leading edge lands at the target x-position.
    /// Implementations confirm the move by observing a frame change and retry on failure.
    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat) throws

    /// Synthesizes a click on the given status item.
    func click(item: MenuBarItemSnapshot) throws

    /// Whether the app currently has the permission needed to synthesize clicks into other
    /// processes (Accessibility). Checked before revealing items for an activation, so the
    /// app never reveals (stranding icons in the menu bar) when the click would fail.
    var canSynthesizeClicks: Bool { get }
}

/// Errors a `WindowServer` can surface. Distinguishing these lets the app decide between a
/// transient retry and flipping to compatibility mode.
public enum WindowServerError: Error, Equatable, Sendable {
    /// A private symbol returned an obviously invalid result (zero connection, garbage
    /// count, empty rect). The trigger for compatibility mode.
    case invalidServerResponse(String)
    /// An item move did not take effect within the retry budget.
    case moveFailed(windowID: CGWindowID)
    /// A click could not be confirmed as delivered.
    case clickFailed(windowID: CGWindowID)
    /// The operation needs a permission the app has not been granted.
    case missingPermission(Permission)
}
