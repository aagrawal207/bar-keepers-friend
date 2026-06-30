import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct ImmovableItemsTests {

    private func item(id: CGWindowID, bundle: String?, title: String? = nil) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id,
            ownerPID: 1,
            ownerBundleID: bundle,
            title: title,
            frame: CGRect(x: 0, y: 0, width: 20, height: 22)
        )
    }

    @Test func controlCenterIsImmovable() {
        #expect(ImmovableItems.isImmovable(item(id: 1, bundle: "com.apple.controlcenter")))
    }

    @Test func ordinaryAppIsMovable() {
        #expect(!ImmovableItems.isImmovable(item(id: 1, bundle: "com.dropbox.Dropbox")))
    }

    @Test func controlCenterDisplayNameIsImmovable() {
        // The attribution layer (and CGWindowList enumeration) populate `ownerBundleID` with a
        // DISPLAY NAME, not a reverse-DNS id — so the real string seen at runtime is
        // "Control Center", which must be caught. (Before the display-name denylist this was
        // movable: the reverse-DNS "com.apple.controlcenter" entry never matched the actual value.)
        #expect(ImmovableItems.isImmovable(item(id: 1, bundle: "Control Center")))
    }

    @Test func controlCenterDisplayNameIsFilteredOut() {
        let items = [
            item(id: 1, bundle: "Maccy"),
            item(id: 2, bundle: "Control Center"),
            item(id: 3, bundle: "com.apple.controlcenter"),
        ]
        // Both the display-name (id 2) and reverse-DNS (id 3) Control Center items are dropped.
        #expect(ImmovableItems.movableItems(from: items).map(\.windowID) == [1])
    }

    @Test func clockTitleIsImmovableEvenWithUnknownOwner() {
        // On Tahoe, owner attribution is unreliable, so the title fallback matters.
        #expect(ImmovableItems.isImmovable(item(id: 1, bundle: nil, title: "Clock 12:45")))
    }

    @Test func iphoneMirroringIsImmovable() {
        #expect(ImmovableItems.isImmovable(item(id: 1, bundle: nil, title: "iPhone Mirroring")))
    }

    @Test func rawSnapshotImmovabilityIgnoresControlCenterDisplayLabel() {
        #expect(!ImmovableItems.isImmovableOnRawSnapshot(item(id: 1, bundle: "Control Center")))
        #expect(ImmovableItems.isImmovable(item(id: 1, bundle: "Control Center")))
    }

    @Test func rawSnapshotStillBlocksReverseDNSAndTitles() {
        #expect(ImmovableItems.isImmovableOnRawSnapshot(item(id: 1, bundle: "com.apple.controlcenter")))
        #expect(ImmovableItems.isImmovableOnRawSnapshot(item(id: 2, bundle: nil, title: "Clock 12:45")))
        #expect(ImmovableItems.isImmovableOnRawSnapshot(item(id: 3, bundle: nil, title: "iPhone Mirroring")))
    }

    @Test func filterKeepsOnlyMovableItems() {
        let items = [
            item(id: 1, bundle: "com.dropbox.Dropbox"),
            item(id: 2, bundle: "com.apple.controlcenter"),
            item(id: 3, bundle: "com.example.App"),
        ]
        let movable = ImmovableItems.movableItems(from: items)
        #expect(movable.map(\.windowID) == [1, 3])
    }
}

@Suite struct FakeWindowServerTests {

    private func item(id: CGWindowID, x: CGFloat) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: id, ownerPID: 1, frame: CGRect(x: x, y: 0, width: 20, height: 22))
    }

    @Test func moveUpdatesItemFrame() async throws {
        let server = FakeWindowServer(items: [item(id: 1, x: 100)])
        let target = try server.menuBarItems()[0]
        try await server.move(item: target, toX: 500)
        #expect(try server.menuBarItems()[0].frame.minX == 500)
        #expect(server.moveRequests.count == 1)
    }

    @Test func clickIsRecorded() throws {
        let server = FakeWindowServer(items: [item(id: 7, x: 100)])
        try server.click(item: server.menuBarItems()[0])
        #expect(server.clickedWindowIDs == [7])
    }

    @Test func enumerationErrorPropagates() {
        let server = FakeWindowServer(items: [item(id: 1, x: 100)])
        server.enumerationError = .invalidServerResponse("garbage count")
        #expect(throws: WindowServerError.self) {
            _ = try server.menuBarItems()
        }
    }

    @Test func moveErrorPropagates() async throws {
        let server = FakeWindowServer(items: [item(id: 1, x: 100)])
        server.moveError = .moveFailed(windowID: 1)
        let target = try #require(try server.menuBarItems().first)
        await #expect(throws: WindowServerError.self) {
            try await server.move(item: target, toX: 200)
        }
    }
}
