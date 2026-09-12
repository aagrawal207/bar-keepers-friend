import CoreGraphics
import Darwin
import Foundation
import Synchronization

// Each scope belongs to the existing serialized gesture caller, including across suspension.
final class CursorConcealment {
    private let sessionAllowsInteraction: () -> Bool
    private let originalPosition: CGPoint
    private let warpCursor: (CGPoint) -> CGError
    private let showCursor: () -> CGError
    private let needsShow: Bool
    private var restored = false
    private(set) var sessionLost = false

    // Only a missing restore point returns nil; interruption must remain distinct from item failure.
    init?(
        canInteract: @escaping () -> Bool = DesktopSession.canInteract,
        position: () -> CGPoint? = { CGEvent(source: nil)?.location },
        enableBackground: () -> Void = { BackgroundCursorCapability.shared.enable() },
        hide: () -> CGError = { CGDisplayHideCursor(kCGNullDirectDisplay) },
        warp: @escaping (CGPoint) -> CGError = { CGWarpMouseCursorPosition($0) },
        show: @escaping () -> CGError = { CGDisplayShowCursor(kCGNullDirectDisplay) }
    ) throws {
        try Task.checkCancellation()
        guard canInteract() else {
            DebugLog.log("cursor: no interactive session; gesture skipped")
            throw CancellationError()
        }
        let savedPosition = position()
        guard canInteract() else {
            DebugLog.log("cursor: session lost before capability setup; gesture skipped")
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard let originalPosition = savedPosition else {
            DebugLog.log("cursor: original position unavailable; gesture skipped")
            return nil
        }
        self.sessionAllowsInteraction = canInteract
        self.originalPosition = originalPosition
        self.warpCursor = warp
        self.showCursor = show
        enableBackground()
        guard canInteract() else {
            DebugLog.log("cursor: session lost before hide; gesture skipped")
            throw CancellationError()
        }
        try Task.checkCancellation()
        let result = hide()
        needsShow = result == .success
        if !needsShow {
            DebugLog.log("cursor: hide failed error=\(result.rawValue); continuing without concealment")
        }
    }

    private var canInteract: Bool {
        guard !restored, !sessionLost else { return false }
        sessionLost = !sessionAllowsInteraction()
        if sessionLost {
            DebugLog.log("cursor: session lost; positional interaction stopped")
        }
        return !sessionLost
    }

    var canSubmitInput: Bool { canInteract && !Task.isCancelled }

    func checkInterruption() throws {
        guard canSubmitInput else { throw CancellationError() }
    }

    func warp(to point: CGPoint) throws -> Bool {
        guard !restored else { return false }
        try checkInterruption()
        let result = warpCursor(point)
        try checkInterruption()
        if result != .success {
            DebugLog.log("cursor: positioning failed error=\(result.rawValue)")
        }
        return result == .success
    }

    func performGesture(_ gesture: () throws -> Void) throws -> Bool {
        // Delayed senders must also check canSubmitInput; once submitted, a down still needs its up.
        guard !restored else { return false }
        try checkInterruption()
        try gesture()
        try checkInterruption()
        return true
    }

    func restore() {
        guard !restored else { return }
        let restorePosition = canInteract
        restored = true
        if restorePosition {
            let positionResult = warpCursor(originalPosition)
            if positionResult != .success {
                DebugLog.log("cursor: restoring original position failed error=\(positionResult.rawValue)")
            }
        }
        // Balance only an accepted hide, even if it did not visibly conceal the cursor.
        // Session loss or a failed warp must not prevent showing or cause an extra show attempt.
        if needsShow {
            let showResult = showCursor()
            if showResult != .success {
                DebugLog.log("cursor: show failed error=\(showResult.rawValue)")
            }
        }
    }

    deinit { restore() }
}

enum DesktopSession {
    static func canInteract() -> Bool {
        canInteract(with: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    static func canInteract(with session: [String: Any]?) -> Bool {
        guard let session,
              session["kCGSSessionOnConsoleKey"] as? Bool == true,
              session["kCGSessionLoginDoneKey"] as? Bool == true else { return false }
        // Unlocked sessions can omit the lock key; an unrecognized present value is not safe.
        guard let locked = session["CGSSessionScreenIsLocked"] else { return true }
        return locked as? Bool == false
    }
}

final class BackgroundCursorCapability: Sendable {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> CGError

    static let shared: BackgroundCursorCapability = {
        guard let library = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
        ) else {
            return BackgroundCursorCapability(mainConnectionID: nil, setConnectionProperty: nil)
        }
        guard let mainSymbol = dlsym(library, "CGSMainConnectionID"),
              let setSymbol = dlsym(library, "CGSSetConnectionProperty") else {
            dlclose(library)
            return BackgroundCursorCapability(mainConnectionID: nil, setConnectionProperty: nil)
        }
        // Keep the library loaded for the lifetime of these dynamically resolved function pointers.
        let mainConnection = unsafeBitCast(mainSymbol, to: MainConnectionID.self)
        let setProperty = unsafeBitCast(setSymbol, to: SetConnectionProperty.self)
        return BackgroundCursorCapability(
            mainConnectionID: { mainConnection() },
            setConnectionProperty: { setProperty($0, $1, $2, $3) }
        )
    }()

    private let mainConnectionID: (@Sendable () -> Int32)?
    private let setConnectionProperty: (@Sendable (Int32, Int32, CFString, CFTypeRef) -> CGError)?
    private let enabledConnectionID = Mutex<Int32?>(nil)

    init(
        mainConnectionID: (@Sendable () -> Int32)?,
        setConnectionProperty: (@Sendable (Int32, Int32, CFString, CFTypeRef) -> CGError)?
    ) {
        self.mainConnectionID = mainConnectionID
        self.setConnectionProperty = setConnectionProperty
    }

    func enable() {
        // Only capability setup is locked; no lock spans a gesture or an async suspension.
        enabledConnectionID.withLock { enabledID in
            guard let mainConnectionID, let setConnectionProperty else {
                DebugLog.log("cursor: background capability unavailable (missing CGS symbols)")
                return
            }
            let connectionID = mainConnectionID()
            guard connectionID > 0 else {
                DebugLog.log("cursor: background capability unavailable (invalid main connection)")
                return
            }
            guard enabledID != connectionID else { return }
            let result = setConnectionProperty(
                connectionID, connectionID, "SetsCursorInBackground" as CFString, kCFBooleanTrue
            )
            if result == .success {
                // Retain our own connection's capability: show presentation can outlive the scope.
                enabledID = connectionID
            } else {
                DebugLog.log("cursor: background capability failed error=\(result.rawValue)")
            }
        }
    }
}
