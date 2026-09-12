import AppKit
import BarKeepersFriendCore
import SwiftUI

/// First-run walkthrough: fixed-size pages under a persistent footer. All state lives in the model.
struct OnboardingView: View {
    static let windowSize = CGSize(width: 560, height: 520)

    let model: OnboardingModel

    var body: some View {
        content.frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    /// The unframed pages, so tests can measure the ideal height at the window width.
    var content: some View {
        VStack(spacing: 0) {
            stepContent
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            OnboardingFooter(model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-root")
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .layoutMode: LayoutModeStep()
        case .permissions: PermissionsStep(model: model)
        case .done: DoneStep(model: model)
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Bar Keeper's Friend")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Version \(Self.versionString)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("onboarding-version")
                }
            }
            Text("Bar Keeper's Friend tidies your menu bar. Tuck away the items you rarely need, bring them back with a click or a shortcut, and leave everything else exactly where it is.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                featureRow(
                    FeatureTile(
                        title: "Hide items behind the anchor",
                        systemImage: "line.3.horizontal.decrease.circle",
                        detail: "Items to the left of the Bar Keeper's Friend icon stay out of sight until you ask for them.",
                        identifier: "onboarding-feature-hide"
                    ),
                    FeatureTile(
                        title: "Floating bar shows hidden icons",
                        systemImage: "menubar.arrow.down.rectangle",
                        detail: "Click the icon to open a bar of your hidden items, then click one to open its menu.",
                        identifier: "onboarding-feature-bar"
                    )
                )
                featureRow(
                    FeatureTile(
                        title: "Stage changes in Settings",
                        systemImage: "slider.horizontal.3",
                        detail: "Choose Shown or Hidden for each item in Settings > Items, then Apply Changes.",
                        identifier: "onboarding-feature-staging"
                    ),
                    FeatureTile(
                        title: "Shortcut and reveal options",
                        systemImage: "keyboard",
                        detail: "Toggle the bar with Option-Command-B, or turn on reveal by hover or scroll in Settings.",
                        identifier: "onboarding-feature-shortcut"
                    )
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-step-welcome")
    }

    // fixedSize(vertical) lets both tiles fill the row's ideal height without claiming spare space.
    private func featureRow(_ leading: FeatureTile, _ trailing: FeatureTile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            leading
            trailing
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var versionString: String {
        AppInfo.displayVersion(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}

private struct LayoutModeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeading(
                title: "On-Demand Layout",
                systemImage: "cursorarrow.click",
                summary: "Bar Keeper's Friend is On-Demand. It moves only the items you explicitly change in Settings > Items and never rearranges the rest of your menu bar."
            )
            VStack(alignment: .leading, spacing: 10) {
                BulletRow(text: "Your menu bar stays exactly as you arranged it until you choose Apply Changes.")
                BulletRow(text: "Hiding or showing one item never shifts the others.")
                BulletRow(text: "A future Live mode that organizes items automatically may cause brief pointer movement, so it would be a separate opt-in. There is nothing to choose right now.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-step-layout-mode")
    }
}

private struct PermissionsStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeading(
                title: "Optional Permissions",
                systemImage: "lock.shield",
                summary: "Both permissions are optional: the basic hide and show works without them. Each one unlocks the extras listed below."
            )
            PermissionCard(
                model: model,
                permission: .accessibility,
                title: "Accessibility",
                systemImage: "accessibility",
                benefits: [
                    "Move items across the anchor when you change Shown or Hidden.",
                    "Activate a hidden item directly from the floating bar.",
                ]
            )
            PermissionCard(
                model: model,
                permission: .screenRecording,
                title: "Screen Recording",
                systemImage: "rectangle.dashed.badge.record",
                benefits: [
                    "Show each hidden icon's real image in the floating bar instead of its app icon.",
                ]
            )
            Text("You can grant or review these any time in Settings > General.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.pollPermissions() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-step-permissions")
    }
}

private struct DoneStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeading(
                title: "You're All Set",
                systemImage: "checkmark.circle.fill",
                tint: AnyShapeStyle(.green),
                summary: "Bar Keeper's Friend is running in your menu bar. Nothing has been hidden yet, and nothing moves until you ask."
            )
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title2)
                    .accessibilityHidden(true)
                Text("Look for this icon in your menu bar. Items to its left are the hidden section: click the icon to reveal them, or right-click it for Pause, Settings, and more.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text("Next, choose which items to hide in Settings > Items and choose Apply Changes.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { model.finishAndOpenSettings() }
                .help("Finish the walkthrough and open Settings.")
                .accessibilityIdentifier("onboarding-open-settings")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-step-done")
    }
}

// MARK: - Building blocks

private struct StepHeading: View {
    let title: String
    let systemImage: String
    var tint = AnyShapeStyle(.tint)
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FeatureTile: View {
    let title: String
    let systemImage: String
    let detail: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(height: 20)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

private struct BulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\u{2022}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionCard: View {
    let model: OnboardingModel
    let permission: Permission
    let title: String
    let systemImage: String
    let benefits: [String]

    private var status: PermissionStatus { model.status(of: permission) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                PermissionStatusChip(status: status)
                    .accessibilityIdentifier("onboarding-permission-status-\(permission.onboardingSlug)")
                Spacer(minLength: 8)
                if status != .granted {
                    Button("Open System Settings\u{2026}") { model.openSystemSettings(for: permission) }
                        .controlSize(.small)
                        .accessibilityIdentifier("onboarding-permission-open-\(permission.onboardingSlug)")
                }
            }
            ForEach(benefits, id: \.self) { BulletRow(text: $0) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-permission-\(permission.onboardingSlug)")
    }
}

/// Same wording and colors as the Settings > General > Permissions chips.
private struct PermissionStatusChip: View {
    let status: PermissionStatus

    var body: some View {
        switch status {
        case .granted:
            chip("Granted", systemImage: "checkmark.circle.fill", tint: .green)
        case .lapsed:
            chip("Needs re-approval", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .denied, .notDetermined:
            chip("Not granted", systemImage: "circle", tint: .secondary)
        }
    }

    private func chip(_ title: String, systemImage: String, tint: some ShapeStyle) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(tint)
            // One element with the wording as its label, so assistive tech never reads the symbol name.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
    }
}

private struct OnboardingFooter: View {
    let model: OnboardingModel

    var body: some View {
        ZStack {
            StepIndicator(current: model.step)
            HStack(spacing: 8) {
                if !model.isLastStep {
                    Button("Skip") { model.complete() }
                        .help("Close this walkthrough. Everything here is also available in Settings.")
                        .accessibilityIdentifier("onboarding-skip")
                }
                Spacer()
                Button("Back") { model.back() }
                    .disabled(!model.canGoBack)
                    .accessibilityIdentifier("onboarding-back")
                Button(model.isLastStep ? "Finish" : "Continue") { model.performPrimaryAction() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(model.isLastStep ? "onboarding-finish" : "onboarding-continue")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-footer")
    }
}

private struct StepIndicator: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingModel.stepCount): \(current.title)")
        .accessibilityIdentifier("onboarding-step-indicator")
    }
}

private extension Permission {
    var onboardingSlug: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "screen-recording"
        }
    }
}
