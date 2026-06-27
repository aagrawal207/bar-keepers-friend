import AppKit
import BarKeepersFriendCore

/// The Phase 1 hide/show engine — the unbreakable baseline.
///
/// It owns two of *our own* `NSStatusItem`s: an always-visible anchor and a hidden-section
/// divider. Hiding works by expanding the divider's `length` so the items to its left are
/// pushed off the screen edge; revealing restores the natural length. This uses **no**
/// private APIs and **no** permissions, so it keeps working regardless of what Apple
/// changes in the private menu-bar internals.
///
/// All visibility *decisions* come from `HideShowStateMachine` in Core; this class only
/// translates the resulting intents into `NSStatusItem.length` mutations.
@MainActor
final class CosmeticHideEngine {
    /// Called when settings should open (anchor right-click / menu).
    var onOpenSettings: (() -> Void)?

    private var anchorItem: NSStatusItem?
    private var hiddenDivider: NSStatusItem?

    private var stateMachine: HideShowStateMachine
    private var preferences: Preferences
    private let onPreferencesChanged: (Preferences) -> Void

    private var autoRehideWorkItem: DispatchWorkItem?

    init(preferences: Preferences, onPreferencesChanged: @escaping (Preferences) -> Void) {
        self.preferences = preferences
        self.onPreferencesChanged = onPreferencesChanged
        self.stateMachine = HideShowStateMachine(
            sections: MenuBarSection.phase1,
            autoRehideSections: preferences.autoRehide ? [.hidden] : [],
            // Launch showing everything: the divider stays at its natural width so the
            // anchor is visible and nothing is hidden until the user clicks. Expanding on
            // launch would overflow a notched menu bar and drop the items off-screen.
            initialVisibility: .shown
        )
    }

    // MARK: - Lifecycle

    func install() {
        let anchor = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        anchor.autosaveName = ControlItem.Identifier.anchor.rawValue
        if let button = anchor.button {
            button.image = Self.anchorImage()
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(anchorClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        anchorItem = anchor

        let divider = NSStatusBar.system.statusItem(withLength: ControlItemLength.collapsed)
        divider.autosaveName = ControlItem.Identifier.hiddenDivider.rawValue
        if let button = divider.button {
            button.image = Self.dividerImage()
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(dividerClicked(_:))
        }
        hiddenDivider = divider

        applyDividerVisibility()
        observeScreenChanges()
    }

    func uninstall() {
        autoRehideWorkItem?.cancel()
        if let anchor = anchorItem { NSStatusBar.system.removeStatusItem(anchor) }
        if let divider = hiddenDivider { NSStatusBar.system.removeStatusItem(divider) }
        anchorItem = nil
        hiddenDivider = nil
    }

    // MARK: - Preferences

    func apply(preferences: Preferences) {
        self.preferences = preferences
        stateMachine.autoRehideSections = preferences.autoRehide ? [.hidden] : []
        hiddenDivider?.button?.image = preferences.showSectionDividers ? Self.dividerImage() : Self.dividerImage()
    }

    // MARK: - Actions

    @objc private func anchorClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            onOpenSettings?()
            return
        }
        toggleHidden()
    }

    @objc private func dividerClicked(_ sender: NSStatusBarButton) {
        toggleHidden()
    }

    func toggleHidden() {
        let intents = stateMachine.apply(.toggle(.hidden))
        enact(intents)
        scheduleAutoRehideIfNeeded()
    }

    private func enact(_ intents: [HideShowStateMachine.Intent]) {
        for intent in intents where intent.section == .hidden {
            setHidden(collapsed: intent.visibility == .collapsed)
        }
    }

    /// Expands the divider to hide the section, or restores natural width to reveal it.
    private func setHidden(collapsed: Bool) {
        guard let divider = hiddenDivider else { return }
        if collapsed {
            let screenWidth = NSScreen.main?.frame.width ?? 1440
            divider.length = ControlItemLength.expanded(forScreenWidth: screenWidth)
        } else {
            divider.length = preferences.showSectionDividers
                ? ControlItemLength.collapsed
                : NSStatusItem.variableLength
        }
    }

    private func applyDividerVisibility() {
        // Start collapsed (hidden section tucked away).
        setHidden(collapsed: stateMachine.visibility(of: .hidden) == .collapsed)
    }

    private func scheduleAutoRehideIfNeeded() {
        autoRehideWorkItem?.cancel()
        guard preferences.autoRehide,
              stateMachine.visibility(of: .hidden) == .shown else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.enact(self.stateMachine.apply(.autoRehide))
        }
        autoRehideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.autoRehideDelay, execute: work)
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        enact(stateMachine.apply(.screenParametersChanged))
    }

    // MARK: - Images

    private static func anchorImage() -> NSImage? {
        NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Bar Keeper's Friend")
    }

    private static func dividerImage() -> NSImage? {
        NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Toggle hidden items")
    }
}
