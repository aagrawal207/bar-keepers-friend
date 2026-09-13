import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FloatingBarControllerTests {
    private let item = MenuBarItemSnapshot(
        windowID: 1, ownerPID: 1, ownerBundleID: "test.app",
        frame: CGRect(x: 100, y: 0, width: 22, height: 22)
    )

    @Test(arguments: [false, true])
    func interruptedClickDoesNotFallbackOrDisableAndAFreshRequestCanSucceed(useAXActivation: Bool) async throws {
        let server = MutableWindowServer(items: [item])
        server.clickError = CancellationError()
        let image = try glyph(side: 8)
        var axCalls = 0
        var rehideCalls = 0
        var autoRehideCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] },
            preferences: Preferences(useAXActivation: useAXActivation), attribute: { $0 },
            activateWithAX: { _, _, _ in axCalls += 1; return false }
        )
        bar.rehideItems = { rehideCalls += 1 }
        bar.scheduleAutoRehideAfterActivation = { autoRehideCalls += 1 }
        await bar.captureAndCache(anchorMinX: 1000)
        bar.activate(windowID: item.windowID)
        let interrupted = try #require(bar.currentActivationTask)
        await interrupted.value

        #expect(!interrupted.isCancelled)
        #expect(server.clickCount == 1)
        #expect(server.base.clickedWindowIDs.isEmpty)
        #expect(axCalls == 0)
        #expect(rehideCalls == 1)
        #expect(autoRehideCalls == 0)
        let items = try await bar.allManageableItems()
        #expect(items.first?.isDisabled == false)

        server.clickError = nil
        bar.activate(windowID: item.windowID)
        await (try #require(bar.currentActivationTask)).value
        #expect(server.base.clickedWindowIDs == [item.windowID])
        #expect(axCalls == 0)
        #expect(rehideCalls == 1)
        #expect(autoRehideCalls == 1)
    }

    @Test func interruptedAXDoesNotDisableAndReleasesAnUncancelledRequest() async throws {
        let server = MutableWindowServer(items: [item])
        server.clickError = WindowServerError.clickFailed(windowID: item.windowID)
        let image = try glyph(side: 8)
        var axCalls = 0
        var cleanupCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] },
            preferences: Preferences(useAXActivation: true), attribute: { $0 },
            activateWithAX: { _, _, _ in axCalls += 1; throw CancellationError() }
        )
        bar.rehideItems = { cleanupCalls += 1 }
        bar.scheduleAutoRehideAfterActivation = { cleanupCalls += 1 }
        await bar.captureAndCache(anchorMinX: 1000)
        bar.activate(windowID: item.windowID)
        let interrupted = try #require(bar.currentActivationTask)
        await interrupted.value

        #expect(!interrupted.isCancelled)
        #expect(server.clickCount == 1)
        #expect(axCalls == 1)
        #expect(cleanupCalls == 1)
        let items = try await bar.allManageableItems()
        #expect(items.first?.isDisabled == false)
    }

    @Test(arguments: [false, true], [false, true])
    func lateAXInterruptionCannotOverwriteTheNewerRequest(newerSucceeds: Bool, newerFinishesFirst: Bool) async throws {
        let other = snapshot(2, x: 200, owner: "test.other")
        let server = MutableWindowServer(items: [item, other])
        server.clickError = WindowServerError.clickFailed(windowID: item.windowID)
        let image = try glyph(side: 8)
        let oldStarted = AsyncGate()
        let oldFinish = AsyncGate()
        let newStarted = AsyncGate()
        let newFinish = AsyncGate()
        var axCalls: [CGWindowID] = []
        var rehideCalls = 0
        var autoRehideCalls = 0
        let preferences = Preferences(useAXActivation: true)
        let engine = CosmeticHideEngine(preferences: preferences, onPreferencesChanged: { _ in })
        defer { engine.uninstall() }
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image, 2: image] },
            preferences: preferences, attribute: { $0 },
            activateWithAX: { id, _, _ in
                axCalls.append(id)
                if id == 1 {
                    await oldStarted.open()
                    await oldFinish.wait()
                    throw CancellationError()
                }
                await newStarted.open()
                await newFinish.wait()
                return newerSucceeds
            }
        )
        engine.floatingBar = bar
        engine.toggleHidden()
        bar.revealHiddenItems = { await engine.revealForActivation() }
        bar.rehideItems = { rehideCalls += 1; engine.rehideAfterActivation() }
        bar.scheduleAutoRehideAfterActivation = { autoRehideCalls += 1; engine.scheduleAutoRehideAfterActivation() }
        await bar.captureAndCache(anchorMinX: 1000)
        bar.activate(windowID: item.windowID)
        let old = try #require(bar.currentActivationTask)
        await oldStarted.wait()
        bar.activate(windowID: other.windowID)
        let newer = try #require(bar.currentActivationTask)
        await newStarted.wait()
        if newerFinishesFirst {
            await newFinish.open()
            await newer.value
        }
        await oldFinish.open()
        await old.value
        #expect(old.isCancelled)
        #expect(!newer.isCancelled)
        #expect(bar.currentActivationTask == newer)
        if !newerFinishesFirst {
            #expect(rehideCalls == 0)
            #expect(autoRehideCalls == 0)
            await newFinish.open()
            await newer.value
        }

        #expect(axCalls == [1, 2])
        #expect(server.clickCount == 2)
        #expect(rehideCalls == (newerSucceeds ? 0 : 1))
        #expect(autoRehideCalls == (newerSucceeds ? 1 : 0))
        #expect(engine.stateMachine.visibility(of: .hidden) == (newerSucceeds ? .shown : .collapsed))
        let items = try await bar.allManageableItems()
        #expect(items.first(where: { $0.id == 1 })?.isDisabled == false)
        #expect(items.first(where: { $0.id == 2 })?.isDisabled == !newerSucceeds)
    }

    @Test(arguments: [false, true])
    func interruptedCurrentActivationReleasesRealEngineOwnership(interruptAX: Bool) async throws {
        let server = MutableWindowServer(items: [item])
        server.clickError = interruptAX ? WindowServerError.clickFailed(windowID: item.windowID) : CancellationError()
        let image = try glyph(side: 8)
        let preferences = Preferences(autoRehide: true, autoRehideDelay: 2, useAXActivation: true, revealOnHover: true)
        var dividerWrites: [Bool] = []
        let engine = CosmeticHideEngine(
            preferences: preferences, setDividerCollapsed: { dividerWrites.append($0) },
            onPreferencesChanged: { _ in }
        )
        defer { engine.uninstall() }
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] }, preferences: preferences,
            attribute: { $0 }, activateWithAX: { _, _, _ in throw CancellationError() }
        )
        engine.floatingBar = bar
        engine.toggleHidden()
        bar.revealHiddenItems = { await engine.revealForActivation() }
        bar.rehideItems = { engine.rehideAfterActivation() }
        bar.scheduleAutoRehideAfterActivation = { engine.scheduleAutoRehideAfterActivation() }
        await bar.captureAndCache(anchorMinX: 1000)
        dividerWrites.removeAll()
        bar.activate(windowID: item.windowID)
        let task = try #require(bar.currentActivationTask)
        await task.value
        #expect(!task.isCancelled)
        #expect(dividerWrites == [false, true])
        #expect(engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(engine.canRevealOnHover)
        #expect(try await bar.allManageableItems().first?.isDisabled == false)
    }

    @Test(arguments: [false, true])
    func ordinaryClickAndAXErrorsStillDisableTheItem(useAXActivation: Bool) async throws {
        let server = MutableWindowServer(items: [item])
        server.clickError = WindowServerError.clickFailed(windowID: item.windowID)
        let image = try glyph(side: 8)
        var axCalls = 0
        var rehideCalls = 0
        var autoRehideCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] },
            preferences: Preferences(useAXActivation: useAXActivation), attribute: { $0 },
            activateWithAX: { id, _, _ in axCalls += 1; throw WindowServerError.clickFailed(windowID: id) }
        )
        bar.rehideItems = { rehideCalls += 1 }
        bar.scheduleAutoRehideAfterActivation = { autoRehideCalls += 1 }
        await bar.captureAndCache(anchorMinX: 1000)
        bar.activate(windowID: item.windowID)
        await (try #require(bar.currentActivationTask)).value

        #expect(axCalls == (useAXActivation ? 1 : 0))
        #expect(rehideCalls == 1)
        #expect(autoRehideCalls == 0)
        let items = try await bar.allManageableItems()
        #expect(items.first?.isDisabled == true)
    }

    @Test(arguments: [false, true])
    func lateUncancelledAXCompletionStillCleansUp(succeeded: Bool) async throws {
        let server = FakeWindowServer(items: [item])
        server.clickError = .clickFailed(windowID: item.windowID)
        let image = try glyph(side: 8)
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] },
            preferences: Preferences(useAXActivation: true), attribute: { $0 },
            activateWithAX: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(5100))
                return succeeded
            }
        )
        var rehideCalls = 0
        var autoRehideCalls = 0
        bar.rehideItems = { rehideCalls += 1 }
        bar.scheduleAutoRehideAfterActivation = { autoRehideCalls += 1 }
        await bar.captureAndCache(anchorMinX: 1000)
        bar.activate(windowID: item.windowID)
        let task = try #require(bar.currentActivationTask)
        await task.value

        #expect(rehideCalls == (succeeded ? 0 : 1))
        #expect(autoRehideCalls == (succeeded ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func cancelledAXCompletionCannotRehideOrScheduleATimer(succeeded: Bool) async throws {
        let server = FakeWindowServer(items: [item])
        server.clickError = .clickFailed(windowID: item.windowID)
        let image = try glyph(side: 8)
        let started = AsyncGate()
        let finish = AsyncGate()
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] },
            preferences: Preferences(useAXActivation: true), attribute: { $0 },
            activateWithAX: { _, _, _ in
                await started.open()
                await finish.wait()
                return succeeded
            }
        )
        var cleanupCalls = 0
        bar.rehideItems = { cleanupCalls += 1 }
        bar.scheduleAutoRehideAfterActivation = { cleanupCalls += 1 }
        await bar.captureAndCache(anchorMinX: 1000)
        bar.activate(windowID: item.windowID)
        let task = try #require(bar.currentActivationTask)
        await started.wait()
        bar.hide()
        await finish.open()
        await task.value

        #expect(cleanupCalls == 0)
        let cached = try await bar.allManageableItems()
        #expect(cached.first?.isDisabled == false)
    }

    @Test func cancellationBeforeCaptureSkipsAllDependencies() async {
        var attributionCalls = 0
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(items: [item]),
            captureIcons: { _ in captureCalls += 1; return [:] },
            preferences: .default,
            attribute: { attributionCalls += 1; return $0 }
        )
        let task = Task { await bar.captureAndCache(anchorMinX: 1000) }
        task.cancel()
        await task.value

        #expect(attributionCalls == 0)
        #expect(captureCalls == 0)
        #expect(!bar.hasCapturedOnce)
    }

    @Test func pausingDuringAttributionDoesNotStartAScreenshot() async {
        let started = AsyncGate()
        let finish = AsyncGate()
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(items: [item]),
            captureIcons: { _ in captureCalls += 1; return [:] },
            preferences: .default,
            attribute: { snapshots in
                await started.open()
                await finish.wait()
                return snapshots
            }
        )
        let engine = CosmeticHideEngine(preferences: .default, onPreferencesChanged: { _ in })
        engine.floatingBar = bar
        let task = engine.runCaptureSequence(forceCollapseAfter: true) {
            await bar.captureAndCache(anchorMinX: 1000)
        }
        await started.wait()
        engine.menuTogglePause()
        await finish.open()
        await task.value

        #expect(captureCalls == 0)
        #expect(!bar.hasCapturedOnce)
        #expect(!bar.isVisible)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
    }

    @Test(arguments: [false, true])
    func lateScreenshotAfterPauseIsDiscardedWithoutRetry(blankScreenshot: Bool) async throws {
        let started = AsyncGate()
        let finish = AsyncGate()
        let image = try glyph(side: 8)
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(items: [item]),
            captureIcons: { _ in
                captureCalls += 1
                await started.open()
                await finish.wait()
                return blankScreenshot ? [:] : [1: image]
            },
            preferences: .default, attribute: { $0 }
        )
        let engine = CosmeticHideEngine(preferences: .default, onPreferencesChanged: { _ in })
        engine.floatingBar = bar
        let task = engine.runCaptureSequence(forceCollapseAfter: true) {
            await bar.captureAndCache(anchorMinX: 1000)
        }
        await started.wait()
        engine.menuTogglePause()
        await finish.open()
        await task.value

        #expect(captureCalls == 1)
        #expect(!bar.hasCapturedOnce)
        #expect(!bar.isVisible)
        #expect(engine.stateMachine.visibility(of: .hidden) == .shown)
    }

    @Test func cancelledRefreshPreservesPreviouslyCachedGlyph() async throws {
        let started = AsyncGate()
        let finish = AsyncGate()
        let original = try glyph(side: 8)
        let late = try glyph(side: 16)
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(items: [item]),
            captureIcons: { _ in
                captureCalls += 1
                if captureCalls == 1 { return [1: original] }
                await started.open()
                await finish.wait()
                return [1: late]
            },
            preferences: .default, attribute: { $0 }
        )
        await bar.captureAndCache(anchorMinX: 1000)
        let task = Task { await bar.captureAndCache(anchorMinX: 1000) }
        await started.wait()
        task.cancel()
        await finish.open()
        await task.value

        let cached = try await bar.allManageableItems()
        #expect(cached.count == 1)
        #expect(cached.first?.image.size == CGSize(width: 8, height: 8))
        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)
        #expect(captureCalls == 2)
    }

    @Test func completedCaptureRemainsUsableAfterAnEarlierCancellation() async throws {
        let image = try glyph(side: 8)
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(items: [item]),
            captureIcons: { _ in captureCalls += 1; return [1: image] },
            preferences: .default, attribute: { $0 }
        )
        let cancelled = Task { await bar.captureAndCache(anchorMinX: 1000) }
        cancelled.cancel()
        await cancelled.value
        await bar.captureAndCache(anchorMinX: 1000)

        #expect(captureCalls == 1)
        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 1000))
    }

    @Test func emptyCaptureCompletesWithoutAttributionOrScreenshot() async {
        var attributionCalls = 0
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(),
            captureIcons: { _ in captureCalls += 1; return [:] },
            preferences: .default,
            attribute: { attributionCalls += 1; return $0 }
        )
        await bar.captureAndCache(anchorMinX: 1000)

        #expect(attributionCalls == 0)
        #expect(captureCalls == 0)
        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)
    }

    @Test func dividerBoundaryControlsMirrorAndObservedPlacementRegardlessOfIntent() async throws {
        let hidden = snapshot(1, x: 278, owner: "test.hidden")
        let shown = snapshot(2, x: 340, owner: "test.shown")
        let crossing = snapshot(3, x: 290)
        let tucked = snapshot(4, x: -200)
        let divider = snapshot(90, x: 300, width: 22)
        let staleDivider = snapshot(91, x: 200, title: ControlItem.Identifier.hiddenDivider.rawValue)
        let server = MutableWindowServer(items: [hidden, shown, crossing, tucked, staleDivider, divider])
        let image = try glyph(side: 8)
        var capturedIDs: [CGWindowID] = []
        var preferences = Preferences.default
        preferences.itemControls = ItemControlStore(
            hiddenInMenuBar: ["test.shown"], shownInMenuBar: ["test.hidden"]
        )
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in
                capturedIDs = items.map(\.windowID)
                return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
            },
            preferences: preferences, attribute: { $0 }
        )
        bar.hiddenDividerWindowID = divider.windowID
        await bar.captureAndCache(anchorMinX: 500)

        #expect(capturedIDs == [4, 1])
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 500))
        let items = try await bar.allManageableItems()
        #expect(items.map(\.id) == [4, 1, 3, 2])
        #expect(items.map(\.observedHidden) == [true, true, false, false])
        #expect(bar.preferences == preferences)

        server.base = FakeWindowServer(items: [hidden, shown, crossing, tucked, staleDivider, snapshot(90, x: 250)])
        #expect(bar.cachedMirrorIsStale(anchorMinX: 500))
        let movedBoundary = try await bar.allManageableItems()
        #expect(movedBoundary.map(\.observedHidden) == [true, false, false, false])
    }

    @Test(arguments: [false, true])
    func dividerTitleIsAFallbackWhenItsWindowIDIsUnavailable(staleID: Bool) async throws {
        let divider = snapshot(90, x: 300, width: 0, title: ControlItem.Identifier.hiddenDivider.rawValue)
        let image = try glyph(side: 8)
        var capturedIDs: [CGWindowID] = []
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(items: [item, snapshot(2, x: 400), divider]),
            captureIcons: { items in capturedIDs = items.map(\.windowID); return [1: image] },
            preferences: .default, attribute: { $0 }
        )
        bar.hiddenDividerWindowID = staleID ? 999 : nil
        await bar.captureAndCache(anchorMinX: 500)

        #expect(capturedIDs == [1])
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 500))
        let items = try await bar.allManageableItems()
        #expect(items.map(\.id) == [1, 2])
        #expect(items.map(\.observedHidden) == [true, false])
    }

    @Test(arguments: [CGFloat(-300), 0, 500])
    func missingDividerUsesOnlyAKnownFiniteAnchor(anchorX: CGFloat) async throws {
        let image = try glyph(side: 8)
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(items: [snapshot(1, x: anchorX - 50), snapshot(2, x: anchorX + 50)]),
            captureIcons: { _ in [1: image] }, preferences: .default, attribute: { $0 }
        )
        bar.hiddenDividerWindowID = 999
        let unknown = try await bar.allManageableItems()
        #expect(unknown.count == 2)
        #expect(unknown.allSatisfy { $0.observedHidden == nil })

        await bar.captureAndCache(anchorMinX: anchorX)
        let observed = try await bar.allManageableItems()
        #expect(observed.map(\.observedHidden) == [true, false])
        #expect(!bar.cachedMirrorIsStale(anchorMinX: anchorX))

        await bar.captureAndCache(anchorMinX: .nan)
        let invalid = try await bar.allManageableItems()
        #expect(invalid.allSatisfy { $0.observedHidden == nil })
    }

    @Test func pickerFiltersOwnAndTransientWindowsBeforeAttributionOnTheCurrentDisplay() async throws {
        let server = MutableWindowServer(items: [
            snapshot(1, x: 100, y: 900),
            snapshot(2, x: 200, y: 900, title: ControlItem.Identifier.anchor.rawValue),
            snapshot(3, x: 300, y: 900),
            snapshot(4, x: 400, y: 900, width: 1, height: 1),
            snapshot(5, x: 450, y: 900, height: 800),
            snapshot(6, x: 500, y: 1100),
            snapshot(7, x: 550),
            snapshot(8, x: -500, y: 900),
            snapshot(9, x: -498, y: 900),
            snapshot(10, x: 600, y: 900)
        ])
        var attributedIDs: [CGWindowID] = []
        var captureCalls = 0
        let replacementPopover = snapshot(11, x: 800, y: 950, height: 800)
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in captureCalls += 1; return [:] },
            preferences: .default,
            attribute: { items in
                attributedIDs = items.map(\.windowID)
                server.base = FakeWindowServer(items: server.base.items.filter { $0.windowID != 5 } + [replacementPopover])
                return items
            }
        )
        bar.controlItemWindowIDs = [1]
        bar.hiddenDividerWindowID = 3
        bar.displayMenuBarTop = 900
        let items = try await bar.allManageableItems()

        #expect(attributedIDs == [8, 10])
        #expect(items.map(\.id) == [8, 10])
        #expect(items.map(\.observedHidden) == [true, false])
        #expect(captureCalls == 0)
        #expect(server.base.clickedWindowIDs.isEmpty)
        #expect(server.base.moveRequests.isEmpty)
    }

    @Test(arguments: [nil, "", "Control Center"] as [String?])
    func unresolvedAttributionPreservesTrustedOwnerGlyphAndFreshGeometry(owner: String?) async throws {
        let divider = snapshot(90, x: 300)
        let unknown = snapshot(2, x: 450, owner: "Control Center")
        let server = MutableWindowServer(items: [snapshot(1, x: 100, owner: "Control Center"), unknown, divider])
        let image = try glyph(side: 8)
        var resolves = true
        var captured: [MenuBarItemSnapshot] = []
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in captured = items; return resolves ? [1: image] : [:] },
            preferences: .default,
            attribute: { items in
                items.map { resolves && $0.windowID == 1 ? $0.attributed(bundleID: "test.trusted", pid: -2) : $0 }
            }
        )
        bar.hiddenDividerWindowID = divider.windowID
        await bar.captureAndCache(anchorMinX: 500)
        resolves = false
        let fresh = snapshot(1, x: -250, width: 28, owner: owner, title: "Item-7")
        server.base = FakeWindowServer(items: [fresh, unknown, divider])
        let items = try await bar.allManageableItems()
        let retained = try #require(items.first)

        #expect(items.map(\.id) == [1])
        #expect(retained.snapshot.ownerBundleID == "test.trusted")
        #expect(retained.snapshot.ownerPID == -2)
        #expect(retained.snapshot.frame == fresh.frame)
        #expect(retained.snapshot.title == "Item-7")
        #expect(retained.observedHidden == true)
        #expect(retained.image.size == CGSize(width: 8, height: 8))

        await bar.captureAndCache(anchorMinX: 500)
        #expect(captured.first?.ownerBundleID == "test.trusted")
        #expect(captured.first?.frame == fresh.frame)
        #expect(!bar.hasIncompleteGlyphs)
        let recaptured = try await bar.allManageableItems()
        #expect(recaptured.first?.image === retained.image)
    }

    @Test(arguments: [false, true])
    func identitySurvivesLeavingTheHiddenSetWhileItsRawWindowRemains(implausible: Bool) async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let divider = snapshot(90, x: 300)
        let server = MutableWindowServer(items: [raw, divider])
        let image = try glyph(side: 8)
        var resolves = true
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] }, preferences: .default,
            attribute: { items in items.map { resolves ? $0.attributed(bundleID: "test.trusted", pid: -2) : $0 } }
        )
        bar.hiddenDividerWindowID = divider.windowID
        await bar.captureAndCache(anchorMinX: 500)
        resolves = false
        server.base = FakeWindowServer(items: [
            snapshot(1, x: implausible ? 100 : 400, height: implausible ? 80 : 22, owner: "Control Center"), divider
        ])
        await bar.captureAndCache(anchorMinX: 500)
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 500))
        if implausible {
            let transient = try await bar.allManageableItems()
            #expect(transient.isEmpty)
            server.base = FakeWindowServer(items: [raw, divider])
        }
        let items = try await bar.allManageableItems()

        #expect(items.map(\.id) == [1])
        #expect(items.first?.snapshot.ownerBundleID == "test.trusted")
        #expect(items.first?.observedHidden == implausible)
    }

    @Test func disappearedWindowLosesItsTrustedIdentityAndGlyph() async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let image = try glyph(side: 8)
        var owner: String? = "test.original"
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] }, preferences: .default,
            attribute: { items in items.map { owner == nil ? $0 : $0.attributed(bundleID: owner, pid: -2) } }
        )
        await bar.captureAndCache(anchorMinX: 500)
        let originalItems = try await bar.allManageableItems()
        let original = try #require(originalItems.first)
        owner = nil
        server.base = FakeWindowServer()
        #expect(bar.cachedMirrorIsStale(anchorMinX: 500))

        server.base = FakeWindowServer(items: [raw])
        let unresolved = try await bar.allManageableItems()
        #expect(unresolved.isEmpty)
        owner = "test.replacement"
        let replacementItems = try await bar.allManageableItems()
        let replacement = try #require(replacementItems.first)
        #expect(replacement.snapshot.ownerBundleID == "test.replacement")
        #expect(replacement.image !== original.image)
    }

    @Test(arguments: ["test.reassigned", "com.apple.controlcenter"])
    func freshResolvedAttributionWinsWithoutReplacingFreshGeometry(newOwner: String) async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let fresh = snapshot(1, x: 600, width: 28, owner: "Control Center", title: "Item-3")
        let server = MutableWindowServer(items: [raw])
        let image = try glyph(side: 8)
        var owner = "test.original"
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] }, preferences: .default,
            attribute: { items in items.map { $0.attributed(bundleID: owner, pid: -2) } }
        )
        await bar.captureAndCache(anchorMinX: 500)
        owner = newOwner
        server.base = FakeWindowServer(items: [fresh])
        let items = try await bar.allManageableItems()

        if newOwner == "com.apple.controlcenter" {
            #expect(items.isEmpty)
        } else {
            let item = try #require(items.first)
            #expect(item.snapshot.ownerBundleID == newOwner)
            #expect(item.snapshot.frame == fresh.frame)
            #expect(item.snapshot.title == fresh.title)
            #expect(item.observedHidden == false)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func newerResolvedOwnerWinsWhenAnOlderCaptureAttributionFinishesLate(
        olderResolves: Bool, geometryChanges: Bool
    ) async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let fresh = snapshot(1, x: geometryChanges ? 600 : 100, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let started = AsyncGate()
        let finish = AsyncGate()
        let image = try glyph(side: 8)
        var calls = 0
        var captured: [MenuBarItemSnapshot] = []
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { items in captured = items; return [1: image] },
            preferences: .default,
            attribute: { items in
                calls += 1
                if calls == 1 {
                    await started.open()
                    await finish.wait()
                    return olderResolves ? [raw.attributed(bundleID: "test.old", pid: -2)] : items
                }
                return calls == 2 ? items.map { $0.attributed(bundleID: "test.new", pid: -3) } : items
            }
        )
        let old = Task { await bar.captureAndCache(anchorMinX: 500) }
        await started.wait()
        server.base = FakeWindowServer(items: [fresh])
        let newer = try await bar.allManageableItems()
        #expect(newer.first?.snapshot.ownerBundleID == "test.new")
        await finish.open()
        await old.value

        if geometryChanges {
            #expect(captured.isEmpty)
        } else {
            #expect(captured.first?.ownerBundleID == "test.new")
            #expect(captured.first?.ownerPID == -3)
        }
        let latest = try await bar.allManageableItems()
        #expect(latest.first?.snapshot.ownerBundleID == "test.new")
        #expect(latest.first?.snapshot.ownerPID == -3)
        #expect(latest.first?.snapshot.frame == fresh.frame)
        #expect(latest.first?.observedHidden == !geometryChanges)
    }

    @Test(arguments: [false, true])
    func lateAttributionCannotRestoreADisappearedWindow(reappearsBeforeCompletion: Bool) async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let started = AsyncGate()
        let finish = AsyncGate()
        var calls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in Issue.record("Unexpected capture"); return [:] },
            preferences: .default,
            attribute: { items in
                calls += 1
                if calls == 1 {
                    await started.open()
                    await finish.wait()
                    return [raw.attributed(bundleID: "test.disappeared", pid: -2)]
                }
                return items
            }
        )
        let old = Task { try await bar.allManageableItems() }
        await started.wait()
        server.base = FakeWindowServer()
        let missing = try await bar.allManageableItems()
        #expect(missing.isEmpty)
        if reappearsBeforeCompletion {
            server.base = FakeWindowServer(items: [raw])
            let reappeared = try await bar.allManageableItems()
            #expect(reappeared.isEmpty)
        }
        await finish.open()
        await #expect(throws: WindowServerError.invalidServerResponse("menu bar geometry changed during attribution")) {
            try await old.value
        }
        server.base = FakeWindowServer(items: [raw])
        let latest = try await bar.allManageableItems()
        #expect(latest.isEmpty)
    }

    @Test func lateScreenshotCannotRestoreAReusedWindowID() async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let started = AsyncGate()
        let finish = AsyncGate()
        let image = try glyph(side: 8)
        var resolves = true
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { _ in
                await started.open()
                await finish.wait()
                return [1: image]
            },
            preferences: .default,
            attribute: { items in items.map { resolves ? $0.attributed(bundleID: "test.disappeared", pid: -2) : $0 } }
        )
        let task = Task { await bar.captureAndCache(anchorMinX: 500) }
        await started.wait()
        resolves = false
        server.base = FakeWindowServer()
        let missing = try await bar.allManageableItems()
        #expect(missing.isEmpty)
        server.base = FakeWindowServer(items: [raw])
        let reappeared = try await bar.allManageableItems()
        #expect(reappeared.isEmpty)
        await finish.open()
        await task.value

        #expect(!bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)
        let latest = try await bar.allManageableItems()
        #expect(latest.isEmpty)
    }

    @Test func cancelledPickerSkipsEnumerationAndAttribution() async {
        let server = MutableWindowServer(items: [item])
        var attributionCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in Issue.record("Unexpected capture"); return [:] },
            preferences: .default,
            attribute: { attributionCalls += 1; return $0 }
        )
        let task = Task { try await bar.allManageableItems() }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(server.readCount == 0)
        #expect(attributionCalls == 0)
    }

    @Test func cancelledPickerAttributionCannotReplaceATrustedOwner() async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let fresh = snapshot(1, x: 600, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let started = AsyncGate()
        let finish = AsyncGate()
        let image = try glyph(side: 8)
        var calls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] }, preferences: .default,
            attribute: { items in
                calls += 1
                if calls == 1 { return items.map { $0.attributed(bundleID: "test.trusted", pid: -2) } }
                if calls == 2 {
                    await started.open()
                    await finish.wait()
                    return items.map { $0.attributed(bundleID: "test.cancelled", pid: -3) }
                }
                return items
            }
        )
        await bar.captureAndCache(anchorMinX: 500)
        let task = Task { try await bar.allManageableItems() }
        await started.wait()
        task.cancel()
        await finish.open()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        server.base = FakeWindowServer(items: [fresh])
        let latest = try await bar.allManageableItems()
        #expect(latest.first?.snapshot.ownerBundleID == "test.trusted")
        #expect(latest.first?.snapshot.ownerPID == -2)
        #expect(latest.first?.snapshot.frame == fresh.frame)
        #expect(latest.first?.observedHidden == false)
        #expect(latest.first?.image.size == CGSize(width: 8, height: 8))
    }

    @Test func enumerationFailurePreservesOwnersGlyphsAndMirrorAcrossReaders() async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let image = try glyph(side: 8)
        let failure = WindowServerError.invalidServerResponse("enumeration failed")
        var resolves = true
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in captureCalls += 1; return [1: image] },
            preferences: .default,
            attribute: { items in items.map { resolves ? $0.attributed(bundleID: "test.trusted", pid: -2) : $0 } }
        )
        await bar.captureAndCache(anchorMinX: 500)
        let originalItems = try await bar.allManageableItems()
        let original = try #require(originalItems.first)
        resolves = false
        server.base.enumerationError = failure

        await #expect(throws: failure) { try await bar.allManageableItems() }
        await bar.captureAndCache(anchorMinX: 500)
        #expect(bar.cachedMirrorIsStale(anchorMinX: 500))
        let report = await bar.makeDiagnosticsReport()
        #expect(report.items.isEmpty)
        #expect(captureCalls == 1)
        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)

        server.base.enumerationError = nil
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 500))
        let recoveredItems = try await bar.allManageableItems()
        let recovered = try #require(recoveredItems.first)
        #expect(recovered.snapshot.ownerBundleID == "test.trusted")
        #expect(recovered.snapshot.ownerPID == -2)
        #expect(recovered.image === original.image)
        #expect(recovered.observedHidden == true)
    }

    @Test(arguments: ["picker", "capture", "diagnostics"])
    func failedPostAXEnumerationCannotPromoteNamesOrReplaceGlyphs(reader: String) async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let image = try glyph(side: 8)
        let failure = WindowServerError.invalidServerResponse("post-AX enumeration failed")
        var resolves = true
        var failValidation = false
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in captureCalls += 1; return [1: image] },
            preferences: .default,
            attribute: { items in
                if failValidation {
                    server.base.enumerationError = failure
                    return items.map { $0.attributed(bundleID: "test.poisoned", pid: -3) }
                }
                return items.map { resolves ? $0.attributed(bundleID: "test.trusted", pid: -2) : $0 }
            }
        )
        await bar.captureAndCache(anchorMinX: 500)
        let originalItems = try await bar.allManageableItems()
        let original = try #require(originalItems.first)
        failValidation = true
        let readsBeforeFailure = server.readCount
        switch reader {
        case "picker":
            await #expect(throws: failure) { try await bar.allManageableItems() }
        case "capture":
            await bar.captureAndCache(anchorMinX: 500)
        default:
            let report = await bar.makeDiagnosticsReport()
            #expect(report.items.isEmpty)
        }
        #expect(server.readCount - readsBeforeFailure == 2)
        #expect(captureCalls == 1)
        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)

        failValidation = false
        resolves = false
        server.base.enumerationError = nil
        let recoveredItems = try await bar.allManageableItems()
        let recovered = try #require(recoveredItems.first)
        #expect(recovered.snapshot.ownerBundleID == "test.trusted")
        #expect(recovered.snapshot.ownerPID == -2)
        #expect(recovered.image === original.image)
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 500))
    }

    @Test(arguments: [false, true])
    func failedOrReflowedScreenshotDoesNotReplaceTheCachedGlyph(enumerationFails: Bool) async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let fresh = snapshot(1, x: 200, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let originalImage = try glyph(side: 8)
        let lateImage = try glyph(side: 16)
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { _ in
                captureCalls += 1
                if captureCalls == 1 { return [1: originalImage] }
                if enumerationFails {
                    server.base.enumerationError = .invalidServerResponse("post-capture enumeration failed")
                } else {
                    server.base = FakeWindowServer(items: [fresh])
                }
                return [1: lateImage]
            },
            preferences: .default,
            attribute: { items in items.map { $0.attributed(bundleID: "test.trusted", pid: -2) } }
        )
        await bar.captureAndCache(anchorMinX: 500)
        let originalItems = try await bar.allManageableItems()
        let original = try #require(originalItems.first)
        await bar.captureAndCache(anchorMinX: 500)
        #expect(captureCalls == 2)
        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)

        server.base.enumerationError = nil
        let recoveredItems = try await bar.allManageableItems()
        let recovered = try #require(recoveredItems.first)
        #expect(recovered.image === original.image)
        #expect(recovered.snapshot.frame == (enumerationFails ? raw.frame : fresh.frame))
    }

    @Test(arguments: ["swapped", "resized", "divider", "anchor"], [false, true])
    func changedGeometryRejectsAXNamesAndAllowsAFreshObservation(change: String, capturing: Bool) async throws {
        let raw = [snapshot(1, x: 100, owner: "Control Center"), snapshot(2, x: 200, owner: "Control Center")]
        let divider = snapshot(90, x: 300, width: 0, title: ControlItem.Identifier.hiddenDivider.rawValue)
        let anchor = snapshot(91, x: 500, title: ControlItem.Identifier.anchor.rawValue)
        var changed = raw + [divider, anchor]
        switch change {
        case "swapped":
            changed[0] = snapshot(1, x: 200, owner: "Control Center")
            changed[1] = snapshot(2, x: 100, owner: "Control Center")
        case "resized":
            changed[0] = snapshot(1, x: 100, width: 30, owner: "Control Center")
        case "divider":
            changed[2] = snapshot(90, x: 150, width: 0, title: divider.title)
        default:
            changed[3] = snapshot(91, x: 700, title: anchor.title)
        }
        let server = MutableWindowServer(items: raw + [divider, anchor])
        let image = try glyph(side: 8)
        var owners: [CGWindowID: String] = [1: "test.first", 2: "test.second"]
        var reflowDuringAX = false
        var captureCalls = 0
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in
                captureCalls += 1
                return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
            },
            preferences: .default,
            attribute: { items in
                if reflowDuringAX {
                    server.base = FakeWindowServer(items: changed)
                    return items.map { $0.attributed(bundleID: "test.poisoned.\($0.windowID)", pid: -3) }
                }
                return items.map { item in
                    owners[item.windowID].map { item.attributed(bundleID: $0, pid: -2) } ?? item
                }
            }
        )
        bar.hiddenDividerWindowID = divider.windowID
        bar.controlItemWindowIDs = [divider.windowID, anchor.windowID]
        await bar.captureAndCache(anchorMinX: 500)
        let original = try await bar.allManageableItems()
        #expect(original.map { ItemControlStore.key(for: $0.snapshot) } == ["test.first", "test.second"])
        reflowDuringAX = true
        let readsBeforeReflow = server.readCount
        if capturing {
            await bar.captureAndCache(anchorMinX: 500)
        } else {
            await #expect(throws: WindowServerError.invalidServerResponse("menu bar geometry changed during attribution")) {
                try await bar.allManageableItems()
            }
        }
        #expect(server.readCount - readsBeforeReflow == 2)
        #expect(captureCalls == 1)
        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)

        reflowDuringAX = false
        owners = [:]
        let recovered = try await bar.allManageableItems()
        #expect(recovered.count == 2)
        for item in recovered {
            let prior = try #require(original.first { $0.id == item.id })
            #expect(ItemControlStore.key(for: item.snapshot) == ItemControlStore.key(for: prior.snapshot))
            #expect(item.image === prior.image)
            #expect(item.snapshot.frame == changed.first(where: { $0.windowID == item.id })?.frame)
        }

        owners = [1: "test.fresh.first", 2: "test.fresh.second"]
        let fresh = try await bar.allManageableItems()
        #expect(fresh.count == 2)
        for item in fresh {
            #expect(item.snapshot.ownerBundleID == owners[item.id])
            #expect(item.snapshot.frame == changed.first(where: { $0.windowID == item.id })?.frame)
        }
        #expect(bar.preferences == .default)
    }

    @Test(arguments: [false, true])
    func enumerationOrderChangesPreserveTheOriginalDedupRepresentative(capturing: Bool) async throws {
        let raw = [
            snapshot(1, x: 100), snapshot(2, x: 102),
            snapshot(90, x: 300, title: ControlItem.Identifier.hiddenDivider.rawValue),
            snapshot(91, x: 400, title: ControlItem.Identifier.hiddenDivider.rawValue)
        ]
        let server = MutableWindowServer(items: raw)
        let image = try glyph(side: 8)
        var attributedIDs: [CGWindowID] = []
        var capturedIDs: [CGWindowID] = []
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in capturedIDs = items.map(\.windowID); return [1: image] },
            preferences: .default,
            attribute: { items in
                attributedIDs = items.map(\.windowID)
                server.base = FakeWindowServer(items: Array(raw.reversed()))
                return items.map { $0.attributed(bundleID: "test.trusted", pid: -2) }
            }
        )
        if capturing {
            await bar.captureAndCache(anchorMinX: 500)
            #expect(capturedIDs == [1])
            #expect(bar.hasCapturedOnce)
            #expect(!bar.hasIncompleteGlyphs)
        } else {
            let items = try await bar.allManageableItems()
            #expect(items.map(\.id) == [1])
            #expect(items.first?.snapshot.frame == raw[0].frame)
            #expect(items.first?.snapshot.ownerBundleID == "test.trusted")
        }
        #expect(attributedIDs == [1])
    }

    @Test func attributionCannotAttachNamesToDifferentCandidateGeometry() async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let stale = snapshot(1, x: 600, owner: "test.poisoned")
        let server = MutableWindowServer(items: [raw])
        var returnsStale = true
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in Issue.record("Unexpected capture"); return [:] },
            preferences: .default, attribute: { returnsStale ? [stale] : $0 }
        )
        await #expect(throws: WindowServerError.invalidServerResponse("attribution changed its candidate geometry")) {
            try await bar.allManageableItems()
        }
        returnsStale = false
        let unmatched = try await bar.allManageableItems()
        #expect(unmatched.isEmpty)
    }

    @Test(arguments: [false, true])
    func activationNeverClicksAStaleSnapshotAfterAFailedOrMissingObservation(enumerationFails: Bool) async throws {
        let server = MutableWindowServer(items: [item])
        let image = try glyph(side: 8)
        var axCalls = 0
        var rehideCalls = 0
        var autoRehideCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] },
            preferences: Preferences(useAXActivation: true), attribute: { $0 },
            activateWithAX: { _, _, _ in axCalls += 1; return false }
        )
        bar.rehideItems = { rehideCalls += 1 }
        bar.scheduleAutoRehideAfterActivation = { autoRehideCalls += 1 }
        await bar.captureAndCache(anchorMinX: 500)
        if enumerationFails {
            server.base.enumerationError = .invalidServerResponse("activation enumeration failed")
        } else {
            server.base = FakeWindowServer()
        }
        bar.activate(windowID: item.windowID)
        let task = try #require(bar.currentActivationTask)
        await task.value

        #expect(server.base.clickedWindowIDs.isEmpty)
        #expect(axCalls == 0)
        #expect(rehideCalls == 1)
        #expect(autoRehideCalls == 0)
        if enumerationFails {
            server.base.enumerationError = nil
            let recovered = try await bar.allManageableItems()
            #expect(recovered.first?.snapshot.ownerBundleID == item.ownerBundleID)
            #expect(recovered.first?.image.size == CGSize(width: 8, height: 8))
            #expect(!bar.cachedMirrorIsStale(anchorMinX: 500))
        }
    }

    @Test(arguments: [false, true])
    func malformedEnumerationDoesNotInvalidateMissingCachedIDs(duplicateID: Bool) async throws {
        let raw = snapshot(1, x: 100, owner: "Control Center")
        let server = MutableWindowServer(items: [raw])
        let image = try glyph(side: 8)
        var resolves = true
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] }, preferences: .default,
            attribute: { items in items.map { resolves ? $0.attributed(bundleID: "test.trusted", pid: -2) : $0 } }
        )
        await bar.captureAndCache(anchorMinX: 500)
        resolves = false
        server.base = FakeWindowServer(items: duplicateID
            ? [snapshot(2, x: 200), snapshot(2, x: 202)]
            : [snapshot(2, x: .nan)])
        await #expect(throws: WindowServerError.invalidServerResponse("invalid menu bar window geometry")) {
            try await bar.allManageableItems()
        }
        await bar.captureAndCache(anchorMinX: 500)
        #expect(bar.cachedMirrorIsStale(anchorMinX: 500))

        server.base = FakeWindowServer(items: [raw])
        let recovered = try await bar.allManageableItems()
        #expect(recovered.first?.snapshot.ownerBundleID == "test.trusted")
        #expect(recovered.first?.image.size == CGSize(width: 8, height: 8))
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 500))
    }

    @Test func activationDoesNotFollowAWindowIDReusedDuringReveal() async throws {
        let server = MutableWindowServer(items: [item])
        let started = AsyncGate()
        let finish = AsyncGate()
        let image = try glyph(side: 8)
        var rehideCalls = 0
        var axCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [1: image] },
            preferences: Preferences(useAXActivation: true), attribute: { $0 },
            activateWithAX: { _, _, _ in axCalls += 1; return false }
        )
        bar.revealHiddenItems = {
            await started.open()
            await finish.wait()
        }
        bar.rehideItems = { rehideCalls += 1 }
        await bar.captureAndCache(anchorMinX: 500)
        bar.activate(windowID: item.windowID)
        let task = try #require(bar.currentActivationTask)
        await started.wait()
        server.base = FakeWindowServer()
        let missing = try await bar.allManageableItems()
        #expect(missing.isEmpty)
        server.base = FakeWindowServer(items: [snapshot(1, x: 300, owner: "test.reused")])
        let replacement = try await bar.allManageableItems()
        #expect(replacement.first?.snapshot.ownerBundleID == "test.reused")
        await finish.open()
        await task.value

        #expect(server.base.clickedWindowIDs.isEmpty)
        #expect(axCalls == 0)
        #expect(rehideCalls == 1)
    }

    // MARK: - Always Hidden tier

    @Test(arguments: [false, true])
    func captureSplitsTuckedItemsAcrossTheAlwaysHiddenDivider(resolveTierByName: Bool) async throws {
        let secret = snapshot(1, x: 100, owner: "test.secret")
        let hidden = snapshot(2, x: 700, owner: "test.hidden")
        let shown = snapshot(3, x: 1100, owner: "test.shown")
        let divider = snapshot(90, x: 976, width: 8, owner: "Control Center", title: ControlItem.Identifier.hiddenDivider.rawValue)
        let tier = snapshot(92, x: 600, width: 8, owner: "Control Center", title: ControlItem.Identifier.alwaysHiddenDivider.rawValue)
        let server = MutableWindowServer(items: [secret, hidden, shown, divider, tier])
        let image = try glyph(side: 8)
        var capturedIDs: [[CGWindowID]] = []
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in
                capturedIDs.append(items.map(\.windowID))
                return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
            },
            preferences: Preferences(itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["test.secret"])),
            attribute: { $0 }
        )
        bar.hiddenDividerWindowID = divider.windowID
        bar.alwaysHiddenDividerWindowID = resolveTierByName ? nil : tier.windowID
        await bar.captureAndCache(anchorMinX: 1000)

        #expect(capturedIDs == [[2, 1]])
        #expect(bar.cachedHiddenItems().map(\.id) == [2])
        #expect(bar.cachedAlwaysHiddenItems().map(\.id) == [1])
        #expect(bar.hasCapturedOnce)
        #expect(!bar.hasIncompleteGlyphs)
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 1000))
        let items = try await bar.allManageableItems()
        #expect(items.map(\.id) == [1, 2, 3])
        #expect(items.map(\.observedPlacement) == [.alwaysHidden, .hidden, .shown])
        #expect(items.map(\.observedHidden) == [true, true, false])

        // Moving the tier divider left turns the secret item into a plain hidden one.
        server.base = FakeWindowServer(items: [secret, hidden, shown, divider, snapshot(92, x: 50, width: 8, owner: "Control Center", title: tier.title)])
        #expect(bar.cachedMirrorIsStale(anchorMinX: 1000))
        let reclassified = try await bar.allManageableItems()
        #expect(reclassified.map(\.observedPlacement) == [.hidden, .hidden, .shown])
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(bar.cachedHiddenItems().map(\.id) == [1, 2])
        #expect(bar.cachedAlwaysHiddenItems().isEmpty)
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 1000))
    }

    @Test func withoutATierDividerEverythingLeftOfTheHiddenDividerStaysPlainHidden() async throws {
        let divider = snapshot(90, x: 976, width: 8, owner: "Control Center", title: ControlItem.Identifier.hiddenDivider.rawValue)
        let server = FakeWindowServer(items: [snapshot(1, x: 100), snapshot(2, x: 700), divider])
        let image = try glyph(side: 8)
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { items in Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) }) },
            preferences: .default, attribute: { $0 }
        )
        bar.hiddenDividerWindowID = divider.windowID
        bar.alwaysHiddenDividerWindowID = 999
        await bar.captureAndCache(anchorMinX: 1000)

        #expect(bar.cachedHiddenItems().map(\.id) == [1, 2])
        #expect(bar.cachedAlwaysHiddenItems().isEmpty)
        let items = try await bar.allManageableItems()
        #expect(items.map(\.observedPlacement) == [.hidden, .hidden])
    }

    @Test(arguments: FloatingBarStyle.allCases)
    func showAppendsTheAlwaysHiddenTierOnlyWhenAskedAndRelayoutKeepsTheChoice(style: FloatingBarStyle) async throws {
        let secret = snapshot(1, x: 100, owner: "test.secret")
        let hidden = snapshot(2, x: 700, owner: "test.hidden")
        let divider = snapshot(90, x: 976, width: 8, owner: "Control Center", title: ControlItem.Identifier.hiddenDivider.rawValue)
        let tier = snapshot(92, x: 600, width: 8, owner: "Control Center", title: ControlItem.Identifier.alwaysHiddenDivider.rawValue)
        let server = FakeWindowServer(items: [secret, hidden, divider, tier])
        let image = try glyph(side: 8)
        let panel = SilentPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        var preferences = Preferences(
            itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["test.secret"]), dismissBarOnMouseExit: false
        )
        preferences.floatingBarStyle = style
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { items in Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) }) },
            preferences: preferences, attribute: { $0 }, panelFactory: { panel }
        )
        bar.hiddenDividerWindowID = divider.windowID
        bar.alwaysHiddenDividerWindowID = tier.windowID
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(!bar.presentsAlwaysHidden)

        await bar.show(anchorMinX: 1000, anchorRightX: 1032)
        #expect(bar.isVisible)
        #expect(!bar.presentsAlwaysHidden)
        let plainFrame = try #require(panel.lastRequestedFrame)

        await bar.show(anchorMinX: 1000, anchorRightX: 1032, includeAlwaysHidden: true)
        #expect(bar.presentsAlwaysHidden)
        let tieredFrame = try #require(panel.lastRequestedFrame)
        #expect(tieredFrame.height > plainFrame.height)
        #expect(tieredFrame.width >= plainFrame.width)

        // A background capture re-lays the open bar out without dropping the tier.
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(bar.isVisible)
        #expect(bar.presentsAlwaysHidden)
        #expect(panel.lastRequestedFrame?.size == tieredFrame.size)

        bar.hide()
        #expect(!bar.presentsAlwaysHidden)
        await bar.show(anchorMinX: 1000, anchorRightX: 1032, presentation: .hover)
        #expect(bar.isVisible)
        #expect(!bar.presentsAlwaysHidden)
        #expect(panel.lastRequestedFrame?.size == plainFrame.size)
        bar.hide()
        #expect(panel.presentations == 4)
    }

    @Test(arguments: [false, true], [false, true])
    func activatingAnItemPastTheTierDividerRevealsBothTiers(hasAllTiersReveal: Bool, secretHasIntent: Bool) async throws {
        let secret = snapshot(1, x: 100, owner: "test.secret")
        let hidden = snapshot(2, x: 700, owner: "test.hidden")
        let divider = snapshot(90, x: 976, width: 8, owner: "Control Center", title: ControlItem.Identifier.hiddenDivider.rawValue)
        let tier = snapshot(92, x: 600, width: 8, owner: "Control Center", title: ControlItem.Identifier.alwaysHiddenDivider.rawValue)
        let server = FakeWindowServer(items: [secret, hidden, divider, tier])
        let image = try glyph(side: 8)
        var hiddenReveals = 0
        var allReveals = 0
        var autoRehideCalls = 0
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { items in Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) }) },
            preferences: Preferences(itemControls: ItemControlStore(alwaysHiddenInMenuBar: secretHasIntent ? ["test.secret"] : [])),
            attribute: { $0 }
        )
        bar.hiddenDividerWindowID = divider.windowID
        bar.alwaysHiddenDividerWindowID = tier.windowID
        bar.revealHiddenItems = { hiddenReveals += 1 }
        if hasAllTiersReveal { bar.revealAllHiddenItems = { allReveals += 1 } }
        bar.scheduleAutoRehideAfterActivation = { autoRehideCalls += 1 }
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(bar.cachedAlwaysHiddenItems().map(\.id) == (secretHasIntent ? [1] : []))
        #expect(bar.cachedHiddenItems().map(\.id) == (secretHasIntent ? [2] : [1, 2]))

        bar.activate(windowID: secret.windowID)
        await (try #require(bar.currentActivationTask)).value
        #expect(allReveals == (hasAllTiersReveal ? 1 : 0))
        #expect(hiddenReveals == (hasAllTiersReveal ? 0 : 1))
        #expect(server.clickedWindowIDs == [secret.windowID])

        bar.activate(windowID: hidden.windowID)
        await (try #require(bar.currentActivationTask)).value
        #expect(allReveals == (hasAllTiersReveal ? 1 : 0))
        #expect(hiddenReveals == (hasAllTiersReveal ? 1 : 2))
        #expect(server.clickedWindowIDs == [secret.windowID, hidden.windowID])
        #expect(autoRehideCalls == 2)
    }

    @Test(arguments: FloatingBarStyle.allCases)
    func anItemWithoutIntentPastTheTierDividerIsMirroredAsPlainHidden(style: FloatingBarStyle) async throws {
        let secret = snapshot(1, x: 100, owner: "test.secret")
        let stray = snapshot(2, x: 200, owner: "test.stray")
        let hidden = snapshot(3, x: 700, owner: "test.hidden")
        let shown = snapshot(4, x: 1100, owner: "test.shown")
        let divider = snapshot(90, x: 976, width: 8, owner: "Control Center", title: ControlItem.Identifier.hiddenDivider.rawValue)
        let tier = snapshot(92, x: 600, width: 8, owner: "Control Center", title: ControlItem.Identifier.alwaysHiddenDivider.rawValue)
        let server = FakeWindowServer(items: [secret, stray, hidden, shown, divider, tier])
        let image = try glyph(side: 8)
        let panel = SilentPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        var preferences = Preferences(
            itemControls: ItemControlStore(hiddenInMenuBar: ["test.hidden"], alwaysHiddenInMenuBar: ["test.secret"]),
            dismissBarOnMouseExit: false
        )
        preferences.floatingBarStyle = style
        var capturedIDs: [[CGWindowID]] = []
        let bar = FloatingBarController(
            windowServer: server,
            captureIcons: { items in
                capturedIDs.append(items.map(\.windowID))
                return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
            },
            preferences: preferences, attribute: { $0 }, panelFactory: { panel }
        )
        bar.hiddenDividerWindowID = divider.windowID
        bar.alwaysHiddenDividerWindowID = tier.windowID
        await bar.captureAndCache(anchorMinX: 1000)

        // Both tier windows are captured once; only the intent-backed one stays in the tier group.
        #expect(capturedIDs == [[3, 1, 2]])
        #expect(bar.cachedHiddenItems().map(\.id) == [2, 3])
        #expect(bar.cachedAlwaysHiddenItems().map(\.id) == [1])
        #expect(!bar.hasIncompleteGlyphs)
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 1000))

        await bar.show(anchorMinX: 1000, anchorRightX: 1032)
        var view = try #require(panel.contentViewController as? NSHostingController<FloatingBarView>).rootView
        #expect(view.items.map(\.id) == [2, 3])
        #expect(view.alwaysHiddenItems.isEmpty)
        await bar.show(anchorMinX: 1000, anchorRightX: 1032, includeAlwaysHidden: true)
        view = try #require(panel.contentViewController as? NSHostingController<FloatingBarView>).rootView
        #expect(view.items.map(\.id) == [2, 3])
        #expect(view.alwaysHiddenItems.map(\.id) == [1])
        bar.hide()

        let items = try await bar.allManageableItems()
        #expect(items.map(\.id) == [1, 2, 3, 4])
        #expect(items.map(\.observedPlacement) == [.alwaysHidden, .hidden, .hidden, .shown])
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { items }, onChange: { _ in }
        )
        await model.reloadItems()
        #expect(model.partition(model.loadedItems).hidden.map(\.id) == [2, 3])
        #expect(model.partition(model.loadedItems).alwaysHidden.map(\.id) == [1])
        #expect(model.placement(of: try #require(model.loadedItems.first { $0.id == 2 })) == .hidden)

        var hiddenReveals = 0
        var allReveals = 0
        bar.revealHiddenItems = { hiddenReveals += 1 }
        bar.revealAllHiddenItems = { allReveals += 1 }
        bar.activate(windowID: stray.windowID)
        await (try #require(bar.currentActivationTask)).value
        #expect(allReveals == 1)
        #expect(hiddenReveals == 0)
        bar.activate(windowID: hidden.windowID)
        await (try #require(bar.currentActivationTask)).value
        #expect(allReveals == 1)
        #expect(hiddenReveals == 1)
        #expect(server.clickedWindowIDs == [stray.windowID, hidden.windowID])

        // Granting the stray owner Always Hidden intent moves it into the tier group on the next capture.
        preferences.itemControls.setPlacement(.alwaysHidden, forKey: "test.stray")
        bar.preferences = preferences
        #expect(!bar.cachedMirrorIsStale(anchorMinX: 1000))
        await bar.captureAndCache(anchorMinX: 1000)
        #expect(bar.cachedHiddenItems().map(\.id) == [3])
        #expect(bar.cachedAlwaysHiddenItems().map(\.id) == [1, 2])
        #expect(try await bar.allManageableItems().map(\.observedPlacement) == [.alwaysHidden, .alwaysHidden, .hidden, .shown])
    }

    @Test func groupedOwnersPastTheTierDividerReadAsHiddenLikePlacement() async throws {
        let grouped = snapshot(1, x: 100, owner: "test.grouped")
        let divider = snapshot(90, x: 976, width: 8, owner: "Control Center", title: ControlItem.Identifier.hiddenDivider.rawValue)
        let tier = snapshot(92, x: 600, width: 8, owner: "Control Center", title: ControlItem.Identifier.alwaysHiddenDivider.rawValue)
        let server = FakeWindowServer(items: [grouped, divider, tier])
        let image = try glyph(side: 8)
        let preferences = Preferences(
            itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["test.grouped"]),
            itemGroups: [ItemGroup(name: "Tools", ownerKeys: ["test.grouped"])]
        )
        let bar = FloatingBarController(
            windowServer: server, captureIcons: { items in Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) }) },
            preferences: preferences, attribute: { $0 }
        )
        bar.hiddenDividerWindowID = divider.windowID
        bar.alwaysHiddenDividerWindowID = tier.windowID
        await bar.captureAndCache(anchorMinX: 1000)

        #expect(bar.cachedHiddenItems().map(\.id) == [1])
        #expect(bar.cachedAlwaysHiddenItems().isEmpty)
        #expect(try await bar.allManageableItems().map(\.observedPlacement) == [.hidden])
    }

    private func snapshot(
        _ id: CGWindowID, x: CGFloat, y: CGFloat = 0, width: CGFloat = 22, height: CGFloat = 22,
        owner: String? = "test.app", title: String? = "Item-0"
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id, ownerPID: -1, ownerBundleID: owner, title: title,
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func glyph(side: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }
}

private final class MutableWindowServer: WindowServer, @unchecked Sendable {
    var base: FakeWindowServer
    var clickError: (any Error)?
    private(set) var readCount = 0
    private(set) var clickCount = 0

    init(items: [MenuBarItemSnapshot]) {
        base = FakeWindowServer(items: items)
    }

    var canSynthesizeClicks: Bool { base.canSynthesizeClicks }
    func menuBarItems() throws -> [MenuBarItemSnapshot] {
        readCount += 1
        return try base.menuBarItems()
    }
    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        try base.menuBarFrame(forDisplayContaining: point)
    }
    func click(item: MenuBarItemSnapshot) throws {
        clickCount += 1
        if let clickError { throw clickError }
        try base.click(item: item)
    }
    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        try await base.move(item: item, toX: targetX, relativeTo: targetWindowID)
    }
}
