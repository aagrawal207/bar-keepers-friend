import AppKit
import BarKeepersFriendCore
import SwiftUI
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct OnboardingTests {
    // MARK: - Model

    @Test func navigationStaysWithinTheFourStepsAndCompletesOnce() {
        let probe = OnboardingTestProbe([.accessibility: .granted, .screenRecording: .denied])
        let recorder = OnboardingTestRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        model.onWillComplete = { recorder.record("will-complete") }
        #expect(OnboardingModel.Step.allCases == [.welcome, .layoutMode, .permissions, .done])
        #expect(OnboardingModel.stepCount == 4)
        #expect(model.step == .welcome)
        #expect(!model.canGoBack)
        #expect(!model.isLastStep)
        #expect(model.stepNumber == 1)

        model.back()
        #expect(model.step == .welcome)
        model.next()
        #expect(model.step == .layoutMode)
        #expect(model.canGoBack)
        #expect(probe.calls == 0)
        #expect(model.status(of: .accessibility) == .notDetermined)

        // Entering the permissions step reads the probe once per permission, before any frame renders.
        model.next()
        #expect(model.step == .permissions)
        #expect(probe.calls == 2)
        #expect(model.status(of: .accessibility) == .granted)
        #expect(model.status(of: .screenRecording) == .denied)

        model.next()
        model.next()
        #expect(model.step == .done)
        #expect(model.isLastStep)
        #expect(model.stepNumber == 4)
        #expect(probe.calls == 2)
        #expect(recorder.events.isEmpty)

        model.performPrimaryAction()
        #expect(model.isCompleted)
        #expect(recorder.events == ["will-complete", "complete"])
        model.performPrimaryAction()
        model.complete()
        #expect(recorder.events == ["will-complete", "complete"])

        // Opening Settings after completion still opens Settings but never completes twice.
        model.finishAndOpenSettings()
        #expect(recorder.events == ["will-complete", "complete", "open-settings"])
    }

    @Test func openingSystemSettingsRoutesToTheInjectedHelpers() {
        let recorder = OnboardingTestRecorder()
        let model = makeModel(recorder: recorder)
        model.openSystemSettings(for: .accessibility)
        model.openSystemSettings(for: .screenRecording)
        #expect(recorder.events == ["request-accessibility", "open-screen-recording"])
        #expect(!model.isCompleted)
    }

    @Test func pollingRefreshesOncePerTickAndStopsWhenCancelled() async {
        let probe = OnboardingTestProbe([.accessibility: .denied, .screenRecording: .denied])
        let ticker = OnboardingTestTicker()
        let recorder = OnboardingTestRecorder()
        let model = makeModel(probe: probe, ticker: ticker, recorder: recorder)

        let polling = Task { await model.pollPermissions() }
        #expect(await waitUntil { ticker.sleepRequests == 1 })
        #expect(probe.calls == 0)
        #expect(ticker.requestedDurations == [.seconds(2)])

        probe.set(.granted, for: .accessibility)
        ticker.tick()
        #expect(await waitUntil { ticker.sleepRequests == 2 })
        #expect(probe.calls == 2)
        #expect(model.status(of: .accessibility) == .granted)

        probe.set(.denied, for: .accessibility)
        ticker.tick()
        #expect(await waitUntil { ticker.sleepRequests == 3 })
        #expect(probe.calls == 4)
        #expect(model.status(of: .accessibility) == .lapsed)

        polling.cancel()
        await polling.value
        ticker.tick()
        await settle(nil)
        #expect(probe.calls == 4)
        #expect(ticker.sleepRequests == 3)
        #expect(ticker.pendingSleeps == 0)
        #expect(recorder.events.isEmpty)
    }

    // MARK: - View

    @Test func continueBackAndSkipNavigateThroughRealPresses() async throws {
        let recorder = OnboardingTestRecorder()
        let model = makeModel(recorder: recorder)
        let hosting = host(OnboardingView(model: model))
        let view = hosting.view

        #expect(try label("onboarding-step-indicator", in: view) == "Step 1 of 4: Welcome")
        #expect(hasElement("onboarding-step-welcome", in: view))
        #expect(hasElement("onboarding-skip", in: view))
        #expect(hasElement("onboarding-continue", in: view))
        #expect(!hasElement("onboarding-finish", in: view))
        #expect(try text("onboarding-version", in: view).hasPrefix("Version "))
        for identifier in [
            "onboarding-feature-hide", "onboarding-feature-bar", "onboarding-feature-staging", "onboarding-feature-shortcut"
        ] {
            #expect(hasElement(identifier, in: view), "\(identifier) belongs on the welcome step")
        }
        let welcomeText = try subtreeText("onboarding-step-welcome", in: view)
        #expect(welcomeText.contains("Bar Keeper's Friend"))
        #expect(welcomeText.contains("Settings > Items"))
        #expect(welcomeText.contains("Option-Command-B"))
        #expect(welcomeText.contains("hover or scroll"))

        let back = try element("onboarding-back", in: view)
        #expect(!back.isAccessibilityEnabled())
        #expect(!back.accessibilityPerformPress())
        await settle(view)
        #expect(model.step == .welcome)

        try await press("onboarding-continue", in: view) { model.step == .layoutMode }
        #expect(await waitForUpdate(view) { hasElement("onboarding-step-layout-mode", in: view) })
        #expect(!hasElement("onboarding-step-welcome", in: view))
        #expect(try label("onboarding-step-indicator", in: view) == "Step 2 of 4: Layout Mode")
        #expect(try element("onboarding-back", in: view).isAccessibilityEnabled())
        let layoutText = try subtreeText("onboarding-step-layout-mode", in: view)
        #expect(layoutText.contains("On-Demand"))
        #expect(layoutText.contains("only the items you explicitly change"))
        #expect(layoutText.contains("never re-applied behind your back"))
        #expect(!layoutText.contains("Live mode"))
        let layoutStep = try element("onboarding-step-layout-mode", in: view)
        let controlRoles: [NSAccessibility.Role] = [.button, .checkBox, .radioButton, .radioGroup, .popUpButton, .menuButton]
        let layoutControls = settingsTestAccessibility(layoutStep).filter { child in
            guard let role = child.accessibilityRole() else { return false }
            return controlRoles.contains(role)
        }
        #expect(layoutControls.isEmpty, "the layout mode step explains On-Demand without offering a control")

        try await press("onboarding-back", in: view) { model.step == .welcome }
        #expect(await waitForUpdate(view) { hasElement("onboarding-step-welcome", in: view) })
        #expect(try label("onboarding-step-indicator", in: view) == "Step 1 of 4: Welcome")

        try await advance(model, in: view, to: .permissions)
        #expect(try label("onboarding-step-indicator", in: view) == "Step 3 of 4: Permissions")
        #expect(hasElement("onboarding-skip", in: view))
        #expect(hasElement("onboarding-permission-accessibility", in: view))
        #expect(hasElement("onboarding-permission-screen-recording", in: view))

        try await press("onboarding-continue", in: view) { model.step == .done }
        #expect(await waitForUpdate(view) { hasElement("onboarding-step-done", in: view) && hasElement("onboarding-finish", in: view) })
        #expect(!hasElement("onboarding-continue", in: view))
        #expect(!hasElement("onboarding-skip", in: view))
        #expect(hasElement("onboarding-open-settings", in: view))
        #expect(try label("onboarding-step-indicator", in: view) == "Step 4 of 4: All Set")
        let doneText = try subtreeText("onboarding-step-done", in: view)
        #expect(doneText.contains("Settings > Items"))

        try await press("onboarding-back", in: view) { model.step == .permissions }
        #expect(await waitForUpdate(view) { hasElement("onboarding-step-permissions", in: view) && hasElement("onboarding-continue", in: view) })
        #expect(recorder.events.isEmpty)
        #expect(!model.isCompleted)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test(arguments: [false, true])
    func skipAndFinishCompleteExactlyOnce(finish: Bool) async throws {
        let recorder = OnboardingTestRecorder()
        let model = makeModel(recorder: recorder)
        let hosting = host(OnboardingView(model: model))
        let view = hosting.view
        if finish {
            try await advance(model, in: view, to: .done)
        }
        let identifier = finish ? "onboarding-finish" : "onboarding-skip"
        #expect(await waitForUpdate(view) { hasElement(identifier, in: view) })

        try await press(identifier, in: view) { model.isCompleted }
        #expect(recorder.events == ["complete"])

        // The host dismisses on completion; a stale second press must still not complete twice.
        hosting.render()
        if let stale = settingsTestAccessibility(view).first(where: { $0.accessibilityIdentifier() == identifier }) {
            _ = stale.accessibilityPerformPress()
        }
        await settle(view)
        model.complete()
        #expect(recorder.events == ["complete"])
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func openSettingsFromTheDoneStepCompletesFirst() async throws {
        let recorder = OnboardingTestRecorder()
        let model = makeModel(recorder: recorder)
        let hosting = host(OnboardingView(model: model))
        let view = hosting.view
        try await advance(model, in: view, to: .done)

        try await press("onboarding-open-settings", in: view) { recorder.events.count == 2 }
        #expect(recorder.events == ["complete", "open-settings"])
        #expect(model.isCompleted)

        hosting.render()
        try press("onboarding-finish", in: view)
        await settle(view)
        #expect(recorder.events == ["complete", "open-settings"])
        #expect(!hosting.testWindow.isVisible)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func permissionChipsFollowTheProbeAndButtonsCallTheInjectedClosures(scheme: ColorScheme) async throws {
        let probe = OnboardingTestProbe([.accessibility: .granted, .screenRecording: .denied])
        let recorder = OnboardingTestRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let hosting = host(OnboardingView(model: model), scheme: scheme)
        let view = hosting.view
        try await advance(model, in: view, to: .permissions)

        let stepText = try subtreeText("onboarding-step-permissions", in: view)
        #expect(stepText.contains("optional"))
        #expect(stepText.contains("Move items across the anchor"))
        #expect(stepText.contains("Activate a hidden item"))
        #expect(stepText.contains("real image"))
        #expect(stepText.contains("Settings > General"))

        let accessibilityChip = try text("onboarding-permission-status-accessibility", in: view)
        #expect(accessibilityChip.contains("Granted"))
        #expect(!accessibilityChip.contains("Not granted"))
        #expect(try text("onboarding-permission-status-screen-recording", in: view).contains("Not granted"))
        #expect(!hasElement("onboarding-permission-open-accessibility", in: view))
        let grantedBitmap = try settingsTestBitmap(view)
        let greenPixels = settingsTestPixelCount(grantedBitmap) { color in
            color.alphaComponent > 0.8 && color.greenComponent > 0.45
                && color.redComponent < 0.45 && color.blueComponent < 0.6
        }
        #expect(greenPixels > 20, "the Granted chip draws in green")

        try await press("onboarding-permission-open-screen-recording", in: view) { !recorder.events.isEmpty }
        #expect(recorder.events == ["open-screen-recording"])

        // The recurring re-approval case: granted earlier, now reported ungranted.
        probe.set(.denied, for: .accessibility)
        model.refreshPermissions()
        #expect(model.status(of: .accessibility) == .lapsed)
        #expect(await waitForUpdate(view) { hasElement("onboarding-permission-open-accessibility", in: view) })
        #expect(try text("onboarding-permission-status-accessibility", in: view).contains("Needs re-approval"))
        let lapsedBitmap = try settingsTestBitmap(view)
        let orangePixels = settingsTestPixelCount(lapsedBitmap) { color in
            color.alphaComponent > 0.8 && color.redComponent > 0.8
                && color.greenComponent > 0.4 && color.greenComponent < 0.8 && color.blueComponent < 0.3
        }
        #expect(orangePixels > 20, "the Needs re-approval chip draws in orange")

        try await press("onboarding-permission-open-accessibility", in: view) { recorder.events.count == 2 }
        #expect(recorder.events == ["open-screen-recording", "request-accessibility"])

        probe.set(.granted, for: .accessibility)
        probe.set(.notDetermined, for: .screenRecording)
        model.refreshPermissions()
        #expect(await waitForUpdate(view) { !hasElement("onboarding-permission-open-accessibility", in: view) })
        #expect(try text("onboarding-permission-status-accessibility", in: view).contains("Granted"))
        #expect(try text("onboarding-permission-status-screen-recording", in: view).contains("Not granted"))
        #expect(hasElement("onboarding-permission-open-screen-recording", in: view))
        #expect(!model.isCompleted)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func everyStepFitsTheFixedWindowWithTheFooterInside(scheme: ColorScheme) async throws {
        for step in OnboardingModel.Step.allCases {
            let probe = OnboardingTestProbe([.accessibility: .granted, .screenRecording: .denied])
            let recorder = OnboardingTestRecorder()
            let model = makeModel(probe: probe, recorder: recorder)
            for _ in 0..<step.rawValue { model.next() }
            if step == .permissions {
                // The widest permissions layout: the longest chip plus both Open System Settings buttons.
                probe.set(.denied, for: .accessibility)
                model.refreshPermissions()
                #expect(model.status(of: .accessibility) == .lapsed)
            }

            let ideal = host(
                OnboardingView(model: model).content.frame(width: OnboardingView.windowSize.width), scheme: scheme
            )
            let idealSize = ideal.view.fittingSize
            #expect(idealSize.width <= OnboardingView.windowSize.width, "\(step) width \(idealSize.width)")
            #expect(idealSize.height <= OnboardingView.windowSize.height, "\(step) needs \(idealSize.height)pt")
            #expect(idealSize.height >= 200, "\(step) rendered no meaningful content")

            let full = host(OnboardingView(model: model), scheme: scheme)
            let view = full.view
            let window = full.testWindow!
            #expect(view.bounds.size == OnboardingView.windowSize)
            #expect(await waitForUpdate(view) {
                (try? element("onboarding-footer", in: view))?.accessibilityFrame().isEmpty == false
            })
            let rootFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
            let footerFrame = try element("onboarding-footer", in: view).accessibilityFrame()
            let stepFrame = try element(stepIdentifier(step), in: view).accessibilityFrame()
            let primaryFrame = try element(step == .done ? "onboarding-finish" : "onboarding-continue", in: view)
                .accessibilityFrame()
            let backFrame = try element("onboarding-back", in: view).accessibilityFrame()
            let indicatorFrame = try element("onboarding-step-indicator", in: view).accessibilityFrame()
            #expect(!footerFrame.isEmpty)
            #expect(!stepFrame.isEmpty)
            #expect(!primaryFrame.isEmpty)
            #expect(!backFrame.isEmpty)
            #expect(rootFrame.contains(footerFrame), "\(step) footer \(footerFrame) escapes \(rootFrame)")
            #expect(rootFrame.contains(stepFrame), "\(step) content \(stepFrame) escapes \(rootFrame)")
            #expect(footerFrame.contains(primaryFrame))
            #expect(footerFrame.contains(backFrame))
            #expect(footerFrame.contains(indicatorFrame))
            #expect(stepFrame.minY >= footerFrame.maxY, "\(step) content overlaps the footer")
            if step != .done {
                let skipFrame = try element("onboarding-skip", in: view).accessibilityFrame()
                #expect(footerFrame.contains(skipFrame))
            }
            let stepControls: [String]
            switch step {
            case .permissions:
                stepControls = ["onboarding-permission-open-accessibility", "onboarding-permission-open-screen-recording"]
            case .done:
                stepControls = ["onboarding-open-settings"]
            case .welcome, .layoutMode:
                stepControls = []
            }
            for identifier in stepControls {
                let control = try element(identifier, in: view)
                #expect(control.isAccessibilityEnabled())
                #expect(stepFrame.contains(control.accessibilityFrame()), "\(identifier) escapes its step")
            }

            // Primary label color is 85% black or white, so interior text pixels carry alpha near 0.85.
            let bitmap = try settingsTestBitmap(view)
            let primaryTextPixels = settingsTestPixelCount(bitmap) { color in
                guard color.alphaComponent > 0.6 else { return false }
                if scheme == .light {
                    return color.redComponent < 0.2 && color.greenComponent < 0.2 && color.blueComponent < 0.2
                }
                return color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent > 0.8
            }
            #expect(primaryTextPixels > 200, "\(step) drew no \(scheme) primary text")
            #expect(!window.isVisible)
            #expect(!window.isKeyWindow)
            #expect(recorder.events.isEmpty)
        }
    }

    // MARK: - Polling

    @Test func permissionPollingRunsOnlyWhileThePermissionsStepIsShowing() async throws {
        let probe = OnboardingTestProbe([.accessibility: .denied, .screenRecording: .granted])
        let ticker = OnboardingTestTicker()
        let recorder = OnboardingTestRecorder()
        let model = makeModel(probe: probe, ticker: ticker, recorder: recorder)
        let hosting = host(OnboardingView(model: model))
        let view = hosting.view

        await settle(view)
        #expect(probe.calls == 0)
        #expect(ticker.sleepRequests == 0)

        try await press("onboarding-continue", in: view) { hasElement("onboarding-step-layout-mode", in: view) }
        await settle(view)
        #expect(probe.calls == 0)
        #expect(ticker.sleepRequests == 0)

        // Entering the step reads both permissions synchronously; polling waits for the first frame.
        try await press("onboarding-continue", in: view) { model.step == .permissions }
        #expect(probe.calls == 2)
        #expect(model.status(of: .screenRecording) == .granted)
        #expect(await waitForUpdate(view) { ticker.sleepRequests == 1 }, "the permissions step must start polling on appear")
        #expect(ticker.requestedDurations == [.seconds(2)])
        #expect(probe.calls == 2)

        probe.set(.granted, for: .accessibility)
        ticker.tick()
        #expect(await waitForUpdate(view) { ticker.sleepRequests == 2 })
        #expect(probe.calls == 4)
        #expect(await waitForUpdate(view) {
            (try? text("onboarding-permission-status-accessibility", in: view))?.contains("Granted") == true
                && !hasElement("onboarding-permission-open-accessibility", in: view)
        })

        // Leaving the step cancels the poll: a late tick must neither read the probe nor sleep again.
        try await press("onboarding-continue", in: view) { hasElement("onboarding-step-done", in: view) }
        #expect(await waitForUpdate(view) { ticker.pendingSleeps == 0 }, "leaving the step must release the pending sleep")
        ticker.tick()
        await settle(view)
        #expect(probe.calls == 4)
        #expect(ticker.sleepRequests == 2)
        #expect(ticker.pendingSleeps == 0)

        try await press("onboarding-back", in: view) { model.step == .permissions }
        #expect(probe.calls == 6)
        #expect(await waitForUpdate(view) { ticker.sleepRequests == 3 }, "returning to the step restarts polling")
        #expect(probe.calls == 6)
        #expect(recorder.events.isEmpty)
        #expect(!hosting.testWindow.isVisible)
    }

    // MARK: - Window controller

    @Test func showBuildsOneFixedWindowAndCompletionDismissesItFirst() throws {
        let recorder = OnboardingTestRecorder()
        let model = makeModel(recorder: recorder)
        var windows: [OnboardingTestWindow] = []
        var activations = 0
        weak var presenter: OnboardingWindowController?
        let controller = OnboardingWindowController(
            model: model,
            makeWindow: { content in
                let window = OnboardingTestWindow(contentViewController: content)
                windows.append(window)
                return window
            },
            activateApp: { activations += 1 }
        )
        presenter = controller
        // Hosts may wire completion after building the presenter; dismissal must not depend on that order.
        model.onComplete = {
            recorder.record(presenter?.window == nil ? "complete-after-dismiss" : "complete-before-dismiss")
        }

        controller.show()
        let window = try #require(windows.first)
        #expect(activations == 1)
        #expect(window.presentations == 1)
        #expect(!window.isVisible)
        #expect(controller.window === window)
        #expect(window.title == "Welcome to Bar Keeper's Friend")
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.resizable))
        #expect(!window.styleMask.contains(.miniaturizable))
        #expect(!window.isReleasedWhenClosed)
        #expect(window.delegate === controller)
        #expect(window.contentViewController is NSHostingController<OnboardingView>)
        #expect(window.contentView?.frame.size == OnboardingView.windowSize)

        controller.show()
        #expect(windows.count == 1)
        #expect(controller.prepareWindow() === window)
        #expect(window.presentations == 2)
        #expect(activations == 2)
        #expect(recorder.events.isEmpty)

        // Skip and Finish both end here.
        model.complete()
        #expect(recorder.events == ["complete-after-dismiss"])
        #expect(controller.window == nil)
        #expect(window.delegate == nil)
        #expect(!window.isVisible)

        controller.close()
        model.complete()
        controller.show()
        #expect(recorder.events == ["complete-after-dismiss"])
        #expect(windows.count == 1)
        #expect(controller.window == nil)
        #expect(activations == 2)
    }

    @Test(arguments: [false, true])
    func closingTheWindowByAnyRouteCountsAsOneSkip(programmatic: Bool) throws {
        let recorder = OnboardingTestRecorder()
        let model = makeModel(recorder: recorder)
        let controller = OnboardingWindowController(
            model: model,
            makeWindow: { OnboardingTestWindow(contentViewController: $0) },
            activateApp: {}
        )
        let window = controller.prepareWindow()
        #expect(window is OnboardingTestWindow)
        #expect(!window.isVisible)
        #expect(recorder.events.isEmpty)

        if programmatic {
            controller.close()
        } else {
            // The title bar close button ends in close(), which reaches the delegate.
            window.close()
        }
        #expect(recorder.events == ["complete"])
        #expect(model.isCompleted)
        #expect(controller.window == nil)
        #expect(!window.isVisible)
        if programmatic {
            #expect(window.delegate == nil)
        }

        controller.close()
        window.close()
        model.complete()
        #expect(recorder.events == ["complete"])
        #expect(controller.window == nil)
    }

    // MARK: - Helpers

    private func makeModel(
        probe: OnboardingTestProbe = OnboardingTestProbe([.accessibility: .denied, .screenRecording: .denied]),
        ticker: OnboardingTestTicker = OnboardingTestTicker(),
        recorder: OnboardingTestRecorder
    ) -> OnboardingModel {
        OnboardingModel(
            permissionProbe: probe,
            pollInterval: .seconds(2),
            sleep: { try await ticker.sleep($0) },
            requestAccessibility: { recorder.record("request-accessibility") },
            openScreenRecording: { recorder.record("open-screen-recording") },
            onOpenSettings: { recorder.record("open-settings") },
            onComplete: { recorder.record("complete") }
        )
    }

    private func host<Content: View>(_ content: Content, scheme: ColorScheme = .light) -> SettingsTestHostingController {
        let hosting = settingsTestHost(content.environment(\.colorScheme, scheme))
        hosting.view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        hosting.testWindow.appearance = hosting.view.appearance
        hosting.render()
        return hosting
    }

    private func stepIdentifier(_ step: OnboardingModel.Step) -> String {
        switch step {
        case .welcome: return "onboarding-step-welcome"
        case .layoutMode: return "onboarding-step-layout-mode"
        case .permissions: return "onboarding-step-permissions"
        case .done: return "onboarding-step-done"
        }
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier })
    }

    private func hasElement(_ identifier: String, in view: NSView) -> Bool {
        settingsTestAccessibility(view).contains { $0.accessibilityIdentifier() == identifier }
    }

    private func text(_ identifier: String, in view: NSView) throws -> String {
        try settingsTestAccessibilityText(element(identifier, in: view))
    }

    private func label(_ identifier: String, in view: NSView) throws -> String? {
        try element(identifier, in: view).accessibilityLabel()
    }

    /// Every label and value beneath a container, so copy assertions do not depend on node grouping.
    private func subtreeText(_ identifier: String, in view: NSView) throws -> String {
        try settingsTestAccessibility(element(identifier, in: view))
            .map { settingsTestAccessibilityText($0) }
            .joined(separator: " ")
    }

    private func press(_ identifier: String, in view: NSView) throws {
        #expect(try element(identifier, in: view).accessibilityPerformPress(), "\(identifier) must accept a press")
    }

    /// SwiftUI may deliver a button action after the press call returns, so effects are awaited.
    private func press(_ identifier: String, in view: NSView, until condition: () -> Bool) async throws {
        try press(identifier, in: view)
        let satisfied = await waitForUpdate(view, until: condition)
        #expect(satisfied, "\(identifier) did not produce the expected change")
    }

    /// Presses Continue until the model reaches `target`, rendering each step before the next press.
    private func advance(_ model: OnboardingModel, in view: NSView, to target: OnboardingModel.Step) async throws {
        while model.step.rawValue < target.rawValue {
            let before = model.step
            try press("onboarding-continue", in: view)
            let advanced = await waitForUpdate(view) {
                model.step.rawValue == before.rawValue + 1 && hasElement(stepIdentifier(model.step), in: view)
            }
            #expect(advanced, "Continue did not advance past \(before)")
            guard advanced else { return }
        }
        #expect(model.step == target)
    }

    private func waitForUpdate(_ view: NSView, until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            (view as? NSHostingView<AnyView>)?._renderForTest(interval: 1.0 / 60)
            view.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while !Task.isCancelled && clock.now < deadline
        return false
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while !Task.isCancelled && clock.now < deadline
        return false
    }

    /// Renders a few frames with main-actor yields, giving any stray async work the chance to surface.
    private func settle(_ view: NSView?, frames: Int = 5) async {
        for _ in 0..<frames {
            (view as? NSHostingView<AnyView>)?._renderForTest(interval: 1.0 / 60)
            view?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Scripted statuses with a call counter, so tests can prove exactly when the model reads the probe.
private final class OnboardingTestProbe: PermissionProbe, Sendable {
    private struct Scripted: Sendable {
        var statuses: [Permission: PermissionStatus]
        var calls = 0
    }

    private let scripted: Mutex<Scripted>

    init(_ statuses: [Permission: PermissionStatus]) {
        scripted = Mutex(Scripted(statuses: statuses))
    }

    func status(of permission: Permission) -> PermissionStatus {
        scripted.withLock { state in
            state.calls += 1
            return state.statuses[permission] ?? .notDetermined
        }
    }

    var calls: Int { scripted.withLock { $0.calls } }

    func set(_ status: PermissionStatus, for permission: Permission) {
        scripted.withLock { $0.statuses[permission] = status }
    }
}

/// Replaces the model's sleep so polling advances one explicit tick at a time instead of waiting 2s.
@MainActor
private final class OnboardingTestTicker {
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextID = 0
    private(set) var sleepRequests = 0
    private(set) var requestedDurations: [Duration] = []

    var pendingSleeps: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        sleepRequests += 1
        requestedDurations.append(duration)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            // Cancellation lands off-actor; resuming only this waiter keeps a restarted poll unaffected.
            Task { @MainActor in self.cancel(id) }
        }
    }

    func tick() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func cancel(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class OnboardingTestRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) { events.append(event) }
}

@MainActor
private final class OnboardingTestWindow: NSWindow {
    private(set) var presentations = 0

    override func makeKeyAndOrderFront(_ sender: Any?) {
        presentations += 1
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place == .out else {
            Issue.record("Onboarding tests must never order a window on screen.")
            return
        }
        super.order(place, relativeTo: otherWin)
    }

    override func orderFrontRegardless() {
        Issue.record("Onboarding tests must never order a window on screen.")
    }
}
