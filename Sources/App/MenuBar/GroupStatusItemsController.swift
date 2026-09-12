import AppKit
import BarKeepersFriendCore

/// The status-item surface the group controller drives. Tests supply a fake; only
/// `SystemGroupStatusItem` touches `NSStatusBar`.
@MainActor
protocol GroupStatusItemHandle: AnyObject {
    var autosaveName: String? { get }
    var image: NSImage? { get set }
    var title: String? { get set }
    var toolTip: String? { get set }
    var onClick: (@MainActor () -> Void)? { get set }
    /// Menu presentation seam: pops `menu` from the status item.
    func present(_ menu: NSMenu)
    func remove()
}

@MainActor
protocol GroupStatusItemFactory {
    /// The name is needed before creation so the saved slot can be seeded ahead of AppKit reading it.
    func makeStatusItem(autosaveName: String) -> any GroupStatusItemHandle
}

/// One entry of a group's menu; `windowID` is nil when no window of that owner is present.
struct GroupMenuEntry: Identifiable {
    enum Availability: Equatable, Sendable {
        case available, notRunning, unactivatable
    }

    let ownerKey: String
    let windowID: CGWindowID?
    /// Alias-aware display name without any availability suffix.
    let title: String
    /// The cached image as held by the floating bar cache; nil for an absent owner.
    let image: NSImage?
    /// True when `image` is a captured menu bar glyph rather than an app-icon fallback.
    let isGlyph: Bool
    let availability: Availability

    var id: String { windowID.map { "\(ownerKey)#\($0)" } ?? ownerKey }
    var isEnabled: Bool { availability == .available }
    var menuTitle: String { availability == .notRunning ? "\(title) (not running)" : title }
}

