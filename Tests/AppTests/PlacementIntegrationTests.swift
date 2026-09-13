import AppKit
import BarKeepersFriendCore
import Synchronization
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
            model.placementPending = engine.placementPending
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
        #expect(model.hasPendingChanges)
        #expect(!model.placementInProgress)
        #expect(engine.placementTask == nil)
        #expect(server.moveRequests.isEmpty)
        model.applyPlacementChanges()
        #expect(!model.hasPendingChanges)
        #expect(model.placementInProgress)
        let task = try #require(engine.placementTask)
        await task.value

        #expect(server.moveRequests.count == 1)
        #expect(server.moveRequests.first?.targetWindowID == 90)
        #expect(server.items.first?.frame.minX == 1040)
        #expect(model.preferences.itemControls.shownInMenuBar == ["Test App"])
        #expect(!model.isHidden(try #require(model.loadedItems.first)))
        #expect(!model.placementInProgress)
        #expect(!model.placementPending)
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

    @Test(arguments: [false, true])
    func nativeInterruptionRetainsIntentWithoutCaptureOrCompletionAndAFreshRetryFinishes(initiallyCollapsed: Bool) async throws {
        let items = [
            MenuBarItemSnapshot(windowID: 1, ownerPID: 1, ownerBundleID: "First App", frame: CGRect(x: 1100, y: 0, width: 24, height: 22)),
            MenuBarItemSnapshot(windowID: 2, ownerPID: 1, ownerBundleID: "Second App", frame: CGRect(x: 1150, y: 0, width: 24, height: 22))
        ]
        let started = AsyncGate()
        let release = AsyncGate()
        let interrupted = Mutex(true)
        let server = DrainingMoveServer(
            base: FakeWindowServer(items: items + controls), started: started, release: release,
            interruptAfterMove: { interrupted.withLock { $0 } }
        )
        let preferences = Preferences(
            autoRehide: false, itemControls: ItemControlStore(hiddenInMenuBar: ["First App", "Second App"])
        )
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        var captureCalls = 0
        var completions = 0
        var dividerWrites: [Bool] = []
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in
                captureCalls += 1
                return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
            },
            preferences: preferences, attribute: { $0 }
        )
        let engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        engine.floatingBar = bar
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        engine.onPlacementCompleted = { completions += 1 }
        if initiallyCollapsed { engine.toggleHidden() }
        dividerWrites.removeAll()
        engine.reconcileHiddenItems()
        let first = try #require(engine.placementTask)
        await started.wait()
        await release.open()
        await first.value

        #expect(!first.isCancelled)
        #expect(engine.placementPending)
        #expect(!engine.placementInProgress)
        #expect(!engine.placementFailed)
        #expect(engine.placementMessage?.contains("interrupted") == true)
        #expect(engine.stateMachine.visibility(of: .hidden) == (initiallyCollapsed ? .collapsed : .shown))
        #expect(dividerWrites == [false, initiallyCollapsed])
        #expect(!engine.captureInFlight)
        #expect(captureCalls == 0)
        #expect(!bar.hasCapturedOnce)
        #expect(completions == 0)
        #expect(server.base.moveRequests.map(\.windowID) == [1])

        interrupted.withLock { $0 = false }
        engine.resumePendingPlacement()
        await (try #require(engine.placementTask)).value

        #expect(server.base.moveRequests.map(\.windowID) == [1, 2])
        #expect(!engine.placementPending)
        #expect(!engine.placementInProgress)
        #expect(!engine.placementFailed)
        #expect(engine.placementMessage == nil)
        #expect(captureCalls == 1)
        #expect(bar.hasCapturedOnce)
        #expect(completions == 1)
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(dividerWrites.last == true)
    }

    @Test func failedShownRemainsActionableAndIdenticalRetryCanSucceed() async throws {
        let (server, engine, model) = fixture()
        server.moveError = .moveFailed(windowID: 1)
        await model.reloadItems()
        model.setHidden(false, for: try #require(model.loadedItems.first))
        model.applyPlacementChanges()
        await (try #require(engine.placementTask)).value

        #expect(model.placementFailed)
        #expect(model.placementMessage?.contains("Couldn't move") == true)
        #expect(!model.placementInProgress)
        #expect(model.isHidden(try #require(model.loadedItems.first)))
        #expect(model.preferences.itemControls.shownInMenuBar == ["Test App"])

        server.moveError = nil
        model.setHidden(false, for: try #require(model.loadedItems.first))
        #expect(model.hasPendingChanges)
        model.applyPlacementChanges()
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
        #expect(permissionRequests == 0)
        #expect(!engine.placementPending)
        model.applyPlacementChanges()

        #expect(engine.placementPending)
        #expect(model.placementPending)
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
        #expect(!model.placementPending)
        #expect(!model.placementFailed)
        #expect(permissionRequests == 1)
    }

    @Test func aPausedPlacementIsAppliedAfterResume() async throws {
        let (server, engine, model) = fixture()
        await model.reloadItems()
        engine.menuTogglePause()
        model.setHidden(false, for: try #require(model.loadedItems.first))
        #expect(!engine.placementPending)
        model.applyPlacementChanges()
        #expect(engine.placementPending)
        #expect(model.placementPending)
        #expect(server.moveRequests.isEmpty)
        #expect(!model.placementInProgress)

        engine.menuTogglePause()
        await (try #require(engine.placementTask)).value
        #expect(server.moveRequests.count == 1)
        #expect(!model.isHidden(try #require(model.loadedItems.first)))
        #expect(!engine.placementPending)
        #expect(!model.placementPending)
    }

    @Test func externalPreferenceUpdateSupersedesAnActiveApplyWithoutStaleMovesOrFailure() async throws {
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
        model.applyPlacementChanges()
        await started.wait()
        let old = try #require(engine.placementTask)
        var replacement = model.preferences.itemControls
        replacement.setHidden(true, for: listed.snapshot)
        model.preferences.itemControls = replacement
        let latest = try #require(engine.placementTask)
        #expect(old.isCancelled)
        #expect(!latest.isCancelled)
        await finish.open()
        await latest.value
        await old.value

        #expect(server.moveRequests.isEmpty)
        #expect(model.isHidden(try #require(model.loadedItems.first)))
        #expect(model.preferences.itemControls.hiddenInMenuBar == ["Test App"])
        #expect(model.preferences.itemControls.shownInMenuBar.isEmpty)
        #expect(calls == 2)
        #expect(!model.hasPendingChanges)
        #expect(!model.placementInProgress)
        #expect(!model.placementPending)
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
        model.applyPlacementChanges()
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
        model.applyPlacementChanges()
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

    // MARK: - Always Hidden tier

    private var alwaysHiddenControl: MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: 92, ownerPID: 1, title: "BKFAlwaysHidden", frame: CGRect(x: 600, y: 0, width: 8, height: 22))
    }

    @Test func alwaysHiddenIntentCreatesTheDividerAndPlacesTheItemBesideIt() async throws {
        let shownItem = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: "Test App", frame: CGRect(x: 1100, y: 0, width: 24, height: 22)
        )
        let server = FakeWindowServer(items: [shownItem] + controls + [alwaysHiddenControl])
        let recorder = AlwaysHiddenDividerRecorder()
        var dividerWrites: [Bool] = []
        let engine = CosmeticHideEngine(
            preferences: Preferences(useFloatingBar: false, itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["Test App"])),
            controlWindowIDs: { (90, 91) }, setDividerCollapsed: { dividerWrites.append($0) },
            alwaysHiddenDivider: recorder.hooks, onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        engine.toggleHidden()
        dividerWrites.removeAll()

        engine.reconcileHiddenItems()
        #expect(recorder.creates == 1)
        await (try #require(engine.placementTask)).value

        #expect(server.moveRequests.map(\.windowID) == [1])
        #expect(server.moveRequests.first?.targetWindowID == 92)
        #expect(server.moveRequests.first?.targetX == 592)
        #expect(server.items.first?.frame.maxX == 592)
        #expect(!engine.placementFailed)
        #expect(!engine.placementPending)
        #expect(dividerWrites == [false, true])
        #expect(recorder.writes == [true, false, true])
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)

        engine.reconcileHiddenItems()
        await (try #require(engine.placementTask)).value
        #expect(server.moveRequests.count == 1)
        #expect(recorder.creates == 1)
    }

    @Test func alwaysHiddenIntentWithoutAUsableDividerWindowDegradesToHidden() async throws {
        let shownItem = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: "Test App", frame: CGRect(x: 1100, y: 0, width: 24, height: 22)
        )
        let server = FakeWindowServer(items: [shownItem] + controls)
        let recorder = AlwaysHiddenDividerRecorder()
        recorder.windowID = nil
        let engine = CosmeticHideEngine(
            preferences: Preferences(useFloatingBar: false, itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["Test App"])),
            controlWindowIDs: { (90, 91) }, alwaysHiddenDivider: recorder.hooks, onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        engine.hiddenItemController = HiddenItemController(windowServer: server)

        engine.reconcileHiddenItems()
        await (try #require(engine.placementTask)).value

        #expect(recorder.creates == 1)
        #expect(server.moveRequests.map(\.targetWindowID) == [91])
        #expect(server.moveRequests.first?.targetX == 976)
        #expect(server.items.first?.frame.maxX == 976)
        #expect(!engine.placementFailed)
    }

    @Test func aMissingAlwaysHiddenDividerWindowLeavesBothTiersRevealedAndPending() async throws {
        let server = FakeWindowServer(items: [item] + controls)
        let recorder = AlwaysHiddenDividerRecorder()
        let engine = CosmeticHideEngine(
            preferences: Preferences(useFloatingBar: false, itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["Test App"])),
            controlWindowIDs: { (90, 91) }, alwaysHiddenDivider: recorder.hooks, onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        engine.toggleHidden()

        engine.reconcileHiddenItems()
        await (try #require(engine.placementTask)).value

        #expect(server.moveRequests.isEmpty)
        #expect(engine.placementPending)
        #expect(engine.placementFailed)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(engine.stateMachine.visibility(of: .alwaysHidden) == .shown)
        #expect(recorder.writes.last == false)
        // Items left revealed by the failed observation must keep Live checks away.
        #expect(!engine.placementInProgress)
        #expect(engine.isBusyForLiveLayout)
        #expect(engine.lastFailedControls == nil)
    }

    // MARK: - Live mode

    @Test func liveModePreviewBacksOffAfterAFailedBatchUntilIntentChanges() async throws {
        let first = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: "First App", frame: CGRect(x: 1100, y: 0, width: 24, height: 22)
        )
        let second = MenuBarItemSnapshot(
            windowID: 2, ownerPID: 1, ownerBundleID: "Second App", frame: CGRect(x: 1150, y: 0, width: 24, height: 22)
        )
        let server = FakeWindowServer(items: [first, second] + controls)
        server.moveError = .moveFailed(windowID: 1)
        let firstIntent = Preferences(useFloatingBar: false, itemControls: ItemControlStore(hiddenInMenuBar: ["First App"]))
        let engine = CosmeticHideEngine(
            preferences: firstIntent, controlWindowIDs: { (90, 91) }, setDividerCollapsed: { _ in },
            onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        let controller = HiddenItemController(windowServer: server)
        engine.hiddenItemController = controller
        engine.toggleHidden()
        #expect(await engine.previewPlacementMoves() == 1)

        engine.reconcileHiddenItems()
        await (try #require(engine.placementTask)).value
        #expect(engine.placementFailed)
        #expect(engine.lastFailedControls == firstIntent.itemControls)
        #expect(!engine.isBusyForLiveLayout)
        // The planner still wants the move; Live mode alone must not keep retrying it.
        #expect(await controller.previewMoves(anchorWindowID: 90, dividerWindowID: 91, controls: firstIntent.itemControls) == 1)
        #expect(await engine.previewPlacementMoves() == 0)
        #expect(await engine.previewPlacementMoves() == 0)
        #expect(server.moveRequests.isEmpty)

        // Presentation-only edits keep the backoff; only a new tier intent lifts it.
        var presentationOnly = firstIntent
        presentationOnly.itemControls.setSuppressed(true, forKey: "First App")
        engine.apply(preferences: presentationOnly)
        #expect(engine.placementTask?.isCancelled == false)
        #expect(await engine.previewPlacementMoves() == 0)

        let secondIntent = Preferences(
            useFloatingBar: false, itemControls: ItemControlStore(hiddenInMenuBar: ["First App", "Second App"])
        )
        engine.apply(preferences: secondIntent)
        #expect(engine.lastFailedControls == nil)
        #expect(await engine.previewPlacementMoves() == 2)
        await (try #require(engine.placementTask)).value
        #expect(engine.placementFailed)
        #expect(engine.lastFailedControls == secondIntent.itemControls)
        #expect(await engine.previewPlacementMoves() == 0)

        // An explicit retry that succeeds clears the backoff and the preview reflects live geometry.
        server.moveError = nil
        engine.reconcileHiddenItems(userInitiated: true)
        await (try #require(engine.placementTask)).value
        #expect(!engine.placementFailed)
        #expect(engine.lastFailedControls == nil)
        #expect(await engine.previewPlacementMoves() == 0)
        try await server.move(item: server.items[0], toX: 1100, relativeTo: 90)
        #expect(await engine.previewPlacementMoves() == 1)
    }
}

private struct DrainingMoveServer: WindowServer {
    let base: FakeWindowServer
    let started: AsyncGate
    let release: AsyncGate
    var interruptAfterMove: @Sendable () -> Bool = { false }
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
        if interruptAfterMove() { throw CancellationError() }
        try Task.checkCancellation()
    }
}
