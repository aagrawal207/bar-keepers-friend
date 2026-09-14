import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

/// End-to-end icon workflows: real Settings controls, the real model, real JSON persistence in an
/// isolated defaults suite, and the real engine. Only the anchor's status button is intercepted.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppIconWorkflowTests {
    @Test func choosingBothIconsPersistsAppliesAndSurvivesRelaunch() async throws {
        let world = try IconWorld()
        defer { world.tearDown() }
        world.stageDraftAndAlias()
        try await world.openStyle()
        let writesBeforeIcons = world.writes
        #expect(world.engine.anchorSymbol == .lines)
        #expect(world.anchorImages.isEmpty)
        #expect(world.headerLabel == "App icon, Ocean theme")

        try world.press("settings-icon-app-theme-sunset")
        try await world.settle { world.headerLabel == "App icon, Sunset theme" }
        try world.choose(menuBarSymbol: .sparkle)
        try await world.settle { world.engine.anchorSymbol == .sparkle }

        // Two edits, two writes, one anchor image; no placement or capture work was requested.
        #expect(world.writes - writesBeforeIcons == 2)
        #expect(world.anchorImages.count == 1)
        #expect(world.anchorImages.last?.isTemplate == true)
        #expect(world.anchorImages.last?.accessibilityDescription == "Bar Keeper's Friend")
        #expect(world.server.moveRequests.isEmpty)
        #expect(!world.engine.placementInProgress)
        #expect(world.model.hasPendingChanges)
        #expect(world.model.pendingChangeCount == 1)
        world.expectAliasAndIntentIntact()
        #expect(world.selectedThemeIdentifiers == ["settings-icon-app-theme-sunset"])

        // Relaunch: a fresh store, model, and engine read what the user chose and nothing else changed.
        let reloaded = world.store.load()
        #expect(reloaded.appIcon == AppIconChoice(menuBarSymbol: .sparkle, appTheme: .sunset))
        #expect(reloaded.itemAliases == world.model.preferences.itemAliases)
        #expect(reloaded.itemControls == world.model.preferences.itemControls)
        let relaunched = try IconWorld(store: world.store)
        defer { relaunched.tearDown() }
        #expect(relaunched.engine.anchorSymbol == .sparkle)
        #expect(relaunched.model.preferences.appIcon.appTheme == .sunset)
        try await relaunched.openStyle()
        #expect(relaunched.headerLabel == "App icon, Sunset theme")
        #expect(relaunched.selectedThemeIdentifiers == ["settings-icon-app-theme-sunset"])
        #expect(!relaunched.model.hasPendingChanges, "drafts are session-only and must not survive relaunch")
    }

    @Test func reselectingTheCurrentIconWritesNothingAndDefaultRestoresTheShippedArtwork() async throws {
        let world = try IconWorld()
        defer { world.tearDown() }
        try await world.openStyle()

        try world.press("settings-icon-app-theme-ocean")
        try await world.settle { world.headerLabel == "App icon, Ocean theme" }
        try world.choose(menuBarSymbol: .lines)
        await Task.yield()
        #expect(world.writes == 0, "re-choosing the current values must not persist or re-apply")
        #expect(world.anchorImages.isEmpty)

        try world.choose(menuBarSymbol: .tray)
        try await world.settle { world.engine.anchorSymbol == .tray }
        try world.choose(menuBarSymbol: .lines)
        try await world.settle { world.engine.anchorSymbol == .lines }
        #expect(world.anchorImages.count == 2)
        #expect(world.writes == 2)
        #expect(world.store.load().appIcon == .default)
        // Ocean must never echo the currently applied theme; with or without the bundled asset it is
        // the teal-to-blue gradient, so its bottom edge is distinctly blue.
        let ocean = try renderBitmap(AppIconRenderer.appImage(.ocean, size: 128), size: CGSize(width: 128, height: 128))
        let bottom = try #require(ocean.colorAt(x: 64, y: 108)?.usingColorSpace(.deviceRGB))
        #expect(bottom.blueComponent > bottom.redComponent + 0.3, "Ocean bottom edge should be blue, got \(bottom)")
    }

    @Test func importedExportedAndCorruptSettingsKeepOneBadIconKeyFromResettingTheRest() throws {
        var preferences = Preferences.default
        preferences.appIcon = AppIconChoice(menuBarSymbol: .sidebar, appTheme: .forest)
        preferences.itemAliases.setAlias("Clipboard", forKey: "Maccy")
        preferences.itemControls.setHidden(true, forKey: "Maccy")

        let exported = try LayoutConfig(preferences: preferences).encoded()
        let imported = try LayoutConfig.decode(from: exported)
        #expect(imported.preferences == preferences)
        #expect(String(decoding: exported, as: UTF8.self).contains("\"menuBarSymbol\" : \"sidebar\""))

        // A future symbol name degrades only its own field: the valid theme beside it must survive.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        json["appIcon"] = ["menuBarSymbol": "hologram", "appTheme": "forest"]
        let store = PreferencesStore(backing: InMemoryDefaults())
        store.save(preferences)
        let partlyBad = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(partlyBad.appIcon == AppIconChoice(menuBarSymbol: .lines, appTheme: .forest))
        #expect(partlyBad.itemAliases.alias(forKey: "Maccy") == "Clipboard")
        #expect(partlyBad.itemControls.isHidden(forKey: "Maccy"))

        // Both fields wrong, and a non-object value, each fall back to the shipped artwork alone.
        for corrupt in [["menuBarSymbol": "hologram", "appTheme": 7] as Any, "ocean" as Any, 42 as Any] {
            json["appIcon"] = corrupt
            let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(decoded.appIcon == .default)
            #expect(decoded.itemAliases.alias(forKey: "Maccy") == "Clipboard")
        }

        // Older saved files have no key at all and must load unchanged with the shipped artwork.
        json.removeValue(forKey: "appIcon")
        let legacy = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.appIcon == .default)
        #expect(legacy.itemAliases == preferences.itemAliases)
        #expect(store.load() == preferences)
    }

    @Test(arguments: AppIconChoice.MenuBarSymbol.allCases)
    func everyMenuBarSymbolRendersAVisibleTemplateGlyph(symbol: AppIconChoice.MenuBarSymbol) throws {
        #expect(AppIconRenderer.isMenuBarSymbolAvailable(symbol), "\(symbol) must ship with macOS 26")
        let image = AppIconRenderer.menuBarImage(symbol)
        #expect(image.isTemplate)
        #expect(image.accessibilityDescription == "Bar Keeper's Friend")
        let bitmap = try renderBitmap(image, size: CGSize(width: 18, height: 18))
        #expect(opaquePixels(bitmap) > 20, "\(symbol) rendered nothing visible")
    }

    @Test(arguments: AppIconChoice.AppTheme.allCases)
    func everyAppThemeRendersDistinctArtworkWithTheSharedMark(theme: AppIconChoice.AppTheme) throws {
        let image = AppIconRenderer.appImage(theme, size: 128)
        let bitmap = try renderBitmap(image, size: CGSize(width: 128, height: 128))
        // The white sparkle sits in the upper middle of every theme; the corners are transparent margin.
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(Double(bitmap.pixelsHigh) * 0.4)))
        #expect(center.usingColorSpace(.deviceRGB)!.brightnessComponent > 0.9, "\(theme) lost the sparkle")
        let corner = try #require(bitmap.colorAt(x: 1, y: 1))
        #expect(corner.alphaComponent < 0.05, "\(theme) painted over the transparent icon margin")
        if theme != .ocean {
            let ocean = try renderBitmap(AppIconRenderer.appImage(.ocean, size: 128), size: CGSize(width: 128, height: 128))
            let x = bitmap.pixelsWide / 2, y = Int(Double(bitmap.pixelsHigh) * 0.85)
            #expect(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) != ocean.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    "\(theme) must look different from the shipped Ocean icon")
        }
    }

    // MARK: - World

    /// Everything a user touches, wired the way `AppCoordinator` wires it, minus the real status bar.
    @MainActor
    private final class IconWorld {
        /// Mutable recorders the closures write into; the world reads them through `settle`.
        private final class Recorder {
            var writes = 0
            var anchorImages: [NSImage] = []
            weak var engine: CosmeticHideEngine?
        }

        let suite: String
        let defaults: UserDefaults
        let store: PreferencesStore
        let server = FakeWindowServer()
        let model: SettingsModel
        let engine: CosmeticHideEngine
        let hosting: SettingsTestHostingController
        private let recorder = Recorder()
        var writes: Int { recorder.writes }
        var anchorImages: [NSImage] { recorder.anchorImages }

        init(store existing: PreferencesStore? = nil) throws {
            suite = "AppIconWorkflowTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            store = existing ?? PreferencesStore(backing: defaults)
            let preferences = store.load()
            let recorder = self.recorder
            let store = self.store
            model = SettingsModel(
                preferences: preferences, loginItem: SettingsTestLoginItem(), itemsProvider: { [] },
                onChange: { updated in
                    // Mirrors AppCoordinator.handlePreferencesChange: persist, then re-apply.
                    store.save(updated)
                    recorder.writes += 1
                    recorder.engine?.apply(preferences: updated)
                }
            )
            engine = CosmeticHideEngine(
                preferences: preferences, controlWindowIDs: { (90, 91) },
                setDividerCollapsed: { _ in }, setAnchorImage: { recorder.anchorImages.append($0) },
                onPreferencesChanged: { _ in }
            )
            recorder.engine = engine
            engine.hiddenItemController = HiddenItemController(windowServer: server)
            hosting = settingsTestHost(SettingsView(model: model, initialTab: .general))
        }

        func tearDown() {
            engine.uninstall()
            defaults.removePersistentDomain(forName: suite)
        }

        func stageDraftAndAlias() {
            let item = settingsTestItem(7, alias: nil, observedHidden: false)
            model.setPlacement(.hidden, for: item)
            model.preferences.itemAliases.setAlias("Clipboard", for: item.snapshot)
        }

        func expectAliasAndIntentIntact() {
            let item = settingsTestItem(7, observedHidden: false)
            #expect(model.preferences.itemAliases.alias(for: item.snapshot) == "Clipboard")
            #expect(model.hasPendingChange(for: item))
        }

        func openStyle() async throws {
            model.requestedTab = .style
            try #require(await settle { find("settings-icon-menu-bar") != nil })
        }

        var headerLabel: String? { find("settings-identity-icon")?.accessibilityLabel() }

        var selectedThemeIdentifiers: [String] {
            settingsTestAccessibility(hosting.view).compactMap { element in
                guard let id = element.accessibilityIdentifier(), id.hasPrefix("settings-icon-app-theme-"),
                      element.property("isAccessibilitySelected") as? Bool == true else { return nil }
                return id
            }
        }

        func find(_ identifier: String) -> SettingsTestAXElement? {
            settingsTestAccessibility(hosting.view).first { $0.accessibilityIdentifier() == identifier }
        }

        func element(_ identifier: String) throws -> SettingsTestAXElement {
            try #require(find(identifier), "missing \(identifier)")
        }

        func press(_ identifier: String) throws {
            #expect(try element(identifier).accessibilityPerformPress(), "\(identifier) did not accept a press")
        }

        /// The menu-bar picker is a pop-up; its menu items are not reachable off screen, so this
        /// drives the exact binding the picker holds, including its no-change guard.
        func choose(menuBarSymbol: AppIconChoice.MenuBarSymbol) throws {
            _ = try element("settings-icon-menu-bar")
            AppIconSettingsSection.menuBarSymbolBinding(model).wrappedValue = menuBarSymbol
        }

        @discardableResult
        func settle(until condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                hosting.render()
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            return false
        }
    }

    private final class InMemoryDefaults: PreferencesPersisting, @unchecked Sendable {
        private var storage: [String: Data] = [:]
        func data(forKey key: String) -> Data? { storage[key] }
        func set(_ data: Data?, forKey key: String) { storage[key] = data }
    }

    private func renderBitmap(_ image: NSImage, size: CGSize) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func opaquePixels(_ bitmap: NSBitmapImageRep) -> Int {
        settingsTestPixelCount(bitmap) { $0.alphaComponent > 0.5 }
    }
}
