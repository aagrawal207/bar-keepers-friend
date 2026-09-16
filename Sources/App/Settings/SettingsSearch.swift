import BarKeepersFriendCore
import SwiftUI

/// Names, section context, and aliases are shared by page filtering and destination selection.
/// These are Settings regions, never item-owner or persistence identities.
enum SettingsSearchTarget: CaseIterable, Hashable, Sendable {
    case pageTitle
    case getStarted, arrangeItems, startup, launchAtLogin, permissions, accessibility, screenRecording
    case menuBarSpacing, spacing, spacingAmount, selectionPadding, resetSpacing, backup, layoutFile, exportLayout, importLayout
    case itemArrangement, placementPreview, menuBarPlacement, hiddenPlacement, alwaysHiddenPlacement, bulkPlacement, placementActions
    case icons, menuBarIcon, appIcon, menuBarAppearance, menuBarStyle, tint, gradient, gradientEnd, opacity
    case shape, cornerRadius, border, borderColor, shadow, resetStyle, stylePreview
    case hiddenItems, floatingBar, floatingBarStyle, closingBar, dismissOnExit, autoRehide, autoRehideDelay
    case revealGestures, hover, scroll, notch, notchMakeRoom
    case shortcutsSection, toggleShortcut, toggleShortcutRecorder, itemShortcuts, itemShortcutRecorder
    case advancedTools, openPresets, openTriggers, openGroups, presets, savePreset
    case presetName, applyPreset, updatePreset, deletePreset
    case triggers, addTrigger, editTrigger, deleteTrigger, triggerRule, triggerName, triggerPreset, triggerConditions
    case addTriggerCondition, removeTriggerCondition, saveTrigger
    case groups, createGroup, groupName, groupMembership, deleteGroup
    case aboutVersion, aboutCompatibility, aboutLinks, aboutProject, aboutSupport, aboutLicense

    struct Entry {
        let title: String
        var keywords = ""
        var aliases: [String] = []
        var sections: [SettingsSearchTarget] = []
        var isHeading = false

        var names: [String] { [title] + aliases }
        var searchTerms: String { (names + [keywords]).joined(separator: " ") }

        static func heading(_ title: String, keywords: String = "", aliases: [String] = []) -> Self {
            Self(title: title, keywords: keywords, aliases: aliases, isHeading: true)
        }
    }