/// Owns one status item per group and pops a menu of the group's items on click. Activation goes
/// through the floating bar's own path; nothing here enumerates, captures, or moves items.
@MainActor
final class GroupStatusItemsController: NSObject {
    /// Retains the source glyph: a released image's address can be reused by its replacement.
    private struct IconSignature: Equatable {
        let windowID: CGWindowID?
        let image: NSImage?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.windowID == rhs.windowID && lhs.image === rhs.image
        }
    }

    private struct Installed {
        let handle: any GroupStatusItemHandle
        var iconSignature: IconSignature?
        var toolTip: String?
    }

    private let factory: any GroupStatusItemFactory
    private let activate: @MainActor (CGWindowID) -> Void
    private var installed: [UUID: Installed] = [:]
    private var groups: [ItemGroup] = []
    private var items: [FloatingBarItem] = []
    private var aliases = ItemAliasStore()
    private var capturedGlyphWindowIDs: Set<CGWindowID> = []

    var installedGroupIDs: Set<UUID> { Set(installed.keys) }

    init(
        factory: any GroupStatusItemFactory = SystemGroupStatusItemFactory(),
        activate: @escaping @MainActor (CGWindowID) -> Void
    ) {
        self.factory = factory
        self.activate = activate
        super.init()
    }

    /// Distinct from the anchor/divider names (`BKFAnchor`/`BKFHidden`), which must never be reused.
    static func autosaveName(for groupID: UUID) -> String {
        "BKFGroup-\(groupID.uuidString)"
    }

    /// Diffs against the installed items: survivors keep their status item (and its slot), deleted
    /// groups lose theirs, new groups get one. Cheap enough to call after every capture.
    func update(
        groups: [ItemGroup],
        items: [FloatingBarItem],
        aliases: ItemAliasStore,
        capturedGlyphWindowIDs: Set<CGWindowID> = []
    ) {
        self.groups = ItemGroupLibrary.normalized(groups)
        self.items = items
        self.aliases = aliases
        self.capturedGlyphWindowIDs = capturedGlyphWindowIDs

        let liveIDs = Set(self.groups.map(\.id))
        for (id, entry) in installed where !liveIDs.contains(id) {
            entry.handle.onClick = nil
            entry.handle.remove()
            installed[id] = nil
        }
        for group in self.groups {
            if installed[group.id] == nil {
                let handle = factory.makeStatusItem(autosaveName: Self.autosaveName(for: group.id))
                let id = group.id
                handle.onClick = { [weak self] in self?.presentMenu(forGroupID: id) }
                installed[group.id] = Installed(handle: handle)
            }
            refreshAppearance(of: group)
        }
    }

    /// Removing a status item discards its saved slot, so this is for disabling groups, not for quit.
    func removeAll() {
        for entry in installed.values {
            entry.handle.onClick = nil
            entry.handle.remove()
        }
        installed.removeAll()
    }

    // MARK: - Menu model

    /// Entries in group order: one per present window of each owner (left to right), or a single
    /// disabled entry for an owner with no window right now.
    func menuModel(for group: ItemGroup) -> [GroupMenuEntry] {
        var entries: [GroupMenuEntry] = []
        for key in group.ownerKeys {
            let matching = items
                .filter { ItemControlStore.key(for: $0.snapshot) == key }
                .sorted { $0.snapshot.frame.minX < $1.snapshot.frame.minX }
            if matching.isEmpty {
                entries.append(GroupMenuEntry(
                    ownerKey: key, windowID: nil, title: aliases.alias(forKey: key) ?? key,
                    image: nil, isGlyph: false, availability: .notRunning
                ))
                continue
            }
            for var item in matching {
                item.alias = aliases.alias(for: item.snapshot)
                entries.append(GroupMenuEntry(
                    ownerKey: key, windowID: item.id, title: item.displayName,
                    image: item.image, isGlyph: capturedGlyphWindowIDs.contains(item.id),
                    availability: item.isDisabled ? .unactivatable : .available
                ))
            }
        }
        return entries
    }

    func makeMenu(for group: ItemGroup) -> NSMenu {
        let menu = NSMenu(title: group.name)
        // Enabled states are managed by hand; auto-validation would disable every action item.
        menu.autoenablesItems = false
        let entries = menuModel(for: group)
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No items in this group", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.menuTitle, action: #selector(menuEntrySelected(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.isEnabled
            item.image = entry.image.flatMap { GroupStatusItemIcon.menuImage(from: $0, template: entry.isGlyph) }
            item.representedObject = entry.windowID.map { NSNumber(value: $0) }
            if entry.availability == .unactivatable {
                item.toolTip = "This item could not be opened."
            }
            menu.addItem(item)
        }
        return menu
    }

    func presentMenu(forGroupID id: UUID) {
        guard let group = groups.first(where: { $0.id == id }), let entry = installed[id] else { return }
        entry.handle.present(makeMenu(for: group))
    }

    @objc func menuEntrySelected(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        activate(CGWindowID(number.uint32Value))
    }

    // MARK: - Appearance

    private func refreshAppearance(of group: ItemGroup) {
        guard var entry = installed[group.id] else { return }
        let entries = menuModel(for: group)
        // The first member with a real glyph represents the group; app icons would render as blobs.
        let glyphSource = entries.first { $0.isGlyph && $0.image != nil }
        let signature = IconSignature(windowID: glyphSource?.windowID, image: glyphSource?.image)
        if entry.iconSignature != signature {
            entry.handle.image = GroupStatusItemIcon.statusIcon(glyph: glyphSource?.image)
            entry.iconSignature = signature
        }
        // Count owners, not windows: one app with two status windows is still one member.
        let running = Set(entries.compactMap { $0.windowID == nil ? nil : $0.ownerKey }).count
        let toolTip = Self.toolTip(name: group.name, memberCount: group.ownerKeys.count, runningCount: running)
        if entry.toolTip != toolTip {
            entry.handle.toolTip = toolTip
            entry.toolTip = toolTip
        }
        installed[group.id] = entry
    }

    static func toolTip(name: String, memberCount: Int, runningCount: Int) -> String {
        guard memberCount > 0 else { return "\(name): no items" }
        let items = memberCount == 1 ? "1 item" : "\(memberCount) items"
        let missing = max(memberCount - runningCount, 0)
        return missing == 0 ? "\(name): \(items)" : "\(name): \(items), \(missing) not running"
    }
}

