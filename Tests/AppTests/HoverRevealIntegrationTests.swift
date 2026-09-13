import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HoverRevealIntegrationTests {
    enum StopReason: CaseIterable, Sendable {
        case preference, floatingBar, pause, uninstall
    }

    enum CacheState: CaseIterable, Sendable {
        case fresh, stale, empty, uncollected, enumerationFailure
    }

    @Test(arguments: CacheState.allCases, [FloatingBarController.Presentation.hover, .click, .keyboard])
    func cachedListOpenNeverRevealsOrRefreshesRealItems(
        cache: CacheState, presentation: FloatingBarController.Presentation
    ) async throws {
        let item = MenuBarItemSnapshot(
            windowID: 1, ownerPID: -1, ownerBundleID: "Test App",
            frame: CGRect(x: 50, y: 0, width: 22, height: 22)
        )
        let other = MenuBarItemSnapshot(
            windowID: 2, ownerPID: -1, ownerBundleID: "Other App",
            frame: CGRect(x: 200, y: 0, width: 22, height: 22)
        )
        let server = FakeWindowServer(items: cache == .empty ? [] : [item, other])
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        var captureCalls = 0
        var dividerWrites: [Bool] = []
        let fixture = Fixture(
            server: server,
            captureIcons: { items in
                captureCalls += 1
                return Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) })
            },
            setDividerCollapsed: { dividerWrites.append($0) }
        )
        defer { fixture.engine.uninstall() }
        fixture.preferences.floatingBarStyle = .vertical
        fixture.bar.preferences = fixture.preferences
        if cache != .uncollected { await fixture.bar.captureAndCache(anchorMinX: 100) }
        if cache == .stale { try await server.move(item: other, toX: 10, relativeTo: 90) }
        if cache == .enumerationFailure { server.enumerationError = .invalidServerResponse("unavailable") }
        let capturesBeforeOpen = captureCalls
        let movesBeforeOpen = server.moveRequests.count
        dividerWrites.removeAll()

        if presentation == .hover {
            fixture.advance(to: 0.2)
            await (try #require(fixture.hover.pendingShowTask)).value
        } else {
            let presented = AsyncGate()
            fixture.panel.onPresent = { Task { await presented.open() } }
            if presentation == .keyboard {
                fixture.engine.toggleFromShortcut()
            } else {
                fixture.engine.toggleFloatingBarForDiagnostics()
            }
            await presented.wait()
        }
        await fixture.engine.captureChain.value

        #expect(dividerWrites.isEmpty)
        #expect(captureCalls == capturesBeforeOpen)
        #expect(fixture.bar.hasCapturedOnce == (cache != .uncollected))
        #expect(fixture.bar.isVisible)
        #expect(fixture.bar.presentation == presentation)
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(server.clickedWindowIDs.isEmpty)
        #expect(server.moveRequests.count == movesBeforeOpen)
        let view = try #require(fixture.panel.contentViewController as? NSHostingController<FloatingBarView>).rootView
        #expect(view.items.map(\.id) == (cache == .empty || cache == .uncollected ? [] : [1]))
        #expect(view.isPreparing == (cache == .uncollected))
        #expect(fixture.panel.nonkeyPresentations == (presentation == .hover ? 1 : 0))
        #expect(fixture.panel.keyPresentations == (presentation == .hover ? 0 : 1))
    }

    @Test func hoverWaitsForCaptureToRestoreTheDividerWithoutCancellingIt() async throws {
        var dividerWrites: [Bool] = []
        let fixture = Fixture(setDividerCollapsed: { dividerWrites.append($0) })
        defer { fixture.engine.uninstall() }
        dividerWrites.removeAll()
        let started = AsyncGate()
        let finish = AsyncGate()
        var captureWasCancelled = false
        let capture = fixture.engine.runCaptureSequence(forceCollapseAfter: true) {
            await started.open()
            await finish.wait()
            captureWasCancelled = Task.isCancelled
        }
        await started.wait()
        #expect(!fixture.engine.canRevealOnHover)
        fixture.advance(to: 0.2)
        await fixture.hover.pendingShowTask?.value
        #expect(!fixture.bar.isVisible)
        #expect(!fixture.hover.ownsPanel)
        #expect(dividerWrites == [false])

        await finish.open()
        await capture.value
        #expect(!captureWasCancelled)
        #expect(dividerWrites == [false, true])
        #expect(fixture.engine.canRevealOnHover)
        fixture.advance(to: 1)
        fixture.advance(to: 1.3)
        await (try #require(fixture.hover.pendingShowTask)).value
        await fixture.engine.captureChain.value
        #expect(fixture.bar.isVisible)
        #expect(fixture.hover.ownsPanel)
        #expect(dividerWrites == [false, true])
    }

    @Test(arguments: [FloatingBarController.Presentation.hover, .click, .keyboard], [false, true])
    func cachedOpenInvalidatesQueuedOptionalCaptureUntilAFreshIdleRequest(
        presentation: FloatingBarController.Presentation, warmUpRetry: Bool
    ) async {
        var dividerWrites: [Bool] = []
        let fixture = Fixture(setDividerCollapsed: { dividerWrites.append($0) })
        defer { fixture.engine.uninstall() }
        dividerWrites.removeAll()
        if warmUpRetry { fixture.engine.fireWarmUpRetry() } else { fixture.engine.refreshFloatingBarCache() }
        if presentation == .hover {
            await fixture.engine.revealFloatingBarOnHover()
        } else {
            let presented = AsyncGate()
            fixture.panel.onPresent = { Task { await presented.open() } }
            if presentation == .keyboard {
                fixture.engine.toggleFromShortcut()
            } else {
                fixture.engine.toggleFloatingBarForDiagnostics()
            }
            await presented.wait()
        }
        #expect(fixture.bar.isVisible)
        fixture.bar.hide()
        await fixture.engine.captureChain.value

        #expect(!fixture.bar.hasCapturedOnce)
        #expect(!dividerWrites.contains(false))
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .collapsed)
        #expect(fixture.engine.canRevealOnHover)

        dividerWrites.removeAll()
        if warmUpRetry { fixture.engine.fireWarmUpRetry() } else { fixture.engine.refreshFloatingBarCache() }
        await fixture.engine.captureChain.value
        #expect(dividerWrites == [false, true])
        #expect(fixture.bar.hasCapturedOnce)
        #expect(fixture.engine.canRevealOnHover)
    }

    @Test(arguments: [FloatingBarController.Presentation.click, .keyboard], [false, true])
    func manualOpenInvalidatesQueuedCaptureWithoutCancellingItsPredecessor(
        presentation: FloatingBarController.Presentation, warmUpRetry: Bool
    ) async {
        var dividerWrites: [Bool] = []
        let fixture = Fixture(setDividerCollapsed: { dividerWrites.append($0) })
        defer { fixture.engine.uninstall() }
        dividerWrites.removeAll()
        let started = AsyncGate()
        let finish = AsyncGate()
        var predecessorWasCancelled = false
        fixture.engine.runCaptureSequence(forceCollapseAfter: false) {
            await started.open()
            await finish.wait()
            predecessorWasCancelled = Task.isCancelled
        }
        await started.wait()
        if warmUpRetry { fixture.engine.fireWarmUpRetry() } else { fixture.engine.refreshFloatingBarCache() }
        let presented = AsyncGate()
        fixture.panel.onPresent = { Task { await presented.open() } }
        if presentation == .keyboard {
            fixture.engine.toggleFromShortcut()
        } else {
            fixture.engine.toggleFloatingBarForDiagnostics()
        }
        await presented.wait()
        #expect(fixture.bar.isVisible)
        #expect(fixture.bar.presentation == presentation)
        #expect(dividerWrites == [false])
        fixture.bar.hide()
        await finish.open()
        await fixture.engine.captureChain.value

        #expect(!predecessorWasCancelled)
        #expect(dividerWrites == [false, true])
        #expect(!fixture.bar.hasCapturedOnce)
        #expect(fixture.engine.canRevealOnHover)
    }

    @Test func queuedRetryRechecksWhetherItsPredecessorCompletedTheCache() async {
        var dividerWrites: [Bool] = []
        let fixture = Fixture(setDividerCollapsed: { dividerWrites.append($0) })
        defer { fixture.engine.uninstall() }
        dividerWrites.removeAll()
        let started = AsyncGate()
        let finish = AsyncGate()
        fixture.engine.runCaptureSequence(forceCollapseAfter: false) {
            await started.open()
            await finish.wait()
            await fixture.bar.captureAndCache(anchorMinX: 100)
        }
        await started.wait()
        #expect(fixture.bar.needsCapture)
        fixture.engine.fireWarmUpRetry()
        await finish.open()
        await fixture.engine.captureChain.value

        #expect(dividerWrites == [false, true])
        #expect(fixture.bar.hasCapturedOnce)
        #expect(!fixture.bar.needsCapture)
        #expect(fixture.engine.canRevealOnHover)
    }

    @Test(arguments: [false, true])
    func completedWarmUpDoesNotDiscardQueuedEventRefresh(suspendedPredecessor: Bool) async throws {
        let item = MenuBarItemSnapshot(
            windowID: 1, ownerPID: -1, ownerBundleID: "Test App",
            frame: CGRect(x: 50, y: 0, width: 22, height: 22)
        )
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        var captureCalls = 0
        var dividerWrites: [Bool] = []
        let fixture = Fixture(
            server: FakeWindowServer(items: [item]),
            captureIcons: { _ in captureCalls += 1; return [1: image] },
            setDividerCollapsed: { dividerWrites.append($0) }
        )
        defer { fixture.engine.uninstall() }
        await fixture.bar.captureAndCache(anchorMinX: 100)
        #expect(!fixture.bar.needsCapture)
        #expect(captureCalls == 1)
        dividerWrites.removeAll()
        let started = AsyncGate()
        let finish = AsyncGate()
        if suspendedPredecessor {
            fixture.engine.runCaptureSequence(forceCollapseAfter: false) {
                await started.open()
                await finish.wait()
                #expect(!Task.isCancelled)
            }
            await started.wait()
        }

        fixture.engine.refreshFloatingBarCache()
        fixture.engine.fireWarmUpRetry()
        await finish.open()
        await fixture.engine.captureChain.value

        #expect(captureCalls == 2)
        #expect(dividerWrites == (suspendedPredecessor ? [false, false, true] : [false, true]))
        #expect(!fixture.bar.needsCapture)
        #expect(fixture.engine.canRevealOnHover)
    }

    @Test(arguments: [false, true])
    func rearmingWarmUpInvalidatesOnlyQueuedRetries(eventRefreshQueued: Bool) async {
        var dividerWrites: [Bool] = []
        let fixture = Fixture(setDividerCollapsed: { dividerWrites.append($0) })
        defer { fixture.engine.uninstall() }
        dividerWrites.removeAll()
        let started = AsyncGate()
        let finish = AsyncGate()
        fixture.engine.runCaptureSequence(forceCollapseAfter: false) {
            await started.open()
            await finish.wait()
            #expect(!Task.isCancelled)
        }
        await started.wait()
        #expect(fixture.bar.needsCapture)
        fixture.engine.fireWarmUpRetry()
        if eventRefreshQueued { fixture.engine.refreshFloatingBarCache() }
        fixture.engine.scheduleWarmUpRetries()
        await finish.open()
        await fixture.engine.captureChain.value

        #expect(dividerWrites == (eventRefreshQueued ? [false, false, true] : [false, true]))
        #expect(fixture.bar.hasCapturedOnce == eventRefreshQueued)
        #expect(fixture.engine.canRevealOnHover)
        if !eventRefreshQueued {
            dividerWrites.removeAll()
            fixture.engine.fireWarmUpRetry()
            await fixture.engine.captureChain.value
            #expect(dividerWrites == [false, true])
            #expect(fixture.bar.hasCapturedOnce)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func queuedOptionalCaptureCannotOverrideActivationOrPause(warmUpRetry: Bool, pause: Bool) async {
        var dividerWrites: [Bool] = []
        let fixture = Fixture(setDividerCollapsed: { dividerWrites.append($0) })
        defer { fixture.engine.uninstall() }
        dividerWrites.removeAll()
        let started = AsyncGate()
        let finish = AsyncGate()
        var predecessorWasCancelled = false
        fixture.engine.runCaptureSequence(forceCollapseAfter: true) {
            await started.open()
            await finish.wait()
            predecessorWasCancelled = Task.isCancelled
        }
        await started.wait()
        if warmUpRetry { fixture.engine.fireWarmUpRetry() } else { fixture.engine.refreshFloatingBarCache() }
        if pause {
            fixture.engine.menuTogglePause()
        } else {
            await fixture.engine.revealForActivation()
        }
        await finish.open()
        await fixture.engine.captureChain.value

        #expect(!dividerWrites.contains(true))
        #expect(predecessorWasCancelled == pause)
        #expect(!fixture.bar.hasCapturedOnce)
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(!fixture.engine.canRevealOnHover)
        #expect(!fixture.engine.captureInFlight)
    }

    @Test(arguments: [false, true])
    func queuedOptionalCaptureCannotCollapseInvalidPlacementControls(warmUpRetry: Bool) async throws {
        var dividerWrites: [Bool] = []
        let server = FakeWindowServer()
        let fixture = Fixture(server: server, setDividerCollapsed: { dividerWrites.append($0) })
        defer { fixture.engine.uninstall() }
        fixture.engine.hiddenItemController = HiddenItemController(windowServer: server)
        fixture.preferences.itemControls.setHidden(false, forKey: "Test App")
        dividerWrites.removeAll()
        fixture.engine.apply(preferences: fixture.preferences)
        let placement = try #require(fixture.engine.placementTask)
        if warmUpRetry { fixture.engine.fireWarmUpRetry() } else { fixture.engine.refreshFloatingBarCache() }
        await fixture.engine.captureChain.value
        await placement.value

        #expect(dividerWrites == [false, false])
        #expect(!fixture.bar.hasCapturedOnce)
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .shown)
        #expect(fixture.engine.placementPending)
        #expect(fixture.engine.placementFailed)
        #expect(server.moveRequests.isEmpty)
        #expect(!fixture.engine.canRevealOnHover)
    }

    @Test(arguments: StopReason.allCases, [false, true])
    func engineStopPathsCancelPendingShowsAndCloseOwnedPanels(reason: StopReason, alreadyOpen: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.engine.uninstall() }
        fixture.advance(to: 0.2)
        let task = try #require(fixture.hover.pendingShowTask)
        if alreadyOpen { await task.value }
        let oldTick = fixture.tick
        switch reason {
        case .preference:
            fixture.preferences.revealOnHover = false
            fixture.engine.apply(preferences: fixture.preferences)
        case .floatingBar:
            fixture.preferences.useFloatingBar = false
            fixture.engine.apply(preferences: fixture.preferences)
        case .pause:
            fixture.engine.menuTogglePause()
        case .uninstall:
            fixture.engine.uninstall()
        }
        await task.value
        oldTick?()
        #expect(!fixture.bar.isVisible)
        #expect(!fixture.hover.ownsPanel)
        #expect(fixture.hover.pendingShowTask == nil)
        #expect(fixture.cancelledTimers == 1)
    }

    @Test func shortcutClosingHoverBarSuppressesReopeningAtTheAnchor() async throws {
        let fixture = Fixture()
        defer { fixture.engine.uninstall() }
        fixture.advance(to: 0.2)
        await (try #require(fixture.hover.pendingShowTask)).value
        fixture.engine.toggleFromShortcut()
        fixture.advance(to: 10)
        #expect(!fixture.bar.isVisible)
        #expect(!fixture.hover.ownsPanel)
        #expect(fixture.hover.pendingShowTask == nil)
    }

    @Test func manualCloseStaysSuppressedWhilePlacementOwnsThePointer() async throws {
        let server = FakeWindowServer(items: [
            MenuBarItemSnapshot(windowID: 1, ownerPID: 1, ownerBundleID: "Test App", frame: CGRect(x: 800, y: 0, width: 24, height: 22)),
            MenuBarItemSnapshot(windowID: 90, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: 1000, y: 0, width: 32, height: 22)),
            MenuBarItemSnapshot(windowID: 91, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: 984, y: 0, width: 16, height: 22))
        ])
        let fixture = Fixture(server: server)
        defer { fixture.engine.uninstall() }
        fixture.advance(to: 0.2)
        await (try #require(fixture.hover.pendingShowTask)).value
        fixture.engine.toggleFromShortcut()

        let started = AsyncGate()
        let release = AsyncGate()
        fixture.engine.hiddenItemController = HiddenItemController(windowServer: server) { items in
            await started.open()
            await release.wait()
            return items
        }
        fixture.preferences.itemControls.setHidden(false, forKey: "Test App")
        fixture.engine.apply(preferences: fixture.preferences)
        let placement = try #require(fixture.engine.placementTask)
        await started.wait()
        #expect(!fixture.engine.canRevealOnHover)
        fixture.point = .zero
        fixture.advance(to: 1)
        fixture.point = CGPoint(x: 116, y: 112)
        fixture.advance(to: 2)
        await release.open()
        await placement.value
        #expect(server.moveRequests.count == 1)
        #expect(fixture.engine.canRevealOnHover)
        for time in [3, 3.2, 10] { fixture.advance(to: time) }
        #expect(!fixture.bar.isVisible)
        #expect(fixture.hover.pendingShowTask == nil)
    }

    @Test func openingAnchorMenuDoesNotStrandAHoverPresentation() async throws {
        let fixture = Fixture()
        defer { fixture.engine.uninstall() }
        fixture.advance(to: 0.2)
        await (try #require(fixture.hover.pendingShowTask)).value
        // No status item is installed, so only the real menu-opening cleanup runs.
        fixture.engine.showAnchorMenu()
        fixture.advance(to: 10)
        #expect(!fixture.bar.isVisible)
        #expect(!fixture.hover.ownsPanel)
        #expect(fixture.hover.pendingShowTask == nil)
    }

    @Test func anchorMenuAndDisablingHoverLeaveAManualPresentationAlone() {
        let fixture = Fixture()
        defer { fixture.engine.uninstall() }
        fixture.bar.beginPresentation()
        fixture.engine.showAnchorMenu()
        fixture.point = .zero
        fixture.advance(to: 10)
        fixture.preferences.revealOnHover = false
        fixture.engine.apply(preferences: fixture.preferences)
        #expect(fixture.bar.isVisible)
        #expect(fixture.bar.presentation == .click)
        #expect(!fixture.hover.ownsPanel)
        #expect(fixture.hover.pendingShowTask == nil)
    }

    @Test(arguments: [FloatingBarController.Presentation.click, .keyboard])
    func hoverPolicySurvivesRelayoutButNotANewManualPresentation(manual: FloatingBarController.Presentation) {
        _ = NSApplication.shared
        let bar = FloatingBarController(
            windowServer: FakeWindowServer(), captureIcons: { _ in [:] }, preferences: .default
        )
        let panel = PresentationPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let frame = CGRect(x: 40, y: 40, width: 92, height: 56)
        bar.beginPresentation(.hover)
        bar.present(panel: panel, finalFrame: frame)
        bar.beginPresentation()
        bar.present(panel: panel, finalFrame: frame)
        #expect(bar.presentation == .hover)
        #expect(panel.nonkeyPresentations == 2)
        #expect(panel.keyPresentations == 0)
        bar.hide()
        bar.beginPresentation(manual)
        bar.present(panel: panel, finalFrame: frame)
        #expect(bar.presentation == manual)
        #expect(panel.nonkeyPresentations == 2)
        #expect(panel.keyPresentations == 1)
        bar.hide()
    }

    @Test func nativeActivationRelinquishesHoverBeforeLeavingTheSectionRevealed() async throws {
        let fixture = Fixture()
        defer { fixture.engine.uninstall() }
        fixture.advance(to: 0.2)
        await (try #require(fixture.hover.pendingShowTask)).value
        fixture.bar.hide(notifyDismissal: false)
        await fixture.engine.revealForActivation()
        fixture.point = CGPoint(x: 0, y: 0)
        fixture.advance(to: 10)
        #expect(!fixture.hover.ownsPanel)
        #expect(!fixture.engine.canRevealOnHover)
        #expect(fixture.engine.stateMachine.visibility(of: .hidden) == .shown)
    }

    // MARK: - Always Hidden tier

    @Test func hoverAndShortcutOpensNeverIncludeTheAlwaysHiddenTier() async throws {
        let secret = MenuBarItemSnapshot(
            windowID: 1, ownerPID: -1, ownerBundleID: "Secret App", frame: CGRect(x: 50, y: 0, width: 22, height: 22)
        )
        let hidden = MenuBarItemSnapshot(
            windowID: 2, ownerPID: -1, ownerBundleID: "Hidden App", frame: CGRect(x: 700, y: 0, width: 22, height: 22)
        )
        let server = FakeWindowServer(items: [secret, hidden] + [
            MenuBarItemSnapshot(windowID: 90, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: 1000, y: 0, width: 32, height: 22)),
            MenuBarItemSnapshot(windowID: 91, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: 984, y: 0, width: 16, height: 22)),
            MenuBarItemSnapshot(windowID: 92, ownerPID: 1, title: "BKFAlwaysHidden", frame: CGRect(x: 600, y: 0, width: 8, height: 22))
        ])
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let recorder = AlwaysHiddenDividerRecorder()
        var dividerWrites: [Bool] = []
        let fixture = Fixture(
            server: server,
            captureIcons: { items in Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) }) },
            setDividerCollapsed: { dividerWrites.append($0) },
            itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["Secret App"]),
            alwaysHiddenDivider: recorder.hooks
        )
        defer { fixture.engine.uninstall() }
        #expect(recorder.creates == 1)
        #expect(fixture.bar.alwaysHiddenDividerWindowID == 92)
        await fixture.bar.captureAndCache(anchorMinX: 100)
        #expect(fixture.bar.cachedHiddenItems().map(\.id) == [2])
        #expect(fixture.bar.cachedAlwaysHiddenItems().map(\.id) == [1])
        dividerWrites.removeAll()
        recorder.writes.removeAll()

        fixture.advance(to: 0.2)
        await (try #require(fixture.hover.pendingShowTask)).value
        #expect(fixture.bar.isVisible)
        #expect(fixture.bar.presentation == .hover)
        #expect(!fixture.bar.presentsAlwaysHidden)
        var view = try #require(fixture.panel.contentViewController as? NSHostingController<FloatingBarView>).rootView
        #expect(view.items.map(\.id) == [2])
        #expect(view.alwaysHiddenItems.isEmpty)
        fixture.bar.hide()

        let presented = AsyncGate()
        fixture.panel.onPresent = { Task { await presented.open() } }
        fixture.engine.toggleFromShortcut()
        await presented.wait()
        #expect(fixture.bar.presentation == .keyboard)
        #expect(!fixture.bar.presentsAlwaysHidden)
        view = try #require(fixture.panel.contentViewController as? NSHostingController<FloatingBarView>).rootView
        #expect(view.alwaysHiddenItems.isEmpty)
        fixture.bar.hide()

        let optionPresented = AsyncGate()
        fixture.panel.onPresent = { Task { await optionPresented.open() } }
        fixture.engine.anchorLeftClick(optionHeld: true)
        await optionPresented.wait()
        #expect(fixture.bar.presentsAlwaysHidden)
        view = try #require(fixture.panel.contentViewController as? NSHostingController<FloatingBarView>).rootView
        #expect(view.items.map(\.id) == [2])
        #expect(view.alwaysHiddenItems.map(\.id) == [1])
        await fixture.engine.captureChain.value

        #expect(dividerWrites.isEmpty)
        #expect(recorder.writes.isEmpty)
        #expect(server.clickedWindowIDs.isEmpty)
        #expect(server.moveRequests.isEmpty)
        #expect(fixture.engine.stateMachine.visibility(of: .alwaysHidden) == .collapsed)
    }

    @Test func optionClickOverAHoverOpenedBarWidensItAsAClickPresentation() async throws {
        let secret = MenuBarItemSnapshot(
            windowID: 1, ownerPID: -1, ownerBundleID: "Secret App", frame: CGRect(x: 50, y: 0, width: 22, height: 22)
        )
        let hidden = MenuBarItemSnapshot(
            windowID: 2, ownerPID: -1, ownerBundleID: "Hidden App", frame: CGRect(x: 700, y: 0, width: 22, height: 22)
        )
        let server = FakeWindowServer(items: [secret, hidden] + [
            MenuBarItemSnapshot(windowID: 90, ownerPID: 1, title: "BKFAnchor", frame: CGRect(x: 1000, y: 0, width: 32, height: 22)),
            MenuBarItemSnapshot(windowID: 91, ownerPID: 1, title: "BKFHidden", frame: CGRect(x: 984, y: 0, width: 16, height: 22)),
            MenuBarItemSnapshot(windowID: 92, ownerPID: 1, title: "BKFAlwaysHidden", frame: CGRect(x: 600, y: 0, width: 8, height: 22))
        ])
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let recorder = AlwaysHiddenDividerRecorder()
        let fixture = Fixture(
            server: server,
            captureIcons: { items in Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, image) }) },
            itemControls: ItemControlStore(alwaysHiddenInMenuBar: ["Secret App"]),
            alwaysHiddenDivider: recorder.hooks
        )
        defer { fixture.engine.uninstall() }
        await fixture.bar.captureAndCache(anchorMinX: 100)
        #expect(fixture.bar.cachedAlwaysHiddenItems().map(\.id) == [1])

        fixture.advance(to: 0.2)
        await (try #require(fixture.hover.pendingShowTask)).value
        #expect(fixture.bar.isVisible)
        #expect(fixture.bar.presentation == .hover)
        #expect(fixture.hover.ownsPanel)
        #expect(fixture.panel.nonkeyPresentations == 1)
        #expect(fixture.panel.keyPresentations == 0)

        let widened = AsyncGate()
        fixture.panel.onPresent = { Task { await widened.open() } }
        fixture.engine.anchorLeftClick(optionHeld: true)
        await widened.wait()
        #expect(fixture.bar.isVisible)
        #expect(fixture.bar.presentsAlwaysHidden)
        #expect(fixture.bar.presentation == .click)
        #expect(!fixture.hover.ownsPanel)
        #expect(fixture.panel.keyPresentations == 1)
        #expect(fixture.panel.nonkeyPresentations == 1)
        let view = try #require(fixture.panel.contentViewController as? NSHostingController<FloatingBarView>).rootView
        #expect(view.items.map(\.id) == [2])
        #expect(view.alwaysHiddenItems.map(\.id) == [1])

        // Leaving the anchor no longer closes it: the click presentation owns the panel now.
        fixture.point = CGPoint(x: 600, y: 600)
        fixture.advance(to: 5)
        #expect(fixture.bar.isVisible)
        fixture.engine.anchorLeftClick(optionHeld: true)
        #expect(!fixture.bar.isVisible)
        #expect(server.clickedWindowIDs.isEmpty)
        #expect(server.moveRequests.isEmpty)
    }
}

