import AppKit
import BarKeepersFriendCore
import SwiftUI
import UniformTypeIdentifiers

/// Every committed widget edit is exactly one `model.preferences` assignment. Widgets are BKF's own
/// status items, so nothing here enumerates, captures, or moves other apps' items.
struct WidgetsSettingsTab: View {
    @Bindable var model: SettingsModel
    /// Injected so tests never present an open panel; production uses `WidgetAppChooser`.
    var chooseApp: @MainActor () -> URL? = WidgetAppChooser.presentOpenPanel

    var body: some View { content }

    var content: WidgetsSettingsContent { WidgetsSettingsContent(model: model, chooseApp: chooseApp) }
}

extension SettingsModel {
    /// Adds or replaces `widget` in one write. Returns the problem that prevented the save, if any.
    @discardableResult
    func saveWidget(_ widget: MenuBarWidget) -> WidgetLibrary.ValidationProblem? {
        let current = preferences.widgets
        let isNew = !current.contains { $0.id == widget.id }
        if let problem = isNew
            ? WidgetLibrary.problem(adding: widget, to: current)
            : WidgetLibrary.problem(updating: widget, in: current) {
            return problem
        }
        let updated = isNew
            ? (try? WidgetLibrary.adding(widget, to: current))
            : (try? WidgetLibrary.updating(widget, in: current))
        if let updated, updated != current { preferences.widgets = updated }
        return nil
    }

    func deleteWidget(id: UUID) {
        let updated = WidgetLibrary.removing(id: id, from: preferences.widgets)
        guard updated != preferences.widgets else { return }
        preferences.widgets = updated
    }
}

struct WidgetsSettingsContent: View {
    @Bindable var model: SettingsModel
    let chooseApp: @MainActor () -> URL?
    @State private var editing: WidgetDraft?

    private var widgets: [MenuBarWidget] { model.preferences.widgets }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .settingsSearchTarget(.widgets)
            if let editing {
                WidgetEditor(
                    draft: editing, existing: widgets, chooseApp: chooseApp,
                    onSave: { widget in
                        // A concurrent change (import, another window) can invalidate a valid draft.
                        if model.saveWidget(widget) == nil { self.editing = nil }
                    },
                    onCancel: { self.editing = nil }
                )
                .id(editing.id)
            } else {
                if widgets.isEmpty {
                    emptyState
                } else {
                    widgetList
                }
                Divider()
                footer
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-widget-content")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Widgets")
                .font(.headline)
            Text("A widget is a menu bar item of your own that runs an action when clicked: open a link, launch an app, run a Shortcut, or toggle the hidden bar. Widgets belong to Bar Keeper's Friend, so it never hides them. Drag them in the menu bar with the Command key like any other item.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-widget-header")
    }

    private var widgetList: some View {
        List {
            ForEach(widgets) { widget in
                WidgetRow(model: model, widget: widget) {
                    editing = WidgetDraft(widget: widget)
                }
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 120, maxHeight: .infinity)
        .accessibilityIdentifier("settings-widget-list")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "star.square.on.square")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No widgets yet.")
                .font(.headline)
            Text("Add a widget to put your own icon in the menu bar. Clicking it opens a link, launches an app, runs a Shortcut, or toggles the hidden bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-widget-empty")
    }

    private var addHint: String? {
        widgets.count >= WidgetLibrary.maxWidgets ? WidgetLibrary.ValidationProblem.tooManyWidgets.message : nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let addHint {
                    Text(addHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-widget-add-hint")
                }
                Spacer(minLength: 8)
                Button("Add Widget…") { editing = WidgetDraft() }
                    .disabled(addHint != nil)
                    .accessibilityIdentifier("settings-widget-add")
            }
            Text("Widgets appear in the menu bar as soon as you save them and need no Apply Changes. Removing a widget also forgets its menu bar position.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-widget-footer")
    }
}

// MARK: - Rows

private struct WidgetRow: View {
    @Bindable var model: SettingsModel
    let widget: MenuBarWidget
    let onEdit: () -> Void
    @State private var confirmingDelete = false

