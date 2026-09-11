import AppKit
import BarKeepersFriendCore
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HoverRevealIntegrationTests {
    enum StopReason: CaseIterable, Sendable {
        case preference, floatingBar, pause, uninstall
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
}

@MainActor
private final class Fixture {
    var time: TimeInterval = 0
    var point = CGPoint(x: 116, y: 112)
    var tick: (@MainActor @Sendable () -> Void)?
    var cancelledTimers = 0
    var preferences = Preferences(autoRehide: false, revealOnHover: true)
    let engine: CosmeticHideEngine
    let bar: FloatingBarController
    var hover: HoverRevealController { engine.hoverRevealController! }

    init(server: FakeWindowServer = FakeWindowServer()) {
        engine = CosmeticHideEngine(
            preferences: preferences, controlWindowIDs: { (90, 91) }, onPreferencesChanged: { _ in }
        )
        bar = FloatingBarController(
            windowServer: server, captureIcons: { _ in [:] }, preferences: preferences, attribute: { $0 }
        )
        engine.floatingBar = bar
        engine.toggleHidden()
        let hover = HoverRevealController(
            anchorFrame: { CGRect(x: 100, y: 100, width: 32, height: 24) },
            panelFrame: { CGRect(x: 40, y: 40, width: 92, height: 56) },
            isPanelVisible: { [weak bar] in bar?.isVisible == true },
            canReveal: { [weak engine] in engine?.canRevealOnHover == true },
            showPanel: { [weak bar] in
                guard !Task.isCancelled else { return }
                bar?.beginPresentation(.hover)
            },
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

    override func makeKeyAndOrderFront(_ sender: Any?) { keyPresentations += 1 }
    override func orderFront(_ sender: Any?) { nonkeyPresentations += 1 }
}
