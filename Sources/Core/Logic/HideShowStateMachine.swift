import Foundation

/// The pure state machine governing whether each section is currently collapsed or shown.
///
/// All visibility decisions live here as a value type so they can be exhaustively tested:
/// feed it events, assert the resulting state and the side-effect *intents* it emits. The
/// AppKit layer is responsible only for turning intents into `NSStatusItem.length` changes.
public struct HideShowStateMachine: Equatable, Sendable {

    /// Whether a toggleable section is collapsed (hidden) or expanded (shown).
    public enum Visibility: Equatable, Sendable {
        case collapsed
        case shown
    }

    /// External events that can change visibility.
    public enum Event: Equatable, Sendable {
        /// User clicked the anchor control item, or pressed the toggle hotkey.
        case toggle(MenuBarSection)
        /// User asked to reveal a section explicitly.
        case show(MenuBarSection)
        /// User asked to collapse a section.
        case hide(MenuBarSection)
        /// Auto-rehide fired (e.g. timer elapsed, focus lost) for any section configured to.
        case autoRehide
        /// The screen layout changed; sections should re-collapse to a known state.
        case screenParametersChanged
    }

    /// A requested change for the AppKit layer to apply to a divider.
    public struct Intent: Equatable, Sendable {
        public let section: MenuBarSection
        public let visibility: Visibility
        public init(section: MenuBarSection, visibility: Visibility) {
            self.section = section
            self.visibility = visibility
        }
    }

    /// Current visibility per section. Sections not present default to `.collapsed`.
    public private(set) var visibilities: [MenuBarSection: Visibility]

    /// Sections that should automatically re-collapse on `.autoRehide`.
    public var autoRehideSections: Set<MenuBarSection>

    public init(
        sections: [MenuBarSection] = MenuBarSection.phase1,
        autoRehideSections: Set<MenuBarSection> = [.hidden],
        initialVisibility: Visibility = .collapsed
    ) {
        var initial: [MenuBarSection: Visibility] = [:]
        for section in sections where section != .visible {
            initial[section] = initialVisibility
        }
        self.visibilities = initial
        self.autoRehideSections = autoRehideSections
    }

    /// The current visibility of a section. `.visible` is always shown.
    public func visibility(of section: MenuBarSection) -> Visibility {
        if section == .visible { return .shown }
        return visibilities[section] ?? .collapsed
    }

    /// Applies an event, mutating state and returning the intents to enact.
    /// Returns only the intents whose visibility actually changed, so the AppKit layer
    /// never thrashes a divider that is already in the right state.
    @discardableResult
    public mutating func apply(_ event: Event) -> [Intent] {
        switch event {
        case let .toggle(section):
            guard section != .visible else { return [] }
            let next: Visibility = visibility(of: section) == .shown ? .collapsed : .shown
            return setVisibility(next, for: section)

        case let .show(section):
            guard section != .visible else { return [] }
            return setVisibility(.shown, for: section)

        case let .hide(section):
            guard section != .visible else { return [] }
            return setVisibility(.collapsed, for: section)

        case .autoRehide:
            var intents: [Intent] = []
            for section in autoRehideSections {
                intents.append(contentsOf: setVisibility(.collapsed, for: section))
            }
            return intents

        case .screenParametersChanged:
            // Re-collapse every toggleable section to a deterministic baseline.
            var intents: [Intent] = []
            for section in visibilities.keys {
                intents.append(contentsOf: setVisibility(.collapsed, for: section))
            }
            return intents
        }
    }

    private mutating func setVisibility(_ next: Visibility, for section: MenuBarSection) -> [Intent] {
        guard visibilities[section] != nil else { return [] }
        guard visibilities[section] != next else { return [] }
        visibilities[section] = next
        return [Intent(section: section, visibility: next)]
    }
}
