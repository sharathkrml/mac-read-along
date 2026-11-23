import XCTest
@testable import ReadAlong

final class SentenceIndexTests: XCTestCase {
    func testSplitsIntoSentences() {
        let sentences = SentenceIndex.sentences(in: "First sentence. Second one! Third?")
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences.map(\.text), ["First sentence.", "Second one!", "Third?"])
    }

    func testRangesStayInsideTheText() {
        let text = "One two three. Four five six."
        let sentences = SentenceIndex.sentences(in: text)
        let length = (text as NSString).length
        for sentence in sentences {
            XCTAssertGreaterThanOrEqual(sentence.range.location, 0)
            XCTAssertLessThanOrEqual(sentence.range.location + sentence.range.length, length)
        }
    }

    func testNormalizesWords() {
        XCTAssertEqual(
            SentenceIndex.words(in: "Hello, world's 42!"),
            ["hello", "worlds", "42"]
        )
    }

    func testEmptyTextHasNoSentences() {
        XCTAssertTrue(SentenceIndex.sentences(in: "").isEmpty)
    }
}
