import AppKit
import BarKeepersFriendCore
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WidgetStatusItemsControllerTests {

    @MainActor
    final class Seams {
        var openedURLs: [URL] = []
        var launched: [String] = []
        var shortcuts: [String] = []
        var toggles = 0
        var openResult = true

        func makeRunner() -> WidgetActionRunner {
            WidgetActionRunner(
                openURL: { [unowned self] url in openedURLs.append(url); return openResult },
                launchApp: { [unowned self] identifier in launched.append(identifier); return true },
                runShortcut: { [unowned self] name in shortcuts.append(name) },
                toggleBar: { [unowned self] in toggles += 1 }
            )
        }
    }

    private static let site = URL(string: "https://example.com")!

    private func makeController(
        _ seams: Seams, failureDisplayDuration: Duration = .seconds(6),
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> (WidgetStatusItemsController, FakeGroupStatusItemFactory) {
        let factory = FakeGroupStatusItemFactory()
        let controller = WidgetStatusItemsController(
            factory: factory, runner: seams.makeRunner(), failureDisplayDuration: failureDisplayDuration, sleep: sleep
        )
        return (controller, factory)
    }

    @Test func updateInstallsOneStatusItemPerWidgetThroughTheFactoryOnly() throws {
        let seams = Seams()
        let (controller, factory) = makeController(seams)
        let dashboard = MenuBarWidget(name: "Dashboard", symbolName: "gauge", action: .openURL(Self.site))
        let focus = MenuBarWidget(name: "Focus", symbolName: "moon", action: .runShortcut(name: "Start Focus"))
        controller.update(widgets: [dashboard, focus])

        #expect(factory.created.count == 2)
        #expect(controller.installedWidgetIDs == [dashboard.id, focus.id])
        #expect(factory.created.map(\.autosaveName) == [
            "BKFWidget-\(dashboard.id.uuidString)", "BKFWidget-\(focus.id.uuidString)"
        ])
        for handle in factory.created {
            let name = try #require(handle.autosaveName)
            #expect(name.hasPrefix(HiddenItemsResolver.controlItemNamePrefix))
            #expect(!ControlItem.Identifier.allCases.map(\.rawValue).contains(name))
            #expect(!name.hasPrefix("BKFGroup-"))
            // The autosave name surfaces as the window title; the resolver must treat it as BKF's own.
            let snapshot = MenuBarItemSnapshot(
                windowID: 1, ownerPID: 1, ownerBundleID: "Bar Keeper's Friend", title: name,
                frame: CGRect(x: 100, y: 0, width: 22, height: 22)
            )
            #expect(HiddenItemsResolver.isOwnControlItem(snapshot))
            #expect(HiddenItemsResolver.hiddenItems(from: [snapshot], leftOfAnchorX: 500).isEmpty)
            #expect(HiddenLayoutPlanner.moves(
                for: [snapshot], anchorMinX: 500, anchorMaxX: 530, dividerMinX: 480,
                controls: ItemControlStore(hiddenInMenuBar: ["Bar Keeper's Friend"])
            ).isEmpty)
            #expect(handle.title == nil)
            #expect(handle.removeCount == 0)
            #expect(handle.onClick != nil)
            let image = try #require(handle.image)
            #expect(image.isTemplate)
        }
        #expect(factory.created[0].toolTip == "Dashboard: Open https://example.com")
        #expect(factory.created[1].toolTip == "Focus: Run Shortcut \"Start Focus\"")
        #expect(seams.openedURLs.isEmpty && seams.shortcuts.isEmpty)

        // A second identical update must not create, remove, or re-render anything.
        controller.update(widgets: [dashboard, focus])
        #expect(factory.created.count == 2)
        #expect(factory.created.map(\.imageWrites) == [1, 1])
        #expect(factory.created.map(\.toolTipWrites) == [1, 1])
        #expect(factory.created.allSatisfy { $0.removeCount == 0 })
    }

    @Test func updateKeepsSurvivorsRemovesDeletedWidgetsAndAddsNewOnes() throws {
        let seams = Seams()
        let (controller, factory) = makeController(seams)
        let dashboard = MenuBarWidget(name: "Dashboard", symbolName: "gauge", action: .openURL(Self.site))
        let focus = MenuBarWidget(name: "Focus", symbolName: "moon", action: .runShortcut(name: "Start Focus"))
        controller.update(widgets: [dashboard, focus])
        let dashboardHandle = try #require(factory.created.first)
        let focusHandle = try #require(factory.created.last)
        let firstImage = try #require(dashboardHandle.image)

        var renamed = dashboard
        renamed.name = "Board"
        renamed.action = .launchApp(bundleIdentifier: "com.apple.Safari")
        let bar = MenuBarWidget(name: "Bar", symbolName: "menubar.rectangle", action: .toggleBar)
        controller.update(widgets: [renamed, bar])

        #expect(factory.created.count == 3)
        #expect(factory.created[0] === dashboardHandle)
        #expect(dashboardHandle.removeCount == 0)
        #expect(dashboardHandle.toolTip == "Board: Launch com.apple.Safari")
        // The rename re-renders once so the image's accessibility description follows the name.
        #expect(dashboardHandle.image !== firstImage)
        #expect(dashboardHandle.imageWrites == 2)
        #expect(dashboardHandle.image?.accessibilityDescription == "Board")
        #expect(focusHandle.removeCount == 1)
        #expect(focusHandle.onClick == nil)
        #expect(controller.installedWidgetIDs == [dashboard.id, bar.id])
        #expect(factory.created[2].autosaveName == "BKFWidget-\(bar.id.uuidString)")
        #expect(factory.created[2].toolTip == "Bar: Toggle the hidden bar")

        // An action-only change leaves the image alone; a symbol change re-renders exactly once.
        var retargeted = renamed
        retargeted.action = .toggleBar
        controller.update(widgets: [retargeted, bar])
        #expect(dashboardHandle.imageWrites == 2)
        #expect(dashboardHandle.toolTip == "Board: Toggle the hidden bar")
        var resymboled = retargeted
        resymboled.symbolName = "safari"
        controller.update(widgets: [resymboled, bar])
        #expect(dashboardHandle.imageWrites == 3)
        #expect(dashboardHandle.image !== firstImage)
        #expect(dashboardHandle.image?.isTemplate == true)

        // A click for a deleted widget runs nothing.
        controller.runAction(forWidgetID: focus.id)
        #expect(seams.shortcuts.isEmpty)

        controller.removeAll()
        #expect(controller.installedWidgetIDs.isEmpty)
        #expect(dashboardHandle.removeCount == 1)
        #expect(factory.created[2].removeCount == 1)
        #expect(focusHandle.removeCount == 1)
        #expect(dashboardHandle.onClick == nil)
        controller.removeAll()
        #expect(dashboardHandle.removeCount == 1)

        controller.update(widgets: [bar])
        #expect(factory.created.count == 4)
        #expect(controller.installedWidgetIDs == [bar.id])
    }

    @Test func widgetsBeyondTheMaximumAndDuplicateIDsGetNoStatusItem() {
        let seams = Seams()
        let (controller, factory) = makeController(seams)
        let shared = UUID()
        let widgets = [MenuBarWidget(id: shared, name: "One", symbolName: "1.circle", action: .toggleBar),
                       MenuBarWidget(id: shared, name: "Dup", symbolName: "2.circle", action: .toggleBar)]
            + (0..<20).map { MenuBarWidget(name: "W\($0)", symbolName: "star", action: .toggleBar) }
        controller.update(widgets: widgets)
        #expect(factory.created.count == WidgetLibrary.maxWidgets)
        #expect(controller.installedWidgetIDs == Set(WidgetLibrary.normalized(widgets).map(\.id)))
        #expect(factory.created[0].toolTip == "One: Toggle the hidden bar")
        #expect(factory.created[0].image?.isTemplate == true)
    }

    @Test func clickingRunsTheWidgetActionExactlyOnceThroughTheRunner() throws {
        let seams = Seams()
        let (controller, factory) = makeController(seams)
        let dashboard = MenuBarWidget(name: "Dashboard", symbolName: "gauge", action: .openURL(Self.site))
        let notes = MenuBarWidget(name: "Notes", symbolName: "note.text", action: .launchApp(bundleIdentifier: "com.apple.Notes"))
        let focus = MenuBarWidget(name: "Focus", symbolName: "moon", action: .runShortcut(name: "Start Focus"))
        let bar = MenuBarWidget(name: "Bar", symbolName: "menubar.rectangle", action: .toggleBar)
        controller.update(widgets: [dashboard, notes, focus, bar])
        #expect(factory.created.count == 4)

        try click(factory.created[0])
        #expect(seams.openedURLs == [Self.site])
        try click(factory.created[1])
        #expect(seams.launched == ["com.apple.Notes"])
        try click(factory.created[2])
        #expect(seams.shortcuts == ["Start Focus"])
        try click(factory.created[3])
        #expect(seams.toggles == 1)
        #expect(seams.openedURLs.count + seams.launched.count + seams.shortcuts.count + seams.toggles == 4)
        // A successful click leaves the normal tooltip in place.
        #expect(factory.created.map(\.toolTipWrites) == [1, 1, 1, 1])
        #expect(factory.created.allSatisfy { $0.presentedMenus.isEmpty })
    }

    @Test func failedClicksExplainThemselvesInTheTooltipAndThenRestoreIt() async throws {
        let seams = Seams()
        let ticker = WidgetTestTicker()
        let (controller, factory) = makeController(seams, failureDisplayDuration: .seconds(6), sleep: ticker.sleep)
        let dashboard = MenuBarWidget(name: "Dashboard", symbolName: "gauge", action: .openURL(Self.site))
        let files = MenuBarWidget(name: "Files", symbolName: "folder", action: .openURL(URL(string: "file:///tmp")!))
        controller.update(widgets: [dashboard, files])
        let dashboardHandle = try #require(factory.created.first)
        let filesHandle = try #require(factory.created.last)
        let normal = "Dashboard: Open https://example.com"
        #expect(dashboardHandle.toolTip == normal)
        #expect(ticker.sleepRequests == 0)

        // A refused action never reaches the seam; the tooltip says why.
        try click(filesHandle)
        #expect(seams.openedURLs.isEmpty)
        #expect(filesHandle.toolTip == "Files: \(WidgetActionError.invalidAction(.unsupportedURLScheme).message)")
        #expect(await ticker.settles { ticker.sleepRequests == 1 })
        #expect(ticker.requestedDurations == [.seconds(6)])

        seams.openResult = false
        try click(dashboardHandle)
        #expect(seams.openedURLs == [Self.site])
        #expect(dashboardHandle.toolTip == "Dashboard: \(WidgetActionError.openURLFailed(Self.site).message)")
        #expect(dashboardHandle.toolTipWrites == 2)
        #expect(await ticker.settles { ticker.sleepRequests == 2 })
        // An identical update keeps the explanation visible instead of clobbering it.
        controller.update(widgets: [dashboard, files])
        #expect(dashboardHandle.toolTipWrites == 2)
        #expect(filesHandle.toolTipWrites == 2)

        // When the display time elapses, both normal tooltips return exactly once.
        ticker.tick()
        #expect(await ticker.settles { dashboardHandle.toolTip == normal && filesHandle.toolTip == "Files: Open file:///tmp" })
        #expect(dashboardHandle.toolTipWrites == 3)
        #expect(filesHandle.toolTipWrites == 3)
        #expect(ticker.pendingSleeps == 0)

        // A later success clears a pending explanation immediately and cancels its timer.
        try click(dashboardHandle)
        #expect(dashboardHandle.toolTip != normal)
        #expect(await ticker.settles { ticker.pendingSleeps == 1 })
        seams.openResult = true
        try click(dashboardHandle)
        #expect(dashboardHandle.toolTip == normal)
        #expect(seams.openedURLs.count == 3)
        #expect(await ticker.settles { ticker.pendingSleeps == 0 })
        #expect(dashboardHandle.toolTipWrites == 5)

        // Editing the widget also drops the explanation, since it described the old action.
        seams.openResult = false
        try click(dashboardHandle)
        #expect(dashboardHandle.toolTip != normal)
        #expect(await ticker.settles { ticker.pendingSleeps == 1 })
        var edited = dashboard
        edited.action = .toggleBar
        controller.update(widgets: [edited, files])
        #expect(dashboardHandle.toolTip == "Dashboard: Toggle the hidden bar")
        #expect(await ticker.settles { ticker.pendingSleeps == 0 })
        let writesAfterEdit = dashboardHandle.toolTipWrites
        // A stray tick after cancellation must not write anything.
        ticker.tick()
        await Task.yield()
        #expect(dashboardHandle.toolTipWrites == writesAfterEdit)
        #expect(dashboardHandle.toolTip == "Dashboard: Toggle the hidden bar")

        // Removing a widget while its explanation is pending cancels the timer with it.
        try click(filesHandle)
        #expect(await ticker.settles { ticker.pendingSleeps == 1 })
        controller.update(widgets: [edited])
        #expect(filesHandle.removeCount == 1)
        #expect(await ticker.settles { ticker.pendingSleeps == 0 })
    }

    @Test func unknownSymbolsFallBackToThePlaceholderGlyph() throws {
        #expect(WidgetStatusItemIcon.isAvailable("star"))
        #expect(WidgetStatusItemIcon.isAvailable(" gauge "))
        #expect(!WidgetStatusItemIcon.isAvailable("definitely.not.a.symbol.name"))
        #expect(!WidgetStatusItemIcon.isAvailable(""))
        #expect(WidgetStatusItemIcon.isAvailable(WidgetLibrary.fallbackSymbolName))
        #expect(WidgetStatusItemIcon.isAvailable(WidgetLibrary.defaultSymbolName))

        let known = WidgetStatusItemIcon.image(symbolName: "star", accessibilityDescription: "Star")
        let fallback = WidgetStatusItemIcon.image(symbolName: "definitely.not.a.symbol.name", accessibilityDescription: "Unknown")
        let placeholder = WidgetStatusItemIcon.image(symbolName: WidgetLibrary.fallbackSymbolName, accessibilityDescription: "Unknown")
        #expect(known.isTemplate && fallback.isTemplate && placeholder.isTemplate)
        #expect(known.size.width > 0 && fallback.size.width > 0)
        #expect(known.accessibilityDescription == "Star")
        #expect(fallback.accessibilityDescription == "Unknown")
        // The fallback draws the placeholder symbol, not an empty image.
        #expect(fallback.size == placeholder.size)
        #expect(fallback.tiffRepresentation == placeholder.tiffRepresentation)
        #expect(fallback.tiffRepresentation != known.tiffRepresentation)

        let seams = Seams()
        let (controller, factory) = makeController(seams)
        controller.update(widgets: [MenuBarWidget(name: "Odd", symbolName: "definitely.not.a.symbol.name", action: .toggleBar)])
        let handle = try #require(factory.created.first)
        #expect(handle.image?.tiffRepresentation == placeholder.tiffRepresentation)
        #expect(handle.toolTip == "Odd: Toggle the hidden bar")
    }

    @Test func autosaveNameAndToolTipAreDerivedFromTheWidget() {
        let id = UUID()
        let widget = MenuBarWidget(id: id, name: "Mail", symbolName: "envelope", action: .openURL(URL(string: "mailto:me@example.com")!))
        #expect(WidgetStatusItemsController.autosaveName(for: id) == "BKFWidget-\(id.uuidString)")
        #expect(WidgetStatusItemsController.toolTip(for: widget) == "Mail: Open mailto:me@example.com")
        #expect(GroupStatusItemSlots.preferredPositionKey(WidgetStatusItemsController.autosaveName(for: id))
                == "NSStatusItem Preferred Position BKFWidget-\(id.uuidString)")
    }

    // MARK: - Helpers

    /// Invokes the handle's click closure as the status bar button would.
    private func click(_ handle: FakeGroupStatusItem) throws {
        let onClick = try #require(handle.onClick)
        onClick()
    }
}

/// Replaces the controller's sleep so the tooltip restore advances one explicit tick at a time.
@MainActor
private final class WidgetTestTicker {
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextID = 0
    private(set) var sleepRequests = 0
    private(set) var requestedDurations: [Duration] = []

    var pendingSleeps: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        sleepRequests += 1
        requestedDurations.append(duration)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            // Cancellation lands off-actor; resuming only this waiter keeps other timers unaffected.
            Task { @MainActor in self.cancel(id) }
        }
    }

    func tick() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// Hops the main actor until `condition` holds; bounded so a hang fails instead of stalling the suite.
    func settles(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func cancel(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
