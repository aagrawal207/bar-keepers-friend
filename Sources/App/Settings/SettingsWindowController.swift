import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Hosts the SwiftUI settings view in an AppKit window. The agent app has no normal window
/// of its own, so we create one on demand and bring the app forward to show it.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeWindow: @MainActor (SettingsView) -> NSWindow
    let model: SettingsModel

    init(
        preferences: Preferences,
        loginItem: any LoginItemManaging,
        itemsProvider: @escaping () async throws -> [FloatingBarItem],
        onRetryPlacement: @escaping () -> Void = {},
        onStageItemOrder: @escaping ([ItemPlacement: [String]], ItemControlStore, Bool) -> Void = { _, _, _ in },
        makeWindow: @escaping @MainActor (SettingsView) -> NSWindow = {
            NSWindow(contentViewController: NSHostingController(rootView: $0))
        },
        onChange: @escaping (Preferences) -> Void
    ) {
        self.makeWindow = makeWindow
        self.model = SettingsModel(
            preferences: preferences,
            loginItem: loginItem,
            itemsProvider: itemsProvider,
            onRetryPlacement: onRetryPlacement,
            onStageItemOrder: onStageItemOrder,
            onChange: onChange
        )
    }

    func show(tab: SettingsView.Tab? = nil) {
        let window = prepareWindow(tab: tab)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A nil tab keeps whatever the user last selected; the window is created only once.
    func prepareWindow(tab: SettingsView.Tab? = nil) -> NSWindow {
        if let window {
            if let tab { model.requestedTab = tab }
            return window
        }
        let window = makeWindow(SettingsView(model: model, initialTab: tab ?? .general))
        Self.configureWindow(window)
        window.center()
        self.window = window
        return window
    }

    static func configureWindow(_ window: NSWindow) {
        window.title = "Bar Keeper's Friend"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // AppKit's titlebar safe area keeps the traffic lights above the fixed-size Settings view.
        // Retain native titlebar dragging; content-background dragging would compete with item drags.
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
    }
}

/// Observable bridge between the SwiftUI view and `Preferences`. Lives in the app target
/// because it touches AppKit (`LoginItemService`); the data it edits is the pure Core type.
@MainActor
@Observable
final class SettingsModel {
    var preferences: Preferences {
        didSet {
            let placementChanged = !oldValue.itemControls.hasSamePlacementIntent(as: preferences.itemControls)
            let orderChanged = oldValue.itemControls.barOrder != preferences.itemControls.barOrder
            if oldValue.itemGroups != preferences.itemGroups || placementChanged || orderChanged {
                placementDrag = nil
                if !orderDraft.isEmpty {
                    draftDiscardedNotice = "Your pending order edits were discarded because the saved arrangement changed."
                }
                orderDraft = ItemOrderDraft()
            }
            if placementChanged {
                // A draft is relative to the arrangement that just changed underneath it.
                if !placementDraft.isEmpty {
                    draftDiscardedNotice = "Your pending placement edits were discarded because the saved arrangement changed (a preset or trigger applied)."
                }
                placementDraft = ItemPlacementDraft()
            }
            onChange(preferences)
        }
    }

    private let loginItem: any LoginItemManaging
    private let onRetryPlacement: () -> Void
    private let onStageItemOrder: ([ItemPlacement: [String]], ItemControlStore, Bool) -> Void
    private let onChange: (Preferences) -> Void
    /// Supplies every manageable menu bar item (both shown and hidden) so the Items tab can list
    /// everything the user might want to toggle. Async because it enumerates + attributes the live
    /// menu bar (an Accessibility sweep off the main thread).
    private let itemsProvider: () async throws -> [FloatingBarItem]

    init(
        preferences: Preferences,
        loginItem: any LoginItemManaging,
        itemsProvider: @escaping () async throws -> [FloatingBarItem],
        onRetryPlacement: @escaping () -> Void = {},
        onStageItemOrder: @escaping ([ItemPlacement: [String]], ItemControlStore, Bool) -> Void = { _, _, _ in },
        onChange: @escaping (Preferences) -> Void
    ) {
        self.preferences = preferences
        self.loginItem = loginItem
        self.loginItemStatus = loginItem.status
        self.itemsProvider = itemsProvider
        self.onRetryPlacement = onRetryPlacement
        self.onStageItemOrder = onStageItemOrder
        self.onChange = onChange
    }

