import AppKit
import BarKeepersFriendCore
import SwiftUI

enum SettingsPlacementDrag {
    static let pasteboardType = NSPasteboard.PasteboardType("com.agraabhi.BarKeepersFriend.placement-item")
}

struct SettingsPlacementDragSource: NSViewRepresentable {
    let model: SettingsModel
    let item: FloatingBarItem
    let placement: ItemPlacement?
    let iconSize: CGFloat

    func makeNSView(context: Context) -> SettingsPlacementDragSourceView {
        let view = SettingsPlacementDragSourceView()
        view.setAccessibilityElement(false)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SettingsPlacementDragSourceView, context: Context) {
        view.model = model
        view.item = item
        view.placement = placement
        view.iconSize = iconSize
        view.toolTip = "\(item.displayName): drag to another bar, then Apply Changes."
        view.window?.invalidateCursorRects(for: view)
    }
}

@MainActor
final class SettingsPlacementDragSourceView: NSView, NSDraggingSource {
    weak var model: SettingsModel?
    var item: FloatingBarItem?
    var placement: ItemPlacement?
    var iconSize: CGFloat = 18
    private var mouseDownPoint: CGPoint?
    private var token: UUID?
    var startDragging: @MainActor (NSView, [NSDraggingItem], NSEvent, any NSDraggingSource) -> Void = { view, items, event, source in
        view.beginDraggingSession(with: items, event: event, source: source)
            .animatesToStartingPositionsOnCancelOrFail = true
    }

    var isDragEnabled: Bool {
        guard let item else { return false }
        return model?.canDragPlacement(of: item, from: placement) == true
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isDragEnabled ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if isDragEnabled { addCursorRect(visibleRect, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        finishDragging()
        mouseDownPoint = isDragEnabled ? event.locationInWindow : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard token == nil, let start = mouseDownPoint, let item,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4,
              let writer = preparePasteboardItem() else { return }
        let dragged = NSDraggingItem(pasteboardWriter: writer)
        let frame = CGRect(x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2,
                           width: iconSize, height: iconSize)
        dragged.setDraggingFrame(frame, contents: item.image)
        startDragging(self, [dragged], event, self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    // Only an opaque, one-drag token leaves the view; owner keys and aliases never enter the pasteboard.
    func preparePasteboardItem() -> NSPasteboardItem? {
        guard let item, let model, let token = model.beginPlacementDrag(of: item, from: placement) else { return nil }
        self.token = token
        let writer = NSPasteboardItem()
        writer.setString(token.uuidString, forType: SettingsPlacementDrag.pasteboardType)
        return writer
    }

    func finishDragging() {
        if let token { model?.endPlacementDrag(token) }
        token = nil
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDragging()
    }
}

struct SettingsPlacementDropArea<Content: View>: NSViewRepresentable {
    let model: SettingsModel
    let placement: ItemPlacement
    let height: CGFloat
    @Binding var isTargeted: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> SettingsPlacementDropView {
        let view = SettingsPlacementDropView(rootView: hostedContent(context))
        view.registerForDraggedTypes([SettingsPlacementDrag.pasteboardType])
        configure(view)
        return view
    }

    func updateNSView(_ view: SettingsPlacementDropView, context: Context) {
        configure(view)
        view.rootView = hostedContent(context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsPlacementDropView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: height)
    }

    private func hostedContent(_ context: Context) -> AnyView {
        AnyView(content()
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.accessibilityEnabled, context.environment.accessibilityEnabled)
            .frame(maxWidth: .infinity)
            .frame(height: height))
    }

    private func configure(_ view: SettingsPlacementDropView) {
        view.model = model
        view.placement = placement
        view.onTargetedChange = { isTargeted = $0 }
    }

    static func dismantleNSView(_ view: SettingsPlacementDropView, coordinator: ()) {
        view.onTargetedChange = { _ in }
        view.unregisterDraggedTypes()
    }
}

// Register the containing host, not a background sibling: drops over glyphs must reach this ancestor.
@MainActor
final class SettingsPlacementDropView: NSHostingView<AnyView> {
    weak var model: SettingsModel?
    var placement: ItemPlacement = .shown
    var onTargetedChange: (Bool) -> Void = { _ in }
    private(set) var isTargeted = false

    private func setTargeted(_ value: Bool) {
        guard value != isTargeted else { return }
        isTargeted = value
        onTargetedChange(value)
    }

    private func token(from sender: NSDraggingInfo) -> UUID? {
        // Reject external drags before reading their pasteboard or invoking a promised-data provider.
        guard let model, let source = sender.draggingSource as? SettingsPlacementDragSourceView,
              source.model === model, sender.draggingSourceOperationMask.contains(.move) else { return nil }
        guard let items = sender.draggingPasteboard.pasteboardItems, items.count == 1,
              let text = items[0].string(forType: SettingsPlacementDrag.pasteboardType),
              let token = UUID(uuidString: text), model.canDropPlacement(token, into: placement) else { return nil }
        return token
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = token(from: sender) != nil
        setTargeted(valid)
        return valid ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        token(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setTargeted(false) }
        guard let token = token(from: sender) else { return false }
        return model?.dropPlacement(token, into: placement) == true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }
}
