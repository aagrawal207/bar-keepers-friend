import AppKit
import BarKeepersFriendCore
import Testing

/// `windowID(forOwnerKey:)` against a fake window server: the cache answers first, enumeration is
/// the fallback, and unknown owners resolve to nil. Nothing is captured for real or clicked.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FloatingBarControllerHotkeysTests {
    private let hiddenA = MenuBarItemSnapshot(
        windowID: 1, ownerPID: 1, ownerBundleID: "test.app", frame: CGRect(x: 100, y: 0, width: 22, height: 22)
    )
    private let hiddenB = MenuBarItemSnapshot(
        windowID: 2, ownerPID: 2, ownerBundleID: "other.app", frame: CGRect(x: 200, y: 0, width: 22, height: 22)
    )
    /// Right of the anchor, so never in the hidden cache.
    private let shown = MenuBarItemSnapshot(
        windowID: 3, ownerPID: 3, ownerBundleID: "shown.app", frame: CGRect(x: 1200, y: 0, width: 22, height: 22)
    )
    /// The app's own always-hidden divider; everything left of it is the always-hidden tier.
    private let alwaysHiddenDivider = MenuBarItemSnapshot(
        windowID: 40, ownerPID: 99, ownerBundleID: "Bar Keeper's Friend",
        title: ControlItem.Identifier.alwaysHiddenDivider.rawValue, frame: CGRect(x: 60, y: 0, width: 8, height: 22)
    )
    private let alwaysHidden = MenuBarItemSnapshot(
        windowID: 4, ownerPID: 4, ownerBundleID: "tucked.app", frame: CGRect(x: 20, y: 0, width: 22, height: 22)
    )

    private func makeBar(_ server: CountingWindowServer, preferences: Preferences = .default) throws -> FloatingBarController {
        let image = try glyph(side: 8)
        return FloatingBarController(
            windowServer: server,
            captureIcons: { snapshots in Dictionary(uniqueKeysWithValues: snapshots.map { ($0.windowID, image) }) },
            preferences: preferences,
            attribute: { $0 }
        )
    }

    /// The tier is intent plus position: a window parked past the divider without intent is a stray.
    private func alwaysHiddenIntent(for snapshot: MenuBarItemSnapshot) -> Preferences {
        var preferences = Preferences.default
        preferences.itemControls.setPlacement(.alwaysHidden, for: snapshot)
        return preferences
    }

    @Test func aCachedHiddenItemResolvesWithoutEnumerating() async throws {
        let server = CountingWindowServer(items: [hiddenA, hiddenB, shown])
        let bar = try makeBar(server)
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(Set(bar.cachedHiddenItems().map(\.id)) == [1, 2])
        let reads = server.readCount

        #expect(await bar.windowID(forOwnerKey: "other.app") == 2)
        #expect(await bar.windowID(forOwnerKey: "test.app") == 1)
        #expect(server.readCount == reads, "cache hits must not touch the menu bar")
        #expect(server.clickedWindowIDs.isEmpty)
    }

    @Test func aCacheMissFallsBackToEnumeratingManageableItems() async throws {
        let server = CountingWindowServer(items: [hiddenA, hiddenB, shown])
        let bar = try makeBar(server)
        #expect(bar.cachedHiddenItems().isEmpty)

        #expect(await bar.windowID(forOwnerKey: "test.app") == 1)
        #expect(server.readCount >= 1)
        // A shown item is never cached, so it always takes the enumeration path.
        let before = server.readCount
        #expect(await bar.windowID(forOwnerKey: "shown.app") == 3)
        #expect(server.readCount > before)
        #expect(server.clickedWindowIDs.isEmpty)
    }

    @Test func unknownOwnersAndFailedEnumerationsResolveToNil() async throws {
        let server = CountingWindowServer(items: [hiddenA])
        let bar = try makeBar(server)
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(await bar.windowID(forOwnerKey: "missing.app") == nil)

        server.enumerationError = .invalidServerResponse("offline")
        #expect(await bar.windowID(forOwnerKey: "missing.app") == nil)
        // The cached owner still answers while the window server is unavailable.
        #expect(await bar.windowID(forOwnerKey: "test.app") == 1)
    }

    @Test func aCachedIDIsAcceptedByTheExistingActivationPath() async throws {
        let server = CountingWindowServer(items: [hiddenA, hiddenB])
        let bar = try makeBar(server)
        var reveals = 0
        bar.revealHiddenItems = { reveals += 1 }
        bar.rehideItems = {}
        bar.scheduleAutoRehideAfterActivation = {}
        await bar.captureAndCache(anchorMinX: 1000)

        // An id outside the cache is a no-op, so a started task proves the resolved id was cached.
        bar.activate(windowID: 999)
        #expect(bar.currentActivationTask == nil)
        let id = try #require(await bar.windowID(forOwnerKey: "other.app"))
        bar.activate(windowID: id)
        let task = try #require(bar.currentActivationTask)
        await task.value
        // The click itself races activation's wall-clock deadline under a contended main actor,
        // so only the reveal (requested before that deadline check) is asserted here.
        #expect(reveals == 1)
        #expect(server.clickedWindowIDs.allSatisfy { $0 == 2 })
    }

    @Test func anAlwaysHiddenCachedItemResolvesFromTheCacheWithoutEnumerating() async throws {
        let server = CountingWindowServer(items: [alwaysHidden, alwaysHiddenDivider, hiddenA, shown])
        let bar = try makeBar(server, preferences: alwaysHiddenIntent(for: alwaysHidden))
        bar.alwaysHiddenDividerWindowID = alwaysHiddenDivider.windowID
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(bar.cachedHiddenItems().map(\.id) == [1])
        #expect(bar.cachedAlwaysHiddenItems().map(\.id) == [4])
        let reads = server.readCount

        #expect(await bar.windowID(forOwnerKey: "tucked.app") == 4)
        #expect(await bar.windowID(forOwnerKey: "test.app") == 1)
        #expect(server.readCount == reads, "both cached tiers answer without touching the menu bar")
        // The divider is the app's own control item, never a resolvable owner.
        #expect(await bar.windowID(forOwnerKey: "Bar Keeper's Friend") == nil)
        #expect(server.clickedWindowIDs.isEmpty)
    }

    @Test func aStrayPastTheTierDividerIsCachedAsPlainHiddenAndStillResolves() async throws {
        // No always-hidden intent: the window sits past the divider but mirrors as plain hidden.
        let server = CountingWindowServer(items: [alwaysHidden, alwaysHiddenDivider, hiddenA])
        let bar = try makeBar(server)
        bar.alwaysHiddenDividerWindowID = alwaysHiddenDivider.windowID
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(Set(bar.cachedHiddenItems().map(\.id)) == [1, 4])
        #expect(bar.cachedAlwaysHiddenItems().isEmpty)
        let reads = server.readCount
        #expect(await bar.windowID(forOwnerKey: "tucked.app") == 4)
        #expect(server.readCount == reads)
    }

    @Test func activatingAnAlwaysHiddenItemRevealsBothTiersAndAPlainOneRevealsOne() async throws {
        let server = CountingWindowServer(items: [alwaysHidden, alwaysHiddenDivider, hiddenA])
        let bar = try makeBar(server, preferences: alwaysHiddenIntent(for: alwaysHidden))
        bar.alwaysHiddenDividerWindowID = alwaysHiddenDivider.windowID
        var hiddenReveals = 0
        var allReveals = 0
        bar.revealHiddenItems = { hiddenReveals += 1 }
        bar.revealAllHiddenItems = { allReveals += 1 }
        bar.rehideItems = {}
        bar.scheduleAutoRehideAfterActivation = {}
        await bar.captureAndCache(anchorMinX: 1000)

        #expect(bar.cachedAlwaysHiddenItems().map(\.id) == [4])
        let tucked = try #require(await bar.windowID(forOwnerKey: "tucked.app"))
        bar.activate(windowID: tucked)
        await (try #require(bar.currentActivationTask)).value
        #expect(allReveals == 1)
        #expect(hiddenReveals == 0)

        let plain = try #require(await bar.windowID(forOwnerKey: "test.app"))
        bar.activate(windowID: plain)
        await (try #require(bar.currentActivationTask)).value
        #expect(allReveals == 1)
        #expect(hiddenReveals == 1)
        #expect(server.clickedWindowIDs.allSatisfy { $0 == 4 || $0 == 1 })
    }

    private func glyph(side: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }
}

/// `FakeWindowServer` plus a read counter, so tests can tell a cache hit from an enumeration.
private final class CountingWindowServer: WindowServer, @unchecked Sendable {
    private let base: FakeWindowServer
    private(set) var readCount = 0
    var enumerationError: WindowServerError? {
        get { base.enumerationError }
        set { base.enumerationError = newValue }
    }

    init(items: [MenuBarItemSnapshot]) {
        base = FakeWindowServer(items: items)
    }

    var canSynthesizeClicks: Bool { base.canSynthesizeClicks }
    var clickedWindowIDs: [CGWindowID] { base.clickedWindowIDs }

    func menuBarItems() throws -> [MenuBarItemSnapshot] {
        readCount += 1
        return try base.menuBarItems()
    }

    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        try base.menuBarFrame(forDisplayContaining: point)
    }

    func click(item: MenuBarItemSnapshot) throws {
        try base.click(item: item)
    }

    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        try await base.move(item: item, toX: targetX, relativeTo: targetWindowID)
    }
}