    var launchAtLogin: Bool {
        get { preferences.launchAtLogin }
        set {
            // Persist what ACTUALLY happened, not what was asked. If SMAppService rejects the
            // change (e.g. the user must approve it in System Settings), `setEnabled` returns
            // false and we keep the prior value — so the @Observable toggle snaps back instead
            // of claiming "on" while the app won't actually launch.
            let succeeded = loginItem.setEnabled(newValue)
            loginItemStatus = loginItem.status
            preferences.launchAtLogin = succeeded ? newValue : preferences.launchAtLogin
        }
    }

    // MARK: - Launch at login status

    /// Why a saved `launchAtLogin` preference is not in effect. A successful `register()` can
    /// still leave the item waiting for approval, which the saved flag alone cannot show.
    enum LoginItemNotice: Equatable, Sendable {
        case needsApproval
        case notRegistered

        var text: String {
            switch self {
            case .needsApproval: return "Needs approval in System Settings > General > Login Items"
            case .notRegistered: return "Not registered; toggle off and on to retry"
            }
        }
    }

    /// Live registration state, re-read after every registration change and polled while visible.
    private(set) var loginItemStatus: LoginItemStatus

    var loginItemNotice: LoginItemNotice? {
        guard preferences.launchAtLogin else { return nil }
        switch loginItemStatus {
        case .enabled: return nil
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .notRegistered
        }
    }

    func refreshLoginItemStatus() {
        loginItemStatus = loginItem.status
    }

    /// Opens System Settings > General > Login Items, where the pending approval lives.
    func openLoginItemSettings() {
        loginItem.openSystemSettings()
    }

    // MARK: - Permissions

    /// Live authorization state for Accessibility + Screen Recording, refreshed from the probe.
    /// The Pro features fail silently without these, so the Settings UI surfaces them and lets the
    /// user jump straight to the right System Settings pane.
    private(set) var permissions = PermissionState()
    private let permissionProbe: PermissionProbe = SystemPermissionProbe()
    var onAccessibilityGranted: (() -> Void)?

    /// Re-reads permission status from the system. Called when the Settings window appears and
    /// can be polled while it's open so a grant the user just toggled in System Settings shows up
    /// without reopening. Cheap (two boolean syscalls); promotes a regranted-then-revoked
    /// permission to `.lapsed` via the pure state machine.
    func refreshPermissions() {
        let wasGranted = permissions.status(of: .accessibility) == .granted
        permissions.refresh(using: permissionProbe)
        if !wasGranted, permissions.status(of: .accessibility) == .granted {
            onAccessibilityGranted?()
        }
    }

    /// Status of a single permission for the UI to render.
    func status(of permission: Permission) -> PermissionStatus {
        permissions.status(of: permission)
    }

    /// Opens the System Settings pane for a permission (and, for Accessibility, fires the grant
    /// prompt so the app appears in the list). Invoked by the Permissions section's button.
    func openPermissionSettings(_ permission: Permission) {
        switch permission {
        case .accessibility:
            AccessibilityPermission.requestAndOpenSettings()
        case .screenRecording:
            ScreenRecordingPermission.openSettings()
        }
    }

    // MARK: - Items management

    private(set) var loadedItems: [FloatingBarItem] = []
    private(set) var itemsLoading = true
    private(set) var itemsLoadError: String? = nil
    @ObservationIgnored private var itemsLoadGeneration: UInt64 = 0
    private var placementDraft = ItemPlacementDraft()
    private var orderDraft = ItemOrderDraft()
    private var applyingOrder = ItemOrderDraft()
    private struct PlacementDrag {
        let token: UUID
        let windowID: CGWindowID
        let ownerKey: String
        let source: ItemPlacement?
    }
    private var placementDrag: PlacementDrag?
    var isDraggingPlacementItem: Bool { placementDrag != nil }
    func isDraggingPlacement(_ item: FloatingBarItem) -> Bool {
        placementDrag?.ownerKey == ItemControlStore.key(for: item.snapshot) && placementDrag != nil
    }
    var placementInProgress = false {
        didSet { if !placementInProgress { applyingOrder = ItemOrderDraft() } }
    }
    var placementIncludesTierChanges = true
    var placementMessage: String? = nil
    var placementFailed = false
    var placementPending = false
    /// Set once a spacing change was written to the global domain; other apps read it at relaunch.
    var spacingNeedsLogout = false
    /// One-shot tab request from outside the window (onboarding, menu); the view consumes it.
    var requestedTab: SettingsView.Tab?
    /// Shown in the Items footer until the next edit, so a vanished draft is explained.
    var draftDiscardedNotice: String?
    /// Owner keys (or the toggle identifier) whose Carbon registration was refused.
    var hotkeyRegistrationFailures: [String] = []

