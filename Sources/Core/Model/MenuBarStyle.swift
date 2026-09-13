import Foundation

/// An sRGB color with 0...1 components. Persists as a hex string so exported layouts stay readable.
public struct RGBA: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    /// Components are clamped to 0...1; a nonfinite color component reads as 0, a nonfinite alpha as 1.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red, fallback: 0)
        self.green = Self.clamp(green, fallback: 0)
        self.blue = Self.clamp(blue, fallback: 0)
        self.alpha = Self.clamp(alpha, fallback: 1)
    }

    /// Accepts `RRGGBB` or `RRGGBBAA`, any case, with or without a leading `#`.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [Double] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(Double(byte) / 255)
            index = next
        }
        self.init(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? bytes[3] : 1)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the color is not fully opaque. Components round to 8 bits.
    public var hexString: String {
        let channels = alpha < 1 ? [red, green, blue, alpha] : [red, green, blue]
        return "#" + channels.map { String(format: "%02X", Self.byte($0)) }.joined()
    }

    /// Components snapped to the 8-bit steps hex can carry, so an encode/decode cycle is lossless.
    public func normalized() -> RGBA {
        RGBA(
            red: Double(Self.byte(red)) / 255,
            green: Double(Self.byte(green)) / 255,
            blue: Double(Self.byte(blue)) / 255,
            alpha: Double(Self.byte(alpha)) / 255
        )
    }

    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let white = RGBA(red: 1, green: 1, blue: 1)
    public static let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)

    private static func clamp(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }

    private static func byte(_ component: Double) -> UInt8 {
        UInt8((clamp(component, fallback: 0) * 255).rounded())
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case red, green, blue, alpha
    }

    /// Reads the hex form written by `encode(to:)`, and a `{red, green, blue, alpha}` object for
    /// hand-edited files. Anything else is a decoding error for the owner to default.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let hex = try? single.decode(String.self) {
            guard let color = RGBA(hex: hex) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "Not a hex color: \(hex)"
                ))
            }
            self = color
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try container.decode(Double.self, forKey: .red),
            green: try container.decode(Double.self, forKey: .green),
            blue: try container.decode(Double.self, forKey: .blue),
            alpha: try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

/// How the menu bar strip is painted behind the system's menu titles and status items.
/// Styling is drawn by this app alone: it needs no permission and never restyles the bar's text.
public struct MenuBarStyle: Hashable, Codable, Sendable {
    public enum Shape: String, CaseIterable, Codable, Sendable {
        /// The whole strip, flush with every display edge.
        case full
        /// The whole strip with rounded bottom corners; the top stays flush with the display edge.
        case rounded
        /// A capsule floating inside the strip, inset from the display edges and the notch.
        case pill

        /// Full bars have no corners to round, so the radius control is inert for them.
        public var usesCornerRadius: Bool { self != .full }
    }

    /// Off leaves the menu bar exactly as macOS draws it.
    public var isEnabled: Bool
    /// Fill color, or the leading color when `gradientEnd` is set.
    public var tint: RGBA
    /// Trailing color of a left-to-right gradient; nil paints a solid tint.
    public var gradientEnd: RGBA?
    /// Overall alpha of the whole overlay, fill and border alike.
    public var opacity: Double
    /// Corner radius in points for `.rounded` and `.pill`.
    public var cornerRadius: Double
    /// Border thickness in points; 0 draws no border.
    public var borderWidth: Double
    public var borderColor: RGBA
    /// A window-server drop shadow under the drawn shape.
    public var shadowEnabled: Bool
    public var shape: Shape

    public static let opacityRange: ClosedRange<Double> = 0...1
    public static let cornerRadiusRange: ClosedRange<Double> = 0...20
    public static let borderWidthRange: ClosedRange<Double> = 0...4

