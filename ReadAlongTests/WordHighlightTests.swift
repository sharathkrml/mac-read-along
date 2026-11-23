import XCTest
@testable import ReadAlong

final class WordWindowTests: XCTestCase {
    func testStartsAtTheFirstGroup() {
        let window = WordWindow.around(wordCursor: nil, wordCount: 10)
        XCTAssertEqual(window?.current, 0..<3)
        XCTAssertEqual(window?.next, 3..<6)
        XCTAssertEqual(window?.word, 0)
    }

    func testAnchorSelectsItsOwnGroup() {
        let window = WordWindow.around(wordCursor: 4, wordCount: 10)
        XCTAssertEqual(window?.current, 3..<6)
        XCTAssertEqual(window?.next, 6..<9)
        XCTAssertEqual(window?.word, 4)
    }

    func testLastPartialGroupHasNoNext() {
        let window = WordWindow.around(wordCursor: 9, wordCount: 10)
        XCTAssertEqual(window?.current, 9..<10)
        XCTAssertEqual(window?.next, 10..<10)
        XCTAssertEqual(window?.word, 9)
    }

    func testShortSentenceIsOneGroup() {
        let window = WordWindow.around(wordCursor: 1, wordCount: 2)
        XCTAssertEqual(window?.current, 0..<2)
        XCTAssertEqual(window?.next, 2..<2)
        XCTAssertEqual(window?.word, 1)
    }

    func testEmptySentenceHasNoWindow() {
        XCTAssertNil(WordWindow.around(wordCursor: 0, wordCount: 0))
    }

    func testAnchorClampsToTheSentence() {
        let window = WordWindow.around(wordCursor: 7, wordCount: 5)
        XCTAssertEqual(window?.word, 4)
        XCTAssertEqual(window?.current, 3..<5)
    }
}

final class HighlightBandsTests: XCTestCase {
    private func word(x: CGFloat, y: CGFloat, w: CGFloat = 0.05, h: CGFloat = 0.02) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    func testWordsOnOneLineMergeIntoOneBand() {
        let bands = HighlightBands.merge([
            word(x: 0.1, y: 0.5),
            word(x: 0.16, y: 0.5),
            word(x: 0.22, y: 0.5),
        ])

        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands[0].minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(bands[0].width, 0.17, accuracy: 0.0001)
    }

    func testWordsOnDifferentLinesStaySeparate() {
        let bands = HighlightBands.merge([
            word(x: 0.1, y: 0.5),
            word(x: 0.1, y: 0.46),
        ])

        XCTAssertEqual(bands.count, 2)
    }

    func testWideGapStaysSeparate() {
        let bands = HighlightBands.merge([
            word(x: 0.1, y: 0.5),
            word(x: 0.4, y: 0.5),
        ])

        XCTAssertEqual(bands.count, 2)
    }
}
