import AppKit
import BarKeepersFriendCore
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct GroupStatusItemsControllerTests {

    @Test func updateInstallsOneStatusItemPerGroupThroughTheFactoryOnly() throws {
        let factory = FakeGroupStatusItemFactory()
        var activated: [CGWindowID] = []
        let controller = GroupStatusItemsController(factory: factory) { activated.append($0) }
        let work = ItemGroup(name: "Work", ownerKeys: ["Maccy", "Itsycal"])
        let tools = ItemGroup(name: "Tools")
        controller.update(groups: [work, tools], items: [], aliases: ItemAliasStore())

        #expect(factory.created.count == 2)
        #expect(controller.installedGroupIDs == [work.id, tools.id])
        #expect(factory.created.map(\.autosaveName) == [
            "BKFGroup-\(work.id.uuidString)", "BKFGroup-\(tools.id.uuidString)"
        ])
        for handle in factory.created {
            let name = try #require(handle.autosaveName)
            #expect(name.hasPrefix(HiddenItemsResolver.controlItemNamePrefix))
            #expect(!ControlItem.Identifier.allCases.map(\.rawValue).contains(name))
            #expect(handle.image === GroupStatusItemIcon.placeholder)
            #expect(handle.title == nil)
            #expect(handle.removeCount == 0)
            #expect(handle.onClick != nil)
        }
        #expect(factory.created[0].toolTip == "Work: 2 items, 2 not running")
        #expect(factory.created[1].toolTip == "Tools: no items")
        #expect(activated.isEmpty)

        // A second identical update must not create, remove, or re-render anything.
        controller.update(groups: [work, tools], items: [], aliases: ItemAliasStore())
        #expect(factory.created.count == 2)
        #expect(factory.created.map(\.imageWrites) == [1, 1])
        #expect(factory.created.map(\.toolTipWrites) == [1, 1])
    }

    @Test func updateKeepsSurvivorsRemovesDeletedGroupsAndAddsNewOnes() throws {
        let factory = FakeGroupStatusItemFactory()
        let controller = GroupStatusItemsController(factory: factory) { _ in }
        let work = ItemGroup(name: "Work", ownerKeys: ["Maccy"])
        let home = ItemGroup(name: "Home", ownerKeys: ["Wisp"])
        controller.update(groups: [work, home], items: [], aliases: ItemAliasStore())
        let workHandle = try #require(factory.created.first)
        let homeHandle = try #require(factory.created.last)

        var renamed = work
        renamed.name = "Focus"
        renamed.appendKey("Itsycal")
        let tools = ItemGroup(name: "Tools")
        controller.update(groups: [renamed, tools], items: [], aliases: ItemAliasStore())

        #expect(factory.created.count == 3)
        #expect(factory.created[0] === workHandle)
        #expect(workHandle.removeCount == 0)
        #expect(workHandle.toolTip == "Focus: 2 items, 2 not running")
        #expect(homeHandle.removeCount == 1)
        #expect(homeHandle.onClick == nil)
        #expect(controller.installedGroupIDs == [work.id, tools.id])
        #expect(factory.created[2].autosaveName == "BKFGroup-\(tools.id.uuidString)")

        // A click that arrives for a deleted group presents nothing.
        controller.presentMenu(forGroupID: home.id)
        #expect(homeHandle.presentedMenus.isEmpty)

        controller.removeAll()
        #expect(controller.installedGroupIDs.isEmpty)
        #expect(workHandle.removeCount == 1)
        #expect(factory.created[2].removeCount == 1)
        #expect(homeHandle.removeCount == 1)
        controller.removeAll()
        #expect(workHandle.removeCount == 1)

        controller.update(groups: [tools], items: [], aliases: ItemAliasStore())
        #expect(factory.created.count == 4)
        #expect(controller.installedGroupIDs == [tools.id])
    }

    @Test func groupsBeyondTheMaximumGetNoStatusItem() {
        let factory = FakeGroupStatusItemFactory()
        let controller = GroupStatusItemsController(factory: factory) { _ in }
        let groups = (0..<25).map { ItemGroup(name: "G\($0)") }
        controller.update(groups: groups, items: [], aliases: ItemAliasStore())
        #expect(factory.created.count == ItemGroupLibrary.maxGroups)
        #expect(controller.installedGroupIDs == Set(groups.prefix(20).map(\.id)))
    }

    @Test func menuModelListsRunningAliasedUnactivatableAndMissingMembers() throws {
        let factory = FakeGroupStatusItemFactory()
        var activated: [CGWindowID] = []
        let controller = GroupStatusItemsController(factory: factory) { activated.append($0) }
        let maccyRight = groupTestItem(11, owner: "Maccy", x: 100)
        let maccyLeft = groupTestItem(12, owner: "Maccy", x: 50)
        var dead = groupTestItem(20, owner: "Dead", x: 200)
        dead.isDisabled = true
        let other = groupTestItem(30, owner: "Other", x: 300)
        var aliases = ItemAliasStore()
        aliases.setAlias("Clipboard", forKey: "Maccy")
        aliases.setAlias("Calendar", forKey: "Itsycal")
        let group = ItemGroup(name: "Work", ownerKeys: ["Maccy", "Itsycal", "Dead"])
        controller.update(
            groups: [group], items: [maccyRight, maccyLeft, dead, other], aliases: aliases,
            capturedGlyphWindowIDs: [12, 30]
        )

        let entries = controller.menuModel(for: group)
        #expect(entries.map(\.windowID) == [12, 11, nil, 20])
        #expect(entries.map(\.ownerKey) == ["Maccy", "Maccy", "Itsycal", "Dead"])
        #expect(entries.map(\.menuTitle) == ["Clipboard", "Clipboard", "Calendar (not running)", "Dead"])
        #expect(entries.map(\.isEnabled) == [true, true, false, false])
        #expect(entries.map(\.availability) == [.available, .available, .notRunning, .unactivatable])
        #expect(entries.map(\.isGlyph) == [true, false, false, false])
        #expect(entries[0].image === maccyLeft.image)
        #expect(entries[1].image === maccyRight.image)
        #expect(entries[2].image == nil)
        #expect(entries[3].image === dead.image)
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(!entries.contains { $0.ownerKey == "Other" })

        let handle = try #require(factory.created.first)
        #expect(handle.toolTip == "Work: 3 items, 1 not running")
        let click = try #require(handle.onClick)
        click()
        let menu = try #require(handle.presentedMenus.last)
        #expect(handle.presentedMenus.count == 1)
        #expect(!menu.autoenablesItems)
        #expect(menu.items.map(\.title) == ["Clipboard", "Clipboard", "Calendar (not running)", "Dead"])
        #expect(menu.items.map(\.isEnabled) == [true, true, false, false])
        #expect(menu.items.allSatisfy { $0.target === controller })
        #expect(menu.items[0].image?.size == GroupStatusItemIcon.menuSize)
        #expect(menu.items[0].image?.isTemplate == true)
        #expect(menu.items[1].image?.isTemplate == false)
        #expect(menu.items[2].image == nil)
        #expect((menu.items[2].representedObject as? NSNumber) == nil)
        #expect(menu.items[3].toolTip == "This item could not be opened.")
        // Shared cached images are never mutated into templates.
        #expect(!maccyLeft.image.isTemplate)

        controller.menuEntrySelected(menu.items[2])
        #expect(activated.isEmpty)
        controller.menuEntrySelected(menu.items[0])
        controller.menuEntrySelected(menu.items[1])
        controller.menuEntrySelected(menu.items[3])
        #expect(activated == [12, 11, 20])
    }

    @Test func emptyGroupMenuExplainsItselfWithoutActions() throws {
        let factory = FakeGroupStatusItemFactory()
        var activated: [CGWindowID] = []
        let controller = GroupStatusItemsController(factory: factory) { activated.append($0) }
        let group = ItemGroup(name: "Empty")
        controller.update(groups: [group], items: [groupTestItem(1, owner: "Maccy", x: 0)], aliases: ItemAliasStore())
        #expect(controller.menuModel(for: group).isEmpty)
        let menu = controller.makeMenu(for: group)
        #expect(!menu.autoenablesItems)
        #expect(menu.items.map(\.title) == ["No items in this group"])
        #expect(menu.items.map(\.isEnabled) == [false])
        #expect(menu.items[0].action == nil)
        #expect(activated.isEmpty)
    }

    @Test func groupIconFollowsTheFirstCapturedGlyphAndFallsBackToTheSymbol() throws {
        let factory = FakeGroupStatusItemFactory()
        let controller = GroupStatusItemsController(factory: factory) { _ in }
        let first = groupTestItem(1, owner: "First", x: 0)
        let second = groupTestItem(2, owner: "Second", x: 30)
        let group = ItemGroup(name: "Work", ownerKeys: ["First", "Second"])

        controller.update(groups: [group], items: [first, second], aliases: ItemAliasStore())
        let handle = try #require(factory.created.first)
        #expect(handle.image === GroupStatusItemIcon.placeholder)
        #expect(handle.imageWrites == 1)

        // Only app-icon fallbacks so far: the second member's glyph wins over the first's fallback.
        controller.update(groups: [group], items: [first, second], aliases: ItemAliasStore(), capturedGlyphWindowIDs: [2])
        let secondIcon = try #require(handle.image)
        #expect(secondIcon !== GroupStatusItemIcon.placeholder)
        #expect(secondIcon.size == GroupStatusItemIcon.statusSize)
        #expect(secondIcon.isTemplate)
        #expect(!second.image.isTemplate)
        #expect(handle.imageWrites == 2)

        controller.update(groups: [group], items: [first, second], aliases: ItemAliasStore(), capturedGlyphWindowIDs: [1, 2])
        let firstIcon = try #require(handle.image)
        #expect(firstIcon !== secondIcon)
        #expect(firstIcon.isTemplate)
        #expect(handle.imageWrites == 3)

        // Same glyph source again: no re-render.
        controller.update(groups: [group], items: [first, second], aliases: ItemAliasStore(), capturedGlyphWindowIDs: [1, 2])
        #expect(handle.image === firstIcon)
        #expect(handle.imageWrites == 3)

        // A freshly captured image for the same window replaces the rendered icon.
        let refreshed = groupTestItem(1, owner: "First", x: 0)
        controller.update(groups: [group], items: [refreshed, second], aliases: ItemAliasStore(), capturedGlyphWindowIDs: [1, 2])
        #expect(handle.image !== firstIcon)
        #expect(handle.imageWrites == 4)

        controller.update(groups: [group], items: [], aliases: ItemAliasStore())
        #expect(handle.image === GroupStatusItemIcon.placeholder)
        #expect(handle.toolTip == "Work: 2 items, 2 not running")
    }

    @Test func fittedIconsPreserveAspectRatioAndLeaveTheSourceUntouched() throws {
        let wide = NSImage(size: CGSize(width: 40, height: 10), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        let fitted = try #require(GroupStatusItemIcon.fitted(wide, in: GroupStatusItemIcon.statusSize, template: true))
        #expect(fitted.size == GroupStatusItemIcon.statusSize)
        #expect(fitted.isTemplate)
        #expect(!wide.isTemplate)
        #expect(wide.size == CGSize(width: 40, height: 10))
        #expect(GroupStatusItemIcon.fitted(NSImage(size: .zero), in: GroupStatusItemIcon.menuSize, template: false) == nil)
        #expect(GroupStatusItemIcon.statusIcon(glyph: nil) === GroupStatusItemIcon.placeholder)
        #expect(GroupStatusItemIcon.statusIcon(glyph: NSImage(size: .zero)) === GroupStatusItemIcon.placeholder)
        #expect(GroupStatusItemIcon.placeholder.isTemplate)
    }

    @Test func toolTipCountsMembersAndMissingWindows() {
        #expect(GroupStatusItemsController.toolTip(name: "Work", memberCount: 0, runningCount: 0) == "Work: no items")
        #expect(GroupStatusItemsController.toolTip(name: "Work", memberCount: 1, runningCount: 1) == "Work: 1 item")
        #expect(GroupStatusItemsController.toolTip(name: "Work", memberCount: 1, runningCount: 0) == "Work: 1 item, 1 not running")
        #expect(GroupStatusItemsController.toolTip(name: "Work", memberCount: 3, runningCount: 3) == "Work: 3 items")
        #expect(GroupStatusItemsController.toolTip(name: "Work", memberCount: 3, runningCount: 5) == "Work: 3 items")
    }

    @Test func newGroupSlotIsSeededJustRightOfTheAnchorExactlyOnce() throws {
        let suite = "GroupStatusItemsControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let name = GroupStatusItemsController.autosaveName(for: UUID())
        let key = GroupStatusItemSlots.preferredPositionKey(name)
        let anchorKey = GroupStatusItemSlots.preferredPositionKey("BKFAnchor")
        #expect(key == "NSStatusItem Preferred Position \(name)")

        // Without a saved anchor slot there is nothing to place relative to.
        #expect(GroupStatusItemSlots.seedIfNeeded(autosaveName: name, defaults: defaults) == nil)
        #expect(defaults.object(forKey: key) == nil)

        defaults.set(412.0, forKey: anchorKey)
        #expect(GroupStatusItemSlots.seedIfNeeded(autosaveName: name, defaults: defaults) == 411)
        #expect(defaults.double(forKey: key) == 411)
        #expect(ControlItemOrder.repairedDividerPosition(anchor: 412, divider: 411) != nil)

        // A remembered slot is the user's arrangement and must survive the anchor moving.
        defaults.set(900.0, forKey: anchorKey)
        #expect(GroupStatusItemSlots.seedIfNeeded(autosaveName: name, defaults: defaults) == nil)
        #expect(defaults.double(forKey: key) == 411)
        #expect(defaults.double(forKey: anchorKey) == 900)
    }

    @Test func floatingBarCacheFeedsGroupMenusWithoutCapturingAgain() async throws {
        let tucked = MenuBarItemSnapshot(
            windowID: 2, ownerPID: -1, ownerBundleID: "Wisp", title: "Item-0",
            frame: CGRect(x: -60, y: 0, width: 22, height: 22)
        )
        let captured = MenuBarItemSnapshot(
            windowID: 1, ownerPID: -1, ownerBundleID: "Maccy", title: "Item-0",
            frame: CGRect(x: 100, y: 0, width: 22, height: 22)
        )
        let shown = MenuBarItemSnapshot(
            windowID: 3, ownerPID: -1, ownerBundleID: "Shown", title: "Item-0",
            frame: CGRect(x: 1200, y: 0, width: 22, height: 22)
        )
        let server = FakeWindowServer(items: [tucked, captured, shown])
        var preferences = Preferences.default
        preferences.itemAliases.setAlias("Clipboard", forKey: "Maccy")
        var captureCalls = 0
        let glyph = try groupTestGlyph(side: 8)
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in captureCalls += 1; return [1: glyph] },
            preferences: preferences, attribute: { $0 }, activateWithAX: { _, _, _ in false }
        )
        #expect(bar.cachedHiddenItems().isEmpty)
        #expect(bar.capturedGlyphWindowIDs.isEmpty)

        // Only the on-screen member captures; the tucked one gets the app-icon fallback.
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(captureCalls == 1)
        let cached = bar.cachedHiddenItems()
        #expect(cached.map(\.id) == [2, 1])
        #expect(cached.map(\.displayName) == ["Wisp", "Clipboard"])
        #expect(cached.map(\.alias) == [nil, "Clipboard"])
        #expect(cached.allSatisfy { !$0.isDisabled })
        #expect(bar.capturedGlyphWindowIDs == [1])
        #expect(cached[1].image.size == CGSize(width: 8, height: 8))
        let again = bar.cachedHiddenItems()
        #expect(again.count == cached.count)
        #expect(zip(again, cached).allSatisfy { $0.image === $1.image })
        #expect(captureCalls == 1)

        let factory = FakeGroupStatusItemFactory()
        var activated: [CGWindowID] = []
        let controller = GroupStatusItemsController(factory: factory) { activated.append($0) }
        let group = ItemGroup(name: "Work", ownerKeys: ["Wisp", "Maccy", "Shown"])
        controller.update(
            groups: [group], items: cached, aliases: preferences.itemAliases,
            capturedGlyphWindowIDs: bar.capturedGlyphWindowIDs
        )
        let entries = controller.menuModel(for: group)
        #expect(entries.map(\.menuTitle) == ["Wisp", "Clipboard", "Shown (not running)"])
        #expect(entries.map(\.isGlyph) == [false, true, false])
        #expect(entries.map(\.isEnabled) == [true, true, false])
        #expect(entries[0].image === cached[0].image)
        #expect(entries[1].image === cached[1].image)
        let handle = try #require(factory.created.first)
        #expect(handle.image !== GroupStatusItemIcon.placeholder)
        #expect(handle.toolTip == "Work: 3 items, 1 not running")

        // Selecting an entry reaches the injected activation, never the window server directly.
        controller.menuEntrySelected(controller.makeMenu(for: group).items[1])
        #expect(activated == [1])
        #expect(server.clickedWindowIDs.isEmpty)
        #expect(captureCalls == 1)
    }
}

