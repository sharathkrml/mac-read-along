import Foundation
import CoreGraphics

/// One recognized visual line of an external window, positioned in the
/// window's own space, normalized to 0…1 with the origin at the window's
/// bottom-left corner (Vision's bounding-box convention).
struct OCRLine: Equatable, Sendable {
    let text: String
    let rect: CGRect
}

/// A reading surface rebuilt from an OCR frame: tracker sentences plus, per
/// sentence, the visual line rectangles it spans (ADR-0001).
struct Surface: Equatable, Sendable {
    let sentences: [Sentence]
    /// rects[sentenceIndex] holds the normalized window-local rectangles of
    /// the lines that sentence spans.
    let rects: [[CGRect]]
}

/// Pure turn of OCR lines into a trackable surface, testable without a screen.
enum SurfaceBuilder {
    static func build(lines: [OCRLine]) -> Surface {
        let ordered = orderLines(
            lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        guard !ordered.isEmpty else { return Surface(sentences: [], rects: []) }

        var text = ""
        var spans: [(range: NSRange, rect: CGRect)] = []
        for line in ordered {
            // Space, not newline: NLTokenizer would end the sentence at a line
            // break, but wrapped sentences must stay one trackable unit.
            if !text.isEmpty { text += " " }
            let location = (text as NSString).length
            text += line.text
            spans.append((
                NSRange(location: location, length: (line.text as NSString).length),
                line.rect
            ))
        }

        let sentences = SentenceIndex.sentences(in: text)
        let rects = sentences.map { sentence in
            spans.compactMap { span in
                NSIntersectionRange(sentence.range, span.range).length > 0 ? span.rect : nil
            }
        }
        return Surface(sentences: sentences, rects: rects)
    }

    /// Reading order: rows top to bottom, lines within a row left to right.
    /// Vision's per-observation y values wobble slightly within one visual row,
    /// so same-row lines are grouped with a height-relative tolerance.
    static func orderLines(_ lines: [OCRLine]) -> [OCRLine] {
        let topDown = lines.sorted { $0.rect.midY > $1.rect.midY }

        var result: [OCRLine] = []
        var row: [OCRLine] = []
        var rowMidY: CGFloat = 0

        func flush() {
            result += row.sorted { $0.rect.minX < $1.rect.minX }
            row = []
        }

        for line in topDown {
            if row.isEmpty {
                row = [line]
                rowMidY = line.rect.midY
                continue
            }
            let tolerance = max(line.rect.height, row.first?.rect.height ?? 0) * 0.6
            if abs(line.rect.midY - rowMidY) <= tolerance {
                row.append(line)
            } else {
                flush()
                row = [line]
                rowMidY = line.rect.midY
            }
        }
        flush()
        return result
    }
}
