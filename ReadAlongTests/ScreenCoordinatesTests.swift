import XCTest
@testable import ReadAlong

final class ScreenCoordinatesTests: XCTestCase {
    func testConvertsTopLeftOriginToBottomLeft() {
        let converted = ScreenCoordinates.appKitRect(
            fromCG: CGRect(x: 10, y: 50, width: 800, height: 600),
            primaryHeight: 1000
        )
        XCTAssertEqual(converted, CGRect(x: 10, y: 350, width: 800, height: 600))
    }

    func testFullScreenRectIsUnchanged() {
        let converted = ScreenCoordinates.appKitRect(
            fromCG: CGRect(x: 0, y: 0, width: 1512, height: 982),
            primaryHeight: 982
        )
        XCTAssertEqual(converted, CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    func testPreservesHorizontalOffsetForDisplaysToTheRight() {
        let converted = ScreenCoordinates.appKitRect(
            fromCG: CGRect(x: 1920, y: 100, width: 400, height: 300),
            primaryHeight: 1080
        )
        XCTAssertEqual(converted, CGRect(x: 1920, y: 680, width: 400, height: 300))
    }

    func testHandlesNegativeOriginForDisplaysToTheLeft() {
        let converted = ScreenCoordinates.appKitRect(
            fromCG: CGRect(x: -1600, y: 0, width: 1600, height: 900),
            primaryHeight: 1080
        )
        XCTAssertEqual(converted, CGRect(x: -1600, y: 180, width: 1600, height: 900))
    }
}
