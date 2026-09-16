import BarKeepersFriendCore
import SwiftUI

/// Searchable regions share their keywords with the sidebar index, including controls hidden by
/// an off switch. These are Settings destinations, never item-owner or persistence identities.
enum SettingsSearchTarget: CaseIterable, Hashable, Sendable {
    case pageTitle
    case getStarted, launchAtLogin, accessibility, screenRecording, spacing, backup
    case itemArrangement, placementPreview, bulkPlacement, placementActions
    case icons, menuBarStyle, tint, gradient, opacity, shape, cornerRadius, border, shadow, resetStyle, stylePreview
    case floatingBar, floatingBarStyle, dismissOnExit, autoRehide, hover, scroll, notch
    case toggleShortcut, itemShortcuts
    case advancedTools, presets, savePreset, triggers, groups
    case aboutVersion, aboutProject, aboutSupport, aboutLicense

    var searchTerms: String {
        switch self {
        case .pageTitle: ""
        case .getStarted: "Get started Arrange Items"
        case .launchAtLogin: "Launch at login startup"
        case .accessibility: "Permissions Accessibility"
        case .screenRecording: "Permissions Screen Recording"
        case .spacing: "Menu bar spacing Reduce menu bar item spacing Selection padding Reset to system default"
        case .backup: "Backup Layout file Export Import"
        case .itemArrangement:
            "Arrange Menu Bar Items Hidden Shown Always Hidden Placement Display name Show in bar Move earlier Move later Retry Reading apps applications alias aliases nickname rename order"
        case .placementPreview: "Placement Preview After Apply Last Observed"
        case .bulkPlacement: "Hide All Show All"
        case .placementActions: "Apply Changes Discard Retry"
        case .icons:
            "Icons Menu bar icon App icon symbol theme"
                + " " + AppIconChoice.MenuBarSymbol.allCases.map(\.displayName).joined(separator: " ")
                + " " + AppIconChoice.AppTheme.allCases.map(\.displayName).joined(separator: " ")
        case .menuBarStyle: "Style the menu bar appearance styles styling background"
        case .tint: "Tint color colour"
        case .gradient: "Gradient end color"
        case .opacity: "Opacity transparency"
        case .shape: "Shape Full Rounded Pill"
        case .cornerRadius: "Corner radius"
        case .border: "Border width Border color"
        case .shadow: "Shadow"
        case .resetStyle: "Reset Style"
        case .stylePreview: "Preview"
        case .floatingBar: "Hidden items Show hidden items in a floating bar"
        case .floatingBarStyle: "Floating bar style Horizontal strip Vertical list"
        case .dismissOnExit: "Dismiss the bar when the pointer leaves it mouse"
        case .autoRehide: "Behavior Automatically re-hide Re-hide after auto-rehide delay"
        case .hover: "Reveal on hover"
        case .scroll: "Reveal on scroll or swipe"
        case .notch: "Notch Make room near the notch Never When needed tuck shown items"
        case .toggleShortcut: "Shortcuts Toggle the bar with a global shortcut Toggle bar Record Clear keyboard hotkey"
        case .itemShortcuts: "Item shortcuts Record Clear"
        case .advancedTools: "Optional tools Presets Triggers Groups"
        case .presets: "Layout Presets Rename Apply Update from Current Delete profiles arrangements"
        case .savePreset: "New preset name Save Current Layout"
        case .triggers:
            TriggerCondition.Kind.allCases.map(\.displayName).joined(separator: " ")
                + " Add Rule Edit Rule Rule name Conditions Apply preset Add Condition Remove Condition Save Delete"
                + " automatic automation percentage wifi network connected not connection application bundle monitor screen weekdays schedule"
        case .groups: "Item Groups New group name Create Group Rename Delete members membership add move remove apps applications"
        case .aboutVersion: "Version macOS Tahoe compatibility"
        case .aboutProject: "Project GitHub website source code"
        case .aboutSupport: "Help Support Feedback Report an issue"
        case .aboutLicense: "MIT License Open source acknowledgments credits"
        }
    }

    static let styleControls: [Self] = [.tint, .gradient, .opacity, .shape, .cornerRadius, .border, .shadow, .resetStyle]
}

