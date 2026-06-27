import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct WindowIDConversionTests {

    @Test func validPositiveNumberConverts() {
        #expect(WindowIDConversion.cgWindowID(fromWindowNumber: 12345) == CGWindowID(12345))
    }

    @Test func zeroIsRejected() {
        #expect(WindowIDConversion.cgWindowID(fromWindowNumber: 0) == nil)
    }

    @Test func negativeIsRejected() {
        // A negative windowNumber must not trap, just return nil.
        #expect(WindowIDConversion.cgWindowID(fromWindowNumber: -1) == nil)
    }

    @Test func valueTooLargeForUInt32IsRejectedNotTrapped() {
        // This is the exact crash: forcing a value past UInt32.max into CGWindowID traps
        // with "Not enough bits to represent the passed value". It must return nil instead.
        let tooBig = Int(UInt32.max) + 1
        #expect(WindowIDConversion.cgWindowID(fromWindowNumber: tooBig) == nil)
    }

    @Test func maxUInt32Converts() {
        #expect(WindowIDConversion.cgWindowID(fromWindowNumber: Int(UInt32.max)) == CGWindowID(UInt32.max))
    }
}