    /// Placement reads intent with grouped owners forced Hidden, exactly as the engine does.
    private var effectiveControls: ItemControlStore {
        ItemGroupLibrary.effectiveControls(groups: preferences.itemGroups, base: preferences.itemControls)
    }

    var hasPendingPlacementChanges: Bool { !placementDraft.isEmpty }
    var hasPendingChanges: Bool { hasPendingPlacementChanges || !orderDraft.isEmpty }

    /// Grouped owners are placed by their group, so the Items tab must not offer them a choice.
    func group(containing item: FloatingBarItem) -> ItemGroup? {
        guard let key = ItemControlStore.key(for: item.snapshot) else { return nil }
        return ItemGroupLibrary.group(containing: key, in: preferences.itemGroups)
    }
    var pendingChangeCount: Int { placementDraft.ownerKeys.union(orderDraft.ownerKeys).count }

    func reloadItems() async {
        guard !Task.isCancelled else { return }
        placementDrag = nil
        itemsLoadGeneration &+= 1
        let generation = itemsLoadGeneration
        itemsLoading = true
        itemsLoadError = nil
        // Tab loads and placement refreshes can overlap without cancelling each other.
        defer {
            if generation == itemsLoadGeneration { itemsLoading = false }
        }
        do {
            let refreshed = try await itemsProvider()
            guard generation == itemsLoadGeneration, !Task.isCancelled else { return }
            loadedItems = refreshed
        } catch {
            guard generation == itemsLoadGeneration,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            itemsLoadError = "Could not read menu bar items. Try again."
        }
    }

    /// Grouping and row controls must agree so a failed move keeps its opposite action available.
    func partition(_ items: [FloatingBarItem]) -> (hidden: [FloatingBarItem], shown: [FloatingBarItem], alwaysHidden: [FloatingBarItem]) {
        var hidden: [FloatingBarItem] = []
        var shown: [FloatingBarItem] = []
        var alwaysHidden: [FloatingBarItem] = []
        for item in items {
            switch placement(of: item) {
            case .shown: shown.append(item)
            case .hidden: hidden.append(item)
            case .alwaysHidden: alwaysHidden.append(item)
            }
        }
        return (orderedPreviewItems(hidden, in: .hidden, includingSuppressed: true),
                orderedPreviewItems(shown, in: .shown, includingSuppressed: true),
                orderedPreviewItems(alwaysHidden, in: .alwaysHidden, includingSuppressed: true))
    }

    /// Pending placement can display intent, but an observed failure must remain actionable.
    func placement(of item: FloatingBarItem) -> ItemPlacement {
        if let staged = placementDraft.placement(for: item.snapshot) { return staged }
        let controls = effectiveControls
        if placementInProgress, placementIncludesTierChanges, let requested = controls.placement(for: item.snapshot) {
            return requested
        }
        return item.observedPlacement ?? controls.placement(for: item.snapshot) ?? .shown
    }

    /// Two-tier view of `placement(of:)`; Always Hidden reads as hidden.
    func isHidden(_ item: FloatingBarItem) -> Bool {
        placement(of: item).isHidden
    }

    func hasPendingChange(for item: FloatingBarItem) -> Bool {
        placementDraft.placement(for: item.snapshot) != nil
            || ItemControlStore.key(for: item.snapshot).map { orderDraft.ownerKeys.contains($0) } == true
    }

    func setHidden(_ hidden: Bool, for item: FloatingBarItem) {
        setPlacement(ItemPlacement(hidden: hidden), forAll: [item])
    }

    func setHidden(_ hidden: Bool, forAll items: [FloatingBarItem]) {
        setPlacement(ItemPlacement(hidden: hidden), forAll: items)
    }

    func canSetHidden(_ hidden: Bool, forAll items: [FloatingBarItem]) -> Bool {
        canSetPlacement(ItemPlacement(hidden: hidden), forAll: items)
    }

    func setPlacement(_ placement: ItemPlacement, for item: FloatingBarItem) {
        setPlacement(placement, forAll: [item])
    }

    func setPlacement(_ placement: ItemPlacement, forAll items: [FloatingBarItem]) {
        guard !placementInProgress else { return }
        placementDrag = nil
        draftDiscardedNotice = nil
        placementDraft = draftSettingPlacement(placement, forAll: items)
        for tier in ItemPlacement.allCases {
            orderDraft.reconcileMembership(in: tier, baseline: previewItems(in: tier, includingOrderDraft: false).map(\.snapshot))
        }
    }

