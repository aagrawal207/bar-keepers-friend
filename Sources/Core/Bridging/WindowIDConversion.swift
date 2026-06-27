import CoreGraphics
import Foundation

/// Safe conversion from an AppKit `NSWindow.windowNumber` (an `Int`) to a `CGWindowID`
/// (a `UInt32`).
///
/// `windowNumber` can be `0`, negative, or an out-of-range sentinel before a window is
/// realized. Force-converting such a value to `CGWindowID` traps with "Not enough bits to
/// represent the passed value", which crashed the app when control-item window ids were
/// read too early. This returns `nil` for any value that doesn't fit instead of trapping.
public enum WindowIDConversion {
    public static func cgWindowID(fromWindowNumber number: Int) -> CGWindowID? {
        guard number > 0 else { return nil }
        return CGWindowID(exactly: number)
    }
}
