import AppKit
import CoreGraphics

struct WindowInfo: Identifiable, Equatable {
    let windowID: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    /// Frame in AppKit global coordinates.
    let frame: CGRect

    var id: CGWindowID { windowID }

    /// Ordinary, visible windows of other apps, ordered front to back.
    static func onScreenWindows() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return windows(
            from: raw,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            primaryHeight: ScreenCoordinates.primaryHeight
        )
    }

    /// Pure filtering and parsing, kept separate from the window-server query so
    /// it can be tested deterministically.
    static func windows(
        from raw: [[String: Any]],
        ownPID: pid_t,
        primaryHeight: CGFloat
    ) -> [WindowInfo] {
        raw.compactMap { parse($0, ownPID: ownPID, primaryHeight: primaryHeight) }
    }

    static func parse(
        _ dict: [String: Any],
        ownPID: pid_t,
        primaryHeight: CGFloat
    ) -> WindowInfo? {
        guard let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer == 0 else { return nil }
        guard let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              pid != ownPID else { return nil }
        guard let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
              alpha > 0.01 else { return nil }
        guard let number = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
              let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              cgRect.width >= 40,
              cgRect.height >= 40 else { return nil }

        return WindowInfo(
            windowID: number,
            ownerName: dict[kCGWindowOwnerName as String] as? String ?? "Window",
            ownerPID: pid,
            frame: ScreenCoordinates.appKitRect(fromCG: cgRect, primaryHeight: primaryHeight)
        )
    }

    static func current(windowID: CGWindowID) -> WindowInfo? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[String: Any]],
        let dict = raw.first,
        let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
        let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }

        return WindowInfo(
            windowID: windowID,
            ownerName: dict[kCGWindowOwnerName as String] as? String ?? "Window",
            ownerPID: (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
            frame: ScreenCoordinates.appKitRect(fromCG: cgRect)
        )
    }
}