    var entry: Entry {
        switch self {
        case .pageTitle: .init(title: "")
        case .getStarted: .heading("Get started")
        case .arrangeItems: .init(title: "Arrange Items", sections: [.getStarted])
        case .startup: .heading("Startup")
        case .launchAtLogin: .init(title: "Launch at login", sections: [.startup])
        case .permissions: .heading("Permissions")
        case .accessibility: .init(title: "Accessibility", sections: [.permissions])
        case .screenRecording: .init(title: "Screen Recording", sections: [.permissions])
        case .menuBarSpacing: .heading("Menu bar spacing")
        case .spacing: .init(title: "Reduce menu bar item spacing", sections: [.menuBarSpacing])
        case .spacingAmount: .init(title: "Spacing", sections: [.menuBarSpacing])
        case .selectionPadding: .init(title: "Selection padding", sections: [.menuBarSpacing])
        case .resetSpacing: .init(title: "Reset to system default", sections: [.menuBarSpacing])
        case .backup: .heading("Backup")
        case .layoutFile: .init(title: "Layout file", sections: [.backup])
        case .exportLayout: .init(title: "Export", sections: [.backup])
        case .importLayout: .init(title: "Import", sections: [.backup])
        case .itemArrangement:
            .init(title: "Items", keywords: "Arrange Display name Show in bar Move earlier Move later Retry Reading apps applications alias aliases nickname rename order")
        case .placementPreview: .heading("Placement Preview", keywords: "After Apply Last Observed")
        case .menuBarPlacement: .heading("Menu Bar", aliases: ["Shown"])
        case .hiddenPlacement: .heading("Hidden Bar", aliases: ["Hidden", "Hidden List"])
        case .alwaysHiddenPlacement: .heading("Always Hidden")
        case .bulkPlacement: .init(title: "Hide All", aliases: ["Show All"])
        case .placementActions: .init(title: "Apply Changes", aliases: ["Discard", "Retry"])
        case .icons: .heading("Icons")
        case .menuBarIcon:
            .init(title: "Menu bar icon", keywords: "symbol " + AppIconChoice.MenuBarSymbol.allCases.map(\.displayName).joined(separator: " "), sections: [.icons])
        case .appIcon:
            .init(title: "App icon", keywords: "theme " + AppIconChoice.AppTheme.allCases.map(\.displayName).joined(separator: " "), sections: [.icons])
        case .menuBarAppearance: .heading("Menu bar")
        case .menuBarStyle: .init(title: "Style the menu bar", keywords: "appearance styles styling background", sections: [.menuBarAppearance])
        case .tint: .init(title: "Tint", keywords: "colour", aliases: ["Tint color"], sections: [.menuBarAppearance])
        case .gradient: .init(title: "Gradient", sections: [.menuBarAppearance])
        case .gradientEnd: .init(title: "Gradient end color", sections: [.menuBarAppearance])
        case .opacity: .init(title: "Opacity", keywords: "transparency", sections: [.menuBarAppearance])
        case .shape: .init(title: "Shape", keywords: "Full Rounded Pill", sections: [.menuBarAppearance])
        case .cornerRadius: .init(title: "Corner radius", sections: [.menuBarAppearance])
        case .border: .init(title: "Border", aliases: ["Border width"], sections: [.menuBarAppearance])
        case .borderColor: .init(title: "Border color", sections: [.menuBarAppearance])
        case .shadow: .init(title: "Shadow", sections: [.menuBarAppearance])
        case .resetStyle: .init(title: "Reset Style", sections: [.menuBarAppearance])
        case .stylePreview: .init(title: "Preview", sections: [.menuBarAppearance])
        case .hiddenItems: .heading("Hidden items")
        case .floatingBar: .init(title: "Show hidden items in a floating bar", aliases: ["Floating bar"], sections: [.hiddenItems])
        case .floatingBarStyle: .init(title: "Floating bar style", keywords: "Horizontal strip Vertical list", sections: [.hiddenItems])
        case .closingBar: .heading("Closing the bar")
        case .dismissOnExit: .init(title: "Dismiss the bar when the pointer leaves it", keywords: "mouse", sections: [.closingBar])
        case .autoRehide: .init(title: "Automatically re-hide", aliases: ["auto-rehide", "auto rehide"], sections: [.closingBar])
        case .autoRehideDelay: .init(title: "Re-hide after", keywords: "auto-rehide delay", sections: [.closingBar])
        case .revealGestures: .heading("Reveal gestures")
        case .hover: .init(title: "Reveal on hover", sections: [.revealGestures])
        case .scroll: .init(title: "Reveal on scroll or swipe", sections: [.revealGestures])
        case .notch: .heading("Notch")
        case .notchMakeRoom: .init(title: "Make room near the notch", keywords: "Never When needed tuck shown items", sections: [.notch])
        case .shortcutsSection: .heading("Shortcuts")
        case .toggleShortcut: .init(title: "Toggle the bar with a global shortcut", keywords: "keyboard hotkey", aliases: ["Keyboard shortcut"], sections: [.shortcutsSection])
        case .toggleShortcutRecorder: .init(title: "Toggle bar", keywords: "Record global shortcut", sections: [.shortcutsSection])
        case .itemShortcuts: .heading("Item shortcuts")
        case .itemShortcutRecorder: .init(title: "Record item shortcut", keywords: "Clear", sections: [.itemShortcuts])
        case .advancedTools: .heading("Optional tools", aliases: ["Tools"])
        case .openPresets: .init(title: "Presets", sections: [.advancedTools])
        case .openTriggers: .init(title: "Triggers", sections: [.advancedTools])
        case .openGroups: .init(title: "Groups", sections: [.advancedTools])
        case .presets: .init(title: "Layout presets", keywords: "profiles arrangements")
        case .savePreset: .init(title: "Save Current Layout", keywords: "New preset name")
        case .presetName: .init(title: "Preset name", aliases: ["Rename"])
        case .applyPreset: .init(title: "Apply")
        case .updatePreset: .init(title: "Update from Current")
        case .deletePreset: .init(title: "Delete")
        case .triggers:
            .init(title: "Rules", keywords: "automatic automation")
        case .addTrigger: .init(title: "Add Rule")
        case .editTrigger: .heading("Edit rule", aliases: ["Edit"])
        case .deleteTrigger: .init(title: "Delete")
        case .triggerRule: .heading("New rule")
        case .triggerName: .init(title: "Rule name", sections: [.triggerRule, .editTrigger])
        case .triggerPreset: .init(title: "Apply preset", sections: [.triggerRule, .editTrigger])
        case .triggerConditions:
            .heading("Conditions", keywords: TriggerCondition.Kind.allCases.map(\.displayName).joined(separator: " ")
                     + " percentage wifi network connected not connection application bundle monitor screen weekdays schedule")
        case .addTriggerCondition: .init(title: "Add Condition", sections: [.triggerConditions])
        case .removeTriggerCondition: .init(title: "Remove Condition", sections: [.triggerConditions])
        case .saveTrigger: .init(title: "Save")
        case .groups: .init(title: "Item groups", keywords: "apps applications")
        case .createGroup: .init(title: "Create Group", keywords: "New group name")
        case .groupName: .init(title: "Group name", aliases: ["Rename"])
        case .groupMembership: .init(title: "Members", keywords: "membership add move remove")
        case .deleteGroup: .init(title: "Delete")
        case .aboutVersion: .init(title: "Version")
        case .aboutCompatibility: .init(title: "macOS 26 Tahoe", keywords: "compatibility")
        case .aboutLinks: .heading("Project & help")
        case .aboutProject: .init(title: "Project", keywords: "GitHub website source code", sections: [.aboutLinks])
        case .aboutSupport: .init(title: "Help & feedback", keywords: "Support Report an issue", sections: [.aboutLinks])
        case .aboutLicense: .init(title: "Open source", keywords: "acknowledgments credits", aliases: ["MIT License"], sections: [.aboutLinks])
        }
    }

