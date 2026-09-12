import AppKit
import BarKeepersFriendCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct StagedPlacementIntegrationTests {
    @Test func mixedDraftEditsReversalsAndRepeatedPreviewsDoNoPlacementWork() async throws {
        let fixture = try Fixture()
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        await model.reloadItems()
        let hidden = try #require(model.loadedItems.first { $0.id == 1 })
        let shown = try #require(model.loadedItems.first { $0.id == 2 })
        let unconfigured = try #require(model.loadedItems.first { $0.id == 5 })
        let preferences = model.preferences
        let rows = model.loadedItems
        let snapshots = fixture.server.base.items
        let reads = fixture.server.readCount

        model.setHidden(true, forAll: [shown, unconfigured])
        model.setHidden(false, for: hidden)
        #expect(model.pendingChangeCount == 3)
        model.setHidden(false, for: unconfigured)
        #expect(model.pendingChangeCount == 2)
        #expect(!model.hasPendingChange(for: unconfigured))
        model.setHidden(true, for: hidden)
        model.setHidden(false, for: shown)
        #expect(!model.hasPendingChanges)
        #expect(model.pendingChangeCount == 0)

        model.setHidden(false, forAll: [hidden])
        model.setHidden(true, for: shown)
        #expect(model.hasPendingChange(for: hidden))
        #expect(model.hasPendingChange(for: shown))
        #expect(model.pendingChangeCount == 2)
        for _ in 0..<10 {
            let preview = model.placementPreview
            #expect(Set(preview.shown.map(\.id)) == [1, 4, 5])
            #expect(Set(preview.hidden.map(\.id)) == [2, 3])
            #expect(preview.unknown.isEmpty)
            for item in preview.shown + preview.hidden {
                let cached = try #require(rows.first { $0.id == item.id })
                #expect(item.image === cached.image)
            }
        }
        await fixture.engine.captureChain.value

        #expect(model.preferences == preferences)
        #expect(model.loadedItems.map(\.snapshot) == rows.map(\.snapshot))
        #expect(fixture.server.base.items == snapshots)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.work.pendingDraftCountsAtStart.isEmpty)
        #expect(fixture.engine.placementTask == nil)
        #expect(!fixture.engine.placementPending)
        #expect(!model.placementPending)
        #expect(!model.placementInProgress)
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.server.base.clickedWindowIDs.isEmpty)
        #expect(fixture.work.placementAttributions.isEmpty)
        #expect(fixture.work.barAttributions.count == 1)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(!fixture.bar.hasCapturedOnce)
        #expect(!fixture.engine.captureInFlight)
        #expect(fixture.work.dividerWrites == [true])
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(fixture.work.providerCalls == 1)
        #expect(fixture.server.readCount == reads)
        #expect(fixture.work.completions == 0)
    }

    @Test(arguments: [false, true])
    func applyCommitsMixedDraftOnceAndSharesPlacementAndCapture(useFloatingBar: Bool) async throws {
        let fixture = try Fixture(useFloatingBar: useFloatingBar)
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        await model.reloadItems()
        let hidden = try #require(model.loadedItems.first { $0.id == 1 })
        let shown = try #require(model.loadedItems.first { $0.id == 2 })
        let untouched = fixture.server.base.items.filter { [3, 4, 5, 90, 91].contains($0.windowID) }
        var expected = model.preferences
        expected.itemControls.setHidden(false, for: hidden.snapshot)
        expected.itemControls.setHidden(true, for: shown.snapshot)

        model.setHidden(false, for: hidden)
        model.setHidden(true, for: shown)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(fixture.engine.placementTask == nil)
        model.applyPlacementChanges()
        let placement = try #require(fixture.engine.placementTask)
        #expect(fixture.work.preferenceWrites == [expected])
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(!model.hasPendingChanges)
        #expect(model.pendingChangeCount == 0)
        #expect(model.placementInProgress)
        await placement.value

        #expect(!placement.isCancelled)
        #expect(fixture.server.moveAttempts == [1, 2])
        #expect(fixture.server.base.moveRequests.map(\.windowID) == [1, 2])
        #expect(fixture.server.base.moveRequests.map(\.targetWindowID) == [90, 91])
        #expect(fixture.server.base.moveRequests.map(\.targetX) == [1040, 976])
        #expect(fixture.server.maxConcurrentMoves == 1)
        #expect(fixture.server.base.items.first { $0.windowID == 1 }?.frame.minX == 1040)
        #expect(fixture.server.base.items.first { $0.windowID == 2 }?.frame.maxX == 976)
        #expect(fixture.server.base.items.filter { [3, 4, 5, 90, 91].contains($0.windowID) } == untouched)
        #expect(fixture.work.placementAttributions == [[1, 2, 3, 4, 5]])
        #expect(fixture.work.captureRequests == (useFloatingBar ? [[3, 2]] : []))
        #expect(fixture.work.movesAtCapture == (useFloatingBar ? [[1, 2]] : []))
        #expect(fixture.work.preferenceWritesAtCapture == (useFloatingBar ? [1] : []))
        #expect(fixture.bar.hasCapturedOnce == useFloatingBar)
        #expect(!fixture.bar.hasIncompleteGlyphs)
        #expect(fixture.work.providerCalls == 2)
        // Capture and each Settings load have their own batched attribution, not one per move.
        #expect(fixture.work.barAttributions.count == (useFloatingBar ? 3 : 2))
        #expect(fixture.work.completions == 1)
        #expect(fixture.work.dividerWrites == [true, false, true])
        #expect(model.preferences == expected)
        #expect(model.preferences.itemControls.hiddenInMenuBar == ["Shown App", "Keep Hidden", "Absent App"])
        #expect(model.preferences.itemControls.shownInMenuBar == ["Hidden App", "Keep Shown"])
        #expect(!model.preferences.itemControls.hasPlacementIntent(forKey: "Unconfigured App"))
        #expect(Set(model.placementPreview.hidden.map(\.id)) == [2, 3])
        #expect(Set(model.placementPreview.shown.map(\.id)) == [1, 4, 5])
        #expect(model.placementPreview.unknown.isEmpty)
        #expect(model.loadedItems.allSatisfy { $0.observedHidden == model.isHidden($0) })
        #expect(!model.placementInProgress)
        #expect(!model.placementPending)
        #expect(!model.placementFailed)
        #expect(model.placementMessage == nil)
        #expect(!fixture.engine.captureInFlight)
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .collapsed)

        model.applyPlacementChanges()
        await fixture.engine.captureChain.value
        #expect(!placement.isCancelled)
        #expect(fixture.work.preferenceWrites == [expected])
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(fixture.work.completions == 1)
        #expect(fixture.work.providerCalls == 2)
    }

    @Test(arguments: [false, true])
    func identicalShownApplyReconcilesLiveGeometryDespiteAFalseCachedHiddenFlag(staleObservation: Bool) async throws {
        let sibling = MenuBarItemSnapshot(
            windowID: 6, ownerPID: 1, ownerBundleID: "Hidden App",
            frame: CGRect(x: 1160, y: 0, width: 24, height: 22)
        )
        let fixture = try Fixture(
            itemControls: ItemControlStore(shownInMenuBar: ["Hidden App"]), additionalItems: [sibling]
        )
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        await model.reloadItems()
        let hidden = try #require(model.loadedItems.first { $0.id == 1 })
        let shownSibling = try #require(model.loadedItems.first { $0.id == sibling.windowID })
        let original = fixture.server.base.items
        let saved = model.preferences
        #expect(hidden.observedHidden == true)
        #expect(shownSibling.observedHidden == false)
        #expect(saved.itemControls.shownInMenuBar == ["Hidden App"])
        #expect(saved.itemControls.hiddenInMenuBar.isEmpty)

        model.setHidden(false, for: hidden)
        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: shownSibling))

        // External reflow changes geometry without submitting a BKF move or changing owner keys.
        let reflowed = MenuBarItemSnapshot(
            windowID: hidden.id, ownerPID: hidden.snapshot.ownerPID,
            ownerBundleID: hidden.snapshot.ownerBundleID, title: hidden.snapshot.title,
            frame: hidden.snapshot.frame.offsetBy(dx: (staleObservation ? 1040 : 1031) - hidden.snapshot.frame.minX, dy: 0)
        )
        fixture.server.base = FakeWindowServer(items: original.map { $0.windowID == hidden.id ? reflowed : $0 })
        await model.reloadItems()
        let cached = try #require(model.loadedItems.first { $0.id == hidden.id })
        #expect(cached.observedHidden == false)
        #expect(cached.snapshot == reflowed)
        #expect(model.loadedItems.filter { $0.snapshot.ownerBundleID == "Hidden App" }.map(\.observedHidden) == [false, false])
        #expect(HiddenLayoutPlanner.isPlacementSatisfied(
            item: cached.snapshot, hidden: false, anchorMaxX: 1032, dividerMinX: 984
        ) == staleObservation)
        if staleObservation {
            fixture.server.base = FakeWindowServer(items: original)
        }
        let live = try #require(fixture.server.base.items.first { $0.windowID == hidden.id })
        #expect(live.frame.minX == (staleObservation ? 800 : 1031))
        #expect(!HiddenLayoutPlanner.isPlacementSatisfied(
            item: live, hidden: false, anchorMaxX: 1032, dividerMinX: 984
        ))
        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: cached))
        #expect(model.preferences == saved)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.engine.placementTask == nil)
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(fixture.work.providerCalls == 2)
        #expect(fixture.work.dividerWrites == [true])

        model.applyPlacementChanges()
        #expect(fixture.work.retryCalls == 1)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(!model.hasPendingChanges)
        let placement = try #require(fixture.engine.placementTask)
        await placement.value

        #expect(fixture.server.moveAttempts == [1])
        #expect(fixture.server.base.moveRequests.map(\.windowID) == [1])
        #expect(fixture.server.base.moveRequests.map(\.targetWindowID) == [90])
        #expect(fixture.server.base.moveRequests.map(\.targetX) == [1040])
        #expect(fixture.server.base.items.first { $0.windowID == 1 }?.frame.minX == 1040)
        #expect(fixture.server.base.items.filter { $0.windowID != 1 } == original.filter { $0.windowID != 1 })
        #expect(fixture.work.placementAttributions == [[1, 2, 3, 4, 5, 6]])
        #expect(fixture.work.captureRequests == [[3]])
        #expect(fixture.work.movesAtCapture == [[1]])
        #expect(fixture.work.preferenceWritesAtCapture == [0])
        #expect(fixture.work.providerCalls == 3)
        #expect(fixture.work.barAttributions.count == 4)
        #expect(fixture.work.completions == 1)
        #expect(model.preferences == saved)
        #expect(model.loadedItems.filter { $0.snapshot.ownerBundleID == "Hidden App" }.allSatisfy {
            $0.observedHidden == false && $0.snapshot.frame.minX >= 1032
        })
        #expect(Set(model.placementPreview.shown.map(\.id)) == [1, 2, 4, 5, 6])
        #expect(!model.placementInProgress)
        #expect(!model.placementPending)
        #expect(!model.placementFailed)
        #expect(model.placementMessage == nil)

        let reads = fixture.server.readCount
        for _ in 0..<3 { model.applyPlacementChanges() }
        await fixture.engine.captureChain.value
        #expect(!placement.isCancelled)
        #expect(fixture.work.retryCalls == 1)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(fixture.server.moveAttempts == [1])
        #expect(fixture.work.placementAttributions.count == 1)
        #expect(fixture.work.captureRequests == [[3]])
        #expect(fixture.work.providerCalls == 3)
        #expect(fixture.server.readCount == reads)
        #expect(fixture.work.completions == 1)
        #expect(fixture.work.dividerWrites == [true, false, true])
    }

    @Test(arguments: [false, true])
    func pausedHiddenIntentCanBeReplacedWithObservedShownBeforeResume(useBulk: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        await model.reloadItems()
        let shown = try #require(model.loadedItems.first { $0.id == 2 })
        let otherOwner = try #require(model.loadedItems.first { $0.id == 1 })
        let shownItems = model.loadedItems.filter { $0.observedHidden == false }
        let original = model.preferences
        let snapshots = fixture.server.base.items
        let reads = fixture.server.readCount
        var deferredHidden = original
        deferredHidden.itemControls.setHidden(true, for: shown.snapshot)
        #expect(shown.observedHidden == false)
        #expect(shown.snapshot.frame.minX >= 1032)
        #expect(!model.canSetHidden(false, forAll: shownItems))

        fixture.engine.menuTogglePause()
        model.setHidden(true, for: shown)
        #expect(model.pendingChangeCount == 1)
        #expect(fixture.work.preferenceWrites.isEmpty)
        model.applyPlacementChanges()
        #expect(fixture.work.preferenceWrites == [deferredHidden])
        #expect(model.preferences == deferredHidden)
        #expect(model.preferences.itemControls.isHidden(shown.snapshot))
        #expect(model.placementPending)
        #expect(fixture.engine.placementPending)
        #expect(!model.placementInProgress)
        #expect(!model.hasPendingChanges)
        #expect(!model.isHidden(shown))
        #expect(fixture.engine.paused)
        #expect(fixture.engine.placementTask == nil)
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.work.captureRequests.isEmpty)

        model.setHidden(false, for: otherOwner)
        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: otherOwner))
        #expect(!model.hasPendingChange(for: shown))
        let afterApply = model.placementPreview
        #expect(Set(afterApply.hidden.map(\.id)) == [2, 3])
        #expect(Set(afterApply.shown.map(\.id)) == [1, 4, 5])
        #expect(afterApply.unknown.isEmpty)
        #expect(model.preferences == deferredHidden)
        model.discardPlacementChanges()
        #expect(!model.hasPendingChanges)
        #expect(model.placementPending)

        #expect(model.canSetHidden(false, forAll: useBulk ? shownItems : [shown]))
        if useBulk {
            model.setHidden(false, forAll: shownItems)
        } else {
            model.setHidden(false, for: shown)
        }
        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: shown))
        #expect(!model.canSetHidden(false, forAll: useBulk ? shownItems : [shown]))
        #expect(!model.isHidden(shown))
        #expect(model.preferences == deferredHidden)
        #expect(fixture.work.preferenceWrites == [deferredHidden])
        model.applyPlacementChanges()
        await fixture.engine.captureChain.value

        #expect(fixture.work.preferenceWrites == [deferredHidden, original])
        #expect(model.preferences == original)
        #expect(model.preferences.itemControls.shownInMenuBar.contains("Shown App"))
        #expect(!model.preferences.itemControls.hiddenInMenuBar.contains("Shown App"))
        #expect(!model.preferences.itemControls.hasPlacementIntent(forKey: "Unconfigured App"))
        #expect(!model.hasPendingChanges)
        #expect(model.pendingChangeCount == 0)
        #expect(model.placementPending)
        #expect(fixture.engine.placementPending)
        #expect(!model.placementInProgress)
        #expect(fixture.engine.paused)
        #expect(fixture.engine.placementTask == nil)
        #expect(fixture.work.pendingDraftCountsAtStart.isEmpty)
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.server.base.items == snapshots)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(fixture.work.placementAttributions.isEmpty)
        #expect(fixture.work.barAttributions.count == 1)
        #expect(fixture.work.providerCalls == 1)
        #expect(fixture.server.readCount == reads)
        #expect(fixture.work.completions == 0)
        #expect(fixture.work.dividerWrites == [true, false])
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .shown)

        fixture.engine.menuTogglePause()
        await (try #require(fixture.engine.placementTask)).value

        #expect(!fixture.engine.paused)
        #expect(fixture.work.preferenceWrites == [deferredHidden, original])
        #expect(model.preferences == original)
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(fixture.work.placementAttributions == [[1, 2, 3, 4, 5]])
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.server.base.items == snapshots)
        #expect(fixture.bar.hasCapturedOnce)
        #expect(!fixture.work.captureRequests.isEmpty)
        #expect(fixture.work.captureRequests.allSatisfy { Set($0) == [1, 3] })
        #expect(fixture.work.preferenceWritesAtCapture.allSatisfy { $0 == 2 })
        #expect(fixture.work.movesAtCapture.allSatisfy { $0.isEmpty })
        #expect(fixture.work.providerCalls == 2)
        #expect(fixture.work.completions == 1)
        #expect(model.loadedItems.first { $0.id == shown.id }?.observedHidden == false)
        #expect(Set(model.placementPreview.hidden.map(\.id)) == [1, 3])
        #expect(Set(model.placementPreview.shown.map(\.id)) == [2, 4, 5])
        #expect(!model.hasPendingChanges)
        #expect(!model.placementPending)
        #expect(!fixture.engine.placementPending)
        #expect(!model.placementInProgress)
        #expect(!model.placementFailed)
        #expect(model.placementMessage == nil)
        #expect(!fixture.engine.captureInFlight)
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .collapsed)
    }

    @Test func discardingMixedDraftLeavesPreferencesAndEngineUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        await model.reloadItems()
        let hidden = try #require(model.loadedItems.first { $0.id == 1 })
        let shown = try #require(model.loadedItems.first { $0.id == 2 })
        let preferences = model.preferences
        let snapshots = fixture.server.base.items
        let reads = fixture.server.readCount
        let original = model.placementPreview

        model.setHidden(true, forAll: model.loadedItems)
        model.setHidden(false, for: hidden)
        #expect(model.hasPendingChange(for: hidden))
        #expect(model.hasPendingChange(for: shown))
        #expect(model.pendingChangeCount == 4)
        model.discardPlacementChanges()
        model.discardPlacementChanges()
        model.applyPlacementChanges()
        await fixture.engine.captureChain.value

        #expect(!model.hasPendingChanges)
        #expect(model.pendingChangeCount == 0)
        #expect(model.loadedItems.allSatisfy { !model.hasPendingChange(for: $0) })
        #expect(model.preferences == preferences)
        #expect(model.placementPreview.hidden.map(\.id) == original.hidden.map(\.id))
        #expect(model.placementPreview.shown.map(\.id) == original.shown.map(\.id))
        #expect(model.placementPreview.unknown.map(\.id) == original.unknown.map(\.id))
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.work.pendingDraftCountsAtStart.isEmpty)
        #expect(fixture.engine.placementTask == nil)
        #expect(!model.placementInProgress)
        #expect(!model.placementPending)
        #expect(!model.placementFailed)
        #expect(model.placementMessage == nil)
        #expect(fixture.work.dividerWrites == [true])
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(fixture.server.base.items == snapshots)
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.work.placementAttributions.isEmpty)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(!fixture.bar.hasCapturedOnce)
        #expect(!fixture.engine.captureInFlight)
        #expect(fixture.work.providerCalls == 1)
        #expect(fixture.work.barAttributions.count == 1)
        #expect(fixture.server.readCount == reads)
        #expect(fixture.work.completions == 0)
    }

    @Test(arguments: [CGWindowID(1), CGWindowID(2)])
    func partialFailureShowsObservedPlacementAndRetryMovesOnlyTheUnresolvedItem(failedID: CGWindowID) async throws {
        let fixture = try Fixture()
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        await model.reloadItems()
        let hidden = try #require(model.loadedItems.first { $0.id == 1 })
        let shown = try #require(model.loadedItems.first { $0.id == 2 })
        fixture.server.failingWindowID.withLock { $0 = failedID }
        model.setHidden(false, for: hidden)
        model.setHidden(true, for: shown)
        model.applyPlacementChanges()
        let saved = model.preferences
        await (try #require(fixture.engine.placementTask)).value

        #expect(fixture.work.preferenceWrites == [saved])
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(fixture.server.moveAttempts == [1, 2])
        #expect(fixture.server.base.moveRequests.map(\.windowID) == [failedID == 1 ? 2 : 1])
        #expect(model.placementFailed)
        #expect(model.placementMessage?.contains("Couldn't move 1") == true)
        #expect(!model.placementInProgress)
        #expect(!model.hasPendingChanges)
        #expect(model.pendingChangeCount == 0)
        #expect(model.loadedItems.allSatisfy { $0.observedHidden == model.isHidden($0) })
        #expect(Set(model.placementPreview.hidden.map(\.id)) == (failedID == 1 ? [1, 2, 3] : [3]))
        #expect(Set(model.placementPreview.shown.map(\.id)) == (failedID == 1 ? [4, 5] : [1, 2, 4, 5]))
        #expect(model.placementPreview.unknown.isEmpty)
        let failed = try #require(model.loadedItems.first { $0.id == failedID })
        #expect(model.isHidden(failed) != saved.itemControls.isHidden(failed.snapshot))
        #expect(fixture.work.completions == 1)
        #expect(fixture.work.providerCalls == 2)
        #expect(fixture.work.captureRequests.count == 1)
        #expect(fixture.work.captureRequests.first == (failedID == 1 ? [3, 1, 2] : [3]))
        #expect(fixture.work.dividerWrites == [true, false, true])

        fixture.server.failingWindowID.withLock { $0 = nil }
        model.retryPlacement()
        #expect(model.placementInProgress)
        #expect(fixture.work.retryCalls == 1)
        #expect(fixture.work.preferenceWrites == [saved])
        await (try #require(fixture.engine.placementTask)).value

        #expect(fixture.server.moveAttempts == [1, 2, failedID])
        #expect(fixture.server.base.moveRequests.map(\.windowID) == (failedID == 1 ? [2, 1] : [1, 2]))
        #expect(fixture.server.maxConcurrentMoves == 1)
        #expect(fixture.work.pendingDraftCountsAtStart == [0, 0])
        #expect(fixture.work.placementAttributions == [[1, 2, 3, 4, 5], [1, 2, 3, 4, 5]])
        #expect(fixture.work.captureRequests.count == 2)
        #expect(fixture.work.captureRequests.last == [3, 2])
        #expect(fixture.work.preferenceWritesAtCapture == [1, 1])
        #expect(fixture.work.providerCalls == 3)
        #expect(fixture.work.completions == 2)
        #expect(fixture.work.dividerWrites == [true, false, true, false, true])
        #expect(fixture.work.preferenceWrites == [saved])
        #expect(model.preferences == saved)
        #expect(Set(model.placementPreview.hidden.map(\.id)) == [2, 3])
        #expect(Set(model.placementPreview.shown.map(\.id)) == [1, 4, 5])
        #expect(model.placementPreview.unknown.isEmpty)
        #expect(model.loadedItems.allSatisfy { $0.observedHidden == model.isHidden($0) })
        #expect(!model.placementFailed)
        #expect(model.placementMessage == nil)
        #expect(!model.placementInProgress)
        #expect(!model.placementPending)
        #expect(!model.hasPendingChanges)
        #expect(!fixture.engine.captureInFlight)
    }

    @Test func repeatedApplyAndDraftEditsCannotReplaceASuspendedPlacement() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let fixture = try Fixture(moveGate: (started, release))
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        await model.reloadItems()
        let hidden = try #require(model.loadedItems.first { $0.id == 1 })
        let shown = try #require(model.loadedItems.first { $0.id == 2 })
        let snapshots = fixture.server.base.items
        model.setHidden(false, for: hidden)
        model.setHidden(true, for: shown)
        model.applyPlacementChanges()
        let original = try #require(fixture.engine.placementTask)
        let saved = model.preferences
        await started.wait()
        let reads = fixture.server.readCount

        for _ in 0..<5 {
            model.applyPlacementChanges()
            model.discardPlacementChanges()
            model.setHidden(true, for: hidden)
            model.setHidden(false, for: shown)
            #expect(!model.hasPendingChanges)
            model.setHidden(true, forAll: model.loadedItems)
            #expect(!model.hasPendingChanges)
            model.setHidden(false, forAll: model.loadedItems)
            #expect(!model.hasPendingChanges)
            model.applyPlacementChanges()
            model.retryPlacement()
            #expect(!original.isCancelled)
            #expect(model.placementInProgress)
            #expect(fixture.engine.placementInProgress)
            #expect(!model.isHidden(hidden))
            #expect(model.isHidden(shown))
            #expect(Set(model.placementPreview.hidden.map(\.id)) == [2, 3])
            #expect(Set(model.placementPreview.shown.map(\.id)) == [1, 4, 5])
        }
        #expect(model.preferences == saved)
        #expect(fixture.work.preferenceWrites == [saved])
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(fixture.work.placementAttributions == [[1, 2, 3, 4, 5]])
        #expect(fixture.server.moveAttempts == [1])
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.server.base.items == snapshots)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(fixture.work.providerCalls == 1)
        #expect(fixture.server.readCount == reads)
        #expect(fixture.work.completions == 0)
        #expect(fixture.work.dividerWrites == [true, false])
        #expect(fixture.engine.captureInFlight)

        await release.open()
        await original.value
        await fixture.engine.captureChain.value
        #expect(!original.isCancelled)
        #expect(fixture.server.moveAttempts == [1, 2])
        #expect(fixture.server.base.moveRequests.map(\.windowID) == [1, 2])
        #expect(fixture.server.maxConcurrentMoves == 1)
        #expect(fixture.work.preferenceWrites == [saved])
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.work.captureRequests == [[3, 2]])
        #expect(fixture.work.movesAtCapture == [[1, 2]])
        #expect(fixture.work.providerCalls == 2)
        #expect(fixture.work.completions == 1)
        #expect(fixture.work.dividerWrites == [true, false, true])
        #expect(Set(model.placementPreview.hidden.map(\.id)) == [2, 3])
        #expect(Set(model.placementPreview.shown.map(\.id)) == [1, 4, 5])
        #expect(!model.hasPendingChanges)
        #expect(!model.placementInProgress)
        #expect(!model.placementPending)
        #expect(!model.placementFailed)
        #expect(!fixture.engine.captureInFlight)
    }

    @MainActor
    private struct Fixture {
        let server: CountedPlacementServer
        let work: Work
        let bar: FloatingBarController
        let engine: CosmeticHideEngine
        let model: SettingsModel

        init(
            useFloatingBar: Bool = true, moveGate: (started: AsyncGate, release: AsyncGate)? = nil,
            itemControls: ItemControlStore? = nil, additionalItems: [MenuBarItemSnapshot] = []
        ) throws {
            let items: [(CGWindowID, String, CGFloat)] = [
                (1, "Hidden App", 800), (2, "Shown App", 1100), (3, "Keep Hidden", 700),
                (4, "Keep Shown", 1200), (5, "Unconfigured App", 1300)
            ]
            let server = CountedPlacementServer(items: items.map { id, owner, x in
                MenuBarItemSnapshot(
                    windowID: id, ownerPID: 1, ownerBundleID: owner,
                    frame: CGRect(x: x, y: 0, width: 24, height: 22)
                )
            } + additionalItems + [
                MenuBarItemSnapshot(windowID: 90, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: 1000, y: 0, width: 32, height: 22)),
                MenuBarItemSnapshot(windowID: 91, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: 984, y: 0, width: 16, height: 22))
            ], moveGate: moveGate)
            let preferences = Preferences(
                autoRehide: false, useFloatingBar: useFloatingBar,
                itemAliases: ItemAliasStore(aliases: ["Hidden App": "Renamed Icon"]),
                itemControls: itemControls ?? ItemControlStore(
                    hiddenInMenuBar: ["Hidden App", "Keep Hidden", "Absent App"],
                    shownInMenuBar: ["Shown App", "Keep Shown"],
                    suppressedFromBar: ["Keep Shown"], barOrder: ["Keep Hidden": 4]
                ),
                dismissBarOnMouseExit: false
            )
            let work = Work()
            let context = try #require(CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let image = try #require(context.makeImage())
            let bar = FloatingBarController(
                windowServer: server,
                captureIcons: { items in
                    work.captureRequests.append(items.map(\.windowID))
                    work.movesAtCapture.append(server.base.moveRequests.map(\.windowID))
                    work.preferenceWritesAtCapture.append(work.preferenceWrites.count)
                    return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
                },
                preferences: preferences,
                attribute: { items in
                    work.barAttributions.append(items.map(\.windowID))
                    return items
                }
            )
            bar.hiddenDividerWindowID = 91
            bar.controlItemWindowIDs = [90, 91]
            let engine = CosmeticHideEngine(
                preferences: preferences, controlWindowIDs: { (90, 91) },
                setDividerCollapsed: { work.dividerWrites.append($0) },
                onPreferencesChanged: { work.preferenceWrites.append($0) }
            )
            engine.floatingBar = bar
            engine.hiddenItemController = HiddenItemController(windowServer: server) { items in
                work.placementAttributions.append(items.map(\.windowID))
                return items
            }
            let model = SettingsModel(
                preferences: preferences, loginItem: LoginItemService(),
                itemsProvider: {
                    work.providerCalls += 1
                    return try await bar.allManageableItems()
                },
                onRetryPlacement: { [weak engine] in
                    work.retryCalls += 1
                    engine?.reconcileHiddenItems(userInitiated: true)
                },
                onChange: { [weak engine] preferences in
                    work.preferenceWrites.append(preferences)
                    engine?.apply(preferences: preferences)
                    bar.preferences = preferences
                }
            )
            engine.onPlacementStatusChanged = { [weak engine, weak model] in
                guard let engine, let model else { return }
                if engine.placementInProgress { work.pendingDraftCountsAtStart.append(model.pendingChangeCount) }
                model.placementInProgress = engine.placementInProgress
                model.placementPending = engine.placementPending
                model.placementMessage = engine.placementMessage
                model.placementFailed = engine.placementFailed
            }
            engine.onPlacementCompleted = { [weak model] in
                work.completions += 1
                await model?.reloadItems()
            }
            engine.toggleHidden()
            self.server = server
            self.work = work
            self.bar = bar
            self.engine = engine
            self.model = model
        }
    }

    @MainActor
    private final class Work {
        var preferenceWrites: [Preferences] = []
        var retryCalls = 0
        var pendingDraftCountsAtStart: [Int] = []
        var placementAttributions: [[CGWindowID]] = []
        var barAttributions: [[CGWindowID]] = []
        var captureRequests: [[CGWindowID]] = []
        var movesAtCapture: [[CGWindowID]] = []
        var preferenceWritesAtCapture: [Int] = []
        var providerCalls = 0
        var completions = 0
        var dividerWrites: [Bool] = []
    }
}

