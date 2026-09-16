import AppKit
import Testing

// Only AppKit's transport is scripted; the source, pasteboard payload, and destination handlers are real.
@MainActor
final class SettingsPlacementTestDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard = NSPasteboard.withUniqueName()
    private(set) var pasteboardReads = 0
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    var draggingPasteboard: NSPasteboard {
        pasteboardReads += 1
        return pasteboard
    }

    init(
        source: Any?, items: [NSPasteboardItem], destination: SettingsPlacementDropView,
        operation: NSDragOperation = .move, locationInWindow: NSPoint? = nil
    ) {
        draggingSource = source
        draggingDestinationWindow = destination.window
        draggingSourceOperationMask = operation
        draggingLocation = locationInWindow ?? destination.convert(
            CGPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil
        )
        super.init()
        if !items.isEmpty { #expect(pasteboard.writeObjects(items)) }
    }

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    nonisolated var draggedImage: NSImage? { nil }

    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        Issue.record("Placement drops must not request promised files.")
        return nil
    }

    func slideDraggedImage(to screenPoint: NSPoint) {
        Issue.record("Scripted placement transport must not animate a native drag image.")
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        Issue.record("Placement drops must read their local token without enumerating native drag images.")
    }

    func resetSpringLoading() {
        Issue.record("Placement drops must not invoke native spring loading.")
    }
}

@MainActor
func settingsPlacementTestPasteboardItem(
    _ text: String, type: NSPasteboard.PasteboardType = SettingsPlacementDrag.pasteboardType
) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    #expect(item.setString(text, forType: type))
    return item
}

// Constructed events go directly to the mounted source's handlers, never through the process event queue.
@MainActor
func settingsPlacementTestMouseEvent(
    _ type: NSEvent.EventType, at location: NSPoint, window: NSWindow, number: Int
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [], timestamp: TimeInterval(number) / 100,
        windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
    ))
}
