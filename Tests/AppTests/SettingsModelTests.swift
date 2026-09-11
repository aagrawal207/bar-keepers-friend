import AppKit
import BarKeepersFriendCore
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SettingsModelTests {
    @Test(arguments: [false, true])
    func cancelledOldLoadCannotReplaceNewItemsOrClearTheirLoadingState(newFinishesFirst: Bool) async {
        let oldStarted = AsyncGate()
        let finishOld = AsyncGate()
        let newStarted = AsyncGate()
        let finishNew = AsyncGate()
        let newerItem = FloatingBarItem(
            snapshot: MenuBarItemSnapshot(windowID: 2, ownerPID: 1, ownerBundleID: "test.new", frame: .zero),
            image: NSImage(size: CGSize(width: 18, height: 18))
        )
        var calls = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: {
                calls += 1
                if calls == 1 {
                    await oldStarted.open()
                    await finishOld.wait()
                    return []
                }
                await newStarted.open()
                await finishNew.wait()
                return [newerItem]
            }, onChange: { _ in }
        )
        let old = Task { await model.reloadItems() }
        await oldStarted.wait()
        old.cancel()
        let new = Task { await model.reloadItems() }
        await newStarted.wait()

        if newFinishesFirst {
            await finishNew.open()
            await new.value
        }
        await finishOld.open()
        await old.value
        #expect(model.itemsLoading == !newFinishesFirst)

        if !newFinishesFirst {
            await finishNew.open()
            await new.value
        }
        #expect(model.loadedItems.map(\.snapshot.windowID) == [2])
        #expect(!model.itemsLoading)
        #expect(calls == 2)
    }

    @Test func cancelledLoadDoesNotCallTheProvider() async {
        var calls = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { calls += 1; return [] }, onChange: { _ in }
        )
        let task = Task { await model.reloadItems() }
        task.cancel()
        await task.value
        #expect(calls == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func olderUncancelledLoadCannotPublishOverNewerLoad(newFinishesFirst: Bool, oldFails: Bool) async {
        let cachedItem = makeItem("test.cached", id: 1)
        let oldItem = makeItem("test.old", id: 2)
        let newItem = makeItem("test.new", id: 3)
        let oldStarted = AsyncGate()
        let finishOld = AsyncGate()
        let newStarted = AsyncGate()
        let finishNew = AsyncGate()
        var calls = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: {
                calls += 1
                if calls == 1 { return [cachedItem] }
                if calls == 2 {
                    await oldStarted.open()
                    await finishOld.wait()
                    if oldFails { throw WindowServerError.invalidServerResponse("enumeration failed") }
                    return [oldItem]
                }
                await newStarted.open()
                await finishNew.wait()
                return [newItem]
            }, onChange: { _ in }
        )
        await model.reloadItems()
        let old = Task { await model.reloadItems() }
        await oldStarted.wait()
        let new = Task { await model.reloadItems() }
        await newStarted.wait()

        if newFinishesFirst {
            await finishNew.open()
            await new.value
        }
        await finishOld.open()
        await old.value
        #expect(!old.isCancelled)
        #expect(model.itemsLoading == !newFinishesFirst)
        #expect(model.loadedItems.map(\.id) == [newFinishesFirst ? newItem.id : cachedItem.id])
        #expect(model.itemsLoadError == nil)

        if !newFinishesFirst {
            await finishNew.open()
            await new.value
        }
        #expect(model.loadedItems.map(\.id) == [newItem.id])
        #expect(!model.itemsLoading)
        #expect(model.itemsLoadError == nil)
        #expect(calls == 3)
    }

    @Test(arguments: [false, true])
    func cancellingCurrentLoadPreservesCachedRowsAndClearsLoading(providerFails: Bool) async {
        let cachedItem = makeItem("test.cached", id: 1)
        let replacement = makeItem("test.replacement", id: 2)
        let started = AsyncGate()
        let finish = AsyncGate()
        var calls = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: {
                calls += 1
                if calls == 1 { return [cachedItem] }
                await started.open()
                await finish.wait()
                if providerFails { throw WindowServerError.invalidServerResponse("enumeration failed") }
                return [replacement]
            }, onChange: { _ in }
        )
        await model.reloadItems()
        let task = Task { await model.reloadItems() }
        await started.wait()
        #expect(model.itemsLoading)
        task.cancel()
        await finish.open()
        await task.value

        #expect(model.loadedItems.map(\.id) == [cachedItem.id])
        #expect(!model.itemsLoading)
        #expect(model.itemsLoadError == nil)
        #expect(calls == 2)
    }

    @Test(arguments: [false, true])
    func loadFailurePreservesRowsAndRetryClearsError(returnEmpty: Bool) async {
        let cachedItem = makeItem("test.cached", id: 1)
        let refreshedItems = returnEmpty ? [] : [makeItem("test.refreshed", id: 2)]
        let retryStarted = AsyncGate()
        let finishRetry = AsyncGate()
        var calls = 0
        let controller = SettingsWindowController(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: {
                calls += 1
                if calls == 1 { return [cachedItem] }
                if calls == 2 { throw WindowServerError.invalidServerResponse("enumeration failed") }
                await retryStarted.open()
                await finishRetry.wait()
                return refreshedItems
            }, onChange: { _ in }
        )
        let model = controller.model
        model.placementMessage = "Could not move an item."
        model.placementFailed = true
        await model.reloadItems()
        #expect(model.loadedItems.map(\.id) == [cachedItem.id])
        #expect(model.itemsLoadError == nil)

        await model.reloadItems()
        #expect(model.loadedItems.map(\.id) == [cachedItem.id])
        #expect(model.itemsLoadError == "Could not read menu bar items. Try again.")
        #expect(!model.itemsLoading)
        #expect(model.placementMessage == "Could not move an item.")
        #expect(model.placementFailed)

        let retry = Task { await model.reloadItems() }
        await retryStarted.wait()
        #expect(model.itemsLoadError == nil)
        #expect(model.itemsLoading)
        #expect(model.loadedItems.map(\.id) == [cachedItem.id])
        await finishRetry.open()
        await retry.value
        #expect(model.loadedItems.map(\.id) == refreshedItems.map(\.id))
        #expect(model.itemsLoadError == nil)
        #expect(!model.itemsLoading)
        #expect(model.placementMessage == "Could not move an item.")
        #expect(model.placementFailed)
        #expect(calls == 3)
    }

    @Test func providerCancellationPreservesCachedRowsWithoutALoadError() async {
        let cachedItem = makeItem()
        var calls = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: {
                calls += 1
                if calls == 1 { return [cachedItem] }
                throw CancellationError()
            }, onChange: { _ in }
        )
        await model.reloadItems()
        await model.reloadItems()

        #expect(!Task.isCancelled)
        #expect(model.loadedItems.map(\.id) == [cachedItem.id])
        #expect(model.itemsLoadError == nil)
        #expect(!model.itemsLoading)
        #expect(calls == 2)
    }

    @Test(arguments: [false, true])
    func observationAndRefreshDoNotRecordPlacementIntent(initiallyHidden: Bool) async {
        var item = makeItem()
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { [item] },
            onRetryPlacement: { retries += 1 },
            onChange: { _ in writes += 1 }
        )
        #expect(!model.placementInProgress)
        #expect(model.placementMessage == nil)
        #expect(!model.placementFailed)

        for hidden in [initiallyHidden, !initiallyHidden] {
            item.observedHidden = hidden
            await model.reloadItems()
            #expect(model.loadedItems.map { model.isHidden($0) } == [hidden])
            let parts = model.partition(model.loadedItems)
            #expect(parts.hidden.map(\.id) == (hidden ? [item.id] : []))
            #expect(parts.shown.map(\.id) == (hidden ? [] : [item.id]))
            #expect(!model.preferences.itemControls.hasPlacementIntent(item.snapshot))
        }

        #expect(model.preferences == .default)
        #expect(writes == 0)
        #expect(retries == 0)
    }

    @Test(arguments: [false, true])
    func anUnconfiguredItemCanRequestTheOppositePlacementOnce(hidden: Bool) {
        let item = makeItem(observedHidden: !hidden)
        var writes: [Preferences] = []
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { [item] },
            onRetryPlacement: { retries += 1 },
            onChange: { writes.append($0) }
        )
        #expect(model.isHidden(item) == !hidden)
        #expect(!model.preferences.itemControls.hasPlacementIntent(item.snapshot))

        model.setHidden(hidden, for: item)

        #expect(model.preferences.itemControls.hasPlacementIntent(item.snapshot))
        #expect(model.preferences.itemControls.isHidden(item.snapshot) == hidden)
        #expect(model.preferences.itemControls.shownInMenuBar.contains("ACME") == !hidden)
        #expect(writes == [model.preferences])
        #expect(retries == 0)
    }

    @Test(arguments: [false, true])
    func failedPlacementKeepsObservedStateAndCanRetrySavedIntent(hidden: Bool) async {
        var item = makeItem(observedHidden: !hidden)
        var requested = Preferences.default
        requested.itemControls.setHidden(hidden, for: item.snapshot)
        var writes = 0
        var retries = 0
        let controller = SettingsWindowController(
            preferences: requested, loginItem: LoginItemService(),
            itemsProvider: { [item] },
            onRetryPlacement: { retries += 1 },
            onChange: { _ in writes += 1 }
        )
        let model = controller.model
        await model.reloadItems()
        model.placementInProgress = true
        #expect(model.isHidden(item) == hidden)

        model.placementMessage = "Couldn't move the item. Select Shown or Hidden to try again."
        model.placementFailed = true
        model.placementInProgress = false
        #expect(model.loadedItems.map { model.isHidden($0) } == [!hidden])
        let parts = model.partition(model.loadedItems)
        #expect(parts.hidden.map(\.id) == (hidden ? [] : [item.id]))
        #expect(parts.shown.map(\.id) == (hidden ? [item.id] : []))
        #expect(model.preferences == requested)
        #expect(writes == 0)

        model.setHidden(hidden, for: item)
        #expect(retries == 1)
        #expect(writes == 0)
        #expect(model.preferences == requested)

        model.placementInProgress = true
        item.observedHidden = hidden
        await model.reloadItems()
        model.placementMessage = nil
        model.placementFailed = false
        model.placementInProgress = false
        #expect(model.loadedItems.map { model.isHidden($0) } == [hidden])
        #expect(model.preferences == requested)
        #expect(writes == 0)
        #expect(retries == 1)
    }

    @Test func pendingPlacementUsesIntentOnlyForConfiguredItems() {
        let items = [
            makeItem("test.hidden", id: 1, observedHidden: false),
            makeItem("test.unconfigured.hidden", id: 2, observedHidden: true),
            makeItem("test.shown", id: 3, observedHidden: true),
            makeItem("test.unconfigured.shown", id: 4, observedHidden: false)
        ]
        let preferences = Preferences(itemControls: ItemControlStore(
            hiddenInMenuBar: ["test.hidden"], shownInMenuBar: ["test.shown"]
        ))
        var writes = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { items }, onChange: { _ in writes += 1 }
        )
        #expect(model.partition(items).hidden.map(\.id) == [2, 3])
        #expect(model.partition(items).shown.map(\.id) == [1, 4])

        model.placementInProgress = true
        #expect(items.map { model.isHidden($0) } == [true, true, false, false])
        #expect(model.partition(items).hidden.map(\.id) == [1, 2])
        #expect(model.partition(items).shown.map(\.id) == [3, 4])

        model.placementInProgress = false
        #expect(model.partition(items).hidden.map(\.id) == [2, 3])
        #expect(model.partition(items).shown.map(\.id) == [1, 4])
        #expect(model.preferences == preferences)
        #expect(writes == 0)
    }

    @Test(arguments: [false, true])
    func unknownPlacementFallsBackToSavedIntentWithoutCreatingIntent(inProgress: Bool) {
        let items = [
            makeItem("test.hidden", id: 1),
            makeItem("test.shown", id: 2),
            makeItem("test.unconfigured", id: 3)
        ]
        #expect(items.allSatisfy { $0.observedHidden == nil })
        let preferences = Preferences(itemControls: ItemControlStore(
            hiddenInMenuBar: ["test.hidden"], shownInMenuBar: ["test.shown"]
        ))
        var writes = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { items }, onChange: { _ in writes += 1 }
        )
        model.placementInProgress = inProgress

        #expect(items.map { model.isHidden($0) } == [true, false, false])
        #expect(model.partition(items).hidden.map(\.id) == [1])
        #expect(model.partition(items).shown.map(\.id) == [2, 3])
        #expect(model.preferences == preferences)
        #expect(writes == 0)
    }

    @Test(arguments: [false, true])
    func bulkPlacementWritesOnceAndRetriesWithoutAnotherWrite(hidden: Bool) {
        let items = [
            makeItem("ACME", id: 1, observedHidden: !hidden),
            makeItem("Maccy", id: 2, observedHidden: !hidden),
            makeItem("test.unconfigured", id: 3, observedHidden: !hidden)
        ]
        var preferences = Preferences.default
        preferences.itemControls.setHidden(hidden, for: items[0].snapshot)
        preferences.itemControls.setHidden(!hidden, for: items[1].snapshot)
        var writes: [Preferences] = []
        var retries = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { items },
            onRetryPlacement: { retries += 1 },
            onChange: { writes.append($0) }
        )

        model.setHidden(hidden, forAll: items)
        let requested = model.preferences
        #expect(items.allSatisfy { requested.itemControls.hasPlacementIntent($0.snapshot) })
        #expect(items.allSatisfy { requested.itemControls.isHidden($0.snapshot) == hidden })
        #expect(writes == [requested])
        #expect(retries == 0)
        let parts = model.partition(items)
        #expect(parts.hidden.map(\.id) == (hidden ? [] : items.map(\.id)))
        #expect(parts.shown.map(\.id) == (hidden ? items.map(\.id) : []))

        model.setHidden(hidden, forAll: items)
        #expect(writes == [requested])
        #expect(retries == 1)
        #expect(model.preferences == requested)
    }

    private func makeItem(
        _ owner: String = "ACME",
        id: CGWindowID = 1,
        observedHidden: Bool? = nil
    ) -> FloatingBarItem {
        FloatingBarItem(
            snapshot: MenuBarItemSnapshot(windowID: id, ownerPID: 1, ownerBundleID: owner, frame: .zero),
            image: NSImage(size: CGSize(width: 18, height: 18)),
            observedHidden: observedHidden
        )
    }
}