    static let styleControls: [Self] = [.tint, .gradient, .gradientEnd, .opacity, .shape, .cornerRadius, .border, .borderColor, .shadow, .resetStyle]
    static let spacingControls: [Self] = [.spacingAmount, .selectionPadding, .resetSpacing]
    static let presetControls: [Self] = [.presetName, .applyPreset, .updatePreset, .deletePreset]
    static let groupControls: [Self] = [.groupName, .groupMembership, .deleteGroup]
    static let triggerEditorControls: [Self] = [.triggerRule, .triggerName, .triggerPreset, .triggerConditions, .addTriggerCondition, .removeTriggerCondition, .saveTrigger]
}

extension SettingsView.Tab {
    var searchTargets: [SettingsSearchTarget] {
        switch self {
        case .general: [.getStarted, .arrangeItems, .startup, .launchAtLogin, .permissions, .accessibility, .screenRecording]
        case .items: [.itemArrangement, .placementPreview, .menuBarPlacement, .hiddenPlacement, .alwaysHiddenPlacement, .bulkPlacement, .placementActions]
        case .style: [.icons, .menuBarIcon, .appIcon, .menuBarAppearance, .menuBarStyle] + SettingsSearchTarget.styleControls + [.stylePreview]
        case .behavior: [.hiddenItems, .floatingBar, .floatingBarStyle, .closingBar, .dismissOnExit, .autoRehide, .autoRehideDelay, .revealGestures, .hover, .scroll]
        case .shortcuts: [.shortcutsSection, .toggleShortcut, .toggleShortcutRecorder, .itemShortcuts, .itemShortcutRecorder]
        case .advanced: [.advancedTools, .openPresets, .openTriggers, .openGroups, .menuBarSpacing, .spacing, .notch, .notchMakeRoom, .backup, .layoutFile, .exportLayout, .importLayout] + SettingsSearchTarget.spacingControls
        case .presets: [.presets, .savePreset] + SettingsSearchTarget.presetControls
        case .triggers: [.triggers, .addTrigger, .editTrigger, .deleteTrigger] + SettingsSearchTarget.triggerEditorControls
        case .groups: [.groups, .createGroup] + SettingsSearchTarget.groupControls
        case .about: [.aboutVersion, .aboutCompatibility, .aboutLinks, .aboutProject, .aboutSupport, .aboutLicense]
        }
    }

