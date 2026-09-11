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

    private func pidItem(id: CGWindowID, pid: pid_t, bundle: String?) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id, ownerPID: pid, ownerBundleID: bundle,
            title: nil, frame: CGRect(x: 0, y: 0, width: 20, height: 22)
        )
    }

    @Test func immovablePIDMakesAnyItemImmovableRegardlessOfLabel() {
        // The whole point of the pid overload: a Control Center MODULE attributes to a localized
        // label (e.g. "Battery") that the display-name denylist deliberately doesn't list, yet it
        // shares Control Center's pid. Passing that pid catches it without enumerating module names.
        let battery = pidItem(id: 1, pid: 501, bundle: "Battery")
        #expect(!ImmovableItems.isImmovable(battery))                       // label alone: movable
        #expect(ImmovableItems.isImmovable(battery, immovablePIDs: [501]))  // by pid: immovable
    }

    @Test func emptyImmovablePIDSetMatchesLabelOnlyBehavior() {
        // With no pids, the overload must reduce exactly to the label/title check — a strict superset.
        let maccy = pidItem(id: 1, pid: 999, bundle: "Maccy")
        let cc = pidItem(id: 2, pid: 501, bundle: "Control Center")
        #expect(ImmovableItems.isImmovable(maccy, immovablePIDs: []) == ImmovableItems.isImmovable(maccy))
        #expect(ImmovableItems.isImmovable(cc, immovablePIDs: []) == ImmovableItems.isImmovable(cc))
    }

    @Test func immovablePIDDoesNotAffectAnUnlistedPID() {
        let maccy = pidItem(id: 1, pid: 999, bundle: "Maccy")
        #expect(!ImmovableItems.isImmovable(maccy, immovablePIDs: [501, 4242]))
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

    private func item(id: CGWindowID, x: CGFloat, width: CGFloat = 20) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: id, ownerPID: 1, frame: CGRect(x: x, y: 0, width: width, height: 22))
    }

    @Test func moveUpdatesItemFrame() async throws {
        let reference = item(id: 99, x: 476)
        let server = FakeWindowServer(items: [item(id: 1, x: 100), reference])
        let target = try server.menuBarItems()[0]
        try await server.move(item: target, toX: 500, relativeTo: reference.windowID)
        #expect(try server.menuBarItems()[0].frame.minX == 500)
        #expect(try server.menuBarItems()[1] == reference)
        #expect(server.moveRequests.count == 1)
        #expect(server.moveRequests.first?.windowID == 1)
        #expect(server.moveRequests.first?.targetX == 500)
        #expect(server.moveRequests.first?.targetWindowID == reference.windowID)
    }

    @Test(arguments: [CGFloat(20), CGFloat(240)])
    func dropBeforeReferencePlacesTheEntireItemToItsLeft(width: CGFloat) async throws {
        let reference = item(id: 99, x: 600)
        let target = item(id: 1, x: 800, width: width)
        let server = FakeWindowServer(items: [target, reference])

        try await server.move(item: target, toX: 592, relativeTo: reference.windowID)

        #expect(try server.menuBarItems()[0].frame.maxX == 592)
        #expect(try server.menuBarItems()[0].frame.width == width)
        #expect(try server.menuBarItems()[1] == reference)
        #expect(server.moveRequests.first?.targetWindowID == reference.windowID)
    }

    @Test func aFixtureWithoutAReferenceStillRecordsTheRequestedWindow() async throws {
        let target = item(id: 1, x: 100)
        let server = FakeWindowServer(items: [target])

        try await server.move(item: target, toX: 200, relativeTo: 99)

        #expect(try server.menuBarItems()[0].frame.minX == 200)
        #expect(server.moveRequests.first?.targetWindowID == 99)
    }

    @Test func clickIsRecorded() throws {
        let server = FakeWindowServer(items: [item(id: 7, x: 100)])
        try server.click(item: server.menuBarItems()[0])
        #expect(server.clickedWindowIDs == [7])
    }

    @Test func clickErrorPropagatesWithoutRecordingSuccess() {
        let target = item(id: 7, x: 100)
        let server = FakeWindowServer(items: [target])
        server.clickError = .clickFailed(windowID: 7)
        #expect(throws: WindowServerError.clickFailed(windowID: 7)) {
            try server.click(item: target)
        }
        #expect(server.clickedWindowIDs.isEmpty)
    }

    @Test func enumerationErrorPropagates() {
        let server = FakeWindowServer(items: [item(id: 1, x: 100)])
        server.enumerationError = .invalidServerResponse("garbage count")
        #expect(throws: WindowServerError.self) {
            _ = try server.menuBarItems()
        }
    }

    @Test func moveErrorPropagates() async throws {
        let server = FakeWindowServer(items: [item(id: 1, x: 100), item(id: 99, x: 176)])
        server.moveError = .moveFailed(windowID: 1)
        let target = try #require(try server.menuBarItems().first)
        await #expect(throws: WindowServerError.self) {
            try await server.move(item: target, toX: 200, relativeTo: 99)
        }
    }
}
