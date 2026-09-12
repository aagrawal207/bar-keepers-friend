import AppKit
import BarKeepersFriendCore
import CoreGraphics
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CosmeticHideEngineTests {
    @Test(arguments: [FloatingBarController.Presentation.hover, .click, .keyboard], [false, true])
    func queuedOptionalCaptureDoesNotRevealBehindACachedPanel(
        presentation: FloatingBarController.Presentation, warmUpRetry: Bool
    ) async {
        let server = FakeWindowServer()
        let preferences = Preferences(autoRehide: false)
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [:] }, preferences: preferences, attribute: { $0 }
        )
        var dividerWrites: [Bool] = []
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, onPreferencesChanged: { _ in }
        )
        engine.floatingBar = bar
        engine.toggleHidden()
        dividerWrites.removeAll()

        if warmUpRetry { engine.fireWarmUpRetry() } else { engine.refreshFloatingBarCache() }
        bar.beginPresentation(presentation)
        await engine.captureChain.value

        #expect(!dividerWrites.contains(false))
        #expect(!bar.hasCapturedOnce)
        #expect(bar.isVisible)
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(!engine.captureInFlight)
        engine.uninstall()
    }

    @Test(arguments: [1, 2], [false, true])
    func skippedOptionalSuccessorsRestoreThePredecessorsReveal(queuedRefreshes: Int, warmUpRetry: Bool) async {
        let server = FakeWindowServer()
        let preferences = Preferences(autoRehide: false)
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [:] }, preferences: preferences, attribute: { $0 }
        )
        var dividerWrites: [Bool] = []
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, onPreferencesChanged: { _ in }
        )
        engine.floatingBar = bar
        engine.toggleHidden()
        dividerWrites.removeAll()
        let started = AsyncGate()
        let finish = AsyncGate()
        let predecessor = engine.runCaptureSequence(forceCollapseAfter: false) {
            await started.open()
            await finish.wait()
        }
        await started.wait()
        #expect(dividerWrites == [false])
        for _ in 0..<queuedRefreshes {
            if warmUpRetry { engine.fireWarmUpRetry() } else { engine.refreshFloatingBarCache() }
        }
        bar.beginPresentation(.hover)
        #expect(dividerWrites == [false])

        await finish.open()
        await engine.captureChain.value
        await predecessor.value

        #expect(dividerWrites == [false, true])
        #expect(!bar.hasCapturedOnce)
        #expect(bar.isVisible)
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(!engine.captureInFlight)
        engine.uninstall()
    }

    @Test(arguments: [false, true])
    func unpausingResumesIconCollectionWithoutAccessibility(incompleteCache: Bool) async throws {
        let item = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: "test.app",
            frame: CGRect(x: 100, y: 0, width: 22, height: 22)
        )
        let server = FakeWindowServer(items: incompleteCache ? [item] : [])
        server.canSynthesizeClicks = false
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        var glyphReady = false
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in glyphReady ? [1: image] : [:] },
            preferences: .default, attribute: { $0 }
        )
        if incompleteCache {
            await bar.captureAndCache(anchorMinX: 1000, allowFallback: false)
            #expect(bar.hasIncompleteGlyphs)
        }
        var preferences = Preferences(useFloatingBar: false)
        let engine = CosmeticHideEngine(preferences: preferences, onPreferencesChanged: { _ in })
        engine.floatingBar = bar
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        engine.menuTogglePause()
        preferences.useFloatingBar = true
        engine.apply(preferences: preferences)
        glyphReady = true
        engine.menuTogglePause()
        await engine.runCaptureSequence(forceCollapseAfter: false) {}.value
        engine.uninstall()

        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)
        #expect(server.moveRequests.isEmpty)
    }

    @Test func unpausingAllowsFreshWorkButDoesNotReviveCancelledWork() async {
        let engine = CosmeticHideEngine(preferences: .default, onPreferencesChanged: { _ in })
        let started = AsyncGate()
        let finish = AsyncGate()
        var oldWasCancelled = false
        var staleWorkRan = false
        var freshWorkRan = false
        let old = engine.runCaptureSequence(forceCollapseAfter: true) {
            await started.open()
            await finish.wait()
            oldWasCancelled = Task.isCancelled
        }
        await started.wait()
        let queued = engine.runCaptureSequence(forceCollapseAfter: true) { staleWorkRan = true }
        engine.menuTogglePause()
        engine.menuTogglePause()
        let fresh = engine.runCaptureSequence(forceCollapseAfter: true) { freshWorkRan = true }

        await finish.open()
        await fresh.value
        await queued.value
        await old.value

        #expect(oldWasCancelled)
        #expect(!staleWorkRan)
        #expect(freshWorkRan)
        #expect(!engine.paused)
        #expect(engine.currentStatus == .ready)
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
    }

    @Test(arguments: [false, true])
    func stoppingOrDisablingCancelsInFlightCapture(disable: Bool) async {
        var preferences = Preferences.default
        let engine = CosmeticHideEngine(preferences: preferences, onPreferencesChanged: { _ in })
        let started = AsyncGate()
        let finish = AsyncGate()
        var wasCancelled = false
        let task = engine.runCaptureSequence(forceCollapseAfter: true) {
            await started.open()
            await finish.wait()
            wasCancelled = Task.isCancelled
        }
        await started.wait()

        if disable {
            preferences.useFloatingBar = false
            engine.apply(preferences: preferences)
        } else {
            engine.uninstall()
        }
        await finish.open()
        await task.value

        #expect(wasCancelled)
        #expect(!engine.captureInFlight)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
    }

    @Test func pausedModeIgnoresTogglesNewCaptureAndLateAutoRehide() async throws {
        let preferences = Preferences(autoRehideDelay: 2)
        var preferenceWrites = 0
        let engine = CosmeticHideEngine(preferences: preferences) { _ in preferenceWrites += 1 }
        engine.menuTogglePause()

        engine.toggleHidden()
        engine.toggleFromShortcut()
        engine.reconcileHiddenItems()
        engine.refreshFloatingBarCache()
        engine.scheduleAutoRehideAfterActivation()
        var captured = false
        await engine.runCaptureSequence(forceCollapseAfter: true) { captured = true }.value
        try await Task.sleep(for: .milliseconds(2200))

        #expect(!captured)
        #expect(preferenceWrites == 0)
        #expect(engine.currentStatus == .paused)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
    }

    @Test func pausingBeforeAQueuedCaptureStartsKeepsItemsRevealed() async {
        let engine = CosmeticHideEngine(preferences: .default, onPreferencesChanged: { _ in })
        var captured = false
        let task = engine.runCaptureSequence(forceCollapseAfter: true) { captured = true }

        engine.menuTogglePause()
        await task.value

        #expect(!captured)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(engine.currentStatus == .paused)
        #expect(!engine.captureInFlight)
    }

    @Test func pauseCancelsTheWholeCaptureChainNotJustItsTail() async {
        let engine = CosmeticHideEngine(preferences: .default, onPreferencesChanged: { _ in })
        let started = AsyncGate()
        let finish = AsyncGate()
        var firstWasCancelled = false
        var queuedCaptures = 0
        let first = engine.runCaptureSequence(forceCollapseAfter: true) {
            await started.open()
            await finish.wait()
            firstWasCancelled = Task.isCancelled
        }
        await started.wait()
        engine.runCaptureSequence(forceCollapseAfter: true) { queuedCaptures += 1 }
        let last = engine.runCaptureSequence(forceCollapseAfter: true) { queuedCaptures += 1 }

        engine.menuTogglePause()
        await finish.open()
        await last.value
        await first.value

        #expect(firstWasCancelled)
        #expect(queuedCaptures == 0)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(engine.currentStatus == .paused)
        #expect(!engine.captureInFlight)
    }

    @Test func pausingDuringAttributionPreventsMovesWhenItReturns() async {
        let items = [MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: "test.app",
            frame: CGRect(x: 1100, y: 0, width: 22, height: 22)
        )]
        let controlsItems = [
            MenuBarItemSnapshot(windowID: 90, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: 1000, y: 0, width: 24, height: 22)),
            MenuBarItemSnapshot(windowID: 91, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: 980, y: 0, width: 16, height: 22))
        ]
        let server = FakeWindowServer(items: items + controlsItems)
        let started = AsyncGate()
        let finish = AsyncGate()
        let mover = HiddenItemController(windowServer: server) { snapshots in
            await started.open()
            await finish.wait()
            return snapshots
        }
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "test.app")
        let engine = CosmeticHideEngine(preferences: .default, onPreferencesChanged: { _ in })
        let task = engine.runCaptureSequence(forceCollapseAfter: true) {
            await mover.reconcile(anchorWindowID: 90, dividerWindowID: 91, controls: controls)
        }

        await started.wait()
        engine.menuTogglePause()
        await finish.open()
        await task.value

        #expect(server.moveRequests.isEmpty)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
    }
}
