import CoreGraphics
import Testing

@Suite struct NativeMoveEventTests {
    @Test func grabAndDropUseDifferentWindowsButTheSameOwningProcess() throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        let destination = CGPoint(x: 1032, y: 16.5)
        let events = try #require(SystemWindowServer().moveEvents(
            source: source, windowID: 75, pid: 1811, targetWindowID: 90, destination: destination
        ))
        #expect(events.down.type == .leftMouseDown)
        #expect(events.up.type == .leftMouseUp)
        #expect(events.down.flags == .maskCommand)
        #expect(events.up.flags.isEmpty)
        #expect(events.up.location == destination)
        #expect(events.down.location == CGPoint(x: 20_000, y: 20_000))
        let privateWindowField = try #require(CGEventField(rawValue: 0x33))
        for field in [CGEventField.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, privateWindowField] {
            #expect(events.down.getIntegerValueField(field) == 75)
            #expect(events.up.getIntegerValueField(field) == 90)
        }
        #expect(events.down.getIntegerValueField(.eventTargetUnixProcessID) == 1811)
        #expect(events.up.getIntegerValueField(.eventTargetUnixProcessID) == 1811)
    }
}
