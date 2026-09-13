import AppKit
import BarKeepersFriendCore
import CoreGraphics
import Synchronization
import Testing

/// Engine wiring for the notch make-room integration, without status items, capture, or mouse events.
///
/// Two groups. The hostless group leaves the engine without a notch, so the coordinator's notch closure
/// returns nil and `makeRoom` skips before any read; it pins the default-off contract and the
/// mode/permission gates. The geometry group injects a synthetic notched display through
/// `notchGeometryProvider`, so the engine, coordinator, and planner run their production code against
/// `FakeWindowServer` deterministically on any machine.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NotchOverflowEngineTests {
    private let anchorID: CGWindowID = 90
    private let dividerID: CGWindowID = 91
    private let hiddenItemID: CGWindowID = 100
    private let victimID: CGWindowID = 1
    private let otherShownID: CGWindowID = 2

    /// Right usable edge used by the hostless fixtures; irrelevant there, since no notch is resolved.
    private static let notchlessRightEdge: CGFloat = 848

    /// A 1512pt notched display whose right usable area starts at x = 848, like a 14-inch MacBook Pro.
    nonisolated static let syntheticNotch = NotchGeometry(
        displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        leftArea: CGRect(x: 0, y: 950, width: 664, height: 32),
        rightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
    )

    // MARK: - Fixture

    private struct Fixture {
        let server: LoggingWindowServer
        let engine: CosmeticHideEngine
        let log: EventLog
        let preferences: Preferences
    }

    /// One hidden item straddles the notch's right edge by 18pt, so the shown item nearest the anchor
    /// (30pt) is the only planned victim; a second shown item proves the plan stops there.
    private func items(rightEdge r: CGFloat, hiddenItemClearsNotch: Bool = false) -> [MenuBarItemSnapshot] {
        let hiddenX = hiddenItemClearsNotch ? r + 40 : r - 18
        return [
            MenuBarItemSnapshot(windowID: hiddenItemID, ownerPID: 1, ownerBundleID: "Hidden App", frame: CGRect(x: hiddenX, y: 0, width: 30, height: 22)),
            MenuBarItemSnapshot(windowID: dividerID, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: r + 136, y: 0, width: 16, height: 22)),
            MenuBarItemSnapshot(windowID: anchorID, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: r + 152, y: 0, width: 32, height: 22)),
            MenuBarItemSnapshot(windowID: victimID, ownerPID: 1, ownerBundleID: "Victim App", frame: CGRect(x: r + 192, y: 0, width: 30, height: 22)),
            MenuBarItemSnapshot(windowID: otherShownID, ownerPID: 1, ownerBundleID: "Other App", frame: CGRect(x: r + 240, y: 0, width: 30, height: 22))
        ]
    }

    /// `notch` nil leaves the engine without a notch provider or anchor frame, so no notch resolves.
    private func makeFixture(
        mode: NotchOverflowMode,
        notch: NotchGeometry? = nil,
        autoRehide: Bool = false,
        autoRehideDelay: TimeInterval = 15,
        itemControls: ItemControlStore = ItemControlStore(),
        configureCoordinator: Bool = true,
        accessibility: Bool = true,
        hiddenItemClearsNotch: Bool = false
    ) -> Fixture {
        let rightEdge = notch?.rightArea?.minX ?? Self.notchlessRightEdge
        let log = EventLog()
        let server = LoggingWindowServer(items: items(rightEdge: rightEdge, hiddenItemClearsNotch: hiddenItemClearsNotch), log: log)
        server.base.canSynthesizeClicks = accessibility
        let preferences = Preferences(
            autoRehide: autoRehide, autoRehideDelay: autoRehideDelay, useFloatingBar: false,
            itemControls: itemControls, notchOverflow: mode
        )
        let controls = (anchor: anchorID, divider: dividerID)
        let anchorFrame = CGRect(x: rightEdge + 152, y: 0, width: 32, height: 24)
        let anchorFrameProvider: (() -> CGRect?)? = notch == nil ? nil : { anchorFrame }
        let engine = CosmeticHideEngine(
            preferences: preferences,
            controlWindowIDs: { controls },
            setDividerCollapsed: { log.record($0 ? .collapse : .reveal) },
            anchorFrame: anchorFrameProvider,
            onPreferencesChanged: { _ in }
        )
        engine.hiddenItemController = HiddenItemController(windowServer: server)
        if let notch { engine.notchGeometryProvider = { notch } }
        if configureCoordinator {
            engine.configureNotchOverflow(windowServer: server, attribute: { $0 })
        }
        return Fixture(server: server, engine: engine, log: log, preferences: preferences)
    }

    private func frame(of id: CGWindowID, in fixture: Fixture) -> CGRect? {
        fixture.server.base.items.first { $0.windowID == id }?.frame
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Make-room finishes with two synchronous reads and a result hop after its gesture lands; the
    /// gesture is the last externally visible step, so give the main actor a beat to drain them.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - Hostless: default off and inert gates

    @Test(arguments: [false, true])
    func neverModeCollapsesSynchronouslyWithoutObservingOrMoving(configureCoordinator: Bool) async throws {
        let f = makeFixture(mode: .never, configureCoordinator: configureCoordinator)
        defer { f.engine.uninstall() }
        #expect((f.engine.notchOverflowCoordinator != nil) == configureCoordinator)

        f.engine.toggleHidden()
        #expect(f.log.all == [.collapse])
        f.engine.toggleHidden()
        #expect(f.log.all == [.collapse, .reveal])
        // Past the 150ms make-room settle: `.never` must not even schedule a pass.
        try await Task.sleep(for: .milliseconds(250))
        #expect(f.log.all == [.collapse, .reveal])
        if let coordinator = f.engine.notchOverflowCoordinator {
            #expect(coordinator.currentMode == .never)
        }

        f.engine.toggleHidden()
        // Synchronous: the write lands inside the call, with no restore hop in between.
        #expect(f.log.all == [.collapse, .reveal, .collapse])
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .collapsed)

        await f.engine.revealForActivation()
        #expect(f.log.all == [.collapse, .reveal, .collapse, .reveal])
        f.engine.rehideAfterActivation()
        #expect(f.log.all == [.collapse, .reveal, .collapse, .reveal, .collapse])
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .collapsed)

        #expect(f.log.observeCount == 0)
        #expect(f.server.base.moveRequests.isEmpty)
        #expect(f.engine.notchOverflowCoordinator?.hasTuckedItems != true)
        #expect(f.engine.notchMessage == nil)
    }

    @Test func whenNeededWithoutAResolvableAnchorScreenSkipsBeforeObserving() async throws {
        let f = makeFixture(mode: .whenNeeded)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        #expect(coordinator.currentMode == .never)

        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(f.log.all == [.collapse, .reveal])
        // The pass runs after the settle and is stamped with the preference; a missing notch is a
        // skip ahead of the first read, so the fake server is never consulted.
        #expect(await waitUntil { coordinator.currentMode == .whenNeeded })
        await settle()
        #expect(f.log.observeCount == 0)
        #expect(f.server.base.moveRequests.isEmpty)
        #expect(!coordinator.hasTuckedItems)
        #expect(f.engine.notchMessage == nil)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)

        f.engine.toggleHidden()
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        #expect(f.log.all == [.collapse, .reveal, .collapse])
        #expect(f.log.observeCount == 0)
        #expect(f.server.base.moveRequests.isEmpty)
    }

    @Test func whenNeededWithoutAccessibilityNeverStartsAPass() async throws {
        let f = makeFixture(mode: .whenNeeded, accessibility: false)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)

        f.engine.toggleHidden()
        f.engine.toggleHidden()
        try await Task.sleep(for: .milliseconds(250))
        // Never stamped: the engine's gate rejected the pass before reaching the coordinator.
        #expect(coordinator.currentMode == .never)
        #expect(f.log.observeCount == 0)

        f.engine.toggleHidden()
        #expect(f.log.all == [.collapse, .reveal, .collapse])
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .collapsed)

        await f.engine.revealForActivation()
        #expect(coordinator.currentMode == .never)
        f.engine.rehideAfterActivation()
        #expect(f.log.all == [.collapse, .reveal, .collapse, .reveal, .collapse])
        #expect(f.server.base.moveRequests.isEmpty)
    }

    @Test func activationWithoutANotchMakesNoRoomAndStillRehides() async throws {
        let f = makeFixture(mode: .whenNeeded)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()

        // The activation awaits its make-room pass inline, so the stamp is visible on return.
        await f.engine.revealForActivation()
        #expect(coordinator.currentMode == .whenNeeded)
        #expect(f.log.all == [.collapse, .reveal])
        #expect(f.log.observeCount == 0)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)

        f.engine.rehideAfterActivation()
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        #expect(f.log.all == [.collapse, .reveal, .collapse])
        #expect(f.log.observeCount == 0)
        #expect(f.server.base.moveRequests.isEmpty)
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func pauseAndResumeWithNothingTuckedCollapseSynchronously() async throws {
        let f = makeFixture(mode: .whenNeeded)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { coordinator.currentMode == .whenNeeded })
        await settle()

        f.engine.menuTogglePause()
        #expect(f.engine.paused)
        #expect(f.log.all == [.collapse, .reveal, .reveal])
        await settle()
        #expect(f.log.observeCount == 0)

        f.engine.menuTogglePause()
        // Nothing tucked, so resume collapses inside the call rather than behind a restore hop.
        #expect(f.log.all == [.collapse, .reveal, .reveal, .collapse])
        #expect(!f.engine.paused)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .collapsed)
        if let placement = f.engine.placementTask { await placement.value }
        #expect(f.log.observeCount == 0)
        #expect(f.server.base.moveRequests.isEmpty)
    }

    @Test func reconcileWithNothingTuckedRunsOnlyThePlacementMove() async throws {
        let f = makeFixture(mode: .whenNeeded, itemControls: ItemControlStore(hiddenInMenuBar: ["Other App"]))
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { coordinator.currentMode == .whenNeeded })
        await settle()

        f.engine.reconcileHiddenItems()
        await (try #require(f.engine.placementTask)).value

        #expect(f.log.moves == [.move(otherShownID, target: dividerID)])
        #expect(!f.engine.placementFailed)
        #expect(!f.engine.placementPending)
        #expect(!coordinator.hasTuckedItems)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(f.log.all.last == .collapse)
        let other = try #require(frame(of: otherShownID, in: f))
        let divider = try #require(frame(of: dividerID, in: f))
        #expect(other.maxX <= divider.minX)
    }

    @Test func autoRehideWithNothingTuckedStillCollapsesAfterTheDelay() async throws {
        let f = makeFixture(mode: .whenNeeded, autoRehide: true, autoRehideDelay: 2)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { coordinator.currentMode == .whenNeeded })
        try await Task.sleep(for: .milliseconds(500))
        #expect(f.log.all == [.collapse, .reveal])

        #expect(await waitUntil(timeout: .seconds(4)) { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        #expect(f.log.all == [.collapse, .reveal, .collapse])
        #expect(f.log.observeCount == 0)
        #expect(f.server.base.moveRequests.isEmpty)
    }

    // MARK: - Synthetic notch geometry: make room, then restore before every collapse

    @Test
    func toggleHiddenMakesRoomOnceAndRestoresBeforeTheCollapseWrite() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        let rightEdge = try #require(notch.rightArea?.minX)
        let hiddenBefore = try #require(frame(of: hiddenItemID, in: f))
        #expect(hiddenBefore.minX < rightEdge)

        f.engine.toggleHidden()
        f.engine.toggleHidden()
        // The reveal write is synchronous; the make-room gesture follows the 150ms settle.
        #expect(f.log.all == [.collapse, .reveal])
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()

        #expect(f.log.moves == [.move(victimID, target: hiddenItemID)])
        #expect(coordinator.tucked.map(\.item.windowID) == [victimID])
        #expect(coordinator.tucked.map(\.neighborWindowID) == [anchorID])
        #expect(coordinator.currentMode == .whenNeeded)
        #expect(f.engine.notchMessage == nil)
        let victim = try #require(frame(of: victimID, in: f))
        #expect(victim.maxX <= hiddenBefore.minX)
        #expect(victim.maxX == hiddenBefore.minX - HiddenLayoutPlanner.hiddenMargin)
        let other = try #require(frame(of: otherShownID, in: f))
        #expect(other.minX == rightEdge + 240)
        // One pass per reveal: nothing else moves while the section stays open.
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.log.moves.count == 1)
        #expect(f.log.all.filter { $0 == .collapse }.count == 1)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)

        let before = f.log.all.count
        f.engine.toggleHidden()
        // The collapse must wait for the restore gesture, so it cannot have landed in the call.
        #expect(!f.log.all.suffix(from: before).contains(.collapse))
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        let tail = f.log.all.suffix(from: before).filter { $0 != .observe }
        #expect(tail == [.move(victimID, target: anchorID), .collapse])
        #expect(!coordinator.hasTuckedItems)
        let anchor = try #require(frame(of: anchorID, in: f))
        let restored = try #require(frame(of: victimID, in: f))
        #expect(restored.minX == anchor.maxX + HiddenLayoutPlanner.shownMargin)
        #expect(f.engine.notchMessage == nil)
    }

    @Test
    func activationMakesRoomAndASupersedingActivationKeepsTheSectionOpen() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()

        await f.engine.revealForActivation()
        #expect(f.log.moves == [.move(victimID, target: hiddenItemID)])
        #expect(coordinator.hasTuckedItems)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(f.log.all.filter { $0 == .collapse }.count == 1)

        let hold = f.server.holdNextMove()
        f.engine.rehideAfterActivation()
        await hold.started.wait()
        #expect(f.log.all.filter { $0 == .collapse }.count == 1)
        #expect(coordinator.hasTuckedItems)

        // A second activation while the first's restore gesture is still in flight.
        let second = Task { await f.engine.revealForActivation() }
        #expect(await waitUntil { f.log.all.filter { $0 == .reveal }.count == 2 })
        await hold.release.open()
        await second.value

        // The stale collapse was skipped by the generation check; the successor re-made room.
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(f.log.all.filter { $0 == .collapse }.count == 1)
        #expect(f.log.moves == [
            .move(victimID, target: hiddenItemID),
            .move(victimID, target: anchorID),
            .move(victimID, target: hiddenItemID)
        ])
        #expect(coordinator.tucked.map(\.item.windowID) == [victimID])

        f.engine.rehideAfterActivation()
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        #expect(f.log.moves.count == 4)
        #expect(f.log.moves.last == .move(victimID, target: anchorID))
        #expect(f.log.all.last == .collapse)
        #expect(!coordinator.hasTuckedItems)
        #expect(f.engine.notchMessage == nil)
    }

    @Test
    func pauseWhileTuckedRestoresAndResumeWithNothingTuckedCollapsesSynchronously() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()
        #expect(coordinator.hasTuckedItems)

        f.engine.menuTogglePause()
        #expect(f.engine.paused)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)
        // Pause reveals everything, including undoing the engine's own displacement.
        #expect(await waitUntil { !coordinator.hasTuckedItems })
        await settle()
        #expect(f.log.moves == [.move(victimID, target: hiddenItemID), .move(victimID, target: anchorID)])
        #expect(f.log.all.filter { $0 == .collapse }.count == 1)
        let anchor = try #require(frame(of: anchorID, in: f))
        #expect(try #require(frame(of: victimID, in: f)).minX >= anchor.maxX)

        f.engine.menuTogglePause()
        #expect(f.log.all.last == .collapse)
        #expect(!f.engine.paused)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .collapsed)
        if let placement = f.engine.placementTask { await placement.value }
        #expect(f.log.moves.count == 2)
    }

    @Test
    func resumeWhileTheRestoreIsStillInFlightCollapsesOnlyAfterIt() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()

        let hold = f.server.holdNextMove()
        f.engine.menuTogglePause()
        await hold.started.wait()
        #expect(coordinator.hasTuckedItems)

        f.engine.menuTogglePause()
        #expect(!f.engine.paused)
        try await Task.sleep(for: .milliseconds(150))
        // Still tucked, so the resume collapse is parked behind the restore gesture.
        #expect(f.log.all.filter { $0 == .collapse }.count == 1)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)

        await hold.release.open()
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        #expect(f.log.moves == [.move(victimID, target: hiddenItemID), .move(victimID, target: anchorID)])
        #expect(f.log.all.last == .collapse)
        #expect(!coordinator.hasTuckedItems)
        if let placement = f.engine.placementTask { await placement.value }
        #expect(f.log.moves.count == 2)
    }

    @Test
    func reconcileStartedWhileTuckedRestoresVictimsBeforePlanning() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch, itemControls: ItemControlStore(hiddenInMenuBar: ["Other App"]))
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()
        #expect(coordinator.hasTuckedItems)

        f.engine.reconcileHiddenItems()
        await (try #require(f.engine.placementTask)).value

        // The victim returns to the shown side before the placement plan is read, so the plan
        // moves only the item with intent and the victim is not stranded in the hidden section.
        #expect(f.log.moves == [
            .move(victimID, target: hiddenItemID),
            .move(victimID, target: anchorID),
            .move(otherShownID, target: dividerID)
        ])
        #expect(!coordinator.hasTuckedItems)
        #expect(!f.engine.placementFailed)
        #expect(!f.engine.placementPending)
        #expect(f.engine.placementMessage == nil)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(f.log.all.last == .collapse)
        let anchor = try #require(frame(of: anchorID, in: f))
        let divider = try #require(frame(of: dividerID, in: f))
        #expect(try #require(frame(of: victimID, in: f)).minX >= anchor.maxX)
        #expect(try #require(frame(of: otherShownID, in: f)).maxX <= divider.minX)
    }

    @Test(arguments: [false, true])
    func autoRehideRestoresVictimsBeforeCollapsing(viaActivation: Bool) async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch, autoRehide: true, autoRehideDelay: 2)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()

        if viaActivation {
            await f.engine.revealForActivation()
            f.engine.scheduleAutoRehideAfterActivation()
        } else {
            f.engine.toggleHidden()
        }
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()
        #expect(coordinator.hasTuckedItems)
        #expect(f.log.all.filter { $0 == .collapse }.count == 1)
        let before = f.log.all.count

        #expect(await waitUntil(timeout: .seconds(4)) { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        let tail = f.log.all.suffix(from: before).filter { $0 != .observe }
        #expect(tail == [.move(victimID, target: anchorID), .collapse])
        #expect(!coordinator.hasTuckedItems)
        let anchor = try #require(frame(of: anchorID, in: f))
        #expect(try #require(frame(of: victimID, in: f)).minX >= anchor.maxX)
    }

    @Test
    func optionClickCollapseRestoresVictimsBeforeBothTiersClose() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()

        // Widens the reveal to both tiers; the earlier victim stays tucked.
        f.engine.toggleAllSections()
        #expect(f.engine.stateMachine.visibility(of: .alwaysHidden) == .shown)
        #expect(coordinator.hasTuckedItems)
        let before = f.log.all.count

        f.engine.toggleAllSections()
        #expect(!f.log.all.suffix(from: before).contains(.collapse))
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        let tail = f.log.all.suffix(from: before).filter { $0 != .observe }
        #expect(tail == [.move(victimID, target: anchorID), .collapse])
        #expect(f.engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)
        #expect(!coordinator.hasTuckedItems)
    }

    @Test
    func turningTheSettingOffWhileTuckedStillRestoresOnTheNextCollapse() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()

        var preferences = f.preferences
        preferences.notchOverflow = .never
        f.engine.apply(preferences: preferences)
        #expect(f.engine.placementTask == nil)
        #expect(coordinator.hasTuckedItems)
        let before = f.log.all.count

        f.engine.toggleHidden()
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        let tail = f.log.all.suffix(from: before).filter { $0 != .observe }
        #expect(tail == [.move(victimID, target: anchorID), .collapse])
        #expect(!coordinator.hasTuckedItems)

        // With the setting off, the next reveal makes no room and collapses without a gesture.
        f.engine.toggleHidden()
        try await Task.sleep(for: .milliseconds(250))
        #expect(f.log.moves.count == 2)
        let observesBefore = f.log.observeCount
        f.engine.toggleHidden()
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        #expect(f.log.moves.count == 2)
        #expect(f.log.observeCount == observesBefore)
    }

    @Test func quitRestoresTuckedVictimsBeforeTeardown() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        #expect(!f.engine.hasNotchVictimsToRestore)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()
        #expect(coordinator.hasTuckedItems)
        #expect(f.engine.hasNotchVictimsToRestore)

        // Quitting with a victim tucked would persist it on the wrong side; the delegate awaits this.
        await f.engine.restoreNotchVictimsBeforeQuit()
        f.engine.uninstall()

        #expect(f.log.moves == [.move(victimID, target: hiddenItemID), .move(victimID, target: anchorID)])
        #expect(!coordinator.hasTuckedItems)
        #expect(!f.engine.hasNotchVictimsToRestore)
        let anchor = try #require(frame(of: anchorID, in: f))
        #expect(try #require(frame(of: victimID, in: f)).minX >= anchor.maxX)
    }

    @Test func quitRestoreGivesUpAfterItsTimeoutWhenTheMoveNeverReturns() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()

        let hold = f.server.holdNextMove()
        let started = ContinuousClock.now
        let quit = Task { await f.engine.restoreNotchVictimsBeforeQuit(timeout: .milliseconds(300)) }
        await hold.started.wait()
        await quit.value
        // A wedged native move must not block quitting; the record stays for a later restore.
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(coordinator.hasTuckedItems)
        await hold.release.open()
        #expect(await waitUntil { !coordinator.hasTuckedItems })
    }

    @Test func aRevealThatNeededNoRoomLeavesLaterCollapsesSynchronous() async throws {
        // The hidden item already sits right of the notch, so the pass runs but tucks nothing.
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch, hiddenItemClearsNotch: true)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(await waitUntil { coordinator.currentMode == .whenNeeded })
        await settle()
        #expect(f.log.observeCount >= 1)
        #expect(f.server.base.moveRequests.isEmpty)
        #expect(!coordinator.hasTuckedItems)

        f.engine.toggleHidden()
        // Nothing to restore, so the collapse write lands inside the call.
        #expect(f.log.all.last == .collapse)
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .collapsed)

        // A fast reveal/collapse/reveal must end revealed, not swallowed by a stale async hop.
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        f.engine.toggleHidden()
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(f.log.all.suffix(3) == [.reveal, .collapse, .reveal])
        await settle()
        #expect(f.server.base.moveRequests.isEmpty)
    }

    @Test func optionClickRevealMakesRoomAndItsCollapseRestoresFirst() async throws {
        let notch = Self.syntheticNotch
        let f = makeFixture(mode: .whenNeeded, notch: notch)
        defer { f.engine.uninstall() }
        let coordinator = try #require(f.engine.notchOverflowCoordinator)
        f.engine.toggleHidden()

        f.engine.toggleAllSections()
        #expect(f.engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(await waitUntil { f.log.moves.count == 1 })
        await settle()
        #expect(f.log.moves == [.move(victimID, target: hiddenItemID)])
        #expect(coordinator.tucked.map(\.item.windowID) == [victimID])
        let before = f.log.all.count

        f.engine.toggleAllSections()
        #expect(!f.log.all.suffix(from: before).contains(.collapse))
        #expect(await waitUntil { f.engine.stateMachine.visibility(of: .hidden) == .collapsed })
        let tail = f.log.all.suffix(from: before).filter { $0 != .observe }
        #expect(tail == [.move(victimID, target: anchorID), .collapse])
        #expect(!coordinator.hasTuckedItems)
    }
}

