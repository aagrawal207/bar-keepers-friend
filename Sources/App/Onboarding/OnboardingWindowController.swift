import AppKit
import SwiftUI

/// Hosts the onboarding pages in a plain, non-resizable window. Closing the window by any route
/// counts as skipping, so the host learns exactly once that first-run guidance is over.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    typealias WindowFactory = @MainActor (NSViewController) -> NSWindow

    let model: OnboardingModel
    private(set) var window: NSWindow?
    private let makeWindow: WindowFactory
    private let activateApp: @MainActor () -> Void

    /// `makeWindow` and `activateApp` exist so tests can present without touching the screen.
    init(
        model: OnboardingModel,
        makeWindow: @escaping WindowFactory = { NSWindow(contentViewController: $0) },
        activateApp: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    ) {
        self.model = model
        self.makeWindow = makeWindow
        self.activateApp = activateApp
        super.init()
        // Hooking the model rather than wrapping onComplete keeps dismissal
        // working however late the host assigns its own onComplete.
        model.onWillComplete = { [weak self] in self?.dismissWindow() }
    }

    /// Builds the window without ordering it on screen; `show()` does the rest.
    @discardableResult
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        let window = makeWindow(hosting)
        window.title = "Welcome to Bar Keeper's Friend"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The hosted size only settles on a later layout pass; fix it now so centering uses the real frame.
        window.setContentSize(OnboardingView.windowSize)
        window.center()
        self.window = window
        return window
    }

    func show() {
        // A completed model cannot dismiss a new window; show onboarding again with a fresh model.
        guard !model.isCompleted else { return }
        let window = prepareWindow()
        activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    /// Programmatic dismissal counts as skipping.
    func close() {
        dismissWindow()
        model.complete()
    }

    private func dismissWindow() {
        guard let window else { return }
        self.window = nil
        // Detaching first keeps the delegate callback from re-entering completion mid-close.
        window.delegate = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.complete()
    }
}