    func canSetPlacement(_ placement: ItemPlacement, forAll items: [FloatingBarItem]) -> Bool {
        guard !placementInProgress else { return false }
        return draftSettingPlacement(placement, forAll: items) != placementDraft
    }

    private func draftSettingPlacement(_ placement: ItemPlacement, forAll items: [FloatingBarItem]) -> ItemPlacementDraft {
        // Grouped owners are placed by their group; staging them would save intent that only
        // takes effect after an ungroup.
        let items = items.filter { group(containing: $0) == nil }
        let keys = Set(items.compactMap { ItemControlStore.key(for: $0.snapshot) })
        let itemIDs = Set(items.map(\.id))
        let siblings = loadedItems.filter {
            guard let key = ItemControlStore.key(for: $0.snapshot) else { return false }
            return keys.contains(key) && !itemIDs.contains($0.id)
        }
        var draft = placementDraft
        draft.setPlacement(
            placement, for: (items + siblings).map { ($0.snapshot, $0.observedPlacement) },
            controls: preferences.itemControls
        )
        return draft
    }

    // MARK: - Local placement drags

    func canDragPlacement(of item: FloatingBarItem, from source: ItemPlacement?) -> Bool {
        guard !itemsLoading, !placementInProgress, let key = ItemControlStore.key(for: item.snapshot),
              let current = loadedItems.first(where: { $0.id == item.id }),
              ItemControlStore.key(for: current.snapshot) == key, group(containing: current) == nil else { return false }
        return previewPlacement(of: current, controls: placementDraft.applying(to: effectiveControls)) == source
    }

    func beginPlacementDrag(of item: FloatingBarItem, from source: ItemPlacement?) -> UUID? {
        guard canDragPlacement(of: item, from: source), let key = ItemControlStore.key(for: item.snapshot) else { return nil }
        let token = UUID()
        placementDrag = PlacementDrag(token: token, windowID: item.id, ownerKey: key, source: source)
        return token
    }

    func endPlacementDrag(_ token: UUID) {
        if placementDrag?.token == token { placementDrag = nil }
    }

    func cancelPlacementDrag() {
        placementDrag = nil
    }

    func canDropPlacement(_ token: UUID, into destination: ItemPlacement) -> Bool {
        placementDragItem(token, into: destination) != nil
    }

    @discardableResult
    func dropPlacement(_ token: UUID, into destination: ItemPlacement, before windowID: CGWindowID? = nil) -> Bool {
        guard let item = placementDragItem(token, into: destination) else { return false }
        let target = windowID.flatMap { id in previewItems(in: destination).first { $0.id == id } }
        guard windowID == nil || target != nil else { return false }
        let nextOwner = target.flatMap { ItemControlStore.key(for: $0.snapshot) }
        guard target == nil || nextOwner != nil else { return false }
        let changesTier = placementDrag?.source != destination
        if changesTier { setPlacement(destination, for: item) }
        stageOrder(item, before: nextOwner, in: destination,
                   ensurePosition: changesTier && placementDraft.placement(for: item.snapshot) != nil)
        placementDrag = nil
        return true
    }

    private func placementDragItem(_ token: UUID, into destination: ItemPlacement) -> FloatingBarItem? {
        guard let drag = placementDrag, drag.token == token,
              let item = loadedItems.first(where: { $0.id == drag.windowID }),
              ItemControlStore.key(for: item.snapshot) == drag.ownerKey,
              canDragPlacement(of: item, from: drag.source),
              drag.source == destination || canSetPlacement(destination, forAll: [item]) else { return nil }
        return item
    }

    // MARK: - Visibility and staged order

    /// Whether the floating bar draws this item; suppression never affects menu-bar placement.
    func isShownInBar(_ item: FloatingBarItem) -> Bool {
        !preferences.itemControls.isSuppressed(item.snapshot)
    }

    func setShownInBar(_ shown: Bool, for item: FloatingBarItem) {
        guard isShownInBar(item) != shown else { return }
        preferences.itemControls.setSuppressed(!shown, for: item.snapshot)
    }

    /// Bar order is per tier: a row can only trade places with rows shown in the same section.
    func canMoveInBar(_ item: FloatingBarItem, _ step: ItemControlStore.BarOrderStep) -> Bool {
        orderNeighbor(of: item, step: step) != nil
    }

