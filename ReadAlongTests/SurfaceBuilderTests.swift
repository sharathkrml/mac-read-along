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
            line("the lazy dog.", x: 0.1, y: 0.88),
        ])

        XCTAssertEqual(surface.sentences.count, 1)
        XCTAssertEqual(surface.rects[0].count, 2)
    }

    /// UI text carries no sentence punctuation. Short rows that are not a
    /// wrapped paragraph must stay separate; otherwise the poll, the counts
    /// and the next post all become one "sentence".
    func testShortUiRowsDoNotBecomeOneGiantSentence() {
        let surface = SurfaceBuilder.build(lines: [
            line("where does most of your internet money actually come from?", x: 0.30, y: 0.70, w: 0.55),
            line("A) your own product", x: 0.30, y: 0.68, w: 0.20),
            line("B) sponsors", x: 0.30, y: 0.66, w: 0.11),
            line("C) x payouts", x: 0.30, y: 0.64, w: 0.12),
            line("D) a job, let's be real", x: 0.30, y: 0.62, w: 0.19),
        ])

        XCTAssertEqual(surface.sentences.map(\.text), [
            "where does most of your internet money actually come from?",
            "A) your own product",
            "B) sponsors",
            "C) x payouts",
            "D) a job, let's be real",
        ])
        XCTAssertEqual(surface.rects.map(\.count), [1, 1, 1, 1, 1])
    }

    /// Even when a wide OCR line bridges columns into one block, a sentence
    /// must not jump from one column to another.
    func testBridgedColumnsDoNotShareASentence() {
        let surface = SurfaceBuilder.build(lines: [
            line("A wide banner heading spanning the window", x: 0.05, y: 0.95, w: 0.92),
            line("left column text without a period", x: 0.05, y: 0.85, w: 0.85),
            line("right", x: 0.95, y: 0.83, w: 0.04),
        ])

        XCTAssertEqual(surface.sentences.count, 3)
        XCTAssertEqual(surface.rects.map(\.count), [1, 1, 1])
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

    /// T3-style window: sidebar, conversation, and terminal share rows. A
    /// sentence in the middle column must still be trackable.
    func testMultiColumnWindowStillTracksTheMiddleColumn() {
        let surface = SurfaceBuilder.build(lines: [
            line("Set up skill integration", x: 0.026, y: 0.830, w: 0.094),
            line("Build + all 58 tests pass.", x: 0.212, y: 0.891, w: 0.102),
            line("Now the onboarding and the start section everything works clearly.", x: 0.297, y: 0.516, w: 0.279),
            line("Whatever I say, I can see it on the screen, but the highlighting is not", x: 0.297, y: 0.493, w: 0.283),
            line("working. Can you try to highlight something on T3 code?", x: 0.297, y: 0.470, w: 0.282),
            line("RegisterExecutionPolicyException /Users/sharath/Documents", x: 0.641, y: 0.905, w: 0.340),
            line("c-read-along/build/Build/Products/Debug/ReadAlong.app", x: 0.641, y: 0.886, w: 0.340),
        ])

        let matched = surface.sentences.first {
            $0.text.contains("Now the onboarding and the start section")
        }
        XCTAssertNotNil(matched)
        XCTAssertFalse(
            surface.sentences.contains {
                $0.text.contains("Set up skill integration") && $0.text.contains("Now the onboarding")
            },
            "sidebar text must not merge into the conversation sentence"
        )

        if let index = surface.sentences.firstIndex(where: { $0.text == matched?.text }) {
            let rects = surface.rects[index]
            XCTAssertEqual(rects.count, 1)
            XCTAssertEqual(rects.first?.minX ?? -1, 0.297, accuracy: 0.001)
        }

        let tracker = ReadingTracker()
        tracker.load(sentences: surface.sentences)
        tracker.handle(TranscriptUpdate(
            text: "Now the onboarding and the start section everything works clearly.",
            isFinal: true
        ))
        XCTAssertEqual(
            tracker.currentSentence?.text,
            "Now the onboarding and the start section everything works clearly."
        )
    }
}

final class SurfaceToneTests: XCTestCase {
    func testBrightPageIsLightAndDarkPageIsDark() {
        XCTAssertEqual(SurfaceTone.classify([UInt8](repeating: 240, count: 64)), .light)
        XCTAssertEqual(SurfaceTone.classify([UInt8](repeating: 30, count: 64)), .dark)
    }

    func testAverageDecidesMixedPages() {
        // Mostly white with a little black text still reads as light paper.
        var page = [UInt8](repeating: 235, count: 100)
        page.replaceSubrange(0..<20, with: [UInt8](repeating: 40, count: 20))
        XCTAssertEqual(SurfaceTone.classify(page), .light)
    }

    func testMissingThumbnailFallsBackToDark() {
        XCTAssertEqual(SurfaceTone.classify([]), .dark)
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

    /// A still window must not run OCR again; a moved one (or a forced read)
    /// must.
    func testRecognitionRunsOnlyForNewFramesOrForcedReads() {
        let frame = [UInt8](repeating: 120, count: 64 * 36)
        var moved = frame
        moved.replaceSubrange(300..<500, with: [UInt8](repeating: 20, count: 200))

        XCTAssertFalse(FrameDifference.needsRecognition(previous: frame, current: frame, force: false))
        XCTAssertTrue(FrameDifference.needsRecognition(previous: frame, current: moved, force: false))
        XCTAssertTrue(FrameDifference.needsRecognition(previous: nil, current: frame, force: false))
        XCTAssertTrue(FrameDifference.needsRecognition(previous: frame, current: frame, force: true))
    }
}