@MainActor
func groupTestGlyph(side: Int) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return try #require(context.makeImage())
}

@MainActor
func groupTestItem(_ id: CGWindowID, owner: String?, x: CGFloat, isDisabled: Bool = false) -> FloatingBarItem {
    let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
        NSColor.black.setFill()
        rect.fill()
        return true
    }
    return FloatingBarItem(
        snapshot: MenuBarItemSnapshot(
            windowID: id, ownerPID: 1, ownerBundleID: owner, title: "Item-0",
            frame: CGRect(x: x, y: 0, width: 22, height: 22)
        ),
        image: image, isDisabled: isDisabled
    )
}

@MainActor
final class FakeGroupStatusItem: GroupStatusItemHandle {
    let autosaveName: String?
    private(set) var imageWrites = 0
    private(set) var toolTipWrites = 0
    private(set) var presentedMenus: [NSMenu] = []
    private(set) var removeCount = 0
    var onClick: (@MainActor () -> Void)?
    var title: String?

    var image: NSImage? {
        didSet { imageWrites += 1 }
    }

    var toolTip: String? {
        didSet { toolTipWrites += 1 }
    }

    init(autosaveName: String) {
        self.autosaveName = autosaveName
    }

    func present(_ menu: NSMenu) {
        presentedMenus.append(menu)
    }

    func remove() {
        removeCount += 1
    }
}

@MainActor
final class FakeGroupStatusItemFactory: GroupStatusItemFactory {
    private(set) var created: [FakeGroupStatusItem] = []

    func makeStatusItem(autosaveName: String) -> any GroupStatusItemHandle {
        let handle = FakeGroupStatusItem(autosaveName: autosaveName)
        created.append(handle)
        return handle
    }
}
