import AppKit
import BarKeepersFriendCore
import SwiftUI
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

    // MARK: - Always Hidden tier

    @Test func applyingAnAlwaysHiddenChoiceCreatesTheDividerAndPlacesBesideItOnce() async throws {
        let fixture = try Fixture(alwaysHiddenDivider: true)
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        await model.reloadItems()
        let shown = try #require(model.loadedItems.first { $0.id == 2 })
        let hidden = try #require(model.loadedItems.first { $0.id == 1 })
        #expect(model.loadedItems.allSatisfy { $0.observedPlacement != .alwaysHidden })
        #expect(fixture.alwaysHidden.creates == 0)
        #expect(fixture.alwaysHidden.writes.isEmpty)
        #expect(!fixture.engine.alwaysHiddenDividerInstalled)
        var expected = model.preferences
        expected.itemControls.setPlacement(.alwaysHidden, for: shown.snapshot)

        model.setPlacement(.alwaysHidden, for: shown)
        #expect(model.placement(of: shown) == .alwaysHidden)
        #expect(model.isHidden(shown))
        #expect(model.partition(model.loadedItems).alwaysHidden.map(\.id) == [2])
        #expect(model.placementPreview.alwaysHidden.map(\.id) == [2])
        #expect(!model.placementPreview.hidden.contains { $0.id == 2 })
        #expect(fixture.alwaysHidden.creates == 0)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.engine.placementTask == nil)

        model.applyPlacementChanges()
        let placement = try #require(fixture.engine.placementTask)
        #expect(fixture.alwaysHidden.creates == 1)
        #expect(fixture.engine.alwaysHiddenDividerInstalled)
        #expect(fixture.work.preferenceWrites == [expected])
        await placement.value

        #expect(fixture.server.base.moveRequests.map(\.windowID) == [2])
        #expect(fixture.server.base.moveRequests.map(\.targetWindowID) == [92])
        #expect(fixture.server.base.moveRequests.map(\.targetX) == [592])
        #expect(fixture.server.base.items.first { $0.windowID == 2 }?.frame.maxX == 592)
        #expect(fixture.work.captureRequests == [[3, 1, 2]])
        #expect(fixture.bar.cachedHiddenItems().map(\.id) == [3, 1])
        #expect(fixture.bar.cachedAlwaysHiddenItems().map(\.id) == [2])
        #expect(fixture.work.dividerWrites == [true, false, true])
        #expect(fixture.alwaysHidden.writes == [true, false, true])
        #expect(fixture.work.completions == 1)
        #expect(model.preferences == expected)
        #expect(model.preferences.itemControls.alwaysHiddenInMenuBar == ["Shown App"])
        #expect(!model.preferences.itemControls.hiddenInMenuBar.contains("Shown App"))
        #expect(model.loadedItems.first { $0.id == 2 }?.observedPlacement == .alwaysHidden)
        #expect(model.placement(of: try #require(model.loadedItems.first { $0.id == 2 })) == .alwaysHidden)
        #expect(model.placement(of: try #require(model.loadedItems.first { $0.id == 1 })) == .hidden)
        #expect(model.partition(model.loadedItems).alwaysHidden.map(\.id) == [2])
        #expect(model.placementPreview.alwaysHidden.map(\.id) == [2])
        #expect(Set(model.placementPreview.hidden.map(\.id)) == [1, 3])
        #expect(!model.hasPendingChanges)
        #expect(!model.placementInProgress)
        #expect(!model.placementFailed)
        #expect(fixture.engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)

        // Returning the item to plain Hidden moves it between the dividers, not back to Shown.
        model.setPlacement(.hidden, for: try #require(model.loadedItems.first { $0.id == 2 }))
        model.applyPlacementChanges()
        await (try #require(fixture.engine.placementTask)).value
        #expect(fixture.server.base.moveRequests.map(\.targetWindowID) == [92, 91])
        #expect(fixture.server.base.moveRequests.last?.targetX == 976)
        let restored = try #require(fixture.server.base.items.first { $0.windowID == 2 })
        #expect(restored.frame.maxX == 976 && restored.frame.minX >= 608)
        #expect(fixture.alwaysHidden.creates == 1)
        #expect(model.preferences.itemControls.placement(forKey: "Shown App") == .hidden)
        #expect(model.loadedItems.first { $0.id == 2 }?.observedPlacement == .hidden)
        #expect(model.placement(of: hidden) == .hidden)
    }

    @Test(arguments: [false, true])
    func mountedDragsStageEveryDirectionAndApplyOnePersistedSerialBatch(useFloatingBar: Bool) async throws {
        let suite = "StagedPlacementDragApply.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(backing: defaults)
        let started = AsyncGate()
        let release = AsyncGate()
        defer { Task { await release.open() } }
        let sibling = MenuBarItemSnapshot(
            windowID: 6, ownerPID: 1, ownerBundleID: "Hidden App",
            frame: CGRect(x: 1160, y: 0, width: 24, height: 22)
        )
        let fixture = try Fixture(
            useFloatingBar: useFloatingBar, moveGate: (started, release), additionalItems: [sibling],
            alwaysHiddenDivider: true, store: store
        )
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        let host = try await mountDragItems(model)
        let saved = model.preferences
        let snapshots = fixture.server.base.items
        let reads = fixture.server.readCount
        #expect(store.hasSavedPreferences)
        #expect(store.load() == saved)
        #expect(model.placementPreview.alwaysHidden.isEmpty)

        // All six directed edges include the initially empty third bar and reversals of absent intent.
        for (from, to) in [
            (ItemPlacement.shown, ItemPlacement.hidden), (.hidden, .alwaysHidden), (.alwaysHidden, .shown),
            (.shown, .alwaysHidden), (.alwaysHidden, .hidden), (.hidden, .shown)
        ] {
            try await stageDrag(5, from: from, into: to, model: model, host: host)
            #expect(model.pendingChangeCount == (to == .shown ? 0 : 1))
            #expect(!model.preferences.itemControls.hasPlacementIntent(forKey: "Unconfigured App"))
        }
        let sameSide = try await beginDrag(5, from: .shown, into: .shown, model: model, host: host)
        expectRejected(sameSide.info, by: sameSide.target)
        #expect(!model.hasPendingChanges)
        #expect(model.isDraggingPlacementItem)
        sameSide.source.finishDragging()
        #expect(!model.isDraggingPlacementItem)

        try await stageDrag(6, from: .shown, into: .alwaysHidden, model: model, host: host)
        #expect(model.pendingChangeCount == 1)
        #expect(Set(model.placementPreview.alwaysHidden.map(\.id)) == [1, 6])
        #expect(model.loadedItems.filter { [1, 6].contains($0.id) }.allSatisfy { model.hasPendingChange(for: $0) })
        try await stageDrag(6, from: .alwaysHidden, into: .shown, model: model, host: host)
        #expect(model.pendingChangeCount == 1, "Mixed observed siblings have no common baseline to reverse to.")
        #expect(model.loadedItems.filter { [1, 6].contains($0.id) }.allSatisfy { model.placement(of: $0) == .shown })

        try await stageDrag(4, from: .shown, into: .hidden, model: model, host: host)
        #expect(!model.placementPreview.hidden.contains { $0.id == 4 })
        #expect(model.placementPreview(includingSuppressed: true).hidden.contains { $0.id == 4 })
        try await stageDrag(4, from: .hidden, into: .alwaysHidden, model: model, host: host)
        #expect(!model.placementPreview.alwaysHidden.contains { $0.id == 4 })
        #expect(model.placementPreview(includingSuppressed: true).alwaysHidden.contains { $0.id == 4 })
        try await stageDrag(4, from: .alwaysHidden, into: .shown, model: model, host: host)
        try await stageDrag(2, from: .shown, into: .hidden, model: model, host: host)
        #expect(model.pendingChangeCount == 2)
        try pressDragControl("settings-placement-discard", in: host)
        try #require(await settleDragUI(host) { !model.hasPendingChanges })
        #expect(model.loadedItems.allSatisfy { model.placement(of: $0) == $0.observedPlacement })

        try await stageDrag(1, from: .hidden, into: .shown, model: model, host: host)
        try await stageDrag(2, from: .shown, into: .alwaysHidden, model: model, host: host)
        try await stageDrag(5, from: .shown, into: .hidden, model: model, host: host)
        #expect(model.pendingChangeCount == 3)
        #expect(model.preferences == saved)
        #expect(store.load() == saved)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.server.base.items == snapshots)
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.server.base.clickedWindowIDs.isEmpty)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(fixture.work.placementAttributions.isEmpty)
        #expect(fixture.work.providerCalls == 1)
        #expect(fixture.server.readCount == reads)
        #expect(fixture.work.dividerWrites == [true])
        #expect(fixture.alwaysHidden.creates == 0)
        #expect(fixture.engine.placementTask == nil)

        let interrupted = try await beginDrag(4, from: .shown, into: .hidden, model: model, host: host)
        #expect(interrupted.target.draggingEntered(interrupted.info) == .move)
        #expect(interrupted.target.prepareForDragOperation(interrupted.info))
        var expected = saved
        expected.itemControls.setPlacement(.shown, forKey: "Hidden App")
        expected.itemControls.setPlacement(.alwaysHidden, forKey: "Shown App")
        expected.itemControls.setPlacement(.hidden, forKey: "Unconfigured App")
        try pressDragControl("settings-placement-apply", in: host)
        try #require(await settleDragUI(host) { fixture.server.moveAttempts == [1] && model.placementInProgress })
        let placement = try #require(fixture.engine.placementTask)
        #expect(fixture.work.preferenceWrites == [expected])
        #expect(store.load() == expected)
        #expect(fixture.work.pendingDraftCountsAtStart == [0])
        #expect(!model.hasPendingChanges)
        #expect(!model.isDraggingPlacementItem)
        #expect(dragSources(in: host).allSatisfy { !$0.isDragEnabled })
        #expect(interrupted.source.preparePasteboardItem() == nil)
        expectRejected(interrupted.info, by: interrupted.target)
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(!placement.isCancelled)

        await release.open()
        await placement.value
        try #require(await settleDragUI(host) { !model.itemsLoading && !model.placementInProgress })
        #expect(fixture.server.moveAttempts == [1, 2, 5])
        #expect(fixture.server.base.moveRequests.map(\.windowID) == [1, 2, 5])
        #expect(fixture.server.base.moveRequests.map(\.targetWindowID) == [90, 92, 91])
        #expect(fixture.server.base.moveRequests.map(\.targetX) == [1040, 592, 976])
        #expect(fixture.server.maxConcurrentMoves == 1)
        #expect(fixture.server.base.items.filter { ![1, 2, 5].contains($0.windowID) }
                == snapshots.filter { ![1, 2, 5].contains($0.windowID) })
        #expect(fixture.work.captureRequests.count == (useFloatingBar ? 1 : 0))
        if useFloatingBar { #expect(Set(try #require(fixture.work.captureRequests.first)) == [2, 3, 5]) }
        #expect(fixture.work.movesAtCapture == (useFloatingBar ? [[1, 2, 5]] : []))
        #expect(fixture.work.preferenceWritesAtCapture == (useFloatingBar ? [1] : []))
        #expect(fixture.work.placementAttributions == [[1, 2, 3, 4, 5, 6]])
        #expect(fixture.work.providerCalls == 2)
        #expect(fixture.work.completions == 1)
        #expect(fixture.work.dividerWrites == [true, false, true])
        #expect(fixture.alwaysHidden.creates == 1)
        #expect(fixture.alwaysHidden.writes == [true, false, true])
        #expect(model.loadedItems.first { $0.id == 1 }?.observedPlacement == .shown)
        #expect(model.loadedItems.first { $0.id == 2 }?.observedPlacement == .alwaysHidden)
        #expect(model.loadedItems.first { $0.id == 5 }?.observedPlacement == .hidden)
        #expect(model.preferences == expected)
        #expect(model.preferences.itemAliases == saved.itemAliases)
        #expect(model.preferences.itemControls.suppressedFromBar == saved.itemControls.suppressedFromBar)
        #expect(model.preferences.itemControls.barOrder == saved.itemControls.barOrder)
        #expect(model.preferences.itemControls.hiddenInMenuBar.contains("Absent App"))
        #expect(!model.placementPending && !model.placementFailed)
        expectRejected(interrupted.info, by: interrupted.target)
        interrupted.source.finishDragging()

        let reloaded = try Fixture(store: PreferencesStore(backing: defaults))
        defer { reloaded.engine.uninstall() }
        #expect(reloaded.model.preferences == expected)
        #expect(!reloaded.model.hasPendingChanges)
        #expect(reloaded.work.preferenceWrites.isEmpty)
        #expect(fixture.work.preferenceWrites == [expected])
        #expect(!host.testWindow.isVisible && !host.testWindow.isKeyWindow)
    }

    @Test func mountedDropRejectsForeignMalformedStaleAndReplayedTokensWithoutLosingDrafts() async throws {
        let suite = "StagedPlacementDragRejection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(backing: defaults)
        let fixture = try Fixture(store: store)
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        let host = try await mountDragItems(model)
        let saved = model.preferences
        let snapshots = fixture.server.base.items
        let reads = fixture.server.readCount
        try await stageDrag(5, from: .shown, into: .hidden, model: model, host: host)
        let valid = try await beginDrag(2, from: .shown, into: .alwaysHidden, model: model, host: host)
        #expect(valid.target.draggingEntered(valid.info) == .move)
        #expect(valid.target.isTargeted)

        let other = try Fixture()
        defer { other.engine.uninstall() }
        let otherHost = try await mountDragItems(other.model)
        let foreign = try await beginDrag(2, from: .shown, into: .hidden, model: other.model, host: otherHost)
        #expect(valid.info.pasteboard.name != foreign.info.pasteboard.name)
        let foreignSources: [Any?] = [nil, NSObject(), foreign.source]
        for source in foreignSources {
            let info = SettingsPlacementTestDraggingInfo(
                source: source, items: [settingsPlacementTestPasteboardItem(valid.token.uuidString)], destination: valid.target
            )
            expectRejected(info, by: valid.target)
            #expect(info.pasteboardReads == 0, "External and wrong-model sources must be rejected before requesting data.")
            #expect(model.canDropPlacement(valid.token, into: .alwaysHidden))
        }
        let copyOnly = SettingsPlacementTestDraggingInfo(
            source: valid.source, items: [settingsPlacementTestPasteboardItem(valid.token.uuidString)],
            destination: valid.target, operation: .copy
        )
        expectRejected(copyOnly, by: valid.target)
        #expect(copyOnly.pasteboardReads == 0)

        let payloads: [[NSPasteboardItem]] = [
            [],
            [settingsPlacementTestPasteboardItem("Shown App", type: .string)],
            [settingsPlacementTestPasteboardItem("not-a-placement-token")],
            [settingsPlacementTestPasteboardItem(UUID().uuidString)],
            [settingsPlacementTestPasteboardItem(foreign.token.uuidString)],
            [settingsPlacementTestPasteboardItem(valid.token.uuidString), settingsPlacementTestPasteboardItem(valid.token.uuidString)]
        ]
        for payload in payloads {
            let info = SettingsPlacementTestDraggingInfo(source: valid.source, items: payload, destination: valid.target)
            expectRejected(info, by: valid.target)
            #expect(info.pasteboardReads > 0)
            #expect(model.canDropPlacement(valid.token, into: .alwaysHidden))
            #expect(model.pendingChangeCount == 1)
        }
        foreign.source.finishDragging()
        try performDrop(valid, model: model)
        try #require(await settleDragUI(host) { dragSources(in: host).contains { $0.item?.id == 2 && $0.placement == .alwaysHidden } })
        #expect(model.pendingChangeCount == 2)
        let replay = SettingsPlacementTestDraggingInfo(
            source: try dragSource(2, from: .alwaysHidden, in: host),
            items: [settingsPlacementTestPasteboardItem(valid.token.uuidString)],
            destination: try dragTarget(.hidden, in: host)
        )
        expectRejected(replay, by: try dragTarget(.hidden, in: host))
        #expect(!model.isDraggingPlacementItem)
        #expect(model.pendingChangeCount == 2)

        let superseded = try await beginDrag(1, from: .hidden, into: .shown, model: model, host: host)
        let successor = try await beginDrag(5, from: .hidden, into: .shown, model: model, host: host)
        superseded.source.finishDragging()
        expectRejected(superseded.info, by: superseded.target)
        #expect(model.isDraggingPlacementItem)
        #expect(model.canDropPlacement(successor.token, into: .shown))
        try performDrop(successor, model: model)
        #expect(model.pendingChangeCount == 1)
        #expect(!model.hasPendingChange(for: try #require(model.loadedItems.first { $0.id == 1 })))
        #expect(!model.hasPendingChange(for: try #require(model.loadedItems.first { $0.id == 5 })))

        let rowInterrupted = try await beginDrag(2, from: .alwaysHidden, into: .shown, model: model, host: host)
        #expect(rowInterrupted.target.draggingEntered(rowInterrupted.info) == .move)
        #expect(rowInterrupted.target.prepareForDragOperation(rowInterrupted.info))
        let editedItem = try #require(model.loadedItems.first { $0.id == 3 })
        let picker = try dragControl("settings-item-placement-3", in: host)
        let shownChoice = try #require(settingsTestAccessibility(picker).first {
            $0.accessibilityRole() == .radioButton && $0.accessibilityLabel() == "Shown"
        })
        #expect(shownChoice.isAccessibilityEnabled())
        // AppKit segments can report false after dispatch; the staged value below verifies the edit.
        _ = shownChoice.accessibilityPerformPress()
        try #require(await settleDragUI(host) {
            model.pendingChangeCount == 2 && !model.isDraggingPlacementItem
                && model.placement(of: editedItem) == .shown
        })
        expectRejected(rowInterrupted.info, by: rowInterrupted.target)
        rowInterrupted.source.finishDragging()

        let cancelled = try await beginDrag(1, from: .hidden, into: .alwaysHidden, model: model, host: host)
        #expect(cancelled.target.draggingEntered(cancelled.info) == .move)
        cancelled.source.finishDragging()
        cancelled.target.draggingEnded(cancelled.info)
        #expect(!cancelled.target.isTargeted)
        expectRejected(cancelled.info, by: cancelled.target)
        #expect(model.pendingChangeCount == 2)
        let discarded = try await beginDrag(1, from: .hidden, into: .alwaysHidden, model: model, host: host)
        #expect(discarded.target.draggingEntered(discarded.info) == .move)
        try pressDragControl("settings-placement-discard", in: host)
        try #require(await settleDragUI(host) { !model.hasPendingChanges && !model.isDraggingPlacementItem })
        expectRejected(discarded.info, by: discarded.target)
        discarded.source.finishDragging()

        #expect(model.preferences == saved)
        #expect(store.load() == saved)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.work.providerCalls == 1)
        #expect(fixture.server.readCount == reads)
        #expect(fixture.server.base.items == snapshots)
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.server.base.clickedWindowIDs.isEmpty)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(fixture.work.placementAttributions.isEmpty)
        #expect(fixture.work.dividerWrites == [true])
        #expect(other.work.preferenceWrites.isEmpty)
        #expect(other.server.moveAttempts.isEmpty)
        #expect(other.work.captureRequests.isEmpty)
        #expect(!host.testWindow.isVisible && !otherHost.testWindow.isVisible)
    }

    @Test func unknownItemsRefreshNavigationAndPreferenceChangesRespectDragLifetime() async throws {
        let suite = "StagedPlacementDragLifetime.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(backing: defaults)
        let loginItem = SettingsTestLoginItem()
        let keyless = MenuBarItemSnapshot(windowID: 70, ownerPID: 1, frame: CGRect(x: 1400, y: 0, width: 24, height: 22))
        let fixture = try Fixture(additionalItems: [keyless], store: store, loginItem: loginItem)
        defer { fixture.engine.uninstall() }
        let model = fixture.model
        let saved = model.preferences
        let snapshots = fixture.server.base.items
        // Missing native controls produce genuine unknown observations through the real item provider.
        fixture.server.base = FakeWindowServer(items: snapshots.filter { ![90, 91].contains($0.windowID) })
        let host = try await mountDragItems(model)
        #expect(model.loadedItems.allSatisfy { $0.observedPlacement == nil })
        #expect(Set(model.placementPreview.unknown.map(\.id)) == [1, 2, 3, 4, 5])
        #expect(!dragSources(in: host).contains { $0.item?.id == keyless.windowID })
        try await stageDrag(5, from: nil, into: .hidden, model: model, host: host)
        try await stageDrag(5, from: .hidden, into: .shown, model: model, host: host)
        #expect(model.pendingChangeCount == 1, "Unknown placement cannot be reversed to an invented observed Shown baseline.")
        #expect(!model.preferences.itemControls.hasPlacementIntent(forKey: "Unconfigured App"))

        let retainedSource = try dragSource(5, from: .shown, in: host)
        let cachedItem = try #require(retainedSource.item)
        // A stale native binding must also fail closed if it loses its owner before a render replaces it.
        let unattributed = MenuBarItemSnapshot(
            windowID: cachedItem.id, ownerPID: cachedItem.snapshot.ownerPID, frame: cachedItem.snapshot.frame
        )
        retainedSource.item = FloatingBarItem(snapshot: unattributed, image: cachedItem.image, observedPlacement: .shown)
        #expect(!retainedSource.isDragEnabled)
        #expect(retainedSource.preparePasteboardItem() == nil)
        retainedSource.item = cachedItem
        #expect(!model.isDraggingPlacementItem)

        let leaving = try await beginDrag(2, from: .shown, into: .alwaysHidden, model: model, host: host)
        #expect(leaving.target.draggingEntered(leaving.info) == .move)
        let readsBeforeNavigation = fixture.work.providerCalls
        try pressDragControl("settings-sidebar-behavior", in: host)
        try #require(await settleDragUI(host) {
            (try? dragControl("settings-detail-title", in: host).accessibilityLabel()) == "Behavior"
                && !model.isDraggingPlacementItem
        })
        #expect(model.pendingChangeCount == 1)
        #expect(fixture.work.providerCalls == readsBeforeNavigation)
        expectRejected(leaving.info, by: leaving.target)
        leaving.source.finishDragging()
        try pressDragControl("settings-sidebar-items", in: host)
        try #require(await settleDragUI(host) {
            !model.itemsLoading && fixture.work.providerCalls == readsBeforeNavigation + 1
                && dragSources(in: host).contains { $0.item?.id == 5 && $0.placement == .shown }
        })
        #expect(model.pendingChangeCount == 1)
        #expect(model.preferences == saved)
        #expect(store.load() == saved)

        let refreshing = try await beginDrag(1, from: .hidden, into: .alwaysHidden, model: model, host: host)
        #expect(refreshing.target.draggingEntered(refreshing.info) == .move)
        #expect(refreshing.target.prepareForDragOperation(refreshing.info))
        let cachedRows = model.loadedItems.map(\.snapshot)
        let readStarted = AsyncGate()
        let readRelease = AsyncGate()
        defer { Task { await readRelease.open() } }
        fixture.work.itemReadGate = (readStarted, readRelease)
        let reload = Task { await model.reloadItems() }
        try #require(await settleDragUI(host) { model.itemsLoading && fixture.work.itemReadGate == nil })
        #expect(model.loadedItems.map(\.snapshot) == cachedRows)
        #expect(dragSources(in: host).allSatisfy { !$0.isDragEnabled })
        #expect(refreshing.source.preparePasteboardItem() == nil)
        #expect(!model.isDraggingPlacementItem)
        expectRejected(refreshing.info, by: refreshing.target)
        reload.cancel()
        await readRelease.open()
        await reload.value
        #expect(!model.itemsLoading)
        #expect(model.itemsLoadError == nil)
        #expect(model.loadedItems.map(\.snapshot) == cachedRows)
        #expect(model.pendingChangeCount == 1)
        expectRejected(refreshing.info, by: refreshing.target)
        refreshing.source.finishDragging()

        fixture.server.base = FakeWindowServer(items: snapshots)
        await model.reloadItems()
        try #require(await settleDragUI(host) { dragSources(in: host).contains { $0.item?.id == 5 && $0.placement == .shown } })
        #expect(model.loadedItems.first { $0.id == 5 }?.observedPlacement == .shown)
        #expect(model.pendingChangeCount == 1)
        #expect(fixture.work.preferenceWrites.isEmpty)
        #expect(store.load() == saved)

        fixture.engine.menuTogglePause()
        let grouping = try await beginDrag(2, from: .shown, into: .alwaysHidden, model: model, host: host)
        #expect(grouping.target.draggingEntered(grouping.info) == .move)
        let group = ItemGroup(name: "Grouped tools", ownerKeys: ["Shown App"])
        var grouped = saved
        grouped.itemGroups = [group]
        model.preferences = grouped
        try #require(await settleDragUI(host) {
            dragSources(in: host).contains { $0.item?.id == 2 && $0.placement == .hidden && !$0.isDragEnabled }
        })
        #expect(model.group(containing: try #require(model.loadedItems.first { $0.id == 2 })) == group)
        #expect(try dragSource(2, from: .hidden, in: host).preparePasteboardItem() == nil)
        #expect(!model.isDraggingPlacementItem)
        #expect(model.pendingChangeCount == 1)
        expectRejected(grouping.info, by: grouping.target)
        grouping.source.finishDragging()
        #expect(store.load() == grouped)
        #expect(grouped.itemControls == saved.itemControls)

        let replaced = try await beginDrag(1, from: .hidden, into: .alwaysHidden, model: model, host: host)
        #expect(replaced.target.draggingEntered(replaced.info) == .move)
        var replacement = grouped
        replacement.itemControls.setPlacement(.shown, forKey: "Hidden App")
        model.preferences = replacement
        #expect(!model.isDraggingPlacementItem)
        #expect(!model.hasPendingChanges)
        #expect(model.draftDiscardedNotice != nil)
        expectRejected(replaced.info, by: replaced.target)
        replaced.source.finishDragging()
        #expect(store.load() == replacement)

        try await stageDrag(5, from: .shown, into: .hidden, model: model, host: host)
        let importing = try await beginDrag(3, from: .hidden, into: .alwaysHidden, model: model, host: host)
        #expect(importing.target.draggingEntered(importing.info) == .move)
        model.importLayout { nil }
        #expect(model.canDropPlacement(importing.token, into: .alwaysHidden))
        #expect(model.pendingChangeCount == 1)
        model.importLayout { try LayoutConfig.decode(from: Data("not JSON".utf8)).preferences }
        #expect(model.transferFailed)
        #expect(model.canDropPlacement(importing.token, into: .alwaysHidden))
        #expect(model.pendingChangeCount == 1)
        #expect(fixture.work.preferenceWrites == [grouped, replacement])

        var imported = replacement
        imported.floatingBarStyle = .vertical
        let exported = try LayoutConfig(preferences: imported).encoded()
        model.importLayout { try LayoutConfig.decode(from: exported).preferences }
        #expect(!model.transferFailed)
        #expect(model.transferMessage == "Imported settings.")
        #expect(!model.isDraggingPlacementItem)
        #expect(!model.hasPendingChanges)
        expectRejected(importing.info, by: importing.target)
        importing.source.finishDragging()
        #expect(model.preferences == imported)
        #expect(PreferencesStore(backing: defaults).load() == imported)
        #expect(fixture.work.preferenceWrites == [grouped, replacement, imported])
        #expect(model.preferences.itemAliases == saved.itemAliases)
        #expect(model.preferences.itemControls.suppressedFromBar == saved.itemControls.suppressedFromBar)
        #expect(model.preferences.itemControls.barOrder == saved.itemControls.barOrder)
        #expect(!model.preferences.itemControls.hasPlacementIntent(forKey: "Unconfigured App"))
        #expect(model.preferences.itemControls.hiddenInMenuBar.contains("Absent App"))
        #expect(loginItem.setEnabledCalls == [imported.launchAtLogin])
        #expect(loginItem.openSystemSettingsCalls == 0)
        #expect(fixture.engine.paused)
        #expect(fixture.engine.placementTask == nil)
        #expect(fixture.server.moveAttempts.isEmpty)
        #expect(fixture.server.base.moveRequests.isEmpty)
        #expect(fixture.server.base.clickedWindowIDs.isEmpty)
        #expect(fixture.work.placementAttributions.isEmpty)
        #expect(fixture.work.captureRequests.isEmpty)
        #expect(fixture.work.retryCalls == 0)
        #expect(fixture.alwaysHidden.creates == 0)
        #expect(!host.testWindow.isVisible && !host.testWindow.isKeyWindow)
    }

    private typealias MountedDrag = (
        source: SettingsPlacementDragSourceView, target: SettingsPlacementDropView,
        token: UUID, info: SettingsPlacementTestDraggingInfo
    )

    private func mountDragItems(_ model: SettingsModel) async throws -> SettingsTestHostingController {
        let host = settingsTestHost(
            SettingsView(model: model, initialTab: .items), configureWindow: SettingsWindowController.configureWindow
        )
        host.render()
        try #require(await settleDragUI(host) {
            !model.itemsLoading && !model.loadedItems.isEmpty && dragSources(in: host).count == model.loadedItems.count
        })
        for placement in [ItemPlacement.shown, .hidden, .alwaysHidden] {
            let target = try dragTarget(placement, in: host)
            #expect(target.model === model)
            #expect(target.window === host.testWindow)
            #expect(target.registeredDraggedTypes.contains(SettingsPlacementDrag.pasteboardType))
        }
        return host
    }

    private func dragSources(in host: SettingsTestHostingController) -> [SettingsPlacementDragSourceView] {
        settingsTestSubviews(host.view).compactMap { $0 as? SettingsPlacementDragSourceView }
    }

    private func dragSource(
        _ id: CGWindowID, from placement: ItemPlacement?, in host: SettingsTestHostingController
    ) throws -> SettingsPlacementDragSourceView {
        let matches = dragSources(in: host).filter { $0.item?.id == id && $0.placement == placement }
        try #require(matches.count == 1, "Expected one mounted drag source for item \(id) in \(String(describing: placement)).")
        return try #require(matches.first)
    }

    private func dragTarget(_ placement: ItemPlacement, in host: SettingsTestHostingController) throws -> SettingsPlacementDropView {
        let matches = settingsTestSubviews(host.view).compactMap { $0 as? SettingsPlacementDropView }.filter { $0.placement == placement }
        try #require(matches.count == 1, "Expected one registered native destination for \(placement).")
        return try #require(matches.first)
    }

    private func beginDrag(
        _ id: CGWindowID, from placement: ItemPlacement?, into destination: ItemPlacement,
        model: SettingsModel, host: SettingsTestHostingController
    ) async throws -> MountedDrag {
        try #require(await settleDragUI(host) {
            dragSources(in: host).contains {
                $0.item?.id == id && $0.placement == placement && $0.isDragEnabled && !$0.bounds.isEmpty
            }
        })
        let source = try dragSource(id, from: placement, in: host)
        let target = try dragTarget(destination, in: host)
        #expect(source.model === model)
        #expect(source.window === host.testWindow)
        #expect(target.model === model)
        #expect(target.window === host.testWindow)
        #expect(target.registeredDraggedTypes.contains(SettingsPlacementDrag.pasteboardType))
        #expect(source.item?.image === model.loadedItems.first { $0.id == id }?.image)
        if let placement { #expect(source.isDescendant(of: try dragTarget(placement, in: host))) }

        if !source.visibleRect.contains(source.bounds) { _ = source.scrollToVisible(source.bounds) }
        try #require(await settleDragUI(host) {
            !source.isHiddenOrHasHiddenAncestor && !source.bounds.intersection(source.visibleRect).isEmpty
        })
        let visible = source.bounds.intersection(source.visibleRect)
        try #require(visible.width > 0 && visible.height > 0, "Item \(id) needs a visible pointer hit area.")
        let point = CGPoint(x: visible.midX, y: visible.midY)
        try #require(try dragHit(at: point, in: source, host: host) === source,
                     "The root hit test must reach the mounted source for item \(id).")
        let origin = source.convert(point, to: nil)
        #expect(host.testWindow.contentLayoutRect.contains(origin))
        let cached = try #require(source.item)
        let preferences = model.preferences
        let pendingCount = model.pendingChangeCount
        let placements = model.loadedItems.map { model.placement(of: $0) }
        let wasDragging = model.isDraggingPlacementItem
        var sessions: [(items: [NSDraggingItem], event: NSEvent)] = []
        let originalStart = source.startDragging
        source.startDragging = { view, items, event, draggingSource in
            #expect(view === source)
            #expect((draggingSource as? SettingsPlacementDragSourceView) === source)
            sessions.append((items, event))
        }
        defer { source.startDragging = originalStart }

        @MainActor
        func event(_ type: NSEvent.EventType, offset: CGFloat = 0, number: Int) throws -> NSEvent {
            try settingsPlacementTestMouseEvent(
                type, at: CGPoint(x: origin.x + offset, y: origin.y), window: host.testWindow, number: number
            )
        }
        @MainActor
        func expectNoStaging() {
            #expect(model.preferences == preferences)
            #expect(model.pendingChangeCount == pendingCount)
            #expect(model.loadedItems.map { model.placement(of: $0) } == placements)
        }

        let click = try event(.leftMouseDown, number: 1)
        #expect(source.acceptsFirstMouse(for: click))
        #expect(!source.mouseDownCanMoveWindow)
        source.mouseDown(with: click)
        source.mouseUp(with: try event(.leftMouseUp, number: 2))
        #expect(sessions.isEmpty)
        #expect(model.isDraggingPlacementItem == wasDragging)
        expectNoStaging()

        source.mouseDown(with: try event(.leftMouseDown, number: 3))
        source.mouseDragged(with: try event(.leftMouseDragged, offset: 2, number: 4))
        #expect(sessions.isEmpty)
        #expect(model.isDraggingPlacementItem == wasDragging)
        expectNoStaging()
        let movement = try event(.leftMouseDragged, offset: 6, number: 5)
        source.mouseDragged(with: movement)
        try #require(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.event === movement)
        try #require(session.items.count == 1)
        let dragged = try #require(session.items.first)
        let components = try #require(dragged.imageComponents)
        try #require(components.count == 1)
        #expect((components.first?.contents as? NSImage) === cached.image)
        let writer = try #require(dragged.item as? NSPasteboardItem)
        #expect(writer.types == [SettingsPlacementDrag.pasteboardType])
        let payload = try #require(writer.string(forType: SettingsPlacementDrag.pasteboardType))
        let token = try #require(UUID(uuidString: payload))
        let validDestination: ItemPlacement = placement == .hidden ? .shown : .hidden
        #expect(model.canDropPlacement(token, into: validDestination))
        expectNoStaging()
        source.mouseDragged(with: try event(.leftMouseDragged, offset: 12, number: 6))
        #expect(sessions.count == 1)
        #expect(model.canDropPlacement(token, into: validDestination))
        expectNoStaging()

        let dropLocation = try dragDropLocation(in: target, host: host)
        let info = SettingsPlacementTestDraggingInfo(
            source: source, items: [writer], destination: target, locationInWindow: dropLocation
        )
        #expect(info.pasteboardReads == 0)
        #expect((info.draggingSource as? SettingsPlacementDragSourceView) === source)
        #expect(model.isDraggingPlacementItem)
        return (source, target, token, info)
    }

    private func dragHit(at point: NSPoint, in view: NSView, host: SettingsTestHostingController) throws -> NSView {
        // NSView.hitTest receives a point in its superview's coordinate system.
        try #require(host.view.hitTest(view.convert(point, to: host.view.superview)), "The Settings root must receive the pointer hit.")
    }

    private func registeredDragAncestor(of hit: NSView) -> NSView? {
        var candidate: NSView? = hit
        while let view = candidate {
            if view.registeredDraggedTypes.contains(SettingsPlacementDrag.pasteboardType) { return view }
            candidate = view.superview
        }
        return nil
    }

    private func dragDropLocation(in target: SettingsPlacementDropView, host: SettingsTestHostingController) throws -> NSPoint {
        let visible = target.bounds.intersection(target.visibleRect)
        try #require(visible.width > 4 && visible.height > 4)
        let glyphs = settingsTestSubviews(target).compactMap { $0 as? SettingsPlacementDragSourceView }
        let emptyPoint = CGPoint(x: visible.maxX - 2, y: visible.midY)
        #expect(!glyphs.contains { target.convert($0.bounds, from: $0).contains(emptyPoint) },
                "The trailing padding must provide a drop point outside the cached glyphs.")
        let emptyHit = try dragHit(at: emptyPoint, in: target, host: host)
        #expect(registeredDragAncestor(of: emptyHit) === target)
        if !glyphs.isEmpty {
            let glyph = try #require(glyphs.first { !$0.bounds.intersection($0.visibleRect).isEmpty })
            let rect = glyph.bounds.intersection(glyph.visibleRect)
            let point = CGPoint(x: rect.midX, y: rect.midY)
            let glyphHit = try dragHit(at: point, in: glyph, host: host)
            #expect(registeredDragAncestor(of: glyphHit) === target)
            return glyph.convert(point, to: nil)
        }
        return target.convert(emptyPoint, to: nil)
    }

    private func performDrop(_ drag: MountedDrag, model: SettingsModel) throws {
        defer { drag.source.finishDragging() }
        let preferences = model.preferences
        let count = model.pendingChangeCount
        try #require(drag.target.draggingEntered(drag.info) == .move)
        #expect(drag.target.isTargeted)
        #expect(drag.target.draggingUpdated(drag.info) == .move)
        try #require(drag.target.prepareForDragOperation(drag.info))
        #expect(model.preferences == preferences)
        #expect(model.pendingChangeCount == count)
        try #require(drag.target.performDragOperation(drag.info))
        #expect(!drag.target.isTargeted)
        #expect(!model.isDraggingPlacementItem)
        #expect(!model.canDropPlacement(drag.token, into: drag.target.placement))
        #expect(model.preferences == preferences)
        drag.target.concludeDragOperation(drag.info)
    }

    private func stageDrag(
        _ id: CGWindowID, from placement: ItemPlacement?, into destination: ItemPlacement,
        model: SettingsModel, host: SettingsTestHostingController
    ) async throws {
        let drag = try await beginDrag(id, from: placement, into: destination, model: model, host: host)
        try performDrop(drag, model: model)
        try #require(await settleDragUI(host) {
            dragSources(in: host).contains { $0.item?.id == id && $0.placement == destination }
        })
    }

    private func expectRejected(_ info: SettingsPlacementTestDraggingInfo, by target: SettingsPlacementDropView) {
        #expect(target.draggingEntered(info).isEmpty)
        #expect(!target.isTargeted)
        #expect(target.draggingUpdated(info).isEmpty)
        #expect(!target.prepareForDragOperation(info))
        #expect(!target.performDragOperation(info))
        #expect(!target.isTargeted)
        target.concludeDragOperation(info)
    }

    private func dragControl(_ id: String, in host: SettingsTestHostingController) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(host.view).first { $0.accessibilityIdentifier() == id }, "Missing \(id).")
    }

    private func pressDragControl(_ id: String, in host: SettingsTestHostingController) throws {
        try #require(try dragControl(id, in: host).accessibilityPerformPress(), "\(id) did not accept a press.")
    }

    private func settleDragUI(_ host: SettingsTestHostingController, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            host.render()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while !Task.isCancelled && ContinuousClock.now < deadline
        return false
    }

    @MainActor
    private struct Fixture {
        let server: CountedPlacementServer
        let work: Work
        let bar: FloatingBarController
        let engine: CosmeticHideEngine
        let model: SettingsModel
        let alwaysHidden: AlwaysHiddenDividerRecorder

        init(
            useFloatingBar: Bool = true, moveGate: (started: AsyncGate, release: AsyncGate)? = nil,
            itemControls: ItemControlStore? = nil, additionalItems: [MenuBarItemSnapshot] = [],
            alwaysHiddenDivider: Bool = false, store: PreferencesStore? = nil,
            loginItem: (any LoginItemManaging)? = nil
        ) throws {
            let items: [(CGWindowID, String, CGFloat)] = [
                (1, "Hidden App", 800), (2, "Shown App", 1100), (3, "Keep Hidden", 700),
                (4, "Keep Shown", 1200), (5, "Unconfigured App", 1300)
            ]
            let tierControl = alwaysHiddenDivider
                ? [MenuBarItemSnapshot(windowID: 92, ownerPID: 1, title: "BKFAlwaysHidden", frame: CGRect(x: 600, y: 0, width: 8, height: 22))]
                : []
            let server = CountedPlacementServer(items: items.map { id, owner, x in
                MenuBarItemSnapshot(
                    windowID: id, ownerPID: 1, ownerBundleID: owner,
                    frame: CGRect(x: x, y: 0, width: 24, height: 22)
                )
            } + additionalItems + [
                MenuBarItemSnapshot(windowID: 90, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: 1000, y: 0, width: 32, height: 22)),
                MenuBarItemSnapshot(windowID: 91, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: 984, y: 0, width: 16, height: 22))
            ] + tierControl, moveGate: moveGate)
            let alwaysHidden = AlwaysHiddenDividerRecorder()
            let initialPreferences = Preferences(
                autoRehide: false, useFloatingBar: useFloatingBar,
                itemAliases: ItemAliasStore(aliases: ["Hidden App": "Renamed Icon"]),
                itemControls: itemControls ?? ItemControlStore(
                    hiddenInMenuBar: ["Hidden App", "Keep Hidden", "Absent App"],
                    shownInMenuBar: ["Shown App", "Keep Shown"],
                    suppressedFromBar: ["Keep Shown"], barOrder: ["Keep Hidden": 4]
                ),
                dismissBarOnMouseExit: false
            )
            if let store, !store.hasSavedPreferences { try #require(store.save(initialPreferences)) }
            let preferences = store?.load() ?? initialPreferences
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
                alwaysHiddenDivider: alwaysHidden.hooks,
                onPreferencesChanged: {
                    work.preferenceWrites.append($0)
                    if let store { #expect(store.save($0)) }
                }
            )
            engine.floatingBar = bar
            engine.hiddenItemController = HiddenItemController(windowServer: server) { items in
                work.placementAttributions.append(items.map(\.windowID))
                return items
            }
            let model = SettingsModel(
                preferences: preferences, loginItem: loginItem ?? LoginItemService(),
                itemsProvider: {
                    work.providerCalls += 1
                    if let gate = work.itemReadGate {
                        work.itemReadGate = nil
                        await gate.started.open()
                        await gate.release.wait()
                    }
                    return try await bar.allManageableItems()
                },
                onRetryPlacement: { [weak engine] in
                    work.retryCalls += 1
                    engine?.reconcileHiddenItems(userInitiated: true)
                },
                onChange: { [weak engine] preferences in
                    work.preferenceWrites.append(preferences)
                    if let store { #expect(store.save(preferences)) }
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
            self.alwaysHidden = alwaysHidden
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
        var itemReadGate: (started: AsyncGate, release: AsyncGate)?
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
