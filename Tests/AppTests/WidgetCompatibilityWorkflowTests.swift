import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WidgetCompatibilityWorkflowTests {
    @Test(arguments: [false, true])
    func legacyWidgetsSurviveSettingsEditsAndBackup(fromLegacyExport: Bool) async throws {
        let suite = "WidgetCompatibilityWorkflowTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "com.agraabhi.BarKeepersFriend.preferences"
        let legacyData = Data(Self.legacyPreferencesJSON.utf8)
        if !fromLegacyExport { defaults.set(legacyData, forKey: storageKey) }
        let store = PreferencesStore(backing: defaults)
        let initial = store.load()
        let server = FakeWindowServer()
        var captures = 0
        var dividerWrites: [Bool] = []
        var itemReads = 0
        var attributionReads = 0
        var writes: [Preferences] = []
        let engine = CosmeticHideEngine(
            preferences: initial, controlWindowIDs: { (90, 91) },
            setDividerCollapsed: { dividerWrites.append($0) }, onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in captures += 1; return [:] },
            preferences: initial, attribute: { attributionReads += 1; return $0 }
        )
        engine.floatingBar = bar
        engine.hiddenItemController = HiddenItemController(
            windowServer: server, attribute: { attributionReads += 1; return $0 }
        )
        let item = settingsTestItem(7, observedHidden: false)
        let model = SettingsModel(
            preferences: initial, loginItem: SettingsTestLoginItem(),
            itemsProvider: { itemReads += 1; return [item] },
            onChange: { updated in
                writes.append(updated)
                #expect(store.save(updated))
                engine.apply(preferences: updated)
                bar.preferences = updated
            }
        )

        if fromLegacyExport {
            let legacyExport = Data("{\"version\":1,\"preferences\":\(Self.legacyPreferencesJSON)}".utf8)
            model.importLayout { try LayoutConfig.decode(from: legacyExport).preferences }
            try #require(!model.transferFailed)
            #expect(model.transferMessage == "Imported settings.")
            #expect(writes.count == 1)
        } else {
            #expect(writes.isEmpty)
        }
        let loaded = model.preferences
        try #require(loaded.widgets.count == 6, "Legacy widget data must not silently fall back to an empty list.")
        let expectedPayload = try widgetPayload(in: legacyData)
        #expect(try widgetPayload(in: JSONEncoder().encode(loaded)) == expectedPayload)
        #expect(loaded.itemAliases.alias(for: item.snapshot) == "Clipboard")
        #expect(store.hasSavedPreferences)

        // A session-only Items draft must survive unrelated edits alongside the inert widget data.
        model.setPlacement(.hidden, for: item)
        let hosting = settingsTestHost(SettingsView(model: model, initialTab: .behavior))
        let writesBeforeEdits = writes.count
        try await press("settings-auto-rehide", in: hosting) { !model.preferences.autoRehide }
        try await press("settings-dismiss-on-exit", in: hosting) { !model.preferences.dismissBarOnMouseExit }
        var expected = loaded
        expected.autoRehide = false
        expected.dismissBarOnMouseExit = false
        #expect(model.preferences == expected)
        #expect(bar.preferences == expected)
        #expect(engine.stateMachine.autoRehideSections.isEmpty)
        #expect(writes.count == writesBeforeEdits + 2)
        #expect(writes.allSatisfy { $0.widgets == loaded.widgets })
        #expect(model.pendingChangeCount == 1)
        #expect(model.hasPendingChange(for: item))

        let saved = try #require(defaults.object(forKey: storageKey) as? Data)
        #expect(try widgetPayload(in: saved) == expectedPayload)
        let reloadedStore = PreferencesStore(backing: defaults)
        #expect(reloadedStore.load() == expected)

        // Exercise the real export encoder; only the save panel and disk write are intercepted.
        var exported: Data?
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("BKF-widget-compatibility.json")
        model.exportLayout { preferences in
            LayoutTransferService.exportLayout(
                preferences, destination: { destination }, write: { data, _ in exported = data }
            )
        }
        try #require(!model.transferFailed)
        #expect(model.transferMessage == "Exported to BKF-widget-compatibility.json.")
        let exportedData = try #require(exported)
        #expect(try widgetPayload(in: exportedData) == expectedPayload)
        #expect(try LayoutConfig.decode(from: exportedData).preferences == expected)
        #expect(writes.count == writesBeforeEdits + 2, "Exporting must not rewrite preferences.")

        let relaunchedModel = SettingsModel(
            preferences: reloadedStore.load(), loginItem: SettingsTestLoginItem(), itemsProvider: { [] },
            onChange: { _ in Issue.record("Loading saved settings must not write preferences.") }
        )
        #expect(relaunchedModel.preferences == expected)
        #expect(!relaunchedModel.hasPendingChanges)
        #expect(itemReads == 0)
        #expect(attributionReads == 0)
        #expect(captures == 0)
        #expect(dividerWrites.isEmpty)
        #expect(server.moveRequests.isEmpty)
        #expect(server.clickedWindowIDs.isEmpty)
        #expect(!engine.placementInProgress && !engine.placementPending)
        #expect(!bar.isVisible)
        #expect(!hosting.testWindow.isVisible)
    }

    private func press(
        _ identifier: String, in hosting: SettingsTestHostingController, until condition: () -> Bool
    ) async throws {
        let element = try #require(settingsTestAccessibility(hosting.view).first {
            $0.accessibilityIdentifier() == identifier
        }, "Missing Settings control \(identifier).")
        try #require(element.isAccessibilityEnabled())
        // Native switches can report false after dispatch; the persisted model change is the oracle.
        _ = element.accessibilityPerformPress()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            hosting.render()
            try await Task.sleep(for: .milliseconds(10))
            if condition() { return }
        } while ContinuousClock.now < deadline
        try #require(condition(), "The Settings edit did not reach the model.")
    }

    private func widgetPayload(in data: Data) throws -> NSArray {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let preferences = root["preferences"] as? [String: Any] ?? root
        return try #require(preferences["widgets"] as? NSArray)
    }

    // Literal legacy JSON pins the persisted shape independently of the current encoder.
    private static let legacyPreferencesJSON = #"""
    {
      "autoRehide": true,
      "dismissBarOnMouseExit": true,
      "controlItemPositions": {"BKFAnchor": 240},
      "itemAliases": {"aliases": {"Item 7": "Clipboard"}},
      "itemControls": {"barOrder": {"Item 7": 2}},
      "widgets": [
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "name": "Dashboard", "symbolName": "gauge",
          "action": {"type": "openURL", "url": "https://example.com/dashboard?tab=1"}
        },
        {
          "id": "22222222-2222-4222-8222-222222222222",
          "name": "Mail", "symbolName": "envelope",
          "action": {"type": "openURL", "url": "mailto:name@example.com?subject=Hi"}
        },
        {
          "id": "33333333-3333-4333-8333-333333333333",
          "name": "Editor", "symbolName": "unknown.legacy.symbol",
          "action": {"type": "launchApp", "bundleIdentifier": "com.example.Editor"}
        },
        {
          "id": "44444444-4444-4444-8444-444444444444",
          "name": "Focus", "symbolName": "moon",
          "action": {"type": "runShortcut", "name": " Start Focus "}
        },
        {
          "id": "55555555-5555-4555-8555-555555555555",
          "name": "Bar", "symbolName": "menubar.rectangle",
          "action": {"type": "toggleBar"}
        },
        {
          "id": "66666666-6666-4666-8666-666666666666",
          "name": "Files", "symbolName": "folder",
          "action": {"type": "openURL", "url": "file:///tmp"}
        }
      ]
    }
    """#
}