    private var searchPath: String { sidebarTab == self ? title : "\(sidebarTab.title) \(title)" }

    static func matching(_ query: String) -> [Self] {
        let words = SettingsSearchWords.inText(query)
        guard !words.isEmpty else { return sidebarTabs }
        return allCases.compactMap { tab -> (tab: Self, rank: Int)? in
            tab.searchMatch(words).map { (tab, $0.rank) }
        }.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return allCases.firstIndex(of: $0.tab)! < allCases.firstIndex(of: $1.tab)!
        }.map(\.tab)
    }

    func highlightTargets(for query: String) -> Set<SettingsSearchTarget> {
        searchMatch(SettingsSearchWords.inText(query))?.targets ?? [.pageTitle]
    }

    private func searchMatch(_ words: [String]) -> (rank: Int, targets: Set<SettingsSearchTarget>)? {
        let entries = searchTargets.map { (target: $0, entry: $0.entry) }
        let text = ([searchPath] + entries.map { $0.entry.searchTerms }).joined(separator: " ")
        guard words.allSatisfy({ text.localizedStandardContains($0) }) else { return nil }
        if words == SettingsSearchWords.inText(title) || words == SettingsSearchWords.inText(searchPath) {
            return (0, [.pageTitle])
        }

        // Match full names before removing qualifiers: "Item shortcuts" names a section, not a page.
        let path = sidebarTab == self ? [title] : [sidebarTab.title, title]
        let unqualified = path.reduce(words) { SettingsSearchWords.removingFirst($1, from: $0) }
        for (offset, candidate) in [words, unqualified].enumerated() where !candidate.isEmpty {
            let exact = entries.filter { $0.entry.names.contains { SettingsSearchWords.inText($0) == candidate } }
            let headings = exact.filter { $0.entry.isHeading }
            if !headings.isEmpty { return (1 + offset * 2, Set(headings.map(\.target))) }
            if !exact.isEmpty { return (2 + offset * 2, Set(exact.map(\.target))) }
        }

        let scored = entries.compactMap { target, entry -> (target: SettingsSearchTarget, score: Int)? in
            let ownWords = unqualified.filter { entry.searchTerms.localizedStandardContains($0) }
            guard !ownWords.isEmpty else { return nil }
            let context = Set(entry.sections.flatMap { SettingsSearchWords.inText($0.entry.title) })
            let coverage = unqualified.filter { ownWords.contains($0) || context.contains($0) }.count
            // Complete control names win ties over neighbors sharing one word ("opacity border").
            let completeName = entry.names.contains { name in
                let nameWords = SettingsSearchWords.inText(name)
                return !nameWords.isEmpty && nameWords.allSatisfy(unqualified.contains)
            }
            return (target, coverage * 2 + (completeName ? 1 : 0))
        }
        let best = scored.map(\.score).max() ?? 0
        let targets = Set(scored.filter { $0.score == best }.map(\.target))
        let rank = words.allSatisfy { title.localizedStandardContains($0) } ? 5 : 6
        return (rank, targets.isEmpty ? [.pageTitle] : targets)
    }
}

private enum SettingsSearchWords {
    static func inText(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func removingFirst(_ phrase: String, from words: [String]) -> [String] {
        let qualifier = inText(phrase)
        guard !qualifier.isEmpty, qualifier.count <= words.count,
              let start = (0...(words.count - qualifier.count)).first(where: {
                  Array(words[$0..<($0 + qualifier.count)]) == qualifier
              }) else { return words }
        var result = words
        result.removeSubrange(start..<(start + qualifier.count))
        return result
    }
}

struct SettingsSearchSectionHeading: View {
    let target: SettingsSearchTarget
    let id: String
    var including: [SettingsSearchTarget] = []

    var body: some View {
        Text(target.entry.title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(id)
            .settingsSearchTarget(target, including: including)
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
    /// Conditional membership keeps the modifier and its content's identity stable.
    func settingsSearchTarget(
        _ target: SettingsSearchTarget, including hiddenTargets: [SettingsSearchTarget] = [], when enabled: Bool = true
    ) -> some View {
        modifier(SettingsSearchTargetModifier(targets: enabled ? Set([target] + hiddenTargets) : []))
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