// MARK: - Icons

enum GroupStatusItemIcon {
    static let statusSize = CGSize(width: 18, height: 18)
    static let menuSize = CGSize(width: 16, height: 16)

    /// Shared instance so callers can tell the placeholder apart from a rendered glyph.
    static let placeholder: NSImage = {
        let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Item group")
            ?? NSImage(size: statusSize)
        image.isTemplate = true
        return image
    }()

    static func statusIcon(glyph: NSImage?) -> NSImage {
        guard let glyph, let fitted = fitted(glyph, in: statusSize, template: true) else { return placeholder }
        return fitted
    }

    static func menuImage(from image: NSImage, template: Bool) -> NSImage? {
        fitted(image, in: menuSize, template: template)
    }

    /// Aspect-fits `image` into a new image. Never mutates `image`: the floating bar shares the
    /// cached instance, and flipping its template flag would change how it draws there.
    static func fitted(_ image: NSImage, in size: CGSize, template: Bool) -> NSImage? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let ratio = min(size.width / source.width, size.height / source.height)
        let drawSize = CGSize(width: source.width * ratio, height: source.height * ratio)
        let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
        let result = NSImage(size: size, flipped: false) { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        result.isTemplate = template
        return result
    }
}

// MARK: - NSStatusBar-backed implementation

/// Seeds a new group's saved slot just right of the anchor. AppKit would otherwise place a brand
/// new status item leftmost, inside the tucked section, where the divider hides it.
enum GroupStatusItemSlots {
    static func preferredPositionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// Returns the seeded slot, or nil when the group already has one or the anchor has none yet.
    @discardableResult
    static func seedIfNeeded(autosaveName: String, defaults: UserDefaults) -> Double? {
        let key = preferredPositionKey(autosaveName)
        guard defaults.object(forKey: key) == nil else { return nil }
        let anchorKey = preferredPositionKey(ControlItem.Identifier.anchor.rawValue)
        guard defaults.object(forKey: anchorKey) != nil else { return nil }
        // Lower slot values sit further right; see ControlItemOrder.
        let slot = defaults.double(forKey: anchorKey) - 1
        defaults.set(slot, forKey: key)
        return slot
    }
}

struct SystemGroupStatusItemFactory: GroupStatusItemFactory {
    func makeStatusItem(autosaveName: String) -> any GroupStatusItemHandle {
        GroupStatusItemSlots.seedIfNeeded(autosaveName: autosaveName, defaults: .standard)
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = autosaveName
        return SystemGroupStatusItem(statusItem: statusItem)
    }
}

@MainActor
final class SystemGroupStatusItem: NSObject, GroupStatusItemHandle {
    private let statusItem: NSStatusItem
    var onClick: (@MainActor () -> Void)?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
        if let button = statusItem.button {
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    var autosaveName: String? { statusItem.autosaveName }

    var image: NSImage? {
        get { statusItem.button?.image }
        set { statusItem.button?.image = newValue }
    }

    var title: String? {
        get { statusItem.button?.title }
        set { statusItem.button?.title = newValue ?? "" }
    }

    var toolTip: String? {
        get { statusItem.button?.toolTip }
        set {
            statusItem.button?.toolTip = newValue
            // An image-only button has no spoken name without an explicit accessibility label.
            statusItem.button?.setAccessibilityLabel(newValue)
        }
    }

    /// Attached only for this click so the button keeps routing later clicks to `clicked`.
    func present(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func remove() {
        onClick = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func clicked(_ sender: Any?) {
        onClick?()
    }
}
