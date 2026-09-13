import AppKit
import BarKeepersFriendCore
import SwiftUI

/// The sidebar column of the Settings window: a compact app identity above the pane list.
/// It is the only way to switch panes, so the window never lets it collapse.
struct SettingsSidebar: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        VStack(spacing: 0) {
            AppIdentityHeader()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-identity-header")
            List(selection: listSelection) {
                ForEach(SettingsView.Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        // VoiceOver and hostless tests switch panes by pressing a row, not only
                        // through native table selection.
                        .accessibilityAction { selection = tab }
                        .accessibilityIdentifier("settings-sidebar-\(tab.rawValue)")
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-sidebar")
    }

    /// Command-clicking the selected row deselects in a List; the detail must always show a pane.
    private var listSelection: Binding<SettingsView.Tab?> {
        Binding(get: { selection }, set: { if let tab = $0 { selection = tab } })
    }
}

/// Icon, name, and version at the top of the sidebar. Keeping the identity out of the detail
/// column leaves that column's full height to the selected pane.
private struct AppIdentityHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
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
