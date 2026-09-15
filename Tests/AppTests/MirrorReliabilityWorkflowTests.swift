import AppKit
import BarKeepersFriendCore
import CoreGraphics
import Testing

/// Drives the real engine, controller, and capture sequencing over a scripted window server. Only
/// the screenshot (the OS boundary) is faked; divider writes are recorded instead of moving the bar.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MirrorReliabilityWorkflowTests {
    private let anchorFrame = CGRect(x: 1000, y: 0, width: 32, height: 33)

    /// A launch inside a fullscreen Space cannot photograph the strip: the pass keeps the items
    /// reachable with fallbacks, never reveals, and never asks ScreenCaptureKit. Leaving the Space
    /// captures once; a complete cache asks for nothing more.
    @Test func hiddenMenuBarLaunchDefersCaptureAndASpaceChangeRecoversIt() async throws {
        let frame = anchorFrame
        let server = FakeWindowServer(items: layout(onScreen: false))
        let image = try glyph()
        var captureCalls = 0
        var dividerWrites: [Bool] = []
        let preferences = Preferences(autoRehide: false)
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in
                captureCalls += 1
                return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
            },
            preferences: preferences, attribute: { $0 }, immovablePIDs: { [] }
        )
        bar.controlItemWindowIDs = [90, 91]
        bar.hiddenDividerWindowID = 91
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, anchorFrame: { frame },
            onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        engine.staleCacheDebounce = 0.05
        engine.floatingBar = bar
        engine.toggleHidden()
        dividerWrites.removeAll()

        engine.fireWarmUpRetry()
        await engine.captureChain.value

        #expect(captureCalls == 0)
        #expect(!dividerWrites.contains(false))
        #expect(bar.hasCapturedOnce)
        #expect(bar.hasIncompleteGlyphs)
        #expect(bar.mirroredWindowIDs == [1, 2])

        // Still hidden: a Space change to another fullscreen Space changes nothing.
        engine.refreshFloatingBarCacheIfStale()
        try await settle(engine)
        #expect(captureCalls == 0)
        #expect(!dividerWrites.contains(false))

        // Hidden passes only restore the collapsed state; the visible one reveals and re-collapses.
        dividerWrites.removeAll()
        server.items = layout(onScreen: true)
        engine.refreshFloatingBarCacheIfStale()
        try await settle(engine)

        #expect(captureCalls == 1)
        #expect(dividerWrites == [false, true])
        #expect(!bar.hasIncompleteGlyphs)
        #expect(bar.mirroredWindowIDs == [1, 2])

        engine.refreshFloatingBarCacheIfStale()
        try await settle(engine)
        #expect(captureCalls == 1)
        #expect(dividerWrites == [false, true])
    }

    /// Closing the bar is the recovery point for a mirror that is incomplete or no longer matches
    /// the menu bar. Reopening cancels a pending refresh; an item the system moved back beside the
    /// anchor disappears from the very next open without any capture.
    @Test func closingTheBarRefreshesAnIncompleteOrStaleMirrorAndOpensFollowPositions() async throws {
        let frame = anchorFrame
        let server = FakeWindowServer(items: layout(onScreen: true))
        let image = try glyph()
        var capturableIDs: Set<CGWindowID> = [1]
        var captureCalls = 0
        var dividerWrites: [Bool] = []
        let panel = SilentPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let preferences = Preferences(autoRehide: false, dismissBarOnMouseExit: false)
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in
                captureCalls += 1
                return Dictionary(uniqueKeysWithValues: items.filter { capturableIDs.contains($0.windowID) }.map { ($0.windowID, image) })
            },
            preferences: preferences, attribute: { $0 }, panelFactory: { panel }, immovablePIDs: { [] }
        )
        bar.controlItemWindowIDs = [90, 91]
        bar.hiddenDividerWindowID = 91
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, anchorFrame: { frame },
            onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        engine.staleCacheDebounce = 0.05
        engine.floatingBar = bar
        engine.toggleHidden()
        bar.onDidHide = { engine.refreshFloatingBarCacheIfStale() }

        engine.fireWarmUpRetry()
        await engine.captureChain.value
        #expect(bar.hasIncompleteGlyphs)
        #expect(bar.mirroredWindowIDs == [1, 2])
        let callsAfterWarmUp = captureCalls
        dividerWrites.removeAll()

        // Reopening before the debounce elapses cancels the refresh: the bar is in use.
        capturableIDs = [1, 2]
        await bar.show(anchorMinX: 1000, anchorRightX: 1032)
        bar.hide()
        await bar.show(anchorMinX: 1000, anchorRightX: 1032)
        try await Task.sleep(for: .milliseconds(150))
        await engine.captureChain.value
        #expect(captureCalls == callsAfterWarmUp)
        #expect(dividerWrites.isEmpty)
        #expect(bar.isVisible)

        bar.hide()
        try await settle(engine)
        #expect(captureCalls == callsAfterWarmUp + 1)
        #expect(dividerWrites == [false, true])
        #expect(!bar.hasIncompleteGlyphs)

        // A complete, current mirror asks for nothing when the bar closes again.
        await bar.show(anchorMinX: 1000, anchorRightX: 1032)
        bar.hide()
        try await settle(engine)
        #expect(captureCalls == callsAfterWarmUp + 1)
        #expect(dividerWrites == [false, true])

        // The system moves item 2 back beside the anchor (the privacy indicator's habit).
        server.items = layout(onScreen: true).map { item in
            item.windowID == 2 ? snapshot(2, x: 1040, owner: item.ownerBundleID) : item
        }
        await bar.show(anchorMinX: 1000, anchorRightX: 1032)
        #expect(bar.mirroredWindowIDs == [1])
        #expect(captureCalls == callsAfterWarmUp + 1)
        // The open already reconciled the mirror, so closing has nothing left to refresh.
        bar.hide()
        try await settle(engine)
        #expect(captureCalls == callsAfterWarmUp + 1)
        #expect(dividerWrites == [false, true])
        #expect(bar.mirroredWindowIDs == [1])
        #expect(!bar.hasIncompleteGlyphs)
    }

    /// A Control Center module that Accessibility names (the privacy indicator here) is left to the
    /// system even when it sits inside the hidden section; an item whose owner could not be resolved
    /// still carries Tahoe's blanket Control Center pid and must stay reachable.
    @Test func resolvedControlCenterModulesAreNotMirroredButUnresolvedItemsAre() async throws {
        let controlCenterPID: pid_t = 1510
        let indicator = snapshot(3, x: 880, owner: "Control Center", pid: controlCenterPID)
        let unresolved = snapshot(4, x: 850, owner: "Control Center", pid: controlCenterPID)
        let server = FakeWindowServer(items: layout(onScreen: true) + [indicator, unresolved])
        let image = try glyph()
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) }) },
            preferences: Preferences(autoRehide: false),
            attribute: { items in
                items.map { item in
                    switch item.windowID {
                    case 3: item.attributed(bundleID: "Screen Recording and Location are in use", pid: controlCenterPID)
                    case 4: item
                    default: item.attributed(bundleID: "test.app.\(item.windowID)", pid: pid_t(200 + item.windowID))
                    }
                }
            },
            immovablePIDs: { [controlCenterPID] }
        )
        bar.controlItemWindowIDs = [90, 91]
        bar.hiddenDividerWindowID = 91

        await bar.captureAndCache(anchorMinX: 1000)

        #expect(bar.mirroredWindowIDs == [4, 1, 2])
        #expect(!bar.hasIncompleteGlyphs)
        let manageable = try await bar.allManageableItems().map(\.id)
        #expect(!manageable.contains(3))
    }

    // MARK: - Fixtures

    /// Two hidden third-party items, the collapsed divider, and the anchor at x=1000.
    private func layout(onScreen: Bool) -> [MenuBarItemSnapshot] {
        [
            snapshot(1, x: 900, onScreen: onScreen),
            snapshot(2, x: 940, onScreen: onScreen),
            snapshot(91, x: 984, width: 16, owner: "Control Center", title: ControlItem.Identifier.hiddenDivider.rawValue, onScreen: onScreen),
            snapshot(90, x: 1000, width: 32, owner: "Control Center", title: ControlItem.Identifier.anchor.rawValue, onScreen: onScreen),
        ]
    }

    private func snapshot(
        _ id: CGWindowID, x: CGFloat, width: CGFloat = 30, owner: String? = "test.app",
        title: String? = "Item-0", pid: pid_t = -1, onScreen: Bool = true
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id, ownerPID: pid, ownerBundleID: owner, title: title,
            frame: CGRect(x: x, y: 0, width: width, height: 33), isOnScreen: onScreen
        )
    }

    private func glyph() throws -> CGImage {
        let side = 8
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    /// Lets the debounced refresh fire, then joins whatever it enqueued.
    private func settle(_ engine: CosmeticHideEngine) async throws {
        try await Task.sleep(for: .milliseconds(150))
        await engine.captureChain.value
    }
}