    private var storedProblem: WidgetLibrary.ValidationProblem? { WidgetLibrary.validate(widget.action) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WidgetSymbolPreview(symbolName: widget.symbolName)
                .frame(width: 22, height: 22)
                .accessibilityIdentifier("settings-widget-symbol-\(widget.id)")

            VStack(alignment: .leading, spacing: 2) {
                Text(widget.name)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("settings-widget-name-\(widget.id)")
                Text(WidgetActionText.settingsText(for: widget.action))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-widget-action-\(widget.id)")
                if let storedProblem {
                    Label(storedProblem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("This action was refused. Edit the widget to fix it; clicking it does nothing until then.")
                        .accessibilityIdentifier("settings-widget-problem-\(widget.id)")
                }
            }

            Spacer(minLength: 8)

            if confirmingDelete {
                Text("Delete \"\(widget.name)\"?")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("settings-widget-delete-prompt-\(widget.id)")
                Button("Cancel") { confirmingDelete = false }
                    .accessibilityIdentifier("settings-widget-cancel-delete-\(widget.id)")
                Button("Delete", role: .destructive) {
                    confirmingDelete = false
                    model.deleteWidget(id: widget.id)
                }
                .accessibilityIdentifier("settings-widget-confirm-delete-\(widget.id)")
            } else {
                Button("Edit…", action: onEdit)
                    .accessibilityIdentifier("settings-widget-edit-\(widget.id)")
                Button("Delete…") { confirmingDelete = true }
                    .help("Delete \(widget.name) and remove its icon from the menu bar.")
                    .accessibilityIdentifier("settings-widget-delete-\(widget.id)")
            }
        }
        .controlSize(.small)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-widget-row-\(widget.id)")
    }
}

/// The symbol as the menu bar will draw it, or the placeholder for a name this OS does not know.
struct WidgetSymbolPreview: View {
    let symbolName: String

    var isAvailable: Bool { WidgetStatusItemIcon.isAvailable(symbolName) }

    var body: some View {
        Image(systemName: isAvailable ? WidgetLibrary.trimmed(symbolName) : WidgetLibrary.fallbackSymbolName)
            .font(.title3)
            .foregroundStyle(isAvailable ? .primary : .secondary)
            .frame(width: 22, height: 22)
            .accessibilityLabel(isAvailable ? "Symbol \(WidgetLibrary.trimmed(symbolName))" : "Placeholder symbol")
    }
}

/// Settings text resolves app names where Core cannot; tooltips keep Core's plain text.
enum WidgetActionText {
    @MainActor
    static func settingsText(for action: WidgetAction) -> String {
        if case let .launchApp(bundleIdentifier) = action,
           let name = WidgetAppChooser.displayName(forBundleIdentifier: bundleIdentifier) {
            return "Launch \(name) (\(bundleIdentifier))"
        }
        return WidgetLibrary.displayText(for: action)
    }
}

// MARK: - Editor

struct WidgetEditor: View {
    let existing: [MenuBarWidget]
    let chooseApp: @MainActor () -> URL?
    let onSave: (MenuBarWidget) -> Void
    let onCancel: () -> Void
    @State private var draft: WidgetDraft
    @State private var chooseAppMessage: String?

