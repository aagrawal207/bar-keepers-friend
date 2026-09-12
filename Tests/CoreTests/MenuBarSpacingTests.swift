import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct MenuBarSpacingTests {

    @Test func systemDefaultMatchesTheValuesMacOSUsesWithoutTheKeys() {
        let d = MenuBarSpacing.systemDefault
        #expect(!d.enabled)
        #expect(d.spacing == 16)
        #expect(d.selectionPadding == 16)
        #expect(d.isSystemDefault)
        #expect(MenuBarSpacing.validRange == 0...16)
        #expect(MenuBarSpacing.validRange.contains(d.spacing))
        #expect(MenuBarSpacing.validRange.contains(d.selectionPadding))
    }

    @Test func isSystemDefaultRequiresExactEquality() {
        #expect(!MenuBarSpacing(enabled: true, spacing: 16, selectionPadding: 16).isSystemDefault)
        #expect(!MenuBarSpacing(enabled: false, spacing: 8, selectionPadding: 16).isSystemDefault)
        #expect(!MenuBarSpacing(enabled: false, spacing: 16, selectionPadding: 8).isSystemDefault)
        #expect(MenuBarSpacing(enabled: false, spacing: 16, selectionPadding: 16).isSystemDefault)
    }

    @Test(arguments: [
        (Int.min, 0), (-1, 0), (0, 0), (1, 1), (7, 7), (15, 15), (16, 16), (17, 16), (Int.max, 16)
    ])
    func clampedBoundsEachNumberIndependently(input: Int, expected: Int) {
        let spacingOnly = MenuBarSpacing(enabled: true, spacing: input, selectionPadding: 3).clamped()
        #expect(spacingOnly.spacing == expected)
        #expect(spacingOnly.selectionPadding == 3)
        #expect(spacingOnly.enabled)

        let paddingOnly = MenuBarSpacing(enabled: false, spacing: 3, selectionPadding: input).clamped()
        #expect(paddingOnly.selectionPadding == expected)
        #expect(paddingOnly.spacing == 3)
        #expect(!paddingOnly.enabled)
    }

    @Test func clampedIsIdentityInsideTheRange() {
        for spacing in MenuBarSpacing.validRange {
            for padding in [0, 8, 16] {
                let value = MenuBarSpacing(enabled: true, spacing: spacing, selectionPadding: padding)
                #expect(value.clamped() == value)
            }
        }
        #expect(MenuBarSpacing.systemDefault.clamped() == .systemDefault)
    }

    @Test func encodesWithStableKeysAndRoundTrips() throws {
        let value = MenuBarSpacing(enabled: true, spacing: 6, selectionPadding: 4)
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["enabled", "spacing", "selectionPadding"])
        #expect(object["enabled"] as? Bool == true)
        #expect(object["spacing"] as? Int == 6)
        #expect(object["selectionPadding"] as? Int == 4)
        #expect(try JSONDecoder().decode(MenuBarSpacing.self, from: data) == value)
        let defaultData = try JSONEncoder().encode(MenuBarSpacing.systemDefault)
        #expect(try JSONDecoder().decode(MenuBarSpacing.self, from: defaultData) == .systemDefault)
    }

    @Test(arguments: [
        ("{}", MenuBarSpacing.systemDefault),
        (#"{"enabled":true}"#, MenuBarSpacing(enabled: true, spacing: 16, selectionPadding: 16)),
        (#"{"spacing":4}"#, MenuBarSpacing(enabled: false, spacing: 4, selectionPadding: 16)),
        (#"{"selectionPadding":0}"#, MenuBarSpacing(enabled: false, spacing: 16, selectionPadding: 0)),
        (#"{"enabled":true,"spacing":2,"selectionPadding":3,"unrelated":"x"}"#, MenuBarSpacing(enabled: true, spacing: 2, selectionPadding: 3))
    ])
    func missingFieldsDecodeAsSystemDefaults(json: String, expected: MenuBarSpacing) throws {
        #expect(try JSONDecoder().decode(MenuBarSpacing.self, from: Data(json.utf8)) == expected)
    }

    @Test func mistypedFieldsFallBackWithoutFailingTheWholeDecode() throws {
        let json = #"{"enabled":"yes","spacing":"8","selectionPadding":1.5}"#
        let decoded = try JSONDecoder().decode(MenuBarSpacing.self, from: Data(json.utf8))
        #expect(decoded == .systemDefault)

        let partlyValid = #"{"enabled":true,"spacing":[8],"selectionPadding":2}"#
        #expect(try JSONDecoder().decode(MenuBarSpacing.self, from: Data(partlyValid.utf8))
                == MenuBarSpacing(enabled: true, spacing: 16, selectionPadding: 2))
    }

    @Test func outOfRangeNumbersDecodeClamped() throws {
        let json = #"{"enabled":true,"spacing":99,"selectionPadding":-5}"#
        let decoded = try JSONDecoder().decode(MenuBarSpacing.self, from: Data(json.utf8))
        #expect(decoded == MenuBarSpacing(enabled: true, spacing: 16, selectionPadding: 0))
    }

    private struct Envelope: Decodable, Equatable {
        let value: MenuBarSpacing
    }

    @Test(arguments: [#""custom""#, "5", "[1,2]", "true"])
    func nonObjectValuesDecodeAsSystemDefault(fragment: String) throws {
        let json = #"{"value":\#(fragment)}"#
        let decoded = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
        #expect(decoded.value == .systemDefault)
    }
}
