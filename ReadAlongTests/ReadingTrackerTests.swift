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
}
