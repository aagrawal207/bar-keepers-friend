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
        view.toolTip = "\(item.displayName): drag between icons to reorder, or to another bar. Then Apply Changes."
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
    func ownsDragToken(_ token: UUID) -> Bool { self.token == token }
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
        let pointer = convert(event.locationInWindow, from: nil)
        let frame = CGRect(x: pointer.x - iconSize / 2, y: pointer.y - iconSize / 2,
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
        if !model.isDraggingPlacementItem { view.clearInsertionIndicator() }
    }

    static func dismantleNSView(_ view: SettingsPlacementDropView, coordinator: ()) {
        view.onTargetedChange = { _ in }
        view.clearInsertionIndicator()
        view.unregisterDraggedTypes()
    }
}

// The registered container owns both the SwiftUI host and feedback, so glyphs share one drop ancestor.
@MainActor
final class SettingsPlacementDropView: NSView {
    private let hostingView: NSHostingView<AnyView>
    var rootView: AnyView {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }
    init(rootView: AnyView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        hostingView.frame = bounds
        super.layout()
    }

    weak var model: SettingsModel?
    var placement: ItemPlacement = .shown
    var onTargetedChange: (Bool) -> Void = { _ in }
    private(set) var isTargeted = false
    private(set) var insertionX: CGFloat?
    private let insertionIndicator = SettingsPlacementInsertionIndicator()

    func clearInsertionIndicator() {
        insertionX = nil
        insertionIndicator.removeFromSuperview()
    }

    private func setTargeted(_ value: Bool) {
        if !value { clearInsertionIndicator() }
        guard value != isTargeted else { return }
        isTargeted = value
        onTargetedChange(value)
    }

    private func token(from sender: NSDraggingInfo) -> UUID? {
        // Reject external drags before reading their pasteboard or invoking a promised-data provider.
        guard let model, let source = sender.draggingSource as? SettingsPlacementDragSourceView,
              source.model === model, let window, sender.draggingDestinationWindow === window,
              source.window === window, sender.draggingSourceOperationMask.contains(.move) else { return nil }
        guard let items = sender.draggingPasteboard.pasteboardItems, items.count == 1,
              let text = items[0].string(forType: SettingsPlacementDrag.pasteboardType),
              let token = UUID(uuidString: text), source.ownsDragToken(token),
              model.canDropPlacement(token, into: placement) else { return nil }
        return token
    }

    private var itemViews: [SettingsPlacementDragSourceView] {
        func descendants(_ view: NSView) -> [SettingsPlacementDragSourceView] {
            view.subviews.flatMap { child in
                if let source = child as? SettingsPlacementDragSourceView { return [source] }
                return descendants(child)
            }
        }
        return descendants(self).filter { $0.placement == placement && $0.item != nil }
            .sorted { convert($0.bounds, from: $0).midX < convert($1.bounds, from: $1).midX }
    }

    private func insertion(at point: CGPoint) -> (before: CGWindowID?, x: CGFloat) {
        let views = itemViews
        for view in views {
            let rect = convert(view.bounds, from: view)
            if point.x < rect.midX { return (view.item?.id, rect.minX) }
        }
        return (nil, views.last.map { convert($0.bounds, from: $0).maxX } ?? min(max(point.x, 8), bounds.maxX - 8))
    }

    private func scrollNearEdge(at point: CGPoint) {
        guard let scroll = itemViews.compactMap(\.enclosingScrollView).first,
              let document = scroll.documentView else { return }
        let viewport = scroll.contentView
        let frame = convert(viewport.bounds, from: viewport)
        guard frame.contains(point), document.bounds.width > viewport.bounds.width else { return }
        let delta: CGFloat = point.x < frame.minX + 24 ? -8 : (point.x > frame.maxX - 24 ? 8 : 0)
        guard delta != 0 else { return }
        var origin = viewport.bounds.origin
        origin.x = min(max(origin.x + delta, document.bounds.minX), document.bounds.maxX - viewport.bounds.width)
        viewport.scroll(to: origin)
        scroll.reflectScrolledClipView(viewport)
        layoutSubtreeIfNeeded()
    }

    private func updateDestination(_ sender: NSDraggingInfo, scrolling: Bool) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard token(from: sender) != nil, bounds.contains(point) else {
            setTargeted(false)
            sender.numberOfValidItemsForDrop = 0
            return []
        }
        if scrolling { scrollNearEdge(at: point) }
        let position = insertion(at: point)
        let x = min(max(position.x, bounds.minX + 2), bounds.maxX - 2)
        insertionX = x
        insertionIndicator.frame = CGRect(x: x - 1.5, y: bounds.midY - 12, width: 3, height: 24)
        if insertionIndicator.superview == nil { addSubview(insertionIndicator, positioned: .above, relativeTo: nil) }
        insertionIndicator.needsDisplay = true
        sender.numberOfValidItemsForDrop = 1
        setTargeted(true)
        return .move
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDestination(sender, scrolling: false)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDestination(sender, scrolling: true)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        token(from: sender) != nil && bounds.contains(convert(sender.draggingLocation, from: nil))
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setTargeted(false) }
        let point = convert(sender.draggingLocation, from: nil)
        guard let token = token(from: sender), bounds.contains(point) else { return false }
        return model?.dropPlacement(token, into: placement, before: insertion(at: point).before) == true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }
}

@MainActor
private final class SettingsPlacementInsertionIndicator: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