extension SettingsView.Tab {
    var searchTargets: [SettingsSearchTarget] {
        switch self {
        case .general: [.getStarted, .launchAtLogin, .accessibility, .screenRecording]
        case .items: [.itemArrangement, .placementPreview, .bulkPlacement, .placementActions]
        case .style: [.icons, .menuBarStyle] + SettingsSearchTarget.styleControls + [.stylePreview]
        case .behavior: [.floatingBar, .floatingBarStyle, .dismissOnExit, .autoRehide, .hover, .scroll]
        case .shortcuts: [.toggleShortcut, .itemShortcuts]
        case .advanced: [.advancedTools, .spacing, .notch, .backup]
        case .presets: [.presets, .savePreset]
        case .triggers: [.triggers]
        case .groups: [.groups]
        case .about: [.aboutVersion, .aboutProject, .aboutSupport, .aboutLicense]
        }
    }

    private var searchPath: String { sidebarTab == self ? title : "\(sidebarTab.title) \(title)" }

    static func matching(_ query: String) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return sidebarTabs }
        func containsWords(_ text: String) -> Bool {
            words.allSatisfy { text.localizedStandardContains($0) }
        }
        let matches = allCases.filter { tab in
            containsWords(([tab.searchPath] + tab.searchTargets.map(\.searchTerms)).joined(separator: " "))
        }
        return matches.filter { containsWords($0.title) } + matches.filter { !containsWords($0.title) }
    }

    func highlightTargets(for query: String) -> Set<SettingsSearchTarget> {
        // A page-qualified query such as "Style opacity" should still point to the opacity row.
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { !searchPath.localizedStandardContains($0) }
        guard !words.isEmpty else { return [.pageTitle] }
        let scored = searchTargets.map { target in
            (target, words.filter { target.searchTerms.localizedStandardContains($0) }.count)
        }
        guard let best = scored.map(\.1).max(), best > 0 else { return [.pageTitle] }
        // A query can span sections ("opacity border"); equally strong matches all get a cue.
        return Set(scored.filter { $0.1 == best }.map(\.0))
    }
}

struct SettingsSearchHighlight: Equatable, Sendable {
    let id = UUID()
    let targets: Set<SettingsSearchTarget>
    static let duration: Duration = .seconds(3)
}

private struct SettingsSearchHighlightKey: EnvironmentKey {
    static let defaultValue: SettingsSearchHighlight? = nil
}

private struct SettingsSearchReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var settingsSearchHighlight: SettingsSearchHighlight? {
        get { self[SettingsSearchHighlightKey.self] }
        set { self[SettingsSearchHighlightKey.self] = newValue }
    }

    /// Tests supply the system motion preference without changing this Mac's accessibility settings.
    var settingsSearchReduceMotion: Bool? {
        get { self[SettingsSearchReduceMotionKey.self] }
        set { self[SettingsSearchReduceMotionKey.self] = newValue }
    }
}

extension View {
    /// The enabling switch can stand in for its hidden controls without changing any preferences.
    func settingsSearchTarget(_ target: SettingsSearchTarget, including hiddenTargets: [SettingsSearchTarget] = []) -> some View {
        modifier(SettingsSearchTargetModifier(targets: Set([target] + hiddenTargets)))
    }
}

private struct SettingsSearchTargetModifier: ViewModifier {
    let targets: Set<SettingsSearchTarget>
    @Environment(\.settingsSearchHighlight) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsSearchReduceMotion) private var motionOverride
    @Environment(\.colorSchemeContrast) private var contrast

    private var isHighlighted: Bool { highlight.map { !$0.targets.isDisjoint(with: targets) } ?? false }

    func body(content: Content) -> some View {
        content
            .background { decoration(filled: true) }
            .overlay { decoration(filled: false) }
            .accessibilityCustomContent(
                AccessibilityCustomContentKey("Settings search", id: "settings-search-match"),
                isHighlighted ? Text("Match") : nil, importance: .high
            )
    }

    private func decoration(filled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(filled ? Color.accentColor.opacity(0.14) : .clear)
            .overlay {
                if !filled {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 3 : 2)
                }
            }
            .opacity(isHighlighted ? 1 : 0)
            .animation((motionOverride ?? reduceMotion) ? nil : .easeOut(duration: 0.2), value: isHighlighted)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
