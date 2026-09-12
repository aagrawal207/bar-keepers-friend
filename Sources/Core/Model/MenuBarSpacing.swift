import Foundation

/// Intent for the system-wide `NSStatusItemSpacing` / `NSStatusItemSelectionPadding` global defaults.
/// Apps read them only when creating status items, so a change lands per app after it relaunches.
public struct MenuBarSpacing: Hashable, Codable, Sendable {
    /// Whether custom values are written to the global domain. Off removes both keys.
    public var enabled: Bool

    /// Points between adjacent status items.
    public var spacing: Int

    /// Points of highlight padding around a selected status item.
    public var selectionPadding: Int

    /// The values macOS uses when the global keys are absent.
    public static let systemDefault = MenuBarSpacing(enabled: false, spacing: 16, selectionPadding: 16)

    /// 16 is the system value; anything above it only spreads the bar out, so the range stops there.
    public static let validRange: ClosedRange<Int> = 0...16

    public init(enabled: Bool, spacing: Int, selectionPadding: Int) {
        self.enabled = enabled
        self.spacing = spacing
        self.selectionPadding = selectionPadding
    }

    /// Exact equality with `systemDefault`: a disabled value that remembers custom numbers is not
    /// the system default, so a reset still has something to restore.
    public var isSystemDefault: Bool { self == .systemDefault }

    /// The same intent with both numbers forced into `validRange`.
    public func clamped() -> MenuBarSpacing {
        MenuBarSpacing(
            enabled: enabled,
            spacing: Self.clamp(spacing),
            selectionPadding: Self.clamp(selectionPadding)
        )
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, validRange.lowerBound), validRange.upperBound)
    }

    // Explicit keys so renaming a Swift property never silently drops stored data.
    enum CodingKeys: String, CodingKey {
        case enabled
        case spacing
        case selectionPadding
    }

    /// Decodes leniently: a missing or mistyped field falls back to the system default, an
    /// out-of-range number is clamped, and a non-object value decodes as `systemDefault`.
    public init(from decoder: Decoder) throws {
        let d = Self.systemDefault
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = d
            return
        }
        let enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        let spacing = (try? container.decodeIfPresent(Int.self, forKey: .spacing)) ?? d.spacing
        let padding = (try? container.decodeIfPresent(Int.self, forKey: .selectionPadding)) ?? d.selectionPadding
        self = MenuBarSpacing(enabled: enabled, spacing: spacing, selectionPadding: padding).clamped()
    }
}