// MARK: - Recording fixtures

/// Divider writes and window-server calls in one ordered log, so a test can assert that a restore
/// gesture lands before the collapse write that follows it.
private enum Event: Equatable, Sendable {
    case reveal
    case collapse
    case observe
    case move(CGWindowID, target: CGWindowID)
}

private final class EventLog: Sendable {
    private let storage = Mutex<[Event]>([])

    func record(_ event: Event) {
        storage.withLock { $0.append(event) }
    }

    var all: [Event] { storage.withLock { $0 } }

    var moves: [Event] {
        all.filter { if case .move = $0 { return true } else { return false } }
    }

    var observeCount: Int { all.filter { $0 == .observe }.count }
}

/// Routes every call to a `FakeWindowServer` while logging reads and completed moves. One move at a
/// time can be parked on a gate so a test can act while that native gesture is still in flight.
private final class LoggingWindowServer: WindowServer, @unchecked Sendable {
    let base: FakeWindowServer
    let log: EventLog
    private let pendingHold = Mutex<MoveHold?>(nil)

    struct MoveHold: Sendable {
        let started = AsyncGate()
        let release = AsyncGate()
    }

    init(items: [MenuBarItemSnapshot], log: EventLog) {
        base = FakeWindowServer(items: items)
        self.log = log
    }

    var canSynthesizeClicks: Bool { base.canSynthesizeClicks }

    /// The next move waits on the returned gate before touching the fake bar.
    func holdNextMove() -> MoveHold {
        let hold = MoveHold()
        pendingHold.withLock { $0 = hold }
        return hold
    }

    func menuBarItems() throws -> [MenuBarItemSnapshot] {
        log.record(.observe)
        return try base.menuBarItems()
    }

    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        try base.menuBarFrame(forDisplayContaining: point)
    }

    func click(item: MenuBarItemSnapshot) throws {
        try base.click(item: item)
    }

    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        let hold = pendingHold.withLock { hold -> MoveHold? in
            defer { hold = nil }
            return hold
        }
        if let hold {
            await hold.started.open()
            await hold.release.wait()
        }
        try await base.move(item: item, toX: targetX, relativeTo: targetWindowID)
        log.record(.move(item.windowID, target: targetWindowID))
    }
}
