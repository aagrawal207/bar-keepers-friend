import AppKit
import BarKeepersFriendCore
import SwiftUI

/// State machine behind a shortcut recorder. Pure with respect to AppKit: key presses arrive as
/// (keyCode, modifier flags) so tests drive it without constructing or posting `NSEvent`s.
@MainActor
@Observable
final class HotkeyRecorderModel {
    /// The committed shortcut, mirrored from the owning preference.
    private(set) var combo: HotkeyCombo?
    private(set) var isRecording = false
    /// Why the last key press was not accepted; cleared when recording starts or succeeds.
    private(set) var message: String?
    /// Modifiers currently held while recording, echoed so the user sees the shortcut forming.
    private(set) var heldModifiers: UInt = 0
    /// The toggle recorder cannot be cleared: turning its switch off is the way to unset it.
    let allowsClear: Bool

    @ObservationIgnored var conflict: (HotkeyCombo) -> HotkeyAssignments.Conflict?
    @ObservationIgnored var onCommit: (HotkeyCombo?) -> Void

    init(
        combo: HotkeyCombo?,
        allowsClear: Bool = true,
        conflict: @escaping (HotkeyCombo) -> HotkeyAssignments.Conflict? = { _ in nil },
        onCommit: @escaping (HotkeyCombo?) -> Void = { _ in }
    ) {
        self.combo = combo
        self.allowsClear = allowsClear
        self.conflict = conflict
        self.onCommit = onCommit
    }

    static let recordingPrompt = "Press shortcut..."
    static let unsetText = "None"

    var displayText: String {
        if isRecording {
            let held = HotkeyCarbon.modifierSymbols(for: heldModifiers)
            return held.isEmpty ? Self.recordingPrompt : "\(Self.recordingPrompt) \(held)"
        }
        guard let combo, combo.isValid else { return Self.unsetText }
        return HotkeyCarbon.displayString(for: combo)
    }

    var canClear: Bool { allowsClear && combo != nil && !isRecording }

    /// Adopts a value changed elsewhere (import, another recorder) without committing it again.
    func update(combo: HotkeyCombo?) {
        guard self.combo != combo else { return }
        self.combo = combo
    }

    func beginRecording() {
        isRecording = true
        message = nil
        heldModifiers = 0
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = 0
    }

    /// Commits `nil`. A no-op when nothing is set or clearing is not allowed.
    func clear() {
        guard allowsClear else { return }
        isRecording = false
        heldModifiers = 0
        message = nil
        guard combo != nil else { return }
        combo = nil
        onCommit(nil)
    }

    func flagsChanged(modifiers: UInt) {
        guard isRecording else { return }
        heldModifiers = HotkeyAssignments.normalizedModifiers(modifiers)
    }

    /// Handles one key press. Returns whether the press was consumed; `false` means the caller
    /// should let the event continue through the responder chain (not recording).
    @discardableResult
    func handle(keyCode: Int, modifiers rawModifiers: UInt) -> Bool {
        guard isRecording else { return false }
        let modifiers = HotkeyAssignments.normalizedModifiers(rawModifiers)
        heldModifiers = modifiers

        if Self.modifierKeyCodes.contains(keyCode) { return true }
        if modifiers == 0 {
            switch keyCode {
            case Self.escapeKeyCode:
                cancelRecording()
                return true
            case Self.deleteKeyCode, Self.forwardDeleteKeyCode:
                if allowsClear {
                    clear()
                    return true
                }
            default:
                break
            }
        }
        if modifiers & HotkeyAssignments.primaryModifierMask == 0 {
            message = "Hold Command, Option, or Control with the key."
            return true
        }
        let candidate = HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        guard candidate.isValid, HotkeyCarbon.keyName(for: keyCode) != nil else {
            message = "That key can't be used for a shortcut."
            return true
        }
        if let conflict = conflict(candidate) ?? (HotkeyAssignments.isSystemReserved(candidate) ? .systemReserved : nil) {
            message = Self.message(for: conflict)
            return true
        }
        isRecording = false
        heldModifiers = 0
        message = nil
        combo = candidate
        onCommit(candidate)
        return true
    }

    static func message(for conflict: HotkeyAssignments.Conflict) -> String {
        switch conflict {
        case .systemReserved: "That shortcut is reserved by macOS."
        case .toggleBar: "Already used to toggle the bar."
        case .item(let owner): "Already used by \(owner)."
        }
    }

    nonisolated static let escapeKeyCode = 53
    nonisolated static let deleteKeyCode = 51
    nonisolated static let forwardDeleteKeyCode = 117
    /// Modifier keys themselves (left/right variants, caps lock, fn) never complete a shortcut.
    nonisolated static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
}