    init(
        draft: WidgetDraft, existing: [MenuBarWidget], chooseApp: @escaping @MainActor () -> URL?,
        onSave: @escaping (MenuBarWidget) -> Void, onCancel: @escaping () -> Void
    ) {
        self.existing = existing
        self.chooseApp = chooseApp
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { draft.isNew(in: existing) }
    private var problem: WidgetLibrary.ValidationProblem? { draft.problem(in: existing) }

    /// An untouched empty field is not a mistake yet; every other problem is shown live.
    private var visibleProblem: WidgetLibrary.ValidationProblem? {
        guard let problem else { return nil }
        switch problem {
        case .emptyName where WidgetLibrary.trimmed(draft.name).isEmpty: return nil
        case .emptyURL where WidgetLibrary.trimmed(draft.urlText).isEmpty: return nil
        case .emptyBundleIdentifier where WidgetLibrary.trimmed(draft.bundleIdentifier).isEmpty: return nil
        case .emptyShortcutName where WidgetLibrary.trimmed(draft.shortcutName).isEmpty: return nil
        default: return problem
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "New Widget" : "Edit Widget") {
                    TextField("Name", text: $draft.name)
                        .accessibilityLabel("Widget name")
                        .accessibilityIdentifier("settings-widget-editor-name")
                    symbolRow
                }

                Section {
                    Picker("Action", selection: $draft.kind) {
                        ForEach(WidgetAction.Kind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityLabel("Action")
                    .accessibilityIdentifier("settings-widget-editor-kind")
                    parameterFields
                } header: {
                    Text("Action")
                } footer: {
                    Text("Only web and email links, installed apps, Shortcuts by name, and the hidden bar toggle can be used. Scripts cannot be run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 8) {
                if let visibleProblem {
                    Text(visibleProblem.message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-widget-editor-error")
                }
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings-widget-editor-cancel")
                Button(isNew ? "Add Widget" : "Save") {
                    if let widget = draft.widget(in: existing) { onSave(widget) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
                .accessibilityIdentifier("settings-widget-editor-save")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-widget-editor")
    }

    private var symbolRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Symbol") {
                HStack(spacing: 8) {
                    TextField("SF Symbol name, such as star or bolt.fill", text: $draft.symbolName)
                        .labelsHidden()
                        .accessibilityLabel("SF Symbol name")
                        .accessibilityIdentifier("settings-widget-editor-symbol")
                    WidgetSymbolPreview(symbolName: draft.symbolName)
                        .accessibilityIdentifier("settings-widget-editor-symbol-preview")
                }
            }
            if !WidgetStatusItemIcon.isAvailable(draft.symbolName) {
                Text(WidgetLibrary.trimmed(draft.symbolName).isEmpty
                     ? "Enter a name from the SF Symbols app."
                     : "This Mac has no symbol with that name; the placeholder will be shown instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-widget-editor-symbol-hint")
            }
        }
    }

    @ViewBuilder private var parameterFields: some View {
        switch draft.kind {
        case .openURL:
            TextField("Link", text: $draft.urlText, prompt: Text("https://example.com or mailto:name@example.com"))
                .accessibilityLabel("Link")
                .accessibilityIdentifier("settings-widget-editor-url")
        case .launchApp:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("App", text: $draft.bundleIdentifier, prompt: Text("Bundle identifier, such as com.apple.Safari"))
                        .accessibilityLabel("App bundle identifier")
                        .accessibilityIdentifier("settings-widget-editor-bundle")
                    Button("Choose App…") { chooseAppFromPanel() }
                        .accessibilityIdentifier("settings-widget-editor-choose-app")
                }
                if let chooseAppMessage {
                    Text(chooseAppMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings-widget-editor-choose-app-error")
                } else if let name = WidgetAppChooser.displayName(forBundleIdentifier: draft.bundleIdentifier) {
                    Text("Launches \(name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-widget-editor-app-name")
                }
            }
        case .runShortcut:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Shortcut", text: $draft.shortcutName, prompt: Text("Name exactly as shown in the Shortcuts app"))
                    .accessibilityLabel("Shortcut name")
                    .accessibilityIdentifier("settings-widget-editor-shortcut")
                Text("Runs the Shortcut by name; it must exist in the Shortcuts app on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .toggleBar:
            Text("Shows or hides the hidden items, like clicking the Bar Keeper's Friend icon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-widget-editor-toggle-note")
        }
    }

    private func chooseAppFromPanel() {
        guard let url = chooseApp() else { return }
        if let identifier = WidgetAppChooser.bundleIdentifier(at: url) {
            draft.bundleIdentifier = identifier
            chooseAppMessage = nil
        } else {
            chooseAppMessage = "\(url.lastPathComponent) is not an app with a bundle identifier."
        }
    }
}

// MARK: - App chooser

/// The one AppKit panel in this tab, kept behind a closure so tests never present it.
@MainActor
enum WidgetAppChooser {
    static func presentOpenPanel() -> URL? {
        // An accessory app's panel can open behind the frontmost app unless we come forward first.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.title = "Choose App"
        panel.message = "Choose the app this widget launches."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func bundleIdentifier(at url: URL) -> String? {
        guard let identifier = Bundle(url: url)?.bundleIdentifier, !WidgetLibrary.trimmed(identifier).isEmpty else {
            return nil
        }
        return identifier
    }

    /// The installed app's name for a bundle identifier, or nil when no such app is installed.
    static func displayName(forBundleIdentifier bundleIdentifier: String) -> String? {
        let identifier = WidgetLibrary.trimmed(bundleIdentifier)
        guard !identifier.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
