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
        #expect(!model.placementPending)
        #expect(!model.hasPendingChanges)
        #expect(model.pendingChangeCount == 0)

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

        #expect(model.hasPendingChanges)
        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: item))
        #expect(model.isHidden(item) == hidden)
        #expect(model.preferences == .default)
        #expect(writes.isEmpty)
        #expect(retries == 0)
        model.applyPlacementChanges()

        #expect(model.preferences.itemControls.hasPlacementIntent(item.snapshot))
        #expect(model.preferences.itemControls.isHidden(item.snapshot) == hidden)
        #expect(model.preferences.itemControls.shownInMenuBar.contains("ACME") == !hidden)
        #expect(writes == [model.preferences])
        #expect(retries == 0)
        #expect(!model.hasPendingChanges)
        #expect(!model.hasPendingChange(for: item))
        model.applyPlacementChanges()
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
        #expect(model.hasPendingChange(for: item))
        #expect(model.isHidden(item) == hidden)
        #expect(retries == 0)
        #expect(writes == 0)
        model.applyPlacementChanges()
        #expect(retries == 1)
        #expect(writes == 0)
        #expect(model.preferences == requested)
        #expect(!model.hasPendingChanges)
        #expect(model.placementFailed)
        #expect(model.placementMessage == "Couldn't move the item. Select Shown or Hidden to try again.")

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
        #expect(model.pendingChangeCount == 3)
        #expect(items.allSatisfy { model.hasPendingChange(for: $0) })
        #expect(items.allSatisfy { model.isHidden($0) == hidden })
        #expect(model.preferences == preferences)
        #expect(writes.isEmpty)
        #expect(retries == 0)
        model.applyPlacementChanges()
        let requested = model.preferences
        #expect(items.allSatisfy { requested.itemControls.hasPlacementIntent($0.snapshot) })
        #expect(items.allSatisfy { requested.itemControls.isHidden($0.snapshot) == hidden })
        #expect(writes == [requested])
        #expect(retries == 0)
        let parts = model.partition(items)
        #expect(parts.hidden.map(\.id) == (hidden ? [] : items.map(\.id)))
        #expect(parts.shown.map(\.id) == (hidden ? items.map(\.id) : []))

        model.setHidden(hidden, forAll: items)
        #expect(model.pendingChangeCount == 3)
        #expect(writes == [requested])
        #expect(retries == 0)
        model.applyPlacementChanges()
        #expect(writes == [requested])
        #expect(retries == 1)
        #expect(model.preferences == requested)
        #expect(!model.hasPendingChanges)
        model.applyPlacementChanges()
        #expect(writes == [requested])
        #expect(retries == 1)
    }

    @Test(arguments: [false, true])
    func keylessEditsAndEmptyApplyHaveNoSideEffects(hidden: Bool) {
        let items = [makeItem(nil, id: 1, observedHidden: !hidden),
                     makeItem("", id: 2, observedHidden: !hidden)]
        var writes = 0
        var retries = 0
        var reads = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return items },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )

        #expect(!model.canSetHidden(hidden, forAll: items))
        #expect(!model.canSetHidden(!hidden, forAll: items))
        #expect(!model.canSetHidden(hidden, forAll: []))
        model.setHidden(hidden, for: items[0])
        model.setHidden(hidden, forAll: items)
        model.setHidden(hidden, forAll: [])
        model.applyPlacementChanges()
        model.discardPlacementChanges()
        model.retryPlacement()

        #expect(!model.hasPendingChanges)
        #expect(model.pendingChangeCount == 0)
        #expect(items.allSatisfy { !model.hasPendingChange(for: $0) })
        #expect(model.preferences == .default)
        #expect(writes == 0)
        #expect(retries == 0)
        #expect(reads == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func mixedOwnerSiblingsShareOneDraftChoiceForSingleAndBulkEdits(hidden: Bool, bulk: Bool) async {
        var items = [
            makeItem("ACME", id: 1, observedHidden: !hidden),
            makeItem("ACME", id: 2, observedHidden: hidden),
            makeItem("Maccy", id: 3, observedHidden: !hidden)
        ]
        for index in items.indices { items[index].alias = "Same" }
        let preferences = Preferences(itemAliases: ItemAliasStore(aliases: ["ACME": "Same", "Maccy": "Same"]))
        var writes: [Preferences] = []
        var retries = 0
        var reads = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return items },
            onRetryPlacement: { retries += 1 }, onChange: { writes.append($0) }
        )
        await model.reloadItems()

        #expect(model.canSetHidden(hidden, forAll: [items[1]]))
        #expect(model.canSetHidden(!hidden, forAll: Array(items.prefix(2))))
        #expect(model.pendingChangeCount == 0)
        if bulk { model.setHidden(hidden, forAll: Array(items.prefix(2))) }
        else { model.setHidden(hidden, for: items[0]) }
        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: items[0]))
        #expect(model.hasPendingChange(for: items[1]))
        #expect(!model.hasPendingChange(for: items[2]))
        #expect(model.isHidden(items[0]) == hidden)
        #expect(model.isHidden(items[1]) == hidden)
        #expect(model.isHidden(items[2]) == !hidden)
        #expect(model.preferences == preferences)
        #expect(writes.isEmpty)

        #expect(!model.canSetHidden(hidden, forAll: [items[1]]))
        #expect(model.canSetHidden(!hidden, forAll: [items[1]]))
        #expect(model.pendingChangeCount == 1)
        model.setHidden(!hidden, for: items[1])
        #expect(model.pendingChangeCount == 1)
        #expect(model.isHidden(items[0]) == !hidden)
        #expect(model.isHidden(items[1]) == !hidden)
        #expect(!model.canSetHidden(!hidden, forAll: Array(items.prefix(2))))
        model.applyPlacementChanges()

        var expected = preferences
        expected.itemControls.setHidden(!hidden, forKey: "ACME")
        #expect(model.preferences == expected)
        #expect(writes == [expected])
        #expect(!model.preferences.itemControls.hasPlacementIntent(items[2].snapshot))
        #expect(!model.hasPendingChanges)
        #expect(retries == 0)
        #expect(reads == 1)
    }

    @Test(arguments: [false, true])
    func reversingAnUnconfiguredEditPreservesAbsentIntent(hidden: Bool) {
        let item = makeItem(observedHidden: hidden)
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { [item] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )

        #expect(!model.canSetHidden(hidden, forAll: [item]))
        #expect(model.canSetHidden(!hidden, forAll: [item]))
        #expect(!model.hasPendingChanges)
        model.setHidden(hidden, for: item)
        #expect(!model.hasPendingChanges)
        model.setHidden(!hidden, for: item)
        #expect(model.hasPendingChanges)
        #expect(!model.canSetHidden(!hidden, forAll: [item]))
        #expect(model.canSetHidden(hidden, forAll: [item]))
        #expect(model.pendingChangeCount == 1)
        model.setHidden(hidden, for: item)
        model.applyPlacementChanges()

        #expect(!model.hasPendingChanges)
        #expect(model.pendingChangeCount == 0)
        #expect(!model.hasPendingChange(for: item))
        #expect(model.isHidden(item) == hidden)
        #expect(!model.canSetHidden(hidden, forAll: [item]))
        #expect(model.preferences == .default)
        #expect(!model.preferences.itemControls.hasPlacementIntent(item.snapshot))
        #expect(writes == 0)
        #expect(retries == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func observedChoiceCanCancelDeferredOrFailedSavedIntent(hidden: Bool, failed: Bool) async {
        let item = makeItem(observedHidden: !hidden)
        var preferences = Preferences.default
        preferences.itemControls.setHidden(hidden, for: item.snapshot)
        var writes: [Preferences] = []
        var retries = 0
        var reads = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item] },
            onRetryPlacement: { retries += 1 }, onChange: { writes.append($0) }
        )
        await model.reloadItems()
        let message = failed ? "Could not move the item." : "Paused. Placement will resume when unpaused."
        model.placementMessage = message
        model.placementPending = true
        model.placementFailed = failed

        #expect(model.isHidden(item) == !hidden)
        #expect(model.canSetHidden(!hidden, forAll: [item]))
        #expect(!model.hasPendingChanges)
        model.setHidden(!hidden, for: item)
        #expect(model.hasPendingChange(for: item))
        #expect(model.pendingChangeCount == 1)
        #expect(!model.canSetHidden(!hidden, forAll: [item]))
        #expect(model.preferences == preferences)
        #expect(writes.isEmpty)
        #expect(retries == 0)

        model.discardPlacementChanges()
        #expect(!model.hasPendingChanges)
        #expect(model.preferences == preferences)
        #expect(model.canSetHidden(!hidden, forAll: [item]))
        #expect(writes.isEmpty)
        model.setHidden(!hidden, forAll: [item])
        #expect(model.pendingChangeCount == 1)
        model.applyPlacementChanges()
        model.applyPlacementChanges()

        var expected = preferences
        expected.itemControls.setHidden(!hidden, for: item.snapshot)
        #expect(model.preferences == expected)
        #expect(writes == [expected])
        #expect(!model.hasPendingChanges)
        #expect(model.isHidden(item) == !hidden)
        #expect(!model.canSetHidden(!hidden, forAll: [item]))
        #expect(model.placementPending)
        #expect(model.placementFailed == failed)
        #expect(model.placementMessage == message)
        #expect(!model.placementInProgress)
        #expect(retries == 0)
        #expect(reads == 1)
    }

    @Test(arguments: [false, true])
    func unknownUnconfiguredBulkChoicesAreAvailableWithoutSideEffects(hidden: Bool) async {
        let items = [makeItem("ACME", id: 1), makeItem("Maccy", id: 2), makeItem("ACME", id: 3)]
        var reads = 0
        var retries = 0
        var writes: [Preferences] = []
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return items },
            onRetryPlacement: { retries += 1 }, onChange: { writes.append($0) }
        )
        await model.reloadItems()

        #expect(model.canSetHidden(hidden, forAll: items))
        #expect(model.canSetHidden(!hidden, forAll: items))
        #expect(!model.hasPendingChanges)
        #expect(model.placementPreview.unknown.map(\.id) == items.map(\.id))
        #expect(model.preferences == .default)
        #expect(reads == 1)
        #expect(writes.isEmpty)
        #expect(retries == 0)

        model.setHidden(hidden, forAll: items)
        #expect(!model.canSetHidden(hidden, forAll: items))
        #expect(model.canSetHidden(!hidden, forAll: items))
        #expect(model.pendingChangeCount == 2)
        #expect(items.allSatisfy { model.hasPendingChange(for: $0) && model.isHidden($0) == hidden })
        #expect(model.preferences == .default)
        model.setHidden(!hidden, forAll: items)
        #expect(model.pendingChangeCount == 2)
        #expect(!model.canSetHidden(!hidden, forAll: items))
        #expect(writes.isEmpty)
        model.applyPlacementChanges()

        var expected = Preferences.default
        expected.itemControls.setHidden(!hidden, forKey: "ACME")
        expected.itemControls.setHidden(!hidden, forKey: "Maccy")
        #expect(model.preferences == expected)
        #expect(writes == [expected])
        #expect(!model.hasPendingChanges)
        #expect(model.placementPreview.unknown.map(\.id) == items.map(\.id))
        #expect(retries == 0)
        #expect(reads == 1)
    }

    @Test(arguments: [false, true])
    func bulkAvailabilityRejectsSatisfiedChoicesWithoutMutatingOtherDrafts(hidden: Bool) {
        let items = [makeItem("ACME", id: 1, observedHidden: hidden),
                     makeItem("Maccy", id: 2, observedHidden: hidden)]
        let other = makeItem("other", id: 3, observedHidden: !hidden)
        var preferences = Preferences.default
        preferences.itemControls.setHidden(hidden, for: items[0].snapshot)
        var reads = 0
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return items + [other] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )

        #expect(!model.canSetHidden(hidden, forAll: items))
        #expect(model.canSetHidden(!hidden, forAll: items))
        #expect(!model.hasPendingChanges)
        model.setHidden(hidden, for: other)
        #expect(!model.canSetHidden(hidden, forAll: items))
        #expect(model.canSetHidden(!hidden, forAll: items))
        model.setHidden(hidden, forAll: items)

        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: other))
        #expect(items.allSatisfy { !model.hasPendingChange(for: $0) })
        #expect(model.preferences == preferences)
        #expect(reads == 0)
        #expect(writes == 0)
        #expect(retries == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func draftSurvivesRefreshAndWindowReplacementWithoutRebasing(hidden: Bool, revert: Bool) async {
        var item = makeItem(observedHidden: !hidden)
        var writes = 0
        var retries = 0
        var reads = 0
        let controller = SettingsWindowController(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        let model = controller.model
        await model.reloadItems()
        model.setHidden(hidden, for: item)

        item = makeItem(id: 99, observedHidden: hidden)
        await controller.model.reloadItems()
        #expect(controller.model === model)
        #expect(model.loadedItems.map(\.id) == [99])
        #expect(model.hasPendingChange(for: item))
        #expect(model.pendingChangeCount == 1)
        model.setHidden(hidden, for: item)
        #expect(model.pendingChangeCount == 1)
        #expect(writes == 0)
        #expect(retries == 0)

        if revert { model.setHidden(!hidden, for: item) }
        model.applyPlacementChanges()
        #expect(!model.hasPendingChanges)
        #expect(model.isHidden(item) == hidden)
        #expect(model.preferences.itemControls.hasPlacementIntent(item.snapshot) == !revert)
        #expect(writes == (revert ? 0 : 1))
        #expect(retries == 0)
        #expect(reads == 2)
    }

    @Test(arguments: [false, true])
    func draftSurvivesEmptyAndFailedLoads(loadFails: Bool) async {
        let item = makeItem(observedHidden: false)
        var reads = 0
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: {
                reads += 1
                if reads == 1 { return [item] }
                if loadFails { throw WindowServerError.invalidServerResponse("enumeration failed") }
                return []
            }, onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        model.setHidden(true, for: item)
        await model.reloadItems()

        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: item))
        #expect(model.loadedItems.map(\.id) == (loadFails ? [item.id] : []))
        #expect(model.placementPreview.hidden.map(\.id) == (loadFails ? [item.id] : []))
        #expect((model.itemsLoadError != nil) == loadFails)
        #expect(writes == 0)
        #expect(retries == 0)
        model.applyPlacementChanges()
        #expect(model.preferences.itemControls.hiddenInMenuBar == ["ACME"])
        #expect(!model.hasPendingChanges)
        #expect(writes == 1)
        #expect(retries == 0)
        #expect(reads == 2)
    }

    @Test func applyMergesOnlyEditedOwnersIntoCurrentPreferences() {
        let hidden = makeItem("ACME", id: 1, observedHidden: false)
        let shown = makeItem("Maccy", id: 2, observedHidden: true)
        let untouched = makeItem("unconfigured", id: 3, observedHidden: false)
        let initial = Preferences(itemControls: ItemControlStore(
            hiddenInMenuBar: ["absent.hidden"], shownInMenuBar: ["absent.shown"]
        ))
        var writes: [Preferences] = []
        var retries = 0
        var reads = 0
        let model = SettingsModel(
            preferences: initial, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [hidden, shown, untouched] },
            onRetryPlacement: { retries += 1 }, onChange: { writes.append($0) }
        )
        model.setHidden(true, for: hidden)
        model.setHidden(false, forAll: [shown, untouched])
        #expect(model.pendingChangeCount == 2)
        #expect(!model.hasPendingChange(for: untouched))
        #expect(writes.isEmpty)

        model.preferences.autoRehide = false
        model.preferences.autoRehideDelay = 43
        model.preferences.floatingBarStyle = .vertical
        model.preferences.revealOnHover = true
        model.preferences.toggleHotkey = HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.option)
        model.setAlias("New name", for: hidden)
        model.preferences.itemControls.setSuppressed(true, for: hidden.snapshot)
        model.preferences.itemControls.setOrderIndex(3, for: shown.snapshot)
        var replacement = model.preferences
        replacement.controlItemPositions = ["existing.slot": 42]
        model.preferences = replacement
        #expect(model.pendingChangeCount == 2)
        #expect(model.preferences.itemControls == ItemControlStore(
            hiddenInMenuBar: ["absent.hidden"], shownInMenuBar: ["absent.shown"],
            suppressedFromBar: ["ACME"], barOrder: ["Maccy": 3]
        ))
        writes.removeAll()

        var expected = model.preferences
        expected.itemControls.setHidden(true, for: hidden.snapshot)
        expected.itemControls.setHidden(false, for: shown.snapshot)
        model.applyPlacementChanges()

        #expect(model.preferences == expected)
        #expect(writes == [expected])
        #expect(!model.preferences.itemControls.hasPlacementIntent(untouched.snapshot))
        #expect(!model.hasPendingChanges)
        #expect(retries == 0)
        #expect(reads == 0)
    }

    @Test(arguments: [false, true])
    func applyClearsDraftBeforeEitherCallbackCanReenter(alreadySaved: Bool) {
        let item = makeItem(observedHidden: false)
        var preferences = Preferences.default
        if alreadySaved { preferences.itemControls.setHidden(true, for: item.snapshot) }
        weak var observedModel: SettingsModel?
        var callbackCounts: [Int] = []
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [item] },
            onRetryPlacement: {
                retries += 1
                callbackCounts.append(observedModel?.pendingChangeCount ?? -1)
                observedModel?.applyPlacementChanges()
            }, onChange: { _ in
                writes += 1
                callbackCounts.append(observedModel?.pendingChangeCount ?? -1)
                observedModel?.applyPlacementChanges()
            }
        )
        observedModel = model
        model.setHidden(true, for: item)
        model.applyPlacementChanges()
        model.applyPlacementChanges()

        #expect(callbackCounts == [0])
        #expect(writes == (alreadySaved ? 0 : 1))
        #expect(retries == (alreadySaved ? 1 : 0))
        #expect(!model.hasPendingChanges)
        #expect(!model.placementInProgress)
        #expect(!model.placementFailed)
        #expect(!model.placementPending)
        #expect(model.placementMessage == nil)
    }

    @Test(arguments: [false, true])
    func activePlacementBlocksEditingDiscardApplyAndRetry(hasDraft: Bool) {
        let item = makeItem(observedHidden: true)
        let other = makeItem("Maccy", id: 2, observedHidden: false)
        let preferences = Preferences(itemControls: ItemControlStore(hiddenInMenuBar: ["ACME"]))
        var writes = 0
        var retries = 0
        var reads = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item, other] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        if hasDraft { model.setHidden(false, for: item) }
        model.placementInProgress = true
        model.placementPending = true
        model.placementFailed = true
        model.placementMessage = "Applying saved placement."

        #expect(!model.canSetHidden(true, forAll: [item, other]))
        #expect(!model.canSetHidden(false, forAll: [item, other]))
        model.setHidden(true, for: item)
        model.setHidden(true, forAll: [item, other])
        model.discardPlacementChanges()
        model.applyPlacementChanges()
        model.retryPlacement()

        #expect(model.hasPendingChanges == hasDraft)
        #expect(model.pendingChangeCount == (hasDraft ? 1 : 0))
        #expect(model.hasPendingChange(for: item) == hasDraft)
        #expect(!model.hasPendingChange(for: other))
        #expect(model.isHidden(item) == !hasDraft)
        #expect(model.preferences == preferences)
        #expect(model.placementInProgress)
        #expect(model.placementPending)
        #expect(model.placementFailed)
        #expect(model.placementMessage == "Applying saved placement.")
        #expect(writes == 0)
        #expect(retries == 0)
        #expect(reads == 0)

        model.placementInProgress = false
        model.discardPlacementChanges()
        #expect(!model.hasPendingChanges)
        #expect(model.isHidden(item))
        #expect(model.preferences == preferences)
        #expect(model.placementPending)
        #expect(model.placementFailed)
        #expect(model.placementMessage == "Applying saved placement.")
        #expect(writes == 0)
        #expect(retries == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func retryRequiresFailedOrPendingPlacementWithoutActiveWorkOrDraft(failed: Bool, pending: Bool) {
        let item = makeItem(observedHidden: false)
        var writes = 0
        var retries = 0
        var reads = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        model.placementFailed = failed
        model.placementPending = pending
        model.placementMessage = "Native placement status."
        model.retryPlacement()
        let expectedRetries = failed || pending ? 1 : 0
        #expect(retries == expectedRetries)

        model.setHidden(true, for: item)
        model.retryPlacement()
        #expect(retries == expectedRetries)
        model.discardPlacementChanges()
        model.placementInProgress = true
        model.retryPlacement()

        #expect(retries == expectedRetries)
        #expect(model.placementFailed == failed)
        #expect(model.placementPending == pending)
        #expect(model.placementMessage == "Native placement status.")
        #expect(model.preferences == .default)
        #expect(writes == 0)
        #expect(reads == 0)
    }

    @Test(arguments: [false, true], [Optional<Bool>.none, false, true])
    func applyingSavedIntentReconcilesOnceRegardlessOfCachedObservation(hidden: Bool, observed: Bool?) async {
        var item = makeItem(observedHidden: !hidden)
        var preferences = Preferences.default
        preferences.itemControls.setHidden(hidden, for: item.snapshot)
        var writes = 0
        var retries = 0
        var reads = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        model.placementFailed = true
        model.placementMessage = "Native result is still authoritative."
        model.setHidden(hidden, for: item)
        item.observedHidden = observed
        await model.reloadItems()
        #expect(model.hasPendingChanges)
        #expect(model.pendingChangeCount == 1)
        #expect(model.partition(model.loadedItems).hidden.map(\.id) == (hidden ? [item.id] : []))
        #expect(model.partition(model.loadedItems).shown.map(\.id) == (hidden ? [] : [item.id]))
        #expect(writes == 0)
        #expect(retries == 0)

        model.applyPlacementChanges()
        #expect(retries == 1)
        model.applyPlacementChanges()

        #expect(!model.hasPendingChanges)
        #expect(model.preferences == preferences)
        #expect(writes == 0)
        #expect(retries == 1)
        let rowHidden = observed ?? hidden
        #expect(model.partition(model.loadedItems).hidden.map(\.id) == (rowHidden ? [item.id] : []))
        #expect(model.partition(model.loadedItems).shown.map(\.id) == (rowHidden ? [] : [item.id]))
        #expect(reads == 2)
        #expect(model.placementFailed)
        #expect(model.placementMessage == "Native result is still authoritative.")
        #expect(!model.placementInProgress)
    }

    @Test(arguments: [false, true])
    func externalPlacementReplacementDiscardsStaleDraftBeforeCallback(changeHiddenSet: Bool) {
        let item = makeItem(observedHidden: false)
        weak var observedModel: SettingsModel?
        var callbackCounts: [Int] = []
        var writes: [Preferences] = []
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { [item] },
            onRetryPlacement: { retries += 1 }, onChange: {
                writes.append($0)
                callbackCounts.append(observedModel?.pendingChangeCount ?? -1)
            }
        )
        observedModel = model
        model.setHidden(true, for: item)
        var replacement = model.preferences
        replacement.itemControls.setHidden(changeHiddenSet, forKey: "external.owner")
        model.preferences = replacement
        model.applyPlacementChanges()

        #expect(callbackCounts == [0])
        #expect(writes == [replacement])
        #expect(!model.hasPendingChanges)
        #expect(!model.hasPendingChange(for: item))
        #expect(!model.isHidden(item))
        #expect(model.preferences == replacement)
        #expect(!model.preferences.itemControls.hasPlacementIntent(item.snapshot))
        #expect(retries == 0)
    }

    @Test(arguments: [false, true])
    func cancelledAndFailedImportKeepTheDraft(fails: Bool) {
        let item = makeItem(observedHidden: false)
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { [item] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        model.setHidden(true, for: item)
        model.importLayout(using: {
            if fails { throw LayoutConfigError.malformed }
            return nil
        })

        #expect(model.hasPendingChanges)
        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: item))
        #expect(model.isHidden(item))
        #expect(model.preferences == .default)
        #expect(model.transferFailed == fails)
        #expect((model.transferMessage != nil) == fails)
        #expect(writes == 0)
        #expect(retries == 0)
    }

    @Test(arguments: [false, true])
    func successfulImportClearsDraftEvenWhenPlacementSetsAreIdentical(changesPlacement: Bool) {
        let item = makeItem(observedHidden: false)
        let loginItem = LoginItemService()
        // Matching the current service state avoids requesting a native registration change.
        let initial = Preferences(launchAtLogin: loginItem.isEnabled)
        weak var observedModel: SettingsModel?
        var callbackCounts: [Int] = []
        var writes: [Preferences] = []
        var retries = 0
        let model = SettingsModel(
            preferences: initial, loginItem: loginItem, itemsProvider: { [item] },
            onRetryPlacement: { retries += 1 }, onChange: {
                writes.append($0)
                callbackCounts.append(observedModel?.pendingChangeCount ?? -1)
            }
        )
        observedModel = model
        model.setHidden(true, for: item)
        var imported = initial
        imported.autoRehide = false
        imported.itemAliases.setAlias("Imported alias", for: item.snapshot)
        if changesPlacement { imported.itemControls.setHidden(false, for: item.snapshot) }
        model.importLayout(using: { imported })
        model.applyPlacementChanges()

        #expect(callbackCounts == [0])
        #expect(writes == [imported])
        #expect(!model.hasPendingChanges)
        #expect(!model.hasPendingChange(for: item))
        #expect(model.preferences == imported)
        #expect(model.transferMessage == "Imported settings.")
        #expect(!model.transferFailed)
        #expect(retries == 0)
    }

    @Test func previewContainsOnlyLoadedItemsAndNeverCallsTheProvider() {
        let item = makeItem(observedHidden: false)
        let preferences = Preferences(itemControls: ItemControlStore(hiddenInMenuBar: ["absent"]))
        var reads = 0
        var writes = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item] }, onChange: { _ in writes += 1 }
        )
        model.setHidden(true, for: item)

        for _ in 0..<3 {
            #expect(model.placementPreview.shown.isEmpty)
            #expect(model.placementPreview.hidden.isEmpty)
            #expect(model.placementPreview.unknown.isEmpty)
        }
        #expect(model.pendingChangeCount == 1)
        #expect(model.preferences == preferences)
        #expect(reads == 0)
        #expect(writes == 0)
    }

    @Test func previewProjectsAllSavedIntentsWhileDraftingOrApplyingSeparatelyFromRows() async {
        let items = [
            makeItem("saved.hidden", id: 1, observedHidden: false),
            makeItem("saved.shown", id: 2, observedHidden: true),
            makeItem("unknown.hidden", id: 3), makeItem("unknown.shown", id: 4),
            makeItem("unknown.unconfigured", id: 5),
            makeItem("unconfigured.hidden", id: 6, observedHidden: true),
            makeItem("unconfigured.shown", id: 7, observedHidden: false),
            makeItem("unknown.untouched", id: 8)
        ]
        let preferences = Preferences(itemControls: ItemControlStore(
            hiddenInMenuBar: ["saved.hidden", "unknown.hidden"],
            shownInMenuBar: ["saved.shown", "unknown.shown"]
        ))
        var reads = 0
        var writes = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return items }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        model.placementPending = true
        #expect(model.placementPreview.hidden.map(\.id) == [2, 6])
        #expect(model.placementPreview.shown.map(\.id) == [1, 7])
        #expect(model.placementPreview.unknown.map(\.id) == [3, 4, 5, 8])
        #expect(items.map { model.isHidden($0) } == [false, true, true, false, false, true, false, false])

        model.setHidden(false, forAll: [items[2], items[4]])
        #expect(model.pendingChangeCount == 2)
        #expect(model.placementPreview.hidden.map(\.id) == [1, 6])
        #expect(model.placementPreview.shown.map(\.id) == [2, 3, 4, 5, 7])
        #expect(model.placementPreview.unknown.map(\.id) == [8])
        #expect(model.partition(items).hidden.map(\.id) == [2, 6])
        #expect(model.partition(items).shown.map(\.id) == [1, 3, 4, 5, 7, 8])
        #expect(!model.hasPendingChange(for: items[0]))
        #expect(!model.hasPendingChange(for: items[1]))

        model.placementInProgress = true
        #expect(model.placementPreview.hidden.map(\.id) == [1, 6])
        #expect(model.placementPreview.shown.map(\.id) == [2, 3, 4, 5, 7])
        #expect(model.placementPreview.unknown.map(\.id) == [8])
        #expect(!model.isHidden(items[2]))
        #expect(model.pendingChangeCount == 2)
        model.placementInProgress = false
        model.discardPlacementChanges()
        #expect(model.placementPreview.hidden.map(\.id) == [2, 6])
        #expect(model.placementPreview.shown.map(\.id) == [1, 7])
        #expect(model.placementPreview.unknown.map(\.id) == [3, 4, 5, 8])
        model.placementInProgress = true
        #expect(!model.hasPendingChanges)
        #expect(model.placementPreview.hidden.map(\.id) == [1, 3, 6])
        #expect(model.placementPreview.shown.map(\.id) == [2, 4, 7])
        #expect(model.placementPreview.unknown.map(\.id) == [5, 8])
        #expect(model.loadedItems.map(\.observedHidden) == items.map(\.observedHidden))
        #expect(model.preferences == preferences)
        #expect(writes == 0)
        #expect(reads == 1)
    }

    @Test func previewReusesImagesAndCurrentAliasesWithHiddenOnlySuppressionAndOrdering() async throws {
        var items = [
            makeItem("shown.first", id: 1, observedHidden: false),
            makeItem("hidden.unordered", id: 2, observedHidden: true),
            makeItem("unknown", id: 3),
            makeItem("hidden.ordered", id: 4, observedHidden: true),
            makeItem("hidden.suppressed", id: 5, observedHidden: true),
            makeItem("shown.last", id: 6, observedHidden: false),
            makeItem("hidden.first", id: 7, observedHidden: true),
            makeItem("unknown.suppressed", id: 8)
        ]
        for index in items.indices { items[index].alias = "Stale alias" }
        items[3].isDisabled = true
        let preferences = Preferences(
            itemAliases: ItemAliasStore(aliases: ["hidden.ordered": "Current alias", "unknown": "Unknown alias"]),
            itemControls: ItemControlStore(
                suppressedFromBar: ["hidden.suppressed", "shown.first", "unknown.suppressed"],
                barOrder: ["hidden.first": 0, "hidden.ordered": 1, "shown.last": 0, "shown.first": 9]
            )
        )
        var reads = 0
        var writes = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return items }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        let preview = model.placementPreview
        #expect(preview.shown.map(\.id) == [1, 6])
        #expect(preview.hidden.map(\.id) == [7, 4, 2])
        #expect(preview.unknown.map(\.id) == [3, 8])
        #expect(preview.hidden.map(\.alias) == [nil, "Current alias", nil])
        #expect(preview.unknown.map(\.alias) == ["Unknown alias", nil])
        #expect(preview.shown.allSatisfy { $0.alias == nil })
        for item in preview.shown + preview.hidden + preview.unknown {
            let original = try #require(items.first { $0.id == item.id })
            #expect(item.image === original.image)
            #expect(item.snapshot == original.snapshot)
            #expect(item.observedHidden == original.observedHidden)
            #expect(item.isDisabled == original.isDisabled)
        }
        #expect(writes == 0)

        model.setHidden(true, for: items[0])
        model.setAlias("", for: items[3])
        model.setAlias("Fresh name", for: items[1])
        #expect(model.hasPendingChange(for: items[0]))
        #expect(model.placementPreview.shown.map(\.id) == [6])
        #expect(model.placementPreview.hidden.map(\.id) == [7, 4, 2])
        #expect(model.placementPreview.hidden.map(\.alias) == [nil, nil, "Fresh name"])
        #expect(model.placementPreview.unknown.map(\.id) == [3, 8])
        #expect(model.loadedItems.allSatisfy { $0.alias == "Stale alias" })
        #expect(writes == 2)

        model.preferences.itemControls.setOrderIndex(-1, for: items[1].snapshot)
        model.preferences.itemControls.setSuppressed(false, for: items[4].snapshot)
        #expect(model.hasPendingChange(for: items[0]))
        #expect(model.placementPreview.hidden.map(\.id) == [2, 7, 4, 5])
        model.discardPlacementChanges()
        #expect(!model.hasPendingChanges)
        #expect(model.placementPreview.shown.map(\.id) == [1, 6])
        #expect(model.placementPreview.hidden.map(\.id) == [2, 7, 4, 5])
        #expect(model.placementPreview.hidden.map(\.alias) == ["Fresh name", nil, nil, nil])
        #expect(model.preferences.itemControls.hiddenInMenuBar.isEmpty)
        #expect(model.preferences.itemControls.shownInMenuBar.isEmpty)
        #expect(writes == 4)
        #expect(reads == 1)
    }

    // MARK: - Always Hidden tier

    @Test func placementReportsThreeTiersFromObservationsIntentAndDrafts() async {
        let items = [
            makeItem("observed.shown", id: 1, observedPlacement: .shown),
            makeItem("observed.hidden", id: 2, observedPlacement: .hidden),
            makeItem("observed.always", id: 3, observedPlacement: .alwaysHidden),
            makeItem("saved.always", id: 4),
            makeItem("saved.hidden", id: 5),
            makeItem("unconfigured", id: 6)
        ]
        let preferences = Preferences(itemControls: ItemControlStore(
            hiddenInMenuBar: ["saved.hidden"], alwaysHiddenInMenuBar: ["saved.always", "observed.shown"]
        ))
        var writes = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { items }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()

        #expect(items.map { model.placement(of: $0) } == [.shown, .hidden, .alwaysHidden, .alwaysHidden, .hidden, .shown])
        #expect(items.map { model.isHidden($0) } == [false, true, true, true, true, false])
        let parts = model.partition(items)
        #expect(parts.shown.map(\.id) == [1, 6])
        #expect(parts.hidden.map(\.id) == [2, 5])
        #expect(parts.alwaysHidden.map(\.id) == [3, 4])
        #expect(items.map(\.observedHidden) == [false, true, true, nil, nil, nil])

        model.placementInProgress = true
        #expect(model.placement(of: items[0]) == .alwaysHidden)
        #expect(model.placement(of: items[1]) == .hidden)
        model.placementInProgress = false

        model.setPlacement(.alwaysHidden, for: items[1])
        #expect(model.placement(of: items[1]) == .alwaysHidden)
        #expect(model.hasPendingChange(for: items[1]))
        #expect(model.partition(items).alwaysHidden.map(\.id) == [2, 3, 4])
        model.setPlacement(.hidden, for: items[1])
        #expect(!model.hasPendingChange(for: items[1]))
        #expect(!model.hasPendingChanges)
        model.setHidden(true, for: items[2])
        #expect(model.placement(of: items[2]) == .hidden)
        #expect(model.hasPendingChange(for: items[2]))
        #expect(writes == 0)
        #expect(model.preferences == preferences)
    }

    @Test func stagingAlwaysHiddenPreviewsAThirdTierAndOnlyApplyPersistsIt() async {
        let items = [makeItem("ACME", id: 1, observedPlacement: .shown), makeItem("Maccy", id: 2, observedPlacement: .hidden)]
        var writes: [Preferences] = []
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { items }, onRetryPlacement: { retries += 1 }, onChange: { writes.append($0) }
        )
        await model.reloadItems()
        #expect(model.placementPreview.alwaysHidden.isEmpty)

        model.setPlacement(.alwaysHidden, for: items[0])
        #expect(model.pendingChangeCount == 1)
        #expect(model.placementPreview.alwaysHidden.map(\.id) == [1])
        #expect(model.placementPreview.shown.isEmpty)
        #expect(model.placementPreview.hidden.map(\.id) == [2])
        #expect(writes.isEmpty)
        #expect(model.canSetPlacement(.hidden, forAll: items))
        #expect(!model.canSetPlacement(.alwaysHidden, forAll: [items[0]]))

        model.applyPlacementChanges()
        #expect(writes.count == 1)
        #expect(retries == 0)
        #expect(model.preferences.itemControls.placement(forKey: "ACME") == .alwaysHidden)
        #expect(!model.preferences.itemControls.hasPlacementIntent(forKey: "Maccy"))
        #expect(!model.hasPendingChanges)
        #expect(model.placement(of: items[0]) == .shown)
        model.placementInProgress = true
        #expect(model.placement(of: items[0]) == .alwaysHidden)
        #expect(model.placementPreview.alwaysHidden.map(\.id) == [1])
    }

    @Test(arguments: [false, true])
    func hideAllAndShowAllStillMeanTheOrdinaryTiers(hidden: Bool) async {
        let items = [makeItem("ACME", id: 1, observedPlacement: .alwaysHidden), makeItem("Maccy", id: 2, observedPlacement: .shown)]
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { items }, onChange: { _ in }
        )
        await model.reloadItems()
        #expect(model.canSetHidden(hidden, forAll: items))
        model.setHidden(hidden, forAll: items)
        #expect(items.map { model.placement(of: $0) } == [ItemPlacement(hidden: hidden), ItemPlacement(hidden: hidden)])
        #expect(model.pendingChangeCount == (hidden ? 2 : 1))
        #expect(model.hasPendingChange(for: items[0]))
        #expect(model.hasPendingChange(for: items[1]) == hidden)
    }

    @Test func barPresentationControlsSaveImmediatelyWithoutStagingOrMovingItems() async {
        let items = [
            makeItem("first.hidden", id: 1, observedPlacement: .hidden),
            makeItem("second.hidden", id: 2, observedPlacement: .hidden),
            makeItem("only.always", id: 3, observedPlacement: .alwaysHidden),
            makeItem("shown", id: 4, observedPlacement: .shown)
        ]
        var writes: [Preferences] = []
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { items }, onRetryPlacement: { retries += 1 }, onChange: { writes.append($0) }
        )
        await model.reloadItems()
        #expect(items.map { model.isShownInBar($0) } == [true, true, true, true])
        #expect(!model.canMoveInBar(items[0], .earlier))
        #expect(model.canMoveInBar(items[0], .later))
        #expect(model.canMoveInBar(items[1], .earlier))
        #expect(!model.canMoveInBar(items[1], .later))
        #expect(!model.canMoveInBar(items[2], .earlier))
        #expect(!model.canMoveInBar(items[2], .later))
        #expect(!model.canMoveInBar(items[3], .earlier))
        #expect(!model.canMoveInBar(items[3], .later))

        model.setShownInBar(false, for: items[0])
        #expect(writes.count == 1)
        #expect(!model.isShownInBar(items[0]))
        #expect(model.preferences.itemControls.suppressedFromBar == ["first.hidden"])
        model.setShownInBar(false, for: items[0])
        #expect(writes.count == 1)
        #expect(model.placementPreview.hidden.map(\.id) == [2])

        model.moveInBar(items[0], .later)
        #expect(writes.count == 2)
        #expect(model.preferences.itemControls.barOrder == ["second.hidden": 0, "first.hidden": 1])
        #expect(model.canMoveInBar(items[0], .earlier))
        #expect(!model.canMoveInBar(items[0], .later))
        model.moveInBar(items[0], .later)
        #expect(writes.count == 2)
        model.moveInBar(items[3], .earlier)
        #expect(writes.count == 2)

        model.setShownInBar(true, for: items[0])
        #expect(writes.count == 3)
        #expect(model.placementPreview.hidden.map(\.id) == [2, 1])
        #expect(!model.hasPendingChanges)
        #expect(retries == 0)
        #expect(model.preferences.itemControls.hiddenInMenuBar.isEmpty)
        #expect(model.preferences.itemControls.shownInMenuBar.isEmpty)
        #expect(model.preferences.itemControls.alwaysHiddenInMenuBar.isEmpty)
        #expect(items.map { model.placement(of: $0) } == [.hidden, .hidden, .alwaysHidden, .shown])
    }

    @Test func draftsFollowTheAlwaysHiddenIntentChangesLikeTheOtherTiers() async {
        let item = makeItem(observedPlacement: .shown)
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { [item] }, onChange: { _ in }
        )
        await model.reloadItems()
        model.setPlacement(.hidden, for: item)
        #expect(model.hasPendingChanges)
        model.preferences.itemControls.setPlacement(.alwaysHidden, for: item.snapshot)
        #expect(!model.hasPendingChanges)
        #expect(model.draftDiscardedNotice != nil)
        #expect(model.placement(of: item) == .shown)
        model.placementInProgress = true
        #expect(model.placement(of: item) == .alwaysHidden)
    }

    private func makeItem(
        _ owner: String? = "ACME",
        id: CGWindowID = 1,
        observedPlacement: ItemPlacement?
    ) -> FloatingBarItem {
        FloatingBarItem(
            snapshot: MenuBarItemSnapshot(windowID: id, ownerPID: 1, ownerBundleID: owner, frame: .zero),
            image: NSImage(size: CGSize(width: 18, height: 18)),
            observedPlacement: observedPlacement
        )
    }

    private func makeItem(
        _ owner: String? = "ACME",
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