/// A shortcut recorder row: the current combo, a Record/Cancel button, and (when allowed) a clear
/// button. While recording, an invisible first-responder view swallows the next key press.
struct HotkeyRecorderView: View {
    /// Prefix for accessibility identifiers ("<id>-value", "<id>-record", "<id>-clear", "<id>-message").
    let id: String
    var combo: HotkeyCombo?
    var allowsClear: Bool = true
    var conflict: (HotkeyCombo) -> HotkeyAssignments.Conflict? = { _ in nil }
    var onCommit: (HotkeyCombo?) -> Void = { _ in }

    @State private var model: HotkeyRecorderModel

    init(
        id: String,
        combo: HotkeyCombo?,
        allowsClear: Bool = true,
        conflict: @escaping (HotkeyCombo) -> HotkeyAssignments.Conflict? = { _ in nil },
        onCommit: @escaping (HotkeyCombo?) -> Void = { _ in }
    ) {
        self.id = id
        self.combo = combo
        self.allowsClear = allowsClear
        self.conflict = conflict
        self.onCommit = onCommit
        _model = State(initialValue: HotkeyRecorderModel(combo: combo, allowsClear: allowsClear))
    }

    var body: some View {
        // Closures are untracked model fields; refreshing them here keeps the latest preferences
        // in the conflict check without recreating the model (which would drop recording state).
        model.conflict = conflict
        model.onCommit = onCommit
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                HotkeyCaptureRepresentable(model: model, id: id, isRecording: model.isRecording)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                Text(model.displayText)
                    .font(.body.monospaced())
                    .foregroundStyle(model.isRecording ? .primary : .secondary)
                    .frame(minWidth: 96, alignment: .trailing)
                    .accessibilityIdentifier("\(id)-value")
                Button(model.isRecording ? "Cancel" : "Record") {
                    if model.isRecording { model.cancelRecording() } else { model.beginRecording() }
                }
                .controlSize(.small)
                .help(recordHelp)
                .accessibilityIdentifier("\(id)-record")
                if model.canClear {
                    Button {
                        model.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Remove this shortcut.")
                    .accessibilityLabel("Clear shortcut")
                    .accessibilityIdentifier("\(id)-clear")
                }
            }
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(id)-message")
            }
        }
        .onChange(of: combo) { _, updated in model.update(combo: updated) }
    }

    private var recordHelp: String {
        if model.isRecording { return "Stop recording without changing the shortcut." }
        return allowsClear ? "Record a new shortcut. Esc cancels; Delete clears." : "Record a new shortcut. Esc cancels."
    }
}

/// Bridges the recorder's first-responder key capture into SwiftUI. `isRecording` is a stored
/// input so a state flip always reaches `updateNSView`, even though the model reference is stable.
private struct HotkeyCaptureRepresentable: NSViewRepresentable {
    let model: HotkeyRecorderModel
    let id: String
    let isRecording: Bool

    func makeNSView(context: Context) -> HotkeyCaptureView {
        let view = HotkeyCaptureView()
        view.model = model
        view.setAccessibilityIdentifier("\(id)-capture")
        return view
    }

    func updateNSView(_ view: HotkeyCaptureView, context: Context) {
        view.model = model
        view.syncFirstResponder(recording: isRecording)
    }
}

/// Invisible NSView that becomes first responder while recording so the next key press reaches
/// the model instead of the window (Cmd-W would otherwise close Settings mid-recording).
final class HotkeyCaptureView: NSView {
    var model: HotkeyRecorderModel?

    override var acceptsFirstResponder: Bool { true }

    /// Takes key focus when recording starts and gives it back when recording ends. Deferred so
    /// the responder change never lands inside SwiftUI's own update pass.
    func syncFirstResponder(recording: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let isFirst = window.firstResponder === self
            if recording, !isFirst, self.model?.isRecording == true {
                window.makeFirstResponder(self)
            } else if !recording, isFirst, self.model?.isRecording != true {
                window.makeFirstResponder(nil)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    /// Command shortcuts are offered here before `keyDown`; consuming them keeps menu equivalents quiet.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event) || super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        model?.flagsChanged(modifiers: event.modifierFlags.rawValue)
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        // Clicking elsewhere abandons the recording rather than leaving a silent key trap armed.
        model?.cancelRecording()
        return super.resignFirstResponder()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model, model.isRecording else { return false }
        return model.handle(keyCode: Int(event.keyCode), modifiers: event.modifierFlags.rawValue)
    }
}
