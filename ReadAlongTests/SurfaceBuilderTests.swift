import XCTest
@testable import ReadAlong

@MainActor
final class SurfaceBuilderTests: XCTestCase {
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.8, h: CGFloat = 0.02) -> OCRLine {
        OCRLine(text: text, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    func testBuildsSentencesWithTheirLineRects() {
        let surface = SurfaceBuilder.build(lines: [
            line("The quick brown fox.", x: 0.1, y: 0.90),
            line("Jumps over the lazy dog.", x: 0.1, y: 0.80),
        ])

        XCTAssertEqual(surface.sentences.count, 2)
        XCTAssertEqual(surface.sentences[0].text, "The quick brown fox.")
        XCTAssertEqual(surface.rects[0].count, 1)
        XCTAssertEqual(surface.rects[0][0].minY, 0.90, accuracy: 0.0001)
        XCTAssertEqual(surface.rects[1][0].minY, 0.80, accuracy: 0.0001)
    }

    func testSentenceSpanningTwoLinesGetsBothRects() {
        let surface = SurfaceBuilder.build(lines: [
            line("The quick brown fox jumps over", x: 0.1, y: 0.90),
            line("the lazy dog.", x: 0.1, y: 0.80),
        ])

        XCTAssertEqual(surface.sentences.count, 1)
        XCTAssertEqual(surface.rects[0].count, 2)
    }

    func testTwoSentencesOnOneLineShareItsRect() {
        let surface = SurfaceBuilder.build(lines: [
            line("One sentence. Two sentences.", x: 0.1, y: 0.90),
        ])

        XCTAssertEqual(surface.sentences.count, 2)
        XCTAssertEqual(surface.rects[0].count, 1)
        XCTAssertEqual(surface.rects[1].count, 1)
        XCTAssertEqual(surface.rects[0], surface.rects[1])
    }

    func testUnorderedLinesAreReadTopToBottomLeftToRight() {
        let surface = SurfaceBuilder.build(lines: [
            line("Second line.", x: 0.1, y: 0.50),
            line("Right column of top row.", x: 0.55, y: 0.91),
            line("Left column of top row.", x: 0.05, y: 0.90),
            line("First line above.", x: 0.1, y: 0.95),
        ])

        XCTAssertEqual(
            surface.sentences.map(\.text),
            [
                "First line above.",
                "Left column of top row.",
                "Right column of top row.",
                "Second line.",
            ]
        )
    }

    func testEmptyInputGivesEmptySurface() {
        XCTAssertTrue(SurfaceBuilder.build(lines: []).sentences.isEmpty)
        XCTAssertTrue(
            SurfaceBuilder.build(lines: [line("   ", x: 0, y: 0)]).sentences.isEmpty
        )
    }
}

final class FrameDifferenceTests: XCTestCase {
    func testIdenticalFramesScoreNearZero() {
        let frame = [UInt8](repeating: 120, count: 64 * 36)
        XCTAssertLessThan(FrameDifference.score(frame, frame), 0.5)
    }

    func testShiftedContentScoresAboveTheChangeThreshold() {
        var still = [UInt8](repeating: 10, count: 64 * 36)
        still.replaceSubrange(300..<500, with: [UInt8](repeating: 240, count: 200))
        var scrolled = [UInt8](repeating: 10, count: 64 * 36)
        scrolled.replaceSubrange(400..<600, with: [UInt8](repeating: 240, count: 200))

        XCTAssertTrue(FrameDifference.isMeaningfulChange(FrameDifference.score(still, scrolled)))
    }

    func testMismatchedFramesAreAlwaysAChange() {
        XCTAssertTrue(FrameDifference.isMeaningfulChange(FrameDifference.score([], [0])))
    }
}
