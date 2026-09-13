import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct StyleSettingsTabTests {
    private final class Writes {
        var all: [Preferences] = []
        var count: Int { all.count }
        var isEmpty: Bool { all.isEmpty }
    }

    /// Captures commit timers so tests fire them deterministically instead of waiting.
    @MainActor
    private final class FakeScheduler {
        private(set) var scheduled: [(delay: TimeInterval, fire: @MainActor @Sendable () -> Void)] = []
        private(set) var cancelled = 0

        func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void {
            scheduled.append((delay, fire))
            return { [weak self] in self?.cancelled += 1 }
        }

        func fireLast() { scheduled.last?.fire() }
    }

    private let red = RGBA(red: 1, green: 0, blue: 0)

    private func makeModel(_ style: MenuBarStyle, writes: Writes = Writes()) -> SettingsModel {
        var preferences = Preferences.default
        preferences.menuBarStyle = style
        preferences.itemAliases.setAlias("Clipboard", for: settingsTestItem(1).snapshot)
        return SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { writes.all.append($0) }
        )
    }

    private func makeEditor(_ model: SettingsModel, scheduler: FakeScheduler = FakeScheduler()) -> MenuBarStyleEditor {
        MenuBarStyleEditor(model: model, scheduler: scheduler.schedule)
    }

    private func host(_ model: SettingsModel, scheme: ColorScheme = .light) -> SettingsTestHostingController {
        settingsTestHost(
            StyleSettingsTab(model: model, editor: makeEditor(model))
                .environment(\.colorScheme, scheme).frame(width: 640)
        )
    }

    private func identifiers(in view: NSView) -> [String] {
        settingsTestAccessibility(view).compactMap { $0.accessibilityIdentifier() }
    }

    private func text(in view: NSView) -> String {
        settingsTestAccessibility(view).flatMap { element in
            [settingsTestAccessibilityText(element), element.property("accessibilityTitle") as? String ?? ""]
        }.joined(separator: " ")
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier })
    }

    /// Re-renders until the condition holds; bounded by iterations, never by wall-clock waits.
    private func settle(_ hosting: SettingsTestHostingController, until condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            hosting.render()
            if condition() { return true }
            await Task.yield()
        }
        hosting.render()
        return condition()
    }

    private static let alwaysPresent = ["settings-style-enabled", "settings-style-preview", "settings-style-note"]
    private static let enabledOnly = [
        "settings-style-tint", "settings-style-gradient-enabled", "settings-style-opacity", "settings-style-opacity-value",
        "settings-style-shape", "settings-style-corner-radius", "settings-style-border-width", "settings-style-shadow",
        "settings-style-reset"
    ]

    // MARK: Layout

    @Test func disabledStyleShowsOnlyTheToggleThePreviewAndTheNote() throws {
        let hosting = host(makeModel(.none))
        let ids = identifiers(in: hosting.view)
        for identifier in Self.alwaysPresent {
            #expect(ids.contains(identifier), "\(identifier) must always be present")
        }
        for identifier in Self.enabledOnly + ["settings-style-gradient-end", "settings-style-border-color"] {
            #expect(!ids.contains(identifier), "\(identifier) must be hidden while styling is off")
        }
        #expect(try element("settings-style-enabled", in: hosting.view).isAccessibilityEnabled())
        let content = text(in: hosting.view)
        #expect(content.contains("Style the menu bar"))
        #expect(content.contains("needs no permissions"))
        #expect(content.contains("does not change the menu bar's text or icons"))
        #expect(content.contains("Show menu bar background"))
        #expect(try element("settings-style-preview", in: hosting.view).accessibilityValue() as? String == "Styling off")
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func enabledStyleShowsEveryControlAndConditionalColorWells() throws {
        var style = MenuBarStyle(isEnabled: true, tint: red, opacity: 0.5, cornerRadius: 12, shape: .rounded)
        let plain = host(makeModel(style))
        let plainIDs = identifiers(in: plain.view)
        for identifier in Self.alwaysPresent + Self.enabledOnly {
            #expect(plainIDs.contains(identifier), "\(identifier) must be present while styling is on")
        }
        #expect(!plainIDs.contains("settings-style-gradient-end"))
        #expect(!plainIDs.contains("settings-style-border-color"))
        let content = text(in: plain.view)
        #expect(content.contains("50%"))
        #expect(content.contains("12 pt"))
        #expect(content.contains("None"))
        #expect(content.contains("Reset Style"))
        #expect(try element("settings-style-corner-radius", in: plain.view).isAccessibilityEnabled())

        style.gradientEnd = RGBA(red: 0, green: 0, blue: 1)
        style.borderWidth = 2
        let rich = host(makeModel(style))
        let richIDs = identifiers(in: rich.view)
        #expect(richIDs.contains("settings-style-gradient-end"))
        #expect(richIDs.contains("settings-style-border-color"))
        #expect(text(in: rich.view).contains("2 pt"))
        let preview = try element("settings-style-preview", in: rich.view)
        let value = try #require(preview.accessibilityValue() as? String)
        #expect(value.contains("Rounded"))
        #expect(value.contains("#FF0000"))
        #expect(value.contains("gradient to #0000FF"))
        #expect(value.contains("50% opacity"))
        #expect(value.contains("2 pt border"))
    }

    @Test(arguments: [false, true], [ColorScheme.light, .dark])
    func richestContentFitsTheSettingsWindow(gradient: Bool, scheme: ColorScheme) {
        var style = MenuBarStyle(isEnabled: true, tint: red, opacity: 0.7, cornerRadius: 10, borderWidth: 3, shadowEnabled: true, shape: .pill)
        if gradient { style.gradientEnd = RGBA(red: 0, green: 0, blue: 1) }
        let hosting = host(makeModel(style), scheme: scheme)
        let size = hosting.view.fittingSize
        #expect(size.width <= 640)
        #expect(size.height <= 600, "fitting height was \(size.height)")
        #expect(identifiers(in: hosting.view).contains("settings-style-preview"))
        #expect(identifiers(in: hosting.view).contains("settings-style-gradient-end") == gradient)
    }

    // MARK: Writes

    @Test func togglingOnWritesOnceAndNeverTouchesPlacement() async throws {
        let writes = Writes()
        let model = makeModel(.none, writes: writes)
        let before = model.preferences
        let hosting = host(model)
        _ = try element("settings-style-enabled", in: hosting.view).accessibilityPerformPress()
        #expect(await settle(hosting) {
            model.preferences.menuBarStyle.isEnabled && identifiers(in: hosting.view).contains("settings-style-tint")
        })
        #expect(writes.count == 1)
        #expect(model.preferences.menuBarStyle == MenuBarStyle(isEnabled: true))
        var expected = before
        expected.menuBarStyle = MenuBarStyle(isEnabled: true)
        #expect(writes.all.last == expected)
        #expect(!model.hasPendingChanges)
        #expect(!model.placementInProgress)
        #expect(!hosting.testWindow.isVisible)

        _ = try element("settings-style-enabled", in: hosting.view).accessibilityPerformPress()
        #expect(await settle(hosting) { !model.preferences.menuBarStyle.isEnabled })
        #expect(writes.count == 2)
        #expect(writes.all.last == before)
    }

    @Test func resetRestoresTheDefaultLookWithOneWriteAndKeepsStylingOn() async throws {
        let writes = Writes()
        let custom = MenuBarStyle(
            isEnabled: true, tint: red, gradientEnd: RGBA(red: 0, green: 0, blue: 1), opacity: 0.9,
            cornerRadius: 3, borderWidth: 4, borderColor: .black, shadowEnabled: true, shape: .pill
        )
        let model = makeModel(custom, writes: writes)
        let hosting = host(model)
        let reset = try element("settings-style-reset", in: hosting.view)
        #expect(reset.isAccessibilityEnabled())
        #expect(reset.accessibilityPerformPress())
        #expect(await settle(hosting) { model.preferences.menuBarStyle == MenuBarStyle(isEnabled: true) })
        #expect(writes.count == 1)
        #expect(writes.all.last?.menuBarStyle == MenuBarStyle(isEnabled: true))
        #expect(writes.all.last?.itemAliases == model.preferences.itemAliases)
        let ids = identifiers(in: hosting.view)
        #expect(ids.contains("settings-style-tint"))
        #expect(!ids.contains("settings-style-gradient-end"))
        #expect(!ids.contains("settings-style-border-color"))
        #expect(!(try element("settings-style-reset", in: hosting.view).isAccessibilityEnabled()))
    }

    @Test func cornerRadiusStepperIsInertForFullAndStepsForRounded() async throws {
        let writes = Writes()
        let model = makeModel(MenuBarStyle(isEnabled: true, cornerRadius: 19, shape: .full), writes: writes)
        let hosting = host(model)
        let full = try element("settings-style-corner-radius", in: hosting.view)
        #expect(!full.isAccessibilityEnabled())
        full.performAccessibilityAction("accessibilityPerformIncrement")
        hosting.render()
        #expect(model.preferences.menuBarStyle.cornerRadius == 19)
        #expect(writes.isEmpty)

        model.preferences.menuBarStyle.shape = .rounded
        #expect(await settle(hosting) {
            (try? element("settings-style-corner-radius", in: hosting.view).isAccessibilityEnabled()) == true
        })
        #expect(writes.count == 1)
        let stepper = try element("settings-style-corner-radius", in: hosting.view)
        #expect(stepper.accessibilityRole() == .incrementor)
        stepper.performAccessibilityAction("accessibilityPerformIncrement")
        #expect(await settle(hosting) { model.preferences.menuBarStyle.cornerRadius == 20 })
        #expect(writes.count == 2)
        stepper.performAccessibilityAction("accessibilityPerformIncrement")
        hosting.render()
        #expect(model.preferences.menuBarStyle.cornerRadius == 20)
        #expect(writes.count == 2)
        #expect(text(in: hosting.view).contains("20 pt"))
    }

    @Test func borderStepperRevealsTheColorWellAndStopsAtTheRangeEnds() async throws {
        let writes = Writes()
        let model = makeModel(MenuBarStyle(isEnabled: true), writes: writes)
        let hosting = host(model)
        #expect(!identifiers(in: hosting.view).contains("settings-style-border-color"))
        let stepper = try element("settings-style-border-width", in: hosting.view)
        stepper.performAccessibilityAction("accessibilityPerformDecrement")
        hosting.render()
        #expect(model.preferences.menuBarStyle.borderWidth == 0)
        #expect(writes.isEmpty)

        stepper.performAccessibilityAction("accessibilityPerformIncrement")
        #expect(await settle(hosting) {
            model.preferences.menuBarStyle.borderWidth == 1 && identifiers(in: hosting.view).contains("settings-style-border-color")
        })
        #expect(writes.count == 1)
        #expect(text(in: hosting.view).contains("1 pt"))
        for _ in 0..<5 {
            try element("settings-style-border-width", in: hosting.view).performAccessibilityAction("accessibilityPerformIncrement")
            hosting.render()
        }
        #expect(await settle(hosting) { model.preferences.menuBarStyle.borderWidth == 4 })
        #expect(writes.count == 4)
        #expect(text(in: hosting.view).contains("4 pt"))
    }

    @Test func valuesChangedElsewhereAreReflectedWithoutExtraWrites() async {
        let writes = Writes()
        let model = makeModel(MenuBarStyle(isEnabled: true, opacity: 0.5), writes: writes)
        let hosting = host(model)
        #expect(text(in: hosting.view).contains("50%"))
        var imported = model.preferences
        imported.menuBarStyle = MenuBarStyle(isEnabled: true, opacity: 0.25, cornerRadius: 4, shape: .pill)
        model.preferences = imported
        #expect(await settle(hosting) {
            let content = text(in: hosting.view)
            return content.contains("25%") && content.contains("4 pt") && !content.contains("50%")
        })
        #expect(writes.count == 1)
    }

    @Test func pendingStreamingEditIsDisplayedAndWrittenWhenTheTabDisappears() async {
        let writes = Writes()
        let model = makeModel(MenuBarStyle(isEnabled: true, opacity: 0.5), writes: writes)
        let scheduler = FakeScheduler()
        let editor = makeEditor(model, scheduler: scheduler)
        let visibility = StyleTabVisibility()
        let hosting = settingsTestHost(RemovableStyleTab(model: model, editor: editor, visibility: visibility).frame(width: 640))

        var streamed = editor.displayed
        streamed.opacity = 0.9
        editor.stage(streamed)
        #expect(await settle(hosting) { text(in: hosting.view).contains("90%") })
        #expect(writes.isEmpty)
        #expect(model.preferences.menuBarStyle.opacity == 0.5)

        visibility.shown = false
        #expect(await settle(hosting) { writes.count == 1 })
        #expect(model.preferences.menuBarStyle.opacity == 0.9)
        #expect(editor.pending == nil)
        scheduler.fireLast()
        #expect(writes.count == 1)
    }

    // MARK: Debounced editor

    @Test func streamingEditsCoalesceIntoOneWriteWhenTheTimerFires() {
        let writes = Writes()
        let model = makeModel(MenuBarStyle(isEnabled: true), writes: writes)
        let scheduler = FakeScheduler()
        let editor = makeEditor(model, scheduler: scheduler)

        var first = editor.displayed
        first.opacity = 0.6
        editor.stage(first)
        var second = first
        second.opacity = 0.7
        editor.stage(second)
        var third = second
        third.tint = red
        editor.stage(third)

        #expect(writes.isEmpty)
        #expect(editor.pending == third.normalized())
        #expect(editor.displayed == third.normalized())
        #expect(model.preferences.menuBarStyle == MenuBarStyle(isEnabled: true))
        #expect(scheduler.scheduled.count == 3)
        #expect(scheduler.cancelled == 2)
        #expect(scheduler.scheduled.allSatisfy { $0.delay == MenuBarStyleEditor.commitDelay })

        scheduler.fireLast()
        #expect(writes.count == 1)
        #expect(model.preferences.menuBarStyle == third.normalized())
        #expect(editor.pending == nil)
        editor.flush()
        #expect(writes.count == 1)
        #expect(!model.hasPendingChanges)
    }

    @Test func commitWritesImmediatelyAndFoldsInThePendingEdit() {
        let writes = Writes()
        let model = makeModel(MenuBarStyle(isEnabled: true), writes: writes)
        let scheduler = FakeScheduler()
        let editor = makeEditor(model, scheduler: scheduler)

        var streamed = editor.displayed
        streamed.opacity = 0.8
        editor.stage(streamed)
        var discrete = editor.displayed
        discrete.shape = .pill
        editor.commit(discrete)
        #expect(writes.count == 1)
        #expect(model.preferences.menuBarStyle == MenuBarStyle(isEnabled: true, opacity: 0.8, shape: .pill))
        #expect(scheduler.cancelled == 1)
        #expect(editor.pending == nil)

        // A stale timer firing after the commit has nothing left to write.
        scheduler.fireLast()
        #expect(writes.count == 1)
        editor.commit(model.preferences.menuBarStyle)
        #expect(writes.count == 1)
    }

    @Test func stagingTheDisplayedValueOrItsUnnormalizedTwinIsANoOp() {
        let writes = Writes()
        let model = makeModel(MenuBarStyle(isEnabled: true), writes: writes)
        let scheduler = FakeScheduler()
        let editor = makeEditor(model, scheduler: scheduler)
        editor.stage(editor.displayed)
        #expect(scheduler.scheduled.isEmpty)
        var twin = editor.displayed
        twin.opacity = 7 // normalizes to 1
        editor.stage(twin)
        #expect(scheduler.scheduled.count == 1)
        var same = editor.displayed
        same.opacity = 1
        editor.stage(same)
        #expect(scheduler.scheduled.count == 1)
        scheduler.fireLast()
        #expect(writes.count == 1)
        #expect(model.preferences.menuBarStyle.opacity == 1)
    }

    @Test func flushDropsAPendingEditWhenTheSavedStyleMovedUnderneath() {
        let writes = Writes()
        let model = makeModel(MenuBarStyle(isEnabled: true), writes: writes)
        let scheduler = FakeScheduler()
        let editor = makeEditor(model, scheduler: scheduler)
        var streamed = editor.displayed
        streamed.tint = red
        editor.stage(streamed)

        let imported = MenuBarStyle(isEnabled: true, shape: .rounded)
        model.preferences.menuBarStyle = imported
        #expect(writes.count == 1)
        scheduler.fireLast()
        #expect(writes.count == 1)
        #expect(model.preferences.menuBarStyle == imported)
        #expect(editor.pending == nil)
        #expect(editor.displayed == imported)
    }

    // MARK: Color bridging

    @Test func colorBridgingRoundTripsThroughSwiftUI() {
        for color in [red, RGBA(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5), .white, .black, MenuBarStyle.defaultTint] {
            let bridged = RGBA(color.color)
            #expect(bridged.normalized() == color.normalized(), "\(color.hexString)")
        }
        #expect(RGBA(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)) == red)
    }

    // MARK: Preview

    private func redPixels(in view: NSView) throws -> Int {
        settingsTestPixelCount(try settingsTestBitmap(view)) { color in
            color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1 && color.alphaComponent > 0.9
        }
    }

    @Test func previewPaintsTheTintBehindFakeItemsAndTheNotch() throws {
        let full = settingsTestHost(MenuBarStylePreview(style: MenuBarStyle(isEnabled: true, tint: red, opacity: 1)).frame(width: 640))
        let fullRed = try redPixels(in: full.view)
        #expect(fullRed > 5000)
        #expect(full.view.fittingSize.height == MenuBarStylePreview.menuBarHeight + MenuBarStylePreview.desktopHeight)

        let pill = settingsTestHost(MenuBarStylePreview(
            style: MenuBarStyle(isEnabled: true, tint: red, opacity: 1, cornerRadius: 20, shape: .pill)
        ).frame(width: 640))
        let pillRed = try redPixels(in: pill.view)
        #expect(pillRed > 2000)
        #expect(pillRed < fullRed)

        let off = settingsTestHost(MenuBarStylePreview(style: .none).frame(width: 640))
        #expect(try redPixels(in: off.view) == 0)

        let translucent = settingsTestHost(MenuBarStylePreview(style: MenuBarStyle(isEnabled: true, tint: red, opacity: 0.3)).frame(width: 640))
        #expect(try redPixels(in: translucent.view) == 0)
        #expect(settingsTestPixelCount(try settingsTestBitmap(translucent.view)) { $0.redComponent > 0.4 && $0.blueComponent < 0.7 } > 1000)
    }

    @Test func previewGeometryUsesTheFakeNotchAndReportsItsStyle() throws {
        let layout = try #require(MenuBarStylePreview.layout(style: MenuBarStyle(isEnabled: true, shape: .pill), width: 640))
        #expect(layout.windowFrame == CGRect(x: 0, y: 400 - 24, width: 640, height: 24))
        #expect(layout.segments.count == 2)
        #expect(layout.segments[0].rect.maxX == (640 - MenuBarStylePreview.notchWidth) / 2 - MenuBarStyleGeometry.pillHorizontalInset)
        #expect(layout.segments[1].rect.minX == (640 + MenuBarStylePreview.notchWidth) / 2 + MenuBarStyleGeometry.pillHorizontalInset)
        #expect(MenuBarStylePreview.layout(style: .none, width: 640) == nil)
        #expect(MenuBarStylePreview.layout(style: MenuBarStyle(isEnabled: true, shape: .full), width: 640)?.segments.count == 1)

        #expect(MenuBarStylePreview.description(of: .none) == "Styling off")
        let described = MenuBarStylePreview.description(of: MenuBarStyle(
            isEnabled: true, tint: red, opacity: 0.45, borderWidth: 1, shadowEnabled: true, shape: .pill
        ))
        #expect(described == "Pill, tint #FF0000, 45% opacity, 1 pt border, shadow")
    }
}

/// Lets a test remove the tab from the hierarchy to drive its disappearance.
@MainActor
@Observable
private final class StyleTabVisibility {
    var shown = true
}

private struct RemovableStyleTab: View {
    let model: SettingsModel
    let editor: MenuBarStyleEditor
    let visibility: StyleTabVisibility

    var body: some View {
        if visibility.shown {
            StyleSettingsTab(model: model, editor: editor)
        } else {
            Text("Tab removed")
        }
    }
}

private extension SettingsTestAXElement {
    /// Increment/decrement are not on the shared helper. AppKit steppers perform the action but
    /// report false, so callers verify the model instead of this return value.
    @discardableResult
    func performAccessibilityAction(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard isAccessibilityEnabled(), object.responds(to: selector) else { return false }
        typealias Perform = @convention(c) (AnyObject, Selector) -> Bool
        let perform = unsafeBitCast(object.method(for: selector), to: Perform.self)
        return perform(object, selector)
    }
}
