import AppKit
import CoreGraphics

/// Translates Core Graphics global coordinates (origin top-left of the main
/// display, y down) into AppKit global coordinates (origin bottom-left, y up).
enum ScreenCoordinates {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
    }

    static func appKitRect(fromCG rect: CGRect) -> CGRect {
        appKitRect(fromCG: rect, primaryHeight: primaryHeight)
    }

    static func appKitRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
