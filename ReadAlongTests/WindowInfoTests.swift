import XCTest
@testable import ReadAlong
import CoreGraphics

final class WindowInfoTests: XCTestCase {
    private let ownPID: pid_t = 999
    private let otherPID: pid_t = 4242

    func testParsesAnOrdinaryWindowAndConvertsItsFrame() throws {
        let window = try XCTUnwrap(WindowInfo.parse(
            dict(number: 7, rect: CGRect(x: 100, y: 50, width: 800, height: 600)),
            ownPID: ownPID,
            primaryHeight: 1000
        ))

        XCTAssertEqual(window.windowID, 7)
        XCTAssertEqual(window.ownerName, "Safari")
        XCTAssertEqual(window.frame, CGRect(x: 100, y: 350, width: 800, height: 600))
    }

    func testKeepsFrontToBackOrder() {
        let windows = WindowInfo.windows(
            from: [
                dict(number: 1, rect: CGRect(x: 0, y: 0, width: 400, height: 400)),
                dict(number: 2, rect: CGRect(x: 10, y: 10, width: 400, height: 400)),
                dict(number: 3, rect: CGRect(x: 20, y: 20, width: 400, height: 400)),
            ],
            ownPID: ownPID,
            primaryHeight: 1000
        )

        XCTAssertEqual(windows.map(\.windowID), [1, 2, 3])
    }

    func testRejectsWindowsAboveTheNormalLayer() {
        let window = WindowInfo.parse(
            dict(number: 7, layer: 25),
            ownPID: ownPID,
            primaryHeight: 1000
        )
        XCTAssertNil(window)
    }

    func testRejectsOurOwnWindows() {
        let window = WindowInfo.parse(
            dict(number: 7, pid: ownPID),
            ownPID: ownPID,
            primaryHeight: 1000
        )
        XCTAssertNil(window)
    }

    func testRejectsInvisibleWindows() {
        let window = WindowInfo.parse(
            dict(number: 7, alpha: 0),
            ownPID: ownPID,
            primaryHeight: 1000
        )
        XCTAssertNil(window)
    }

    func testRejectsTooSmallWindows() {
        let window = WindowInfo.parse(
            dict(number: 7, rect: CGRect(x: 0, y: 0, width: 39, height: 400)),
            ownPID: ownPID,
            primaryHeight: 1000
        )
        XCTAssertNil(window)
    }

    func testRejectsWindowsWithoutABoundsDictionary() {
        var raw = dict(number: 7)
        raw.removeValue(forKey: kCGWindowBounds as String)
        let window = WindowInfo.parse(raw, ownPID: ownPID, primaryHeight: 1000)
        XCTAssertNil(window)
    }

    func testRejectsWindowsWithoutANumber() {
        let window = WindowInfo.parse(
            dict(number: nil),
            ownPID: ownPID,
            primaryHeight: 1000
        )
        XCTAssertNil(window)
    }

    // MARK: - Helpers

    private func dict(
        number: Int?,
        layer: Int = 0,
        pid: pid_t? = nil,
        alpha: Double = 1,
        rect: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowOwnerPID as String: NSNumber(value: pid ?? otherPID),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowOwnerName as String: "Safari",
            kCGWindowBounds as String: [
                "X": rect.origin.x,
                "Y": rect.origin.y,
                "Width": rect.width,
                "Height": rect.height,
            ] as [String: Any],
        ]
        if let number {
            dict[kCGWindowNumber as String] = NSNumber(value: number)
        }
        return dict
    }
}
