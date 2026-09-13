import Foundation

/// When saved Shown/Hidden placement is re-applied to the menu bar.
public enum LayoutMode: String, Codable, Sendable, CaseIterable {
    /// Placement is applied at launch, on Apply Changes, and when displays change.
    case onDemand
    /// Also re-applied after apps launch or quit, once the pointer has been idle.
    case live
}
