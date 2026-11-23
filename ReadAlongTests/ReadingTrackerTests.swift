import XCTest
@testable import ReadAlong

@MainActor
final class ReadingTrackerTests: XCTestCase {
    private func makeTracker(_ texts: [String]) -> ReadingTracker {
        let tracker = ReadingTracker()
        tracker.load(sentences: texts.enumerated().map { index, text in
            Sentence(
                text: text,
                range: NSRange(location: index * 100, length: text.count),
                words: SentenceIndex.words(in: text)
            )
        })
        return tracker
    }

    private func say(_ tracker: ReadingTracker, _ text: String, final: Bool = false) {
        tracker.handle(TranscriptUpdate(text: text, isFinal: final))
    }

    private let fiveSentences = [
        "Alpha beta gamma delta",
        "Epsilon zeta eta theta",
        "Iota kappa lambda mu",
        "Nu xi omicron pi",
        "Rho sigma tau upsilon",
    ]

    func testLocatesFromFirstThreeWordMatch() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "iota kappa lambda")
        XCTAssertEqual(tracker.cursor, 2)
    }

    func testSingleWordDoesNotMove() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "iota kappa lambda")
        say(tracker, "rho")
        XCTAssertEqual(tracker.cursor, 2)
    }

    func testTwoWordsFromTheNextSentenceDoNotMove() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "iota kappa lambda")
        say(tracker, "nu xi")
        XCTAssertEqual(tracker.cursor, 2)
    }

    func testThreeWordsFromTheNextSentenceMove() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "iota kappa lambda")
        say(tracker, "nu xi omicron")
        XCTAssertEqual(tracker.cursor, 3)
    }

    func testFinishingTheCurrentSentenceAdvances() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "iota kappa lambda")
        say(tracker, "iota kappa lambda mu")
        XCTAssertEqual(tracker.cursor, 3)
    }

    func testThreeWordPhraseFromALaterSentenceRelocates() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "alpha beta gamma")
        say(tracker, "rho sigma tau")
        XCTAssertEqual(tracker.cursor, 4)
    }

    func testThreeWordPhraseFromAnEarlierSentenceRelocates() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "rho sigma tau")
        say(tracker, "alpha beta gamma")
        XCTAssertEqual(tracker.cursor, 0)
    }

    func testNearestMatchWins() {
        let tracker = makeTracker([
            "One two three four",
            "Five six seven eight",
            "Nine ten eleven twelve",
            "One two three zero",
        ])
        say(tracker, "five six seven")
        say(tracker, "one two three")
        XCTAssertEqual(tracker.cursor, 0)
    }

    func testShortSentenceNeedsItsFullText() {
        let tracker = makeTracker([
            "Read this first",
            "Yes please",
            "Another line follows",
        ])
        say(tracker, "read this first")
        say(tracker, "yes")
        XCTAssertEqual(tracker.cursor, 0)

        say(tracker, "yes please")
        XCTAssertEqual(tracker.cursor, 1)
    }

    func testToleratesOneCharacterMistake() {
        let tracker = makeTracker([
            "The quick brown fox jumps",
            "Over the lazy dog today",
        ])
        say(tracker, "the quik brown")
        XCTAssertEqual(tracker.cursor, 0)
    }

    func testNoMatchHoldsPosition() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "epsilon zeta eta")
        say(tracker, "completely unrelated phrase")
        XCTAssertEqual(tracker.cursor, 1)
    }

    func testFinalSpeechIsCommitted() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "iota kappa lambda", final: true)
        XCTAssertEqual(tracker.cursor, 2)
        say(tracker, "mu", final: false)
        XCTAssertEqual(tracker.cursor, 3)
    }

    // MARK: - Re-capture (reload)

    private func makeSentences(_ texts: [String]) -> [Sentence] {
        texts.enumerated().map { index, text in
            Sentence(
                text: text,
                range: NSRange(location: index * 100, length: text.count),
                words: SentenceIndex.words(in: text)
            )
        }
    }

    func testReloadKeepsCursorWhenCurrentSentenceSurvives() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "iota kappa lambda")

        // Same text re-captured with different ranges.
        tracker.reload(makeSentences([
            "Alpha beta gamma delta",
            "Epsilon zeta eta theta",
            "Iota kappa lambda mu",
            "Nu xi omicron pi",
            "Rho sigma tau upsilon",
        ]))
        XCTAssertEqual(tracker.cursor, 2)

        say(tracker, "nu xi omicron")
        XCTAssertEqual(tracker.cursor, 3)
    }

    func testReloadDropsCursorWhenCurrentSentenceDisappears() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "iota kappa lambda")

        tracker.reload(makeSentences([
            "Alpha beta gamma delta",
            "Epsilon zeta eta theta",
            "Nu xi omicron pi",
            "Rho sigma tau upsilon",
        ]))
        XCTAssertNil(tracker.cursor)

        // No guessing: unrelated speech does not move the highlight.
        say(tracker, "unrelated words here")
        XCTAssertNil(tracker.cursor)

        // Three words relocate onto the visible text again.
        say(tracker, "rho sigma tau")
        XCTAssertEqual(tracker.cursor, 3)
    }

    // MARK: - Word marker (display only)

    func testWordMarkerFollowsTheVoiceInsideTheSentence() {
        let tracker = makeTracker(["Alpha beta gamma delta epsilon zeta eta theta"])

        say(tracker, "alpha beta gamma")
        XCTAssertEqual(tracker.cursor, 0)
        XCTAssertEqual(tracker.wordCursor, 2)

        say(tracker, "alpha beta gamma delta epsilon")
        XCTAssertEqual(tracker.cursor, 0)
        XCTAssertEqual(tracker.wordCursor, 4)
    }

    /// The marker may move on a single word; the sentence cursor must not.
    func testSingleWordMovesTheMarkerButNotTheCursor() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "alpha beta gamma")
        say(tracker, "delta")

        XCTAssertEqual(tracker.cursor, 0)
        XCTAssertEqual(tracker.wordCursor, 3)
    }

    func testWordMarkerResetsWhenTheSentenceAdvances() {
        let tracker = makeTracker(["Alpha beta gamma delta", "Epsilon zeta eta theta"])
        say(tracker, "alpha beta gamma")
        say(tracker, "alpha beta gamma delta")

        XCTAssertEqual(tracker.cursor, 1)
        XCTAssertNil(tracker.wordCursor)

        say(tracker, "epsilon zeta")
        XCTAssertEqual(tracker.wordCursor, 1)
    }

    func testRelocationPlacesTheMarkerOnTheMatchedWords() {
        let tracker = makeTracker([
            "Alpha beta gamma delta",
            "Epsilon zeta eta theta mu",
        ])
        say(tracker, "alpha beta gamma")
        say(tracker, "zeta eta theta")

        XCTAssertEqual(tracker.cursor, 1)
        XCTAssertEqual(tracker.wordCursor, 3)
    }

    /// A lone repeated word ("and") should sit at the next occurrence, not
    /// spring back to the one already read.
    func testRepeatedWordsPreferForwardProgress() {
        let tracker = makeTracker(["Alpha beta gamma and delta and epsilon"])
        say(tracker, "alpha beta gamma and delta")
        XCTAssertEqual(tracker.wordCursor, 4)

        say(tracker, "and")
        XCTAssertEqual(tracker.wordCursor, 5)
    }

    func testManualMoveDropsTheOldWordMarker() {
        let tracker = makeTracker(fiveSentences)
        say(tracker, "alpha beta gamma")
        XCTAssertEqual(tracker.wordCursor, 2)

        tracker.moveCursor(by: 1)
        XCTAssertNil(tracker.wordCursor)
    }

    func testReloadKeepsTheWordMarker() {
        let tracker = makeTracker(["Alpha beta gamma delta epsilon"])
        say(tracker, "alpha beta gamma delta epsilon")
        XCTAssertEqual(tracker.wordCursor, 4)

        tracker.reload(makeSentences(["Alpha beta gamma delta epsilon"]))
        XCTAssertEqual(tracker.cursor, 0)
        XCTAssertEqual(tracker.wordCursor, 4)
    }

    // MARK: - Manual movement

    func testMoveCursorStepsAndClamps() {
        let tracker = makeTracker(fiveSentences)
        tracker.moveCursor(by: 1)
        XCTAssertEqual(tracker.cursor, 0)
        tracker.moveCursor(by: 3)
        XCTAssertEqual(tracker.cursor, 3)
        tracker.moveCursor(by: -10)
        XCTAssertEqual(tracker.cursor, 0)
        tracker.moveCursor(by: 99)
        XCTAssertEqual(tracker.cursor, 4)
    }
}