    /// The system dark gray (#1C1C1E), a neutral first fill for a freshly enabled style.
    public static let defaultTint = RGBA(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    /// A lighter gray (#48484A) that reads as a visible ramp from the default tint.
    public static let defaultGradientEnd = RGBA(red: 72 / 255, green: 72 / 255, blue: 74 / 255)
    /// A quarter-opaque white edge that reads on both light and dark tints.
    public static let defaultBorderColor = RGBA(red: 1, green: 1, blue: 1, alpha: 64 / 255)
    public static let defaultOpacity = 0.45
    public static let defaultCornerRadius = 8.0

    public init(
        isEnabled: Bool = false,
        tint: RGBA = MenuBarStyle.defaultTint,
        gradientEnd: RGBA? = nil,
        opacity: Double = MenuBarStyle.defaultOpacity,
        cornerRadius: Double = MenuBarStyle.defaultCornerRadius,
        borderWidth: Double = 0,
        borderColor: RGBA = MenuBarStyle.defaultBorderColor,
        shadowEnabled: Bool = false,
        shape: Shape = .full
    ) {
        self.isEnabled = isEnabled
        self.tint = tint
        self.gradientEnd = gradientEnd
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.shadowEnabled = shadowEnabled
        self.shape = shape
    }

    /// Styling off with default values, so enabling it shows a sensible bar immediately.
    public static let none = MenuBarStyle()

    public var hasGradient: Bool { gradientEnd != nil }
    public var hasBorder: Bool { borderWidth > 0 }

    /// Whether the overlay would paint anything at all.
    public var isVisible: Bool {
        let normalized = normalized()
        return normalized.isEnabled && normalized.opacity > 0
    }

    /// Every value clamped into its range and every color snapped to hex precision.
    public func normalized() -> MenuBarStyle {
        MenuBarStyle(
            isEnabled: isEnabled,
            tint: tint.normalized(),
            gradientEnd: gradientEnd?.normalized(),
            opacity: Self.clamp(opacity, to: Self.opacityRange, fallback: Self.defaultOpacity),
            cornerRadius: Self.clamp(cornerRadius, to: Self.cornerRadiusRange, fallback: Self.defaultCornerRadius),
            borderWidth: Self.clamp(borderWidth, to: Self.borderWidthRange, fallback: 0),
            borderColor: borderColor.normalized(),
            shadowEnabled: shadowEnabled,
            shape: shape
        )
    }

    /// Reduce Transparency asks for solid surfaces, so the overlay ignores any translucency.
    public func honoringReduceTransparency(_ reduceTransparency: Bool) -> MenuBarStyle {
        guard reduceTransparency else { return self }
        var solid = self
        solid.opacity = 1
        return solid
    }

    /// Whether the values differ from the defaults in any way other than the on/off switch.
    public var isDefaultAppearance: Bool {
        var comparable = normalized()
        comparable.isEnabled = false
        return comparable == .none
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Codable

    // Explicit keys so renaming a Swift property never silently drops stored data.
    enum CodingKeys: String, CodingKey {
        case isEnabled
        case tint
        case gradientEnd
        case opacity
        case cornerRadius
        case borderWidth
        case borderColor
        case shadowEnabled
        case shape
    }

    /// Decodes leniently: a missing or mistyped field falls back to its default, out-of-range
    /// numbers are clamped, and a non-object value decodes as `.none`.
    public init(from decoder: Decoder) throws {
        let d = MenuBarStyle.none
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = d
            return
        }
        let gradientEnd = (try? container.decodeIfPresent(RGBA.self, forKey: .gradientEnd)) ?? nil
        self = MenuBarStyle(
            isEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled,
            tint: (try? container.decodeIfPresent(RGBA.self, forKey: .tint)) ?? d.tint,
            gradientEnd: gradientEnd,
            opacity: (try? container.decodeIfPresent(Double.self, forKey: .opacity)) ?? d.opacity,
            cornerRadius: (try? container.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? d.cornerRadius,
            borderWidth: (try? container.decodeIfPresent(Double.self, forKey: .borderWidth)) ?? d.borderWidth,
            borderColor: (try? container.decodeIfPresent(RGBA.self, forKey: .borderColor)) ?? d.borderColor,
            shadowEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .shadowEnabled)) ?? d.shadowEnabled,
            shape: (try? container.decodeIfPresent(Shape.self, forKey: .shape)) ?? d.shape
        ).normalized()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(tint, forKey: .tint)
        try container.encodeIfPresent(gradientEnd, forKey: .gradientEnd)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(borderColor, forKey: .borderColor)
        try container.encode(shadowEnabled, forKey: .shadowEnabled)
        try container.encode(shape, forKey: .shape)
    }
}
