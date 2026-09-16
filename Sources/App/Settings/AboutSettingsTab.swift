import BarKeepersFriendCore
import SwiftUI

struct AboutSettingsTab: View {
    let model: SettingsModel

    private static let projectURL = URL(string: "https://github.com/aagrawal207/bar-keepers-friend")!

    private static var versionString: String {
        AppInfo.displayVersion(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: AppIconRenderer.appImage(model.preferences.appIcon.appTheme, size: 128))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .accessibilityLabel("App icon, \(model.preferences.appIcon.appTheme.displayName) theme")
                        .accessibilityIdentifier("settings-about-icon")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bar Keeper's Friend")
                            .font(.headline)
                        Text("Version \(Self.versionString)")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-about-version")
                            .settingsSearchTarget(.aboutVersion)
                        Text("Made for macOS 26 Tahoe.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-about-compatibility")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            }

            Section("Project & help") {
                LabeledContent("Project") {
                    Link("View on GitHub", destination: Self.projectURL)
                        .accessibilityIdentifier("settings-about-project")
                        .settingsSearchTarget(.aboutProject)
                }
                LabeledContent("Help & feedback") {
                    Link("Report an issue", destination: Self.projectURL.appendingPathComponent("issues"))
                        .accessibilityIdentifier("settings-about-issues")
                        .settingsSearchTarget(.aboutSupport)
                }
                LabeledContent("Open source") {
                    Link("MIT License", destination: Self.projectURL.appendingPathComponent("blob/main/LICENSE"))
                        .accessibilityIdentifier("settings-about-license")
                        .settingsSearchTarget(.aboutLicense)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-about-content")
    }
}
