import AppKit
import BarKeepersFriendCore
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlacementIntegrationTests {
    private let item = MenuBarItemSnapshot(
        windowID: 1, ownerPID: 1, ownerBundleID: "Test App",
        frame: CGRect(x: 800, y: 0, width: 24, height: 22)
    )
    private var controls: [MenuBarItemSnapshot] {
        [
            MenuBarItemSnapshot(windowID: 90, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: 1000, y: 0, width: 32, height: 22)),
            MenuBarItemSnapshot(windowID: 91, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: 984, y: 0, width: 16, height: 22))
        ]
    }

    private func fixture() -> (FakeWindowServer, CosmeticHideEngine, SettingsModel) {
        let server = FakeWindowServer(items: [item] + controls)
        let preferences = Preferences(useFloatingBar: false)
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [:] },
            preferences: preferences, attribute: { $0 }
        )
        bar.hiddenDividerWindowID = 91
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) }, onPreferencesChanged: { _ in }
        )
        engine.floatingBar = bar
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { try await bar.allManageableItems() },
            onRetryPlacement: { [weak engine] in engine?.reconcileHiddenItems(userInitiated: true) },
            onChange: { [weak engine] in engine?.apply(preferences: $0) }
        )
        engine.onPlacementStatusChanged = { [weak engine, weak model] in
            guard let engine, let model else { return }
            model.placementInProgress = engine.placementInProgress
            model.placementMessage = engine.placementMessage
            model.placementFailed = engine.placementFailed
        }
        engine.onPlacementCompleted = { [weak model] in await model?.reloadItems() }
        return (server, engine, model)
    }

    @Test func shownForAnUnconfiguredHiddenItemRunsTheRealPlacementPath() async throws {
        let (server, engine, model) = fixture()
        await model.reloadItems()
        let listed = try #require(model.loadedItems.first)
        #expect(model.isHidden(listed))
        #expect(model.preferences.itemControls.hiddenInMenuBar.isEmpty)
        #expect(model.preferences.itemControls.shownInMenuBar.isEmpty)

        model.setHidden(false, for: listed)
        #expect(model.placementInProgress)
        let task = try #require(engine.placementTask)
        await task.value

        #expect(server.moveRequests.count == 1)
        #expect(server.moveRequests.first?.targetWindowID == 90)
        #expect(server.items.first?.frame.minX == 1040)
        #expect(model.preferences.itemControls.shownInMenuBar == ["Test App"])
        #expect(!model.isHidden(try #require(model.loadedItems.first)))
        #expect(!model.placementInProgress)
        #expect(!model.placementFailed)
        #expect(!engine.placementPending)
    }

    @Test func placementFindsNativeControlsWhenAppKitWindowNumbersAreUnavailable() async throws {
        let server = FakeWindowServer(items: [item] + controls)
        let engine = CosmeticHideEngine(
            preferences: Preferences(useFloatingBar: false, itemControls: ItemControlStore(shownInMenuBar: ["Test App"])),
            onPreferencesChanged: { _ in }
        )
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        engine.reconcileHiddenItems()
        await (try #require(engine.placementTask)).value
        #expect(server.moveRequests.count == 1)
        #expect(server.moveRequests.first?.targetWindowID == 90)
        #expect(!engine.placementFailed)
    }

    @Test func replacingAnActivationStillWaitsForTheNativeMoveToRelease() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let deferred = AsyncGate()
        let server = DrainingMoveServer(base: FakeWindowServer(items: [item] + controls), started: started, release: release)
        let engine = CosmeticHideEngine(
            preferences: Preferences(useFloatingBar: false), controlWindowIDs: { (90, 91) }, onPreferencesChanged: { _ in }
        )
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        engine.onPlacementStatusChanged = { [weak engine] in
            if engine?.placementPending == true, engine?.placementInProgress == false {
                Task { await deferred.open() }
            }
        }
        engine.apply(preferences: Preferences(useFloatingBar: false, itemControls: ItemControlStore(shownInMenuBar: ["Test App"])))
        await started.wait()
        let first = Task { await engine.revealForActivation() }
        await deferred.wait()
        first.cancel()
        var secondFinished = false
        let second = Task {
            await engine.revealForActivation()
            secondFinished = true
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!secondFinished)
        await release.open()
        await first.value
        await second.value
        #expect(secondFinished)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(server.base.moveRequests.count == 1)
    }

    @Test func failedShownRemainsActionableAndIdenticalRetryCanSucceed() async throws {
        let (server, engine, model) = fixture()
        server.moveError = .moveFailed(windowID: 1)
        await model.reloadItems()
        model.setHidden(false, for: try #require(model.loadedItems.first))
        await (try #require(engine.placementTask)).value

        #expect(model.placementFailed)
        #expect(model.placementMessage?.contains("Couldn't move") == true)
        #expect(!model.placementInProgress)
        #expect(model.isHidden(try #require(model.loadedItems.first)))
        #expect(model.preferences.itemControls.shownInMenuBar == ["Test App"])

        server.moveError = nil
        model.setHidden(false, for: try #require(model.loadedItems.first))
        await (try #require(engine.placementTask)).value
        #expect(!model.isHidden(try #require(model.loadedItems.first)))
        #expect(!model.placementFailed)
        #expect(model.placementMessage == nil)
        #expect(server.moveRequests.count == 1)
    }

    @Test func permissionRecoveryReplaysPendingShownOnlyIntentOnce() async throws {
        let (server, engine, model) = fixture()
        server.canSynthesizeClicks = false
        var permissionRequests = 0
        engine.onNeedsAccessibilityForMove = { permissionRequests += 1 }
        await model.reloadItems()
        model.setHidden(false, for: try #require(model.loadedItems.first))

        #expect(engine.placementPending)
        #expect(server.moveRequests.isEmpty)
        #expect(permissionRequests == 1)
        #expect(!model.placementInProgress)
        #expect(model.placementMessage?.contains("Accessibility") == true)
        server.canSynthesizeClicks = true
        engine.resumePendingPlacement()
        await (try #require(engine.placementTask)).value
        engine.resumePendingPlacement()

        #expect(server.moveRequests.count == 1)
        #expect(!engine.placementPending)
        #expect(!model.placementFailed)
        #expect(permissionRequests == 1)
    }

    @Test func aPausedPlacementIsAppliedAfterResume() async throws {
        let (server, engine, model) = fixture()
        await model.reloadItems()
        engine.menuTogglePause()
        model.setHidden(false, for: try #require(model.loadedItems.first))
        #expect(engine.placementPending)
        #expect(server.moveRequests.isEmpty)
        #expect(!model.placementInProgress)

        engine.menuTogglePause()
        await (try #require(engine.placementTask)).value
        #expect(server.moveRequests.count == 1)
        #expect(!model.isHidden(try #require(model.loadedItems.first)))
        #expect(!engine.placementPending)
    }

    @Test func aSupersededRequestCannotMoveOrPublishFailureAfterTheNewRequest() async throws {
        let (server, engine, model) = fixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        var calls = 0
        engine.hiddenItemController = HiddenItemController(windowServer: server) { snapshots in
            calls += 1
            if calls == 1 {
                await started.open()
                await finish.wait()
            }
            return snapshots
        }
        await model.reloadItems()
        let listed = try #require(model.loadedItems.first)
        model.setHidden(false, for: listed)
        await started.wait()
        let old = try #require(engine.placementTask)
        model.setHidden(true, for: listed)
        let latest = try #require(engine.placementTask)
        await finish.open()
        await latest.value
        await old.value

        #expect(server.moveRequests.isEmpty)
        #expect(model.isHidden(try #require(model.loadedItems.first)))
        #expect(model.preferences.itemControls.hiddenInMenuBar == ["Test App"])
        #expect(model.preferences.itemControls.shownInMenuBar.isEmpty)
        #expect(!model.placementInProgress)
        #expect(!model.placementFailed)
    }

    @Test func missingControlsStayRevealedAndPendingUntilControlsBecomeAvailable() async throws {
        let server = FakeWindowServer(items: [item] + controls)
        var available = false
        let engine = CosmeticHideEngine(
            preferences: Preferences(useFloatingBar: false, itemControls: ItemControlStore(shownInMenuBar: ["Test App"])),
            controlWindowIDs: { available ? (90, 91) : nil }, onPreferencesChanged: { _ in }
        )
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        engine.reconcileHiddenItems()
        await (try #require(engine.placementTask)).value
        #expect(engine.placementPending)
        #expect(engine.placementFailed)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(server.moveRequests.isEmpty)

        available = true
        engine.resumePendingPlacement()
        await (try #require(engine.placementTask)).value
        #expect(!engine.placementPending)
        #expect(!engine.placementFailed)
        #expect(server.moveRequests.count == 1)
    }

    @Test func presentationOnlyPreferencesNeverSchedulePhysicalMoves() {
        let (_, engine, model) = fixture()
        model.preferences.itemAliases.setAlias("Nickname", forKey: "Test App")
        model.preferences.itemControls.setSuppressed(true, forKey: "Test App")
        model.preferences.itemControls.setOrderIndex(1, forKey: "Test App")
        model.preferences.revealOnHover = true
        #expect(engine.placementTask == nil)
        #expect(!engine.placementPending)
    }

    @Test func pendingBackgroundPlacementWaitsForTheActivationRevealToClose() async throws {
        let (server, engine, model) = fixture()
        server.canSynthesizeClicks = false
        await model.reloadItems()
        model.setHidden(false, for: try #require(model.loadedItems.first))
        await engine.revealForActivation()
        server.canSynthesizeClicks = true
        engine.resumePendingPlacement()
        #expect(engine.placementPending)
        #expect(engine.placementTask == nil)
        #expect(server.moveRequests.isEmpty)

        engine.toggleHidden()
        await (try #require(engine.placementTask)).value
        #expect(server.moveRequests.count == 1)
        #expect(!engine.placementPending)
    }

    @Test func anEmptyPlacementRequestDoesNotTakeOwnershipFromLaunchCapture() async {
        let engine = CosmeticHideEngine(preferences: .default, onPreferencesChanged: { _ in })
        let capture = engine.runCaptureSequence(forceCollapseAfter: true) {}
        engine.reconcileHiddenItems()
        await capture.value
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(engine.placementTask == nil)
    }

    @Test func captureCompletionDoesNotCollapseAnActivationReveal() async {
        let engine = CosmeticHideEngine(preferences: .default, onPreferencesChanged: { _ in })
        let started = AsyncGate()
        let finish = AsyncGate()
        let capture = engine.runCaptureSequence(forceCollapseAfter: true) {
            await started.open()
            await finish.wait()
        }
        await started.wait()
        await engine.revealForActivation()
        await finish.open()
        await capture.value
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
    }

    @Test func activationDefersAnAlreadyRunningPlacementUntilTheMenuCloses() async throws {
        let (server, engine, model) = fixture()
        let started = AsyncGate()
        let finish = AsyncGate()
        let deferred = AsyncGate()
        let originalStatusChanged = engine.onPlacementStatusChanged
        engine.onPlacementStatusChanged = { [weak engine] in
            originalStatusChanged?()
            if engine?.placementPending == true, engine?.placementInProgress == false {
                Task { await deferred.open() }
            }
        }
        var calls = 0
        engine.hiddenItemController = HiddenItemController(windowServer: server) { snapshots in
            calls += 1
            if calls == 1 {
                await started.open()
                await finish.wait()
            }
            return snapshots
        }
        await model.reloadItems()
        model.setHidden(false, for: try #require(model.loadedItems.first))
        await started.wait()
        let old = try #require(engine.placementTask)
        let activation = Task { await engine.revealForActivation() }
        await deferred.wait()
        await finish.open()
        await activation.value
        await old.value

        #expect(engine.placementPending)
        #expect(server.moveRequests.isEmpty)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
        engine.resumePendingPlacement()
        #expect(server.moveRequests.isEmpty)
        engine.toggleHidden()
        await (try #require(engine.placementTask)).value
        #expect(server.moveRequests.count == 1)
        #expect(!engine.placementPending)
    }

    @Test func aRejectedInitialCaptureGetsTheBoundedWarmupSecondPass() async throws {
        let server = FakeWindowServer(items: [item] + controls)
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        var attributionCalls = 0
        var captureCalls = 0
        let preferences = Preferences(useFloatingBar: false)
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { _ in captureCalls += 1; return [1: image] },
            preferences: preferences,
            attribute: { snapshots in
                attributionCalls += 1
                if attributionCalls == 1 {
                    try? await server.move(item: snapshots[0], toX: 850, relativeTo: 90)
                }
                return snapshots
            }
        )
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) }, onPreferencesChanged: { _ in }
        )
        engine.floatingBar = bar
        engine.apply(preferences: Preferences(useFloatingBar: true))
        await engine.captureChain.value
        engine.uninstall()

        #expect(attributionCalls == 2)
        #expect(captureCalls == 1)
        #expect(bar.hasCapturedOnce)
        #expect(!bar.needsCapture)
    }

    @Test(arguments: [false, true])
    func withdrawingIntentRestoresTheDividerWithoutOverridingPause(pauseBeforeCompletion: Bool) async throws {
        let server = FakeWindowServer(items: [item] + controls)
        var dividerCollapsed = false
        let started = AsyncGate()
        let finish = AsyncGate()
        let engine = CosmeticHideEngine(
            preferences: Preferences(useFloatingBar: false), controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerCollapsed = $0 }, onPreferencesChanged: { _ in }
        )
        engine.hiddenItemController = HiddenItemController(windowServer: server) { snapshots in
            await started.open()
            await finish.wait()
            return snapshots
        }
        engine.toggleHidden()
        #expect(dividerCollapsed)
        engine.apply(preferences: Preferences(useFloatingBar: false, itemControls: ItemControlStore(shownInMenuBar: ["Test App"])))
        await started.wait()
        #expect(!dividerCollapsed)
        engine.apply(preferences: Preferences(useFloatingBar: false))
        let restoration = try #require(engine.placementTask)
        if pauseBeforeCompletion { engine.menuTogglePause() }
        await finish.open()
        await restoration.value

        #expect(dividerCollapsed == !pauseBeforeCompletion)
        #expect(engine.stateMachine.visibility(of: .hidden) == (pauseBeforeCompletion ? .shown : .collapsed))
        #expect(server.moveRequests.isEmpty)
        #expect(!engine.placementInProgress)
    }
}

private struct DrainingMoveServer: WindowServer {
    let base: FakeWindowServer
    let started: AsyncGate
    let release: AsyncGate
    var canSynthesizeClicks: Bool { base.canSynthesizeClicks }
    func menuBarItems() throws -> [MenuBarItemSnapshot] { try base.menuBarItems() }
    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        try base.menuBarFrame(forDisplayContaining: point)
    }
    func click(item: MenuBarItemSnapshot) throws { try base.click(item: item) }
    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        try await base.move(item: item, toX: targetX, relativeTo: targetWindowID)
        await started.open()
        await release.wait()
        try Task.checkCancellation()
    }
}