    func moveInBar(_ item: FloatingBarItem, _ step: ItemControlStore.BarOrderStep) {
        guard let destination = orderNeighbor(of: item, step: step) else { return }
        placementDrag = nil
        stageOrder(item, before: destination.before, in: destination.placement)
    }

    private func orderNeighbor(of item: FloatingBarItem, step: ItemControlStore.BarOrderStep) -> (placement: ItemPlacement, before: String?)? {
        let tier = placement(of: item)
        guard canDragPlacement(of: item, from: tier), let key = ItemControlStore.key(for: item.snapshot) else { return nil }
        let owners = ItemOrderDraft.ownerOrder(previewItems(in: tier).map(\.snapshot))
        guard let index = owners.firstIndex(of: key),
              owners.indices.contains(index + (step == .earlier ? -1 : 1)) else { return nil }
        return (tier, step == .earlier ? owners[index - 1] : (index + 2 < owners.count ? owners[index + 2] : nil))
    }

    private func stageOrder(_ item: FloatingBarItem, before nextOwner: String?, in tier: ItemPlacement, ensurePosition: Bool = false) {
        guard let key = ItemControlStore.key(for: item.snapshot) else { return }
        let current = previewItems(in: tier).map(\.snapshot)
        let baseline = previewItems(in: tier, includingOrderDraft: false).map(\.snapshot)
        if orderDraft.move(key, before: nextOwner, in: tier, items: current, baseline: baseline, ensurePosition: ensurePosition) {
            draftDiscardedNotice = nil
        }
    }

    func applyPlacementChanges() {
        guard !placementInProgress, hasPendingChanges else { return }
        placementDrag = nil
        let hadPlacementChanges = !placementDraft.isEmpty
        let controls = orderDraft.applying(to: placementDraft.applying(to: preferences.itemControls))
        let nativeOrders = orderDraft.orders.filter { $0.key == .shown || !preferences.useFloatingBar }
            .mapValues { owners in owners.filter { ItemGroupLibrary.group(containing: $0, in: preferences.itemGroups) == nil } }
            .filter { !$0.value.isEmpty }
        let intentChanged = !controls.hasSamePlacementIntent(as: preferences.itemControls)
        // Callbacks can synchronously reenter Settings; no applied edits may remain pending.
        applyingOrder = orderDraft
        placementDraft = ItemPlacementDraft()
        orderDraft = ItemOrderDraft()
        if !nativeOrders.isEmpty { onStageItemOrder(nativeOrders, controls, hadPlacementChanges) }
        if controls != preferences.itemControls {
            preferences.itemControls = controls
        }
        if !intentChanged && (hadPlacementChanges || !nativeOrders.isEmpty) {
            // Cached section membership cannot verify the native destination's full-edge postcondition.
            onRetryPlacement()
        }
    }

    func discardPlacementChanges() {
        guard !placementInProgress else { return }
        placementDrag = nil
        placementDraft = ItemPlacementDraft()
        orderDraft = ItemOrderDraft()
    }

    func retryPlacement() {
        guard !placementInProgress, !hasPendingChanges, placementFailed || placementPending else { return }
        placementDrag = nil
        onRetryPlacement()
    }

    var placementPreview: (shown: [FloatingBarItem], hidden: [FloatingBarItem], alwaysHidden: [FloatingBarItem], unknown: [FloatingBarItem]) {
        placementPreview(includingSuppressed: false)
    }

    func placementPreview(includingSuppressed: Bool, includingOrderDraft: Bool = true) -> (shown: [FloatingBarItem], hidden: [FloatingBarItem], alwaysHidden: [FloatingBarItem], unknown: [FloatingBarItem]) {
        // A tier Apply reconciles all saved owners; order-only edits keep the observed tier membership.
        let controls = placementDraft.applying(to: effectiveControls)
        var shown: [FloatingBarItem] = []
        var hidden: [FloatingBarItem] = []
        var alwaysHidden: [FloatingBarItem] = []
        var unknown: [FloatingBarItem] = []
        for var item in loadedItems {
            item.alias = preferences.itemAliases.alias(for: item.snapshot)
            let projected = previewPlacement(of: item, controls: controls)
            switch projected {
            case .hidden?: hidden.append(item)
            case .alwaysHidden?: alwaysHidden.append(item)
            case .shown?: shown.append(item)
            case nil: unknown.append(item)
            }
        }
        return (orderedPreviewItems(shown, in: .shown, includingSuppressed: true, includingOrderDraft: includingOrderDraft),
                orderedPreviewItems(hidden, in: .hidden, includingSuppressed: includingSuppressed, includingOrderDraft: includingOrderDraft),
                orderedPreviewItems(alwaysHidden, in: .alwaysHidden, includingSuppressed: includingSuppressed, includingOrderDraft: includingOrderDraft), unknown)
    }

