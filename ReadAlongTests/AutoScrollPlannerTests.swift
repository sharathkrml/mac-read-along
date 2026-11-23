import XCTest
@testable import ReadAlong

final class AutoScrollPlannerTests: XCTestCase {
    private let viewport: CGFloat = 900

    func testHighSentenceDoesNotScroll() {
        XCTAssertNil(AutoScrollPlanner.scrollDownPixels(
            sentenceTop: 40, sentenceBottom: 120, viewportHeight: viewport
        ))
    }

    func testSentencePastLowerThirdScrollsToPutTopAThirdFromTop() {
        let pixels = AutoScrollPlanner.scrollDownPixels(
            sentenceTop: 700, sentenceBottom: 760, viewportHeight: viewport
        )
        XCTAssertEqual(pixels ?? 0, 700 - viewport / 3, accuracy: 1)
    }

    func testSentenceNearingButAboveTriggerDoesNotScroll() {
        XCTAssertNil(AutoScrollPlanner.scrollDownPixels(
            sentenceTop: 300, sentenceBottom: 590, viewportHeight: viewport
        ))
    }

    func testTriggerUsesTheSentenceBottomNotItsTop() {
        XCTAssertNotNil(AutoScrollPlanner.scrollDownPixels(
            sentenceTop: 400, sentenceBottom: 650, viewportHeight: viewport
        ))
    }

    func testHugeSentenceClampsAtZero() {
        let pixels = AutoScrollPlanner.scrollDownPixels(
            sentenceTop: 50, sentenceBottom: 850, viewportHeight: viewport
        )
        XCTAssertEqual(pixels ?? -1, 0)
    }

    func testZeroViewportNeverScrolls() {
        XCTAssertNil(AutoScrollPlanner.scrollDownPixels(
            sentenceTop: 10, sentenceBottom: 20, viewportHeight: 0
        ))
    }
}
