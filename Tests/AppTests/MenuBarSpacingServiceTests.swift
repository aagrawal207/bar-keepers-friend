import BarKeepersFriendCore
import Testing

/// Test stand-in for the user's global defaults domain; the real one is never touched by tests.
@MainActor
final class InMemoryGlobalDefaults: GlobalDefaultsWriting {
    var storage: [String: Int]
    private(set) var writes: [(key: String, value: Int?)] = []

    init(_ storage: [String: Int] = [:]) {
        self.storage = storage
    }

    func integer(forKey key: String) -> Int? { storage[key] }

    func set(_ value: Int?, forKey key: String) {
        writes.append((key, value))
        storage[key] = value
    }
}

@Suite
@MainActor
struct MenuBarSpacingServiceTests {
    private let spacingKey = MenuBarSpacingService.spacingKey
    private let paddingKey = MenuBarSpacingService.selectionPaddingKey

    @Test func keysAreTheExactGlobalDomainKeysMacOSReads() {
        #expect(spacingKey == "NSStatusItemSpacing")
        #expect(paddingKey == "NSStatusItemSelectionPadding")
    }

    @Test func enablingWritesBothKeysAndReportsAChange() {
        let defaults = InMemoryGlobalDefaults()
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(service.apply(MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4)))
        #expect(defaults.storage == [spacingKey: 8, paddingKey: 4])
        #expect(defaults.writes.count == 2)
        #expect(service.current() == MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4))
    }

    @Test func reapplyingIdenticalValuesWritesNothing() {
        let defaults = InMemoryGlobalDefaults([spacingKey: 8, paddingKey: 4])
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(!service.apply(MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4)))
        #expect(defaults.writes.isEmpty)
        #expect(!service.apply(MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4)))
        #expect(defaults.writes.isEmpty)
        #expect(defaults.storage == [spacingKey: 8, paddingKey: 4])
    }

    @Test func onlyTheKeyThatDiffersIsRewritten() throws {
        let defaults = InMemoryGlobalDefaults([spacingKey: 8, paddingKey: 4])
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(service.apply(MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 2)))
        let write = try #require(defaults.writes.first)
        #expect(defaults.writes.count == 1)
        #expect(write.key == paddingKey)
        #expect(write.value == 2)
        #expect(defaults.storage == [spacingKey: 8, paddingKey: 2])
    }

    @Test func enabledSystemValuesAreStillWrittenExplicitly() {
        let defaults = InMemoryGlobalDefaults()
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(service.apply(MenuBarSpacing(enabled: true, spacing: 16, selectionPadding: 16)))
        #expect(defaults.storage == [spacingKey: 16, paddingKey: 16])
    }

    @Test func outOfRangeValuesAreClampedBeforeWriting() {
        let defaults = InMemoryGlobalDefaults()
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(service.apply(MenuBarSpacing(enabled: true, spacing: 99, selectionPadding: -3)))
        #expect(defaults.storage == [spacingKey: 16, paddingKey: 0])
    }

    @Test func disablingRemovesBothKeysOnceAndThenIsANoOp() {
        let defaults = InMemoryGlobalDefaults([spacingKey: 8, paddingKey: 4])
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(service.apply(MenuBarSpacing(enabled: false, spacing: 8, selectionPadding: 4)))
        #expect(defaults.storage.isEmpty)
        #expect(defaults.writes.count == 2)
        #expect(defaults.writes.allSatisfy { $0.value == nil })
        #expect(service.current() == .systemDefault)

        #expect(!service.apply(.systemDefault))
        #expect(!service.apply(MenuBarSpacing(enabled: false, spacing: 2, selectionPadding: 2)))
        #expect(defaults.writes.count == 2)
    }

    @Test func disablingWithOnlyOneKeyPresentRemovesJustThatKey() throws {
        let defaults = InMemoryGlobalDefaults([spacingKey: 8])
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(service.apply(.systemDefault))
        #expect(defaults.storage.isEmpty)
        let write = try #require(defaults.writes.first)
        #expect(defaults.writes.count == 1)
        #expect(write.key == spacingKey)
        #expect(write.value == nil)
    }

    @Test func launchApplicationNeverRemovesValuesConfiguredElsewhere() {
        let defaults = InMemoryGlobalDefaults([spacingKey: 6, paddingKey: 6])
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(!service.applyAtLaunch(.systemDefault))
        #expect(!service.applyAtLaunch(MenuBarSpacing(enabled: false, spacing: 2, selectionPadding: 2)))
        #expect(defaults.writes.isEmpty)
        #expect(defaults.storage == [spacingKey: 6, paddingKey: 6])

        #expect(service.applyAtLaunch(MenuBarSpacing(enabled: true, spacing: 2, selectionPadding: 6)))
        #expect(defaults.storage == [spacingKey: 2, paddingKey: 6])
        #expect(defaults.writes.count == 1)
        #expect(!service.applyAtLaunch(MenuBarSpacing(enabled: true, spacing: 2, selectionPadding: 6)))
    }

    @Test func currentReflectsTheDomainWithoutClamping() {
        let empty = MenuBarSpacingService(defaults: InMemoryGlobalDefaults())
        #expect(empty.current() == .systemDefault)

        let manual = MenuBarSpacingService(defaults: InMemoryGlobalDefaults([spacingKey: 40, paddingKey: -2]))
        #expect(manual.current() == MenuBarSpacing(enabled: true, spacing: 40, selectionPadding: -2))

        let spacingOnly = MenuBarSpacingService(defaults: InMemoryGlobalDefaults([spacingKey: 6]))
        #expect(spacingOnly.current() == MenuBarSpacing(enabled: true, spacing: 6, selectionPadding: 16))

        let paddingOnly = MenuBarSpacingService(defaults: InMemoryGlobalDefaults([paddingKey: 0]))
        #expect(paddingOnly.current() == MenuBarSpacing(enabled: true, spacing: 16, selectionPadding: 0))
    }

    @Test func applyingTheCurrentReadingBackIsANoOp() {
        let defaults = InMemoryGlobalDefaults([spacingKey: 6, paddingKey: 3])
        let service = MenuBarSpacingService(defaults: defaults)
        #expect(!service.apply(service.current()))
        #expect(defaults.writes.isEmpty)
    }
}
