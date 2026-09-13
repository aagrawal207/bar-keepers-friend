import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct MenuBarStyleTests {

    // MARK: RGBA

    @Test func componentsAreClampedAndNonfiniteValuesFallBack() {
        let color = RGBA(red: -1, green: 2, blue: 0.5, alpha: 7)
        #expect(color.red == 0)
        #expect(color.green == 1)
        #expect(color.blue == 0.5)
        #expect(color.alpha == 1)
        let broken = RGBA(red: .nan, green: .infinity, blue: -.infinity, alpha: .nan)
        #expect(broken == RGBA(red: 0, green: 0, blue: 0, alpha: 1))
    }

    @Test(arguments: [
        ("#FF0000", RGBA(red: 1, green: 0, blue: 0)),
        ("00ff00", RGBA(red: 0, green: 1, blue: 0)),
        ("#0000FF80", RGBA(red: 0, green: 0, blue: 1, alpha: 128 / 255)),
        (" #ffffff ", RGBA.white),
        ("#000000", RGBA.black),
        ("#00000000", RGBA.clear)
    ])
    func hexParsesSixAndEightDigitForms(hex: String, expected: RGBA) {
        #expect(RGBA(hex: hex) == expected)
    }

    @Test(arguments: ["", "#", "#FFF", "#GGGGGG", "#12345", "#1234567", "#123456789", "red", "#FF FF FF"])
    func malformedHexIsRejected(hex: String) {
        #expect(RGBA(hex: hex) == nil)
    }

    @Test func hexStringOmitsAlphaOnlyWhenOpaque() {
        #expect(RGBA(red: 1, green: 0, blue: 0).hexString == "#FF0000")
        #expect(RGBA(red: 0, green: 0, blue: 1, alpha: 0.5).hexString == "#0000FF80")
        #expect(RGBA(red: 28 / 255, green: 28 / 255, blue: 30 / 255).hexString == "#1C1C1E")
        #expect(RGBA.clear.hexString == "#00000000")
    }

    @Test func hexRoundTripsEveryByteValue() throws {
        for byte in 0...255 {
            let value = Double(byte) / 255
            let color = RGBA(red: value, green: 1 - value, blue: value, alpha: value)
            let parsed = try #require(RGBA(hex: color.hexString))
            #expect(parsed == color.normalized())
            #expect(parsed.hexString == color.hexString)
        }
    }

    @Test func normalizedSnapsToHexPrecisionAndIsIdempotent() {
        let color = RGBA(red: 0.5, green: 0.123456, blue: 0.999, alpha: 0.3)
        let normalized = color.normalized()
        #expect(normalized.red == 128.0 / 255)
        #expect(normalized.green == 31.0 / 255)
        #expect(normalized.blue == 1)
        #expect(normalized.alpha == 77.0 / 255)
        #expect(normalized.normalized() == normalized)
        #expect(RGBA(hex: normalized.hexString) == normalized)
    }

    @Test func rgbaEncodesAsAHexStringAndDecodesBothForms() throws {
        let color = RGBA(red: 1, green: 0.5, blue: 0, alpha: 0.5)
        let data = try JSONEncoder().encode(color)
        #expect(String(decoding: data, as: UTF8.self) == "\"#FF800080\"")
        #expect(try JSONDecoder().decode(RGBA.self, from: data) == color.normalized())

        let object = Data(#"{"red":1,"green":0,"blue":0}"#.utf8)
        #expect(try JSONDecoder().decode(RGBA.self, from: object) == RGBA(red: 1, green: 0, blue: 0))
        let withAlpha = Data(#"{"red":0,"green":0,"blue":1,"alpha":0.25}"#.utf8)
        #expect(try JSONDecoder().decode(RGBA.self, from: withAlpha) == RGBA(red: 0, green: 0, blue: 1, alpha: 0.25))
    }

    @Test(arguments: [#""nope""#, "12", "[1,2,3]", "true", #"{"red":"1","green":0,"blue":0}"#])
    func rgbaRejectsValuesItCannotRead(fragment: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RGBA.self, from: Data(fragment.utf8))
        }
    }

    // MARK: MenuBarStyle defaults and normalization

    @Test func noneIsDisabledWithDefaultValues() {
        let none = MenuBarStyle.none
        #expect(!none.isEnabled)
        #expect(none.tint == MenuBarStyle.defaultTint)
        #expect(none.gradientEnd == nil)
        #expect(none.opacity == MenuBarStyle.defaultOpacity)
        #expect(none.cornerRadius == MenuBarStyle.defaultCornerRadius)
        #expect(none.borderWidth == 0)
        #expect(none.borderColor == MenuBarStyle.defaultBorderColor)
        #expect(!none.shadowEnabled)
        #expect(none.shape == .full)
        #expect(!none.hasGradient)
        #expect(!none.hasBorder)
        #expect(!none.isVisible)
        #expect(none.isDefaultAppearance)
        // Defaults must survive a hex round trip so the default preferences encode stably.
        #expect(none.normalized() == none)
    }

    @Test func enablingAloneMakesTheStyleVisibleButKeepsDefaultAppearance() {
        let enabled = MenuBarStyle(isEnabled: true)
        #expect(enabled.isVisible)
        #expect(enabled.isDefaultAppearance)
        var tinted = enabled
        tinted.tint = .white
        #expect(!tinted.isDefaultAppearance)
        var transparent = enabled
        transparent.opacity = 0
        #expect(!transparent.isVisible)
    }

    @Test func normalizedClampsEveryNumericValue() {
        let wild = MenuBarStyle(
            isEnabled: true, tint: RGBA(red: 2, green: -1, blue: 0.5), gradientEnd: RGBA(red: 0.2, green: 0.2, blue: 0.2),
            opacity: 4, cornerRadius: -3, borderWidth: 99, borderColor: .white, shadowEnabled: true, shape: .pill
        )
        let normalized = wild.normalized()
        #expect(normalized.opacity == 1)
        #expect(normalized.cornerRadius == 0)
        #expect(normalized.borderWidth == 4)
        #expect(normalized.tint == RGBA(red: 1, green: 0, blue: 128 / 255))
        #expect(normalized.gradientEnd == RGBA(red: 51 / 255, green: 51 / 255, blue: 51 / 255))
        #expect(normalized.isEnabled)
        #expect(normalized.shadowEnabled)
        #expect(normalized.shape == .pill)
        #expect(normalized.normalized() == normalized)
    }

    @Test func nonfiniteNumbersNormalizeToDefaults() {
        var style = MenuBarStyle(isEnabled: true)
        style.opacity = .nan
        style.cornerRadius = .infinity
        style.borderWidth = -.infinity
        let normalized = style.normalized()
        #expect(normalized.opacity == MenuBarStyle.defaultOpacity)
        #expect(normalized.cornerRadius == MenuBarStyle.defaultCornerRadius)
        #expect(normalized.borderWidth == 0)
    }

    @Test func normalizedIsIdentityInsideTheRanges() {
        let style = MenuBarStyle(
            isEnabled: true, tint: RGBA(hex: "#123456")!, gradientEnd: RGBA(hex: "#ABCDEF")!,
            opacity: 0.6, cornerRadius: 12, borderWidth: 2, borderColor: RGBA(hex: "#FFFFFF40")!,
            shadowEnabled: true, shape: .rounded
        )
        #expect(style.normalized() == style)
    }

    @Test func reduceTransparencyForcesFullOpacityAndNothingElse() {
        let style = MenuBarStyle(isEnabled: true, opacity: 0.3, shape: .pill)
        let solid = style.honoringReduceTransparency(true)
        #expect(solid.opacity == 1)
        var expected = style
        expected.opacity = 1
        #expect(solid == expected)
        #expect(style.honoringReduceTransparency(false) == style)
    }

    @Test func shapesReportWhetherTheRadiusApplies() {
        #expect(!MenuBarStyle.Shape.full.usesCornerRadius)
        #expect(MenuBarStyle.Shape.rounded.usesCornerRadius)
        #expect(MenuBarStyle.Shape.pill.usesCornerRadius)
        #expect(MenuBarStyle.Shape.allCases == [.full, .rounded, .pill])
    }

    // MARK: Codable

    @Test func encodesWithStableKeysAndRoundTrips() throws {
        let style = MenuBarStyle(
            isEnabled: true, tint: RGBA(hex: "#FF0000")!, gradientEnd: RGBA(hex: "#0000FF")!,
            opacity: 0.5, cornerRadius: 10, borderWidth: 1, borderColor: RGBA(hex: "#FFFFFF80")!,
            shadowEnabled: true, shape: .pill
        )
        let data = try JSONEncoder().encode(style)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "isEnabled", "tint", "gradientEnd", "opacity", "cornerRadius", "borderWidth", "borderColor", "shadowEnabled", "shape"
        ])
        #expect(object["isEnabled"] as? Bool == true)
        #expect(object["tint"] as? String == "#FF0000")
        #expect(object["gradientEnd"] as? String == "#0000FF")
        #expect(object["opacity"] as? Double == 0.5)
        #expect(object["cornerRadius"] as? Double == 10)
        #expect(object["borderWidth"] as? Double == 1)
        #expect(object["borderColor"] as? String == "#FFFFFF80")
        #expect(object["shadowEnabled"] as? Bool == true)
        #expect(object["shape"] as? String == "pill")
        #expect(try JSONDecoder().decode(MenuBarStyle.self, from: data) == style)
    }

    @Test func solidStylesOmitTheGradientKeyAndNoneRoundTrips() throws {
        let data = try JSONEncoder().encode(MenuBarStyle.none)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["gradientEnd"] == nil)
        #expect(object["isEnabled"] as? Bool == false)
        #expect(object["tint"] as? String == "#1C1C1E")
        #expect(object["borderColor"] as? String == "#FFFFFF40")
        #expect(try JSONDecoder().decode(MenuBarStyle.self, from: data) == .none)
    }

    @Test(arguments: [
        ("{}", MenuBarStyle.none),
        (#"{"isEnabled":true}"#, MenuBarStyle(isEnabled: true)),
        (#"{"shape":"rounded","cornerRadius":4}"#, MenuBarStyle(cornerRadius: 4, shape: .rounded)),
        (##"{"tint":"#FF0000","unrelated":"x"}"##, MenuBarStyle(tint: RGBA(red: 1, green: 0, blue: 0))),
        (##"{"gradientEnd":"#00FF00"}"##, MenuBarStyle(gradientEnd: RGBA(red: 0, green: 1, blue: 0)))
    ])
    func missingFieldsDecodeAsDefaults(json: String, expected: MenuBarStyle) throws {
        #expect(try JSONDecoder().decode(MenuBarStyle.self, from: Data(json.utf8)) == expected)
    }

    @Test func mistypedFieldsFallBackIndividually() throws {
        let json = ##"{"isEnabled":"yes","tint":"#ZZZZZZ","gradientEnd":5,"opacity":"0.5","cornerRadius":[1],"borderWidth":true,"borderColor":{},"shadowEnabled":1,"shape":"hexagon"}"##
        let decoded = try JSONDecoder().decode(MenuBarStyle.self, from: Data(json.utf8))
        #expect(decoded == .none)

        let partlyValid = #"{"isEnabled":true,"tint":"oops","opacity":0.25,"shape":"pill"}"#
        let partly = try JSONDecoder().decode(MenuBarStyle.self, from: Data(partlyValid.utf8))
        #expect(partly == MenuBarStyle(isEnabled: true, opacity: 0.25, shape: .pill))
    }

    @Test func outOfRangeNumbersDecodeClamped() throws {
        let json = #"{"isEnabled":true,"opacity":7,"cornerRadius":-2,"borderWidth":40}"#
        let decoded = try JSONDecoder().decode(MenuBarStyle.self, from: Data(json.utf8))
        #expect(decoded == MenuBarStyle(isEnabled: true, opacity: 1, cornerRadius: 0, borderWidth: 4))
    }

    private struct Envelope: Decodable, Equatable {
        let value: MenuBarStyle
    }

    @Test(arguments: [#""custom""#, "5", "[1,2]", "true", "null"])
    func nonObjectValuesDecodeAsNone(fragment: String) throws {
        let json = #"{"value":\#(fragment)}"#
        let decoded = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
        #expect(decoded.value == .none)
    }

    @Test func decodedColorsAreAlwaysHexPrecise() throws {
        let json = #"{"isEnabled":true,"tint":{"red":0.5,"green":0.5,"blue":0.5,"alpha":0.5}}"#
        let decoded = try JSONDecoder().decode(MenuBarStyle.self, from: Data(json.utf8))
        #expect(decoded.tint == RGBA(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5).normalized())
        #expect(decoded.tint.hexString == "#80808080")
        let reencoded = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(MenuBarStyle.self, from: reencoded) == decoded)
    }
}