@MainActor
private final class Fixture {
    var time: TimeInterval = 0
    var point = CGPoint(x: 116, y: 112)
    var tick: (@MainActor @Sendable () -> Void)?
    var cancelledTimers = 0
    var preferences = Preferences(autoRehide: false, dismissBarOnMouseExit: false, revealOnHover: true)
    let engine: CosmeticHideEngine
    let bar: FloatingBarController
    let panel: PresentationPanel
    var hover: HoverRevealController { engine.hoverRevealController! }

    init(
        server: FakeWindowServer = FakeWindowServer(),
        captureIcons: @escaping ([MenuBarItemSnapshot]) async -> [CGWindowID: CGImage] = { _ in [:] },
        setDividerCollapsed: @escaping (Bool) -> Void = { _ in },
        itemControls: ItemControlStore = ItemControlStore(),
        alwaysHiddenDivider: AlwaysHiddenDividerHooks? = nil
    ) {
        _ = NSApplication.shared
        preferences = Preferences(
            autoRehide: false, itemControls: itemControls, dismissBarOnMouseExit: false, revealOnHover: true
        )
        let panel = PresentationPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        self.panel = panel
        engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) }, setDividerCollapsed: setDividerCollapsed,
            anchorFrame: { CGRect(x: 100, y: 100, width: 32, height: 24) }, alwaysHiddenDivider: alwaysHiddenDivider,
            onPreferencesChanged: { _ in }
        )
        bar = FloatingBarController(
            windowServer: server, captureIcons: captureIcons, preferences: preferences, attribute: { $0 },
            panelFactory: { panel }
        )
        engine.floatingBar = bar
        engine.toggleHidden()
        let hover = HoverRevealController(
            anchorFrame: { CGRect(x: 100, y: 100, width: 32, height: 24) },
            panelFrame: { CGRect(x: 40, y: 40, width: 92, height: 56) },
            isPanelVisible: { [weak bar] in bar?.isVisible == true },
            canReveal: { [weak engine] in engine?.canRevealOnHover == true },
            showPanel: { [weak engine] in await engine?.revealFloatingBarOnHover() },
            hidePanel: { [weak bar] in bar?.hide() },
            pointerLocation: { [weak self] in self?.point ?? .zero },
            isMouseButtonPressed: { false },
            now: { [weak self] in self?.time ?? 0 },
            scheduleTimer: { [weak self] _, tick in
                self?.tick = tick
                return { [weak self] in
                    self?.cancelledTimers += 1
                    self?.tick = nil
                }
            }
        )
        engine.hoverRevealController = hover
        bar.onDidHide = { [weak hover] in hover?.relinquishForManualInteraction() }
        engine.apply(preferences: preferences)
    }

    func advance(to time: TimeInterval) {
        self.time = time
        tick?()
    }
}

@MainActor
private final class PresentationPanel: NSPanel {
    var keyPresentations = 0
    var nonkeyPresentations = 0
    var onPresent: (() -> Void)?

    override func makeKeyAndOrderFront(_ sender: Any?) {
        keyPresentations += 1
        onPresent?()
    }
    override func orderFront(_ sender: Any?) {
        nonkeyPresentations += 1
        onPresent?()
    }
    override func orderOut(_ sender: Any?) {}
}
