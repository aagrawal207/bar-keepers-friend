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

    // MARK: - Always Hidden tier

    @Test func noAlwaysHiddenDividerIsCreatedWithoutIntent() async {
        let server = FakeWindowServer(items: tieredControls + [tieredItem(1, x: 1100, owner: "Hidden App")])
        let recorder = AlwaysHiddenDividerRecorder()
        var dividerWrites: [Bool] = []
        let preferences = Preferences(
            autoRehide: false, useFloatingBar: false,
            itemControls: ItemControlStore(hiddenInMenuBar: ["Hidden App"], shownInMenuBar: ["Shown App"])
        )
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, alwaysHiddenDivider: recorder.hooks,
            onPreferencesChanged: { _ in }
        )
        engine.hiddenItemController = HiddenItemController(windowServer: server)

        engine.apply(preferences: preferences)
        engine.toggleHidden()
        engine.anchorLeftClick(optionHeld: true)
        engine.anchorLeftClick(optionHeld: false)
        await engine.runCaptureSequence(forceCollapseAfter: true) {}.value
        engine.menuTogglePause()
        engine.menuTogglePause()
        engine.reconcileHiddenItems()
        if let placement = engine.placementTask { await placement.value }

        #expect(recorder.creates == 0)
        #expect(recorder.writes.isEmpty)
        #expect(!engine.alwaysHiddenDividerInstalled)
        #expect(!dividerWrites.isEmpty)
        #expect(server.moveRequests.map(\.targetWindowID) == [91])
        engine.uninstall()
    }

    @Test(arguments: [false, true])
    func alwaysHiddenIntentCreatesTheDividerOnceAndTheLaunchBaselineCollapsesBoth(viaReconcile: Bool) async {
        let server = FakeWindowServer(items: tieredControls)
        let recorder = AlwaysHiddenDividerRecorder()
        var dividerWrites: [Bool] = []
        let preferences = Preferences(
            autoRehide: false, useFloatingBar: false,
            itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["Secret App"])
        )
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, alwaysHiddenDivider: recorder.hooks,
            onPreferencesChanged: { _ in }
        )
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        #expect(!engine.alwaysHiddenDividerInstalled)

        if viaReconcile {
            engine.reconcileHiddenItems()
            await engine.placementTask?.value
        } else {
            engine.apply(preferences: preferences)
        }
        #expect(recorder.creates == 1)
        #expect(engine.alwaysHiddenDividerInstalled)
        engine.apply(preferences: preferences)
        engine.reconcileHiddenItems()
        await engine.placementTask?.value
        #expect(recorder.creates == 1)

        recorder.writes.removeAll()
        dividerWrites.removeAll()
        await engine.runCaptureSequence(forceCollapseAfter: true) {}.value
        #expect(dividerWrites == [false, true])
        #expect(recorder.writes == [false, true])
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)
        #expect(server.moveRequests.isEmpty)
        engine.uninstall()
        #expect(!engine.alwaysHiddenDividerInstalled)
    }

    @Test func reflowClicksRevealOnlyTheHiddenTierAndOptionRevealsBoth() {
        let recorder = AlwaysHiddenDividerRecorder()
        var dividerWrites: [Bool] = []
        let preferences = Preferences(
            autoRehide: false, useFloatingBar: false,
            itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["Secret App"])
        )
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, alwaysHiddenDivider: recorder.hooks,
            onPreferencesChanged: { _ in }
        )
        engine.apply(preferences: preferences)
        engine.toggleHidden()
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)
        recorder.writes.removeAll()
        dividerWrites.removeAll()

        engine.anchorLeftClick(optionHeld: false)
        #expect(dividerWrites == [false])
        #expect(recorder.writes.isEmpty)
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)
        engine.anchorLeftClick(optionHeld: false)
        #expect(dividerWrites == [false, true])
        #expect(recorder.writes.isEmpty)

        engine.anchorLeftClick(optionHeld: true)
        #expect(dividerWrites == [false, true, false])
        #expect(recorder.writes == [false])
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .shown)
        engine.anchorLeftClick(optionHeld: false)
        #expect(dividerWrites == [false, true, false, true])
        #expect(recorder.writes == [false, true])
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)

        engine.anchorLeftClick(optionHeld: true)
        engine.anchorLeftClick(optionHeld: true)
        #expect(dividerWrites == [false, true, false, true, false, true])
        #expect(recorder.writes == [false, true, false, true])
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)
        engine.uninstall()
    }

    @Test func pauseRevealsBothTiersAndResumeCollapsesBoth() async {
        let recorder = AlwaysHiddenDividerRecorder()
        var dividerWrites: [Bool] = []
        let preferences = Preferences(
            autoRehide: false, useFloatingBar: false,
            itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["Secret App"])
        )
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, alwaysHiddenDivider: recorder.hooks,
            onPreferencesChanged: { _ in }
        )
        engine.apply(preferences: preferences)
        engine.toggleHidden()
        recorder.writes.removeAll()
        dividerWrites.removeAll()

        engine.menuTogglePause()
        #expect(dividerWrites == [false])
        #expect(recorder.writes == [false])
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .shown)
        engine.anchorLeftClick(optionHeld: true)
        #expect(recorder.writes == [false])

        engine.menuTogglePause()
        await engine.placementTask?.value
        #expect(dividerWrites == [false, true])
        #expect(recorder.writes == [false, true])
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)
        #expect(engine.currentStatus != .paused)
        engine.uninstall()
    }

    @Test func optionClickPresentsTheCachedAlwaysHiddenTierWithoutRevealingAnything() async throws {
        let hiddenItem = tieredItem(1, x: 700, owner: "Hidden App")
        let secretItem = tieredItem(2, x: 300, owner: "Secret App")
        let shownItem = tieredItem(3, x: 1100, owner: "Shown App")
        let server = FakeWindowServer(items: [hiddenItem, secretItem, shownItem] + tieredControls)
        let recorder = AlwaysHiddenDividerRecorder()
        var dividerWrites: [Bool] = []
        let preferences = Preferences(
            autoRehide: false,
            itemControls: ItemControlStore(hiddenInMenuBar: ["Hidden App"], alwaysHiddenInMenuBar: ["Secret App"]),
            dismissBarOnMouseExit: false
        )
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        var captureCalls = 0
        let panel = SilentPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in
                captureCalls += 1
                return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
            },
            preferences: preferences, attribute: { $0 }, panelFactory: { panel }
        )
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) },
            anchorFrame: { CGRect(x: 1000, y: 0, width: 32, height: 24) },
            alwaysHiddenDivider: recorder.hooks, onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        engine.floatingBar = bar
        engine.apply(preferences: preferences)
        #expect(bar.alwaysHiddenDividerWindowID == 92)
        #expect(bar.hiddenDividerWindowID == 91)
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(bar.cachedHiddenItems().map(\.id) == [1])
        #expect(bar.cachedAlwaysHiddenItems().map(\.id) == [2])
        engine.toggleHidden()
        let capturesBefore = captureCalls
        recorder.writes.removeAll()
        dividerWrites.removeAll()

        engine.anchorLeftClick(optionHeld: true)
        #expect(await waitUntil { bar.isVisible })
        #expect(bar.presentsAlwaysHidden)
        #expect(bar.presentation == .click)
        engine.anchorLeftClick(optionHeld: false)
        #expect(!bar.isVisible)
        #expect(!bar.presentsAlwaysHidden)

        engine.anchorLeftClick(optionHeld: false)
        #expect(await waitUntil { bar.isVisible })
        #expect(!bar.presentsAlwaysHidden)
        engine.anchorLeftClick(optionHeld: true)
        #expect(await waitUntil { bar.presentsAlwaysHidden })
        #expect(bar.isVisible)
        engine.anchorLeftClick(optionHeld: true)
        #expect(!bar.isVisible)

        #expect(dividerWrites.isEmpty)
        #expect(recorder.writes.isEmpty)
        #expect(captureCalls == capturesBefore)
        #expect(server.moveRequests.isEmpty)
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)
        #expect(panel.presentations == 3)
    }

    @Test func optionClickWithoutATierTogglesThePlainBarLikeAClick() async throws {
        let hiddenItem = tieredItem(1, x: 700, owner: "Hidden App")
        let server = FakeWindowServer(items: [hiddenItem] + Array(tieredControls.prefix(2)))
        let recorder = AlwaysHiddenDividerRecorder()
        let preferences = Preferences(
            autoRehide: false, itemControls: ItemControlStore(hiddenInMenuBar: ["Hidden App"]),
            dismissBarOnMouseExit: false
        )
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let panel = SilentPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) }) },
            preferences: preferences, attribute: { $0 }, panelFactory: { panel }
        )
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            anchorFrame: { CGRect(x: 1000, y: 0, width: 32, height: 24) },
            alwaysHiddenDivider: recorder.hooks, onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        engine.floatingBar = bar
        engine.apply(preferences: preferences)
        await bar.captureAndCache(anchorMinX: 1000)
        engine.toggleHidden()
        #expect(recorder.creates == 0)
        #expect(!engine.alwaysHiddenDividerInstalled)

        engine.anchorLeftClick(optionHeld: false)
        #expect(await waitUntil { bar.isVisible })
        #expect(!bar.presentsAlwaysHidden)
        engine.anchorLeftClick(optionHeld: true)
        #expect(!bar.isVisible)

        engine.anchorLeftClick(optionHeld: true)
        #expect(await waitUntil { bar.isVisible })
        #expect(!bar.presentsAlwaysHidden)
        #expect(bar.presentation == .click)
        engine.anchorLeftClick(optionHeld: true)
        #expect(!bar.isVisible)
        #expect(panel.presentations == 2)
        #expect(recorder.writes.isEmpty)
    }

    private var tieredControls: [MenuBarItemSnapshot] {
        [
            MenuBarItemSnapshot(windowID: 90, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: 1000, y: 0, width: 32, height: 22)),
            MenuBarItemSnapshot(windowID: 91, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: 984, y: 0, width: 16, height: 22)),
            MenuBarItemSnapshot(windowID: 92, ownerPID: 1, title: "BKFAlwaysHidden", frame: CGRect(x: 600, y: 0, width: 8, height: 22))
        ]
    }

    private func tieredItem(_ id: CGWindowID, x: CGFloat, owner: String) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: id, ownerPID: 1, ownerBundleID: owner, frame: CGRect(x: x, y: 0, width: 24, height: 22))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

/// Records the engine's always-hidden divider lifecycle; nothing here touches NSStatusBar.
@MainActor
final class AlwaysHiddenDividerRecorder {
    var creates = 0
    var writes: [Bool] = []
    var windowID: CGWindowID? = 92

    var hooks: AlwaysHiddenDividerHooks {
        AlwaysHiddenDividerHooks(
            create: { [unowned self] in self.creates += 1 },
            windowID: { [unowned self] in self.windowID },
            setCollapsed: { [unowned self] in self.writes.append($0) }
        )
    }
}

/// A panel that records presentation requests instead of touching the screen.
@MainActor
final class SilentPanel: NSPanel {
    private(set) var presentations = 0
    /// The size a presentation asked for; `frame` may lag while an AppKit animation is in flight.
    private(set) var lastRequestedFrame: CGRect?
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        lastRequestedFrame = frameRect
        super.setFrame(frameRect, display: flag)
    }
    override func makeKeyAndOrderFront(_ sender: Any?) { presentations += 1 }
    override func orderFront(_ sender: Any?) { presentations += 1 }
    override func orderOut(_ sender: Any?) {}
    override func orderFrontRegardless() { Issue.record("Tests must never order a panel on screen.") }
}
