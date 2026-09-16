import AppKit
import BarKeepersFriendCore
import SwiftUI

/// The sidebar column of the Settings window: a compact app identity above the pane list.
/// It is the only way to switch panes, so the window never lets it collapse.
struct SettingsSidebar: View {
    @Binding var selection: SettingsView.Tab
    @Binding var searchText: String
    var appTheme: AppIconChoice.AppTheme = .ocean
    var onSearchSelection: (SettingsView.Tab, String) -> Void = { _, _ in }

    private var tabs: [SettingsView.Tab] { SettingsView.Tab.matching(searchText) }

    var body: some View {
        VStack(spacing: 0) {
            AppIdentityHeader(theme: appTheme)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-identity-header")
            SettingsSearchField(text: $searchText) {
                guard searchText.contains(where: { !$0.isWhitespace }), let tab = tabs.first else { return }
                select(tab)
            }
            .frame(height: 24)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            List(selection: listSelection) {
                ForEach(tabs) { tab in
                    // Activating the current pane must work without a selection-change notification.
                    Button { select(tab) } label: {
                        Label(tab.title, systemImage: tab.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-sidebar-\(tab.rawValue)")
                    .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if tabs.isEmpty {
                    Text("No matching settings")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .accessibilityIdentifier("settings-search-empty")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-sidebar")
    }

    /// Command-clicking the selected row deselects in a List; the detail must always show a pane.
    private var listSelection: Binding<SettingsView.Tab?> {
        Binding(get: { selection }, set: { if let tab = $0 { select(tab) } })
    }

    private func select(_ tab: SettingsView.Tab) {
        let query = searchText
        searchText = ""
        selection = tab
        if query.contains(where: { !$0.isWhitespace }) { onSearchSelection(tab, query) }
    }
}

// SwiftUI searchable reserves window chrome; this native field stays within the sidebar's layout.
private struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search Settings"
        field.setAccessibilityLabel("Search Settings")
        field.setAccessibilityIdentifier("settings-search")
        field.controlSize = .small
        field.maximumRecents = 0
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField

        init(parent: SettingsSearchField) { self.parent = parent }

        @objc func changed(_ field: NSSearchField) { parent.text = field.stringValue }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            // Return and Escape belong to the input method while it is composing text.
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.text = ""
                return true
            default:
                return false
            }
        }
    }
}

/// Icon, name, and version at the top of the sidebar. Keeping the identity out of the detail
/// column leaves that column's full height to the selected pane.
private struct AppIdentityHeader: View {
    let theme: AppIconChoice.AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: AppIconRenderer.appImage(theme, size: 96))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .accessibilityLabel("App icon, \(theme.displayName) theme")
                .accessibilityIdentifier("settings-identity-icon")
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.appName)
                    .font(.headline)
                    .lineLimit(2)
                Text("Version \(Self.versionString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 22pt lines the icon up with the sidebar rows' own leading content edge.
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Bar Keeper's Friend"
    }

    private static var versionString: String {
        AppInfo.displayVersion(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}
