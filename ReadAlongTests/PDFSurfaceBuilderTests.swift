import XCTest
@testable import ReadAlong

@MainActor
final class PDFSurfaceBuilderTests: XCTestCase {
    private let pageOne = "The quick brown fox. Jumps over the lazy dog."
    private let pageTwo = "A second page begins here. It also ends."

    private var sentences: [PDFSentence] {
        PDFSurfaceBuilder.build(pages: [pageOne, pageTwo])
    }

    func testMapsSentencesToTheirPagesWithLocalRanges() {
        let result = sentences
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.map(\.page), [0, 0, 1, 1])

        let pageTexts = [pageOne, pageTwo]
        for sentence in result {
            let local = (pageTexts[sentence.page] as NSString)
                .substring(with: sentence.localRange)
            XCTAssertTrue(
                local.contains(sentence.sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                "local text '\(local)' must contain the sentence"
            )
        }
    }

    func testSentenceWordsTrackAcrossPages() {
        let result = sentences
        XCTAssertEqual(result[2].sentence.words, ["a", "second", "page", "begins", "here"])
    }

    func testBlankPagesKeepLaterPageIndicesCorrect() {
        let result = PDFSurfaceBuilder.build(pages: [nil, "", pageTwo])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.page == 2 })
    }

    func testImageOnlyPDFYieldsNoSentences() {
        XCTAssertTrue(PDFSurfaceBuilder.build(pages: [nil, nil]).isEmpty)
        XCTAssertTrue(PDFSurfaceBuilder.build(pages: ["", "  "]).isEmpty)
    }
}
