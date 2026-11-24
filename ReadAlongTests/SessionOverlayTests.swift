import XCTest
@testable import ReadAlong

@MainActor
final class SessionOverlayTests: XCTestCase {
    /// The window may sit on a secondary screen whose AppKit origin is not
    /// zero. Highlight rectangles are already converted into that screen's
    /// view space, so they must not have the screen origin applied again.
    func testHighlightRectStaysOnTheTargetWindowsScreen() {
        let view = OverlayView()
        view.screenFrame = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        view.targetFrame = CGRect(x: -2093, y: 76, width: 1634, height: 1282)
        let local = view.targetFrame.offsetBy(
            dx: -view.screenFrame.minX,
            dy: -view.screenFrame.minY
        )

        let placed = view.place(
            CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.02),
            in: local
        )

        XCTAssertEqual(placed.minX, 467 + 0.5 * 1634, accuracy: 0.001)
        XCTAssertEqual(placed.minY, 76 + 0.5 * 1282, accuracy: 0.001)
        XCTAssertTrue(local.contains(placed))
    }
}