private final class CountedPlacementServer: WindowServer, @unchecked Sendable {
    var base: FakeWindowServer
    let failingWindowID = Mutex<CGWindowID?>(nil)
    private let moveGate: (started: AsyncGate, release: AsyncGate)?
    private let counts = Mutex((reads: 0, attempts: [CGWindowID](), inFlight: 0, maxInFlight: 0))

    init(items: [MenuBarItemSnapshot], moveGate: (started: AsyncGate, release: AsyncGate)?) {
        base = FakeWindowServer(items: items)
        self.moveGate = moveGate
    }

    var readCount: Int { counts.withLock { $0.reads } }
    var moveAttempts: [CGWindowID] { counts.withLock { $0.attempts } }
    var maxConcurrentMoves: Int { counts.withLock { $0.maxInFlight } }
    var canSynthesizeClicks: Bool { base.canSynthesizeClicks }

    func menuBarItems() throws -> [MenuBarItemSnapshot] {
        counts.withLock { $0.reads += 1 }
        return try base.menuBarItems()
    }

    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        try base.menuBarFrame(forDisplayContaining: point)
    }

    func click(item: MenuBarItemSnapshot) throws { try base.click(item: item) }

    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        let firstMove = counts.withLock {
            $0.attempts.append(item.windowID)
            $0.inFlight += 1
            $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
            return $0.attempts.count == 1
        }
        defer { counts.withLock { $0.inFlight -= 1 } }
        if firstMove, let moveGate {
            await moveGate.started.open()
            await moveGate.release.wait()
        }
        try Task.checkCancellation()
        if failingWindowID.withLock({ $0 == item.windowID }) {
            throw WindowServerError.moveFailed(windowID: item.windowID)
        }
        try await base.move(item: item, toX: targetX, relativeTo: targetWindowID)
    }
}