    private func orderedPreviewItems(
        _ items: [FloatingBarItem], in placement: ItemPlacement, includingSuppressed: Bool, includingOrderDraft: Bool = true
    ) -> [FloatingBarItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshots = items.map(\.snapshot)
        if placement.isHidden && preferences.useFloatingBar {
            snapshots = ItemControlStore.orderedBarItems(from: snapshots, controls: preferences.itemControls)
        }
        if includingOrderDraft {
            snapshots = (placementInProgress ? applyingOrder : orderDraft).ordered(snapshots, in: placement)
        }
        if !includingSuppressed { snapshots.removeAll { preferences.itemControls.isSuppressed($0) } }
        return snapshots.compactMap { byID[$0.windowID] }
    }

    func previewItems(in placement: ItemPlacement, includingOrderDraft: Bool = true) -> [FloatingBarItem] {
        let preview = placementPreview(includingSuppressed: true, includingOrderDraft: includingOrderDraft)
        switch placement {
        case .shown: return preview.shown
        case .hidden: return preview.hidden
        case .alwaysHidden: return preview.alwaysHidden
        }
    }

    private func previewPlacement(of item: FloatingBarItem, controls: ItemControlStore) -> ItemPlacement? {
        (!placementDraft.isEmpty || (placementInProgress && placementIncludesTierChanges)) && controls.hasPlacementIntent(item.snapshot)
            ? controls.placement(for: item.snapshot) : item.observedPlacement
    }

    /// The user's display nickname for the item, edited via the name field. Empty clears it.
    func alias(for item: FloatingBarItem) -> String {
        preferences.itemAliases.alias(for: item.snapshot) ?? ""
    }

    func setAlias(_ alias: String, for item: FloatingBarItem) {
        preferences.itemAliases.setAlias(alias, for: item.snapshot)
    }

    // MARK: - Layout export/import

    /// A short status line shown under the Backup buttons after an export/import. `nil` when
    /// there's nothing to report; `transferFailed` colors it as an error.
    private(set) var transferMessage: String?
    private(set) var transferFailed = false

    /// Writes the current settings to a user-chosen JSON file. A cancel clears the status line;
    /// a failed write names its reason so the user does not mistake it for a cancel.
    func exportLayout(
        using exporter: @MainActor (Preferences) -> LayoutTransferService.ExportOutcome = { LayoutTransferService.exportLayout($0) }
    ) {
        switch exporter(preferences) {
        case .saved(let url):
            transferFailed = false
            transferMessage = "Exported to \(url.lastPathComponent)."
        case .cancelled:
            transferMessage = nil
        case .failed(let reason):
            transferFailed = true
            transferMessage = "Couldn't write the layout file: \(reason)"
        }
    }

    /// Reads settings from a user-chosen JSON file and applies them. A malformed/incompatible
    /// file surfaces an error line instead of throwing into the UI. Assigning `preferences`
    /// triggers `onChange`, so the whole app (engine, bar, hotkeys) re-applies at once.
    func importLayout(
        using importer: @MainActor () throws -> Preferences? = { try LayoutTransferService.importLayout() }
    ) {
        do {
            if var imported = try importer() {
                // Keep the login-item registration in sync with the imported flag, and record
                // what actually took: if registration was rejected, don't persist a launchAtLogin
                // the system didn't honor (same truth-over-intent rule as the toggle setter).
                let succeeded = loginItem.setEnabled(imported.launchAtLogin)
                loginItemStatus = loginItem.status
                if !succeeded { imported.launchAtLogin = loginItem.isEnabled }
                // A trigger baseline and the onboarding flag describe this machine, not the file.
                imported.triggerState = TriggerRuntimeState()
                imported.hasCompletedOnboarding = preferences.hasCompletedOnboarding
                placementDraft = ItemPlacementDraft()
                orderDraft = ItemOrderDraft()
                placementDrag = nil
                preferences = imported
                onStageItemOrder([:], imported.itemControls, false)
                transferFailed = false
                transferMessage = "Imported settings."
            } else {
                transferMessage = nil // cancelled
            }
        } catch {
            transferFailed = true
            transferMessage = "Couldn't import that file — it isn't a valid layout."
        }
    }
}
