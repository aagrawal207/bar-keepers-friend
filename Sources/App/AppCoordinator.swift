import AppKit
import BarKeepersFriendCore

/// Wires together the runtime pieces and owns their lifetimes. Kept deliberately thin:
/// all decision-making lives in Core; this class only connects Core to AppKit objects.
@MainActor
final class AppCoordinator {
    private let preferencesStore = PreferencesStore(backing: UserDefaults.standard)
    private var preferences: Preferences
    private var hideEngine: CosmeticHideEngine?
    private var settingsWindowController: SettingsWindowController?
    private let loginItem = LoginItemService()

    private let windowServer: WindowServer = SystemWindowServer()
    private let capture = IconCaptureService()
    private var floatingBar: FloatingBarController?

    init() {
        preferences = preferencesStore.load()
    }

    /// True if another copy of this app (same bundle id) is already running.
    static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        // Count includes ourselves; more than one means a duplicate.
        return running.count > 1
    }

    func start() {
        let bar = FloatingBarController(
            windowServer: windowServer,
            capture: capture,
            preferences: preferences
        )
        floatingBar = bar

        let engine = CosmeticHideEngine(preferences: preferences) { [weak self] updated in
            self?.persist(updated)
        }
        engine.floatingBar = bar
        engine.install()
        engine.onOpenSettings = { [weak self] in self?.showSettings() }
        hideEngine = engine

        // Prompt for Screen Recording up front when the floating bar is enabled, since it
        // needs capture to show icons. Permission-free hide/show still works without it.
        if preferences.useFloatingBar, !capture.hasScreenRecordingAccess {
            Task { await capture.requestScreenRecordingAccess() }
        }

        // TEMP self-test: a few seconds after launch, capture the hidden items to PNGs so
        // the legacy off-screen capture path can be verified without a manual click.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            await self.captureSelfTest()
        }
    }

    /// TEMP: captures on-screen menu bar items and dumps PNGs to verify on-screen capture.
    private func captureSelfTest() async {
        let snapshots = (try? windowServer.menuBarItems()) ?? []
        // On-screen, non-system status items (positive x), excluding our own.
        let onScreen = snapshots
            .filter { $0.frame.minX >= 0 && $0.frame.minX < 2000 }
            .filter { !HiddenItemsResolver.isOwnControlItem($0) }
            .filter { !($0.title?.isEmpty ?? true) || $0.frame.width < 60 }
            .sorted { $0.frame.minX < $1.frame.minX }
            .prefix(5)
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/bkf-captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in onScreen {
            DebugLog.log("SELFTEST item: id=\(item.windowID) x=\(Int(item.frame.minX)) w=\(Int(item.frame.width)) title=\(item.title ?? "nil")")
        }
        // RECT-based capture: crop the display to each item's frame.
        guard let (display, displayFrame) = await capture.firstDisplay() else {
            DebugLog.log("SELFTEST: no display"); return
        }
        DebugLog.log("SELFTEST display: \(Int(displayFrame.width))x\(Int(displayFrame.height))")
        var rectOK = 0
        for item in onScreen {
            // Item frame is in global top-left coords; for a single display at origin this
            // is also display-relative. Pad height to the full menu bar.
            let rect = CGRect(x: item.frame.minX, y: 0, width: item.frame.width, height: 24)
            if let img = await capture.captureDisplayRegion(rect, display: display, fullDisplayFrame: displayFrame) {
                let rep = NSBitmapImageRep(cgImage: img)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: dir.appendingPathComponent("rect-\(item.windowID).png"))
                    rectOK += 1
                }
            }
        }
        DebugLog.log("SELFTEST: rectCaptured=\(rectOK)/\(onScreen.count) dir=\(dir.path)")
    }

    func stop() {
        hideEngine?.uninstall()
    }

    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                preferences: preferences,
                loginItem: loginItem
            ) { [weak self] updated in
                self?.persist(updated)
                self?.hideEngine?.apply(preferences: updated)
                self?.floatingBar?.preferences = updated
            }
        }
        settingsWindowController?.show()
    }

    private func persist(_ updated: Preferences) {
        preferences = updated
        preferencesStore.save(updated)
    }
}
