import AppKit
import PDFKit

/// A tracker sentence anchored to one PDF page, with its range inside that
/// page's extracted string (used to ask PDFKit for exact line rectangles).
struct PDFSentence: Equatable {
    let sentence: Sentence
    let page: Int
    let localRange: NSRange
}

/// Pure turn of per-page PDF text into trackable sentences. Testable without
/// a document: pages join with a paragraph break so NLTokenizer splits
/// cleanly between them and no sentence spans pages.
enum PDFSurfaceBuilder {
    static func build(pages: [String?]) -> [PDFSentence] {
        var text = ""
        var offsets: [(page: Int, offset: Int, length: Int)] = []
        for (index, pageText) in pages.enumerated() {
            let page = pageText ?? ""
            if !text.isEmpty { text += "\n\n" }
            let offset = (text as NSString).length
            text += page
            offsets.append((index, offset, (page as NSString).length))
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let nsText = text as NSString
        return SentenceIndex.sentences(in: text).compactMap { sentence in
            // The last page whose offset precedes the sentence wins, so a
            // sentence beginning in the joiner still lands on its own page.
            guard let owner = offsets.last(where: { $0.offset <= sentence.range.location }) else {
                return nil
            }
            let location = sentence.range.location - owner.offset
            let length = min(sentence.range.length, owner.length - location)
            guard location >= 0, length > 0 else { return nil }
            return PDFSentence(
                sentence: sentence,
                page: owner.page,
                localRange: NSRange(location: location, length: length)
            )
        }
    }
}

/// Draws the two-stage highlight over a PDFView. It lives as a document-glued
/// subview of the PDFView, so line rectangles in the PDFView's own space draw
/// at the same coordinates with no conversion and stay put while scrolling.
final class PDFHighlightView: NSView {
    var currentRects: [CGRect] = [] {
        didSet { needsDisplay = true }
    }
    var nextRects: [CGRect] = [] {
        didSet { needsDisplay = true }
    }

    /// Match the PDFView's orientation so line rectangles (given in the
    /// PDFView's own space) draw at identical coordinates.
    override var isFlipped: Bool { superview?.isFlipped ?? true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for rect in nextRects {
            fill(rect, color: ReaderTheme.nextFill)
        }
        for rect in currentRects {
            fill(rect, color: ReaderTheme.readingFill)
            outline(rect, color: ReaderTheme.readingStroke)
        }
    }

    private func fill(_ rect: CGRect, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3).fill()
    }

    private func outline(_ rect: CGRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
        path.lineWidth = 1
        path.stroke()
    }
}
