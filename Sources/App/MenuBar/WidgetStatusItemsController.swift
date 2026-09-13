import AppKit
import BarKeepersFriendCore

/// Owns one status item per widget and runs its action on click. Widgets are BKF's own items, so the
/// "BKF" name prefix keeps them out of mirroring, placement, and the Items list like the controls.
@MainActor
final class WidgetStatusItemsController {
    /// What the rendered image was made from; the name is its accessibility description.
    private struct ImageSource: Equatable {
        let symbolName: String
        let name: String
    }

    private struct Installed {
        let handle: any GroupStatusItemHandle
        var widget: MenuBarWidget
        var imageSource: ImageSource?
        var toolTip: String?
        var failure: String?
        var failureReset: Task<Void, Never>?
    }

    private let factory: any GroupStatusItemFactory
    private let runner: WidgetActionRunner
    /// How long a failed click's explanation replaces the normal tooltip.
    private let failureDisplayDuration: Duration
    private let sleep: @MainActor (Duration) async throws -> Void
    private var installed: [UUID: Installed] = [:]
    private var widgets: [MenuBarWidget] = []

    var installedWidgetIDs: Set<UUID> { Set(installed.keys) }

    init(
        factory: any GroupStatusItemFactory = SystemGroupStatusItemFactory(),
        runner: WidgetActionRunner,
        failureDisplayDuration: Duration = .seconds(6),
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.factory = factory
        self.runner = runner
        self.failureDisplayDuration = failureDisplayDuration
        self.sleep = sleep
    }

    /// Distinct from the anchor/divider/group names, which must never be reused.
    static func autosaveName(for widgetID: UUID) -> String {
        "BKFWidget-\(widgetID.uuidString)"
    }

    static func toolTip(for widget: MenuBarWidget) -> String {
        "\(widget.name): \(WidgetLibrary.displayText(for: widget.action))"
    }

    /// Diffs against the installed items: survivors keep their status item (and its slot), deleted
    /// widgets lose theirs, new widgets get one. Cheap enough to call on every preference change.
    func update(widgets: [MenuBarWidget]) {
        self.widgets = WidgetLibrary.normalized(widgets)
        let liveIDs = Set(self.widgets.map(\.id))
        for (id, entry) in installed where !liveIDs.contains(id) {
            entry.failureReset?.cancel()
            entry.handle.onClick = nil
            entry.handle.remove()
            installed[id] = nil
        }
        for widget in self.widgets {
            if installed[widget.id] == nil {
                let handle = factory.makeStatusItem(autosaveName: Self.autosaveName(for: widget.id))
                let id = widget.id
                handle.onClick = { [weak self] in self?.runAction(forWidgetID: id) }
                installed[widget.id] = Installed(handle: handle, widget: widget)
            } else if installed[widget.id]?.widget != widget {
                // An edited widget starts clean; a stale failure would describe the old action.
                clearFailure(forWidgetID: widget.id)
                installed[widget.id]?.widget = widget
            }
            refreshAppearance(of: widget)
        }
    }

    /// Removing a status item discards its saved slot, so this is for disabling widgets, not for quit.
    func removeAll() {
        for entry in installed.values {
            entry.failureReset?.cancel()
            entry.handle.onClick = nil
            entry.handle.remove()
        }
        installed.removeAll()
    }

    // MARK: - Clicks

    func runAction(forWidgetID id: UUID) {
        guard let widget = widgets.first(where: { $0.id == id }), installed[id] != nil else { return }
        switch runner.run(widget.action) {
        case .success:
            clearFailure(forWidgetID: id)
        case let .failure(error):
            showFailure(error, for: widget)
        }
    }

    /// A status item cannot present an alert without stealing focus, so the tooltip carries the reason.
    private func showFailure(_ error: WidgetActionError, for widget: MenuBarWidget) {
        guard var entry = installed[widget.id] else { return }
        entry.failureReset?.cancel()
        entry.failure = "\(widget.name): \(error.message)"
        let id = widget.id
        let duration = failureDisplayDuration
        let sleep = sleep
        entry.failureReset = Task { @MainActor [weak self] in
            // Cancellation means the explanation was already replaced; nothing is left to restore.
            guard (try? await sleep(duration)) != nil, !Task.isCancelled else { return }
            self?.clearFailure(forWidgetID: id)
        }
        installed[widget.id] = entry
        refreshAppearance(of: widget)
    }

    private func clearFailure(forWidgetID id: UUID) {
        guard var entry = installed[id], entry.failure != nil || entry.failureReset != nil else { return }
        entry.failureReset?.cancel()
        entry.failureReset = nil
        entry.failure = nil
        installed[id] = entry
        if let widget = widgets.first(where: { $0.id == id }) { refreshAppearance(of: widget) }
    }

    // MARK: - Appearance

    private func refreshAppearance(of widget: MenuBarWidget) {
        guard var entry = installed[widget.id] else { return }
        let source = ImageSource(symbolName: widget.symbolName, name: widget.name)
        if entry.imageSource != source {
            entry.handle.image = WidgetStatusItemIcon.image(symbolName: source.symbolName, accessibilityDescription: source.name)
            entry.imageSource = source
        }
        let toolTip = entry.failure ?? Self.toolTip(for: widget)
        if entry.toolTip != toolTip {
            entry.handle.toolTip = toolTip
            entry.toolTip = toolTip
        }
        installed[widget.id] = entry
    }
}

// MARK: - Icons

enum WidgetStatusItemIcon {
    /// Whether the running OS ships a symbol by this name; Core cannot know and falls back otherwise.
    static func isAvailable(_ symbolName: String) -> Bool {
        NSImage(systemSymbolName: WidgetLibrary.trimmed(symbolName), accessibilityDescription: nil) != nil
    }

    /// Template rendering so the glyph follows the menu bar's light/dark appearance like a system item.
    static func image(symbolName: String, accessibilityDescription: String) -> NSImage {
        let image = NSImage(systemSymbolName: WidgetLibrary.trimmed(symbolName), accessibilityDescription: accessibilityDescription)
            ?? NSImage(systemSymbolName: WidgetLibrary.fallbackSymbolName, accessibilityDescription: accessibilityDescription)
            ?? NSImage(size: GroupStatusItemIcon.statusSize)
        image.isTemplate = true
        return image
    }
}
