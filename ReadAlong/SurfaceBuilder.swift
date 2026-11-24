import Foundation
import CoreGraphics

/// One recognized word of a line: its range within the line's text and its own
/// normalized rectangle, used for the word-level highlight (ADR-0005).
struct OCRWord: Equatable, Sendable {
    let range: NSRange
    let rect: CGRect
}

/// One recognized visual line of an external window, positioned in the
/// window's own space, normalized to 0…1 with the origin at the window's
/// bottom-left corner (Vision's bounding-box convention).
struct OCRLine: Equatable, Sendable {
    let text: String
    let rect: CGRect
    /// Word boxes within `text`; empty when Vision could not produce them.
    var words: [OCRWord] = []
}

/// A reading surface rebuilt from an OCR frame: tracker sentences plus the
/// rectangles the overlay paints (ADR-0001, ADR-0005).
struct Surface: Equatable, Sendable {
    let sentences: [Sentence]
    /// rects[sentenceIndex] holds the normalized window-local rectangles of
    /// the lines that sentence spans.
    let rects: [[CGRect]]
    /// wordRects[sentenceIndex][wordIndex] is that word's rectangle, aligned
    /// with `sentences[sentenceIndex].words`; empty when word geometry is
    /// unavailable and the overlay must fall back to line rects.
    let wordRects: [[CGRect]]
}

/// Whether the tracked window reads as a light or dark surface. The overlay
/// picks highlight colors that keep the underlying text legible either way.
enum SurfaceTone: Equatable, Sendable {
    case light
    case dark

    static func classify(_ thumb: [UInt8]) -> SurfaceTone {
        guard !thumb.isEmpty else { return .dark }
        let mean = thumb.reduce(0) { $0 + Int($1) } / thumb.count
        return mean > 150 ? .light : .dark
    }
}

/// Pure turn of OCR lines into a trackable surface, testable without a screen.
enum SurfaceBuilder {
    /// Builds the reading surface. `columnHint` is the x position (normalized
    /// to the window) where the user clicked to pick the window: when given,
    /// the surface keeps only that column's text.
    static func build(lines: [OCRLine], columnHint: CGFloat? = nil) -> Surface {
        // A window is often several columns (sidebar, document, terminal).
        // Sentences must not run across a gutter: joining columns made speech
        // match one giant sentence with rectangles all over the window.
        let blocks = columnBlocks(lines)
        guard !blocks.isEmpty else { return Surface(sentences: [], rects: [], wordRects: []) }
        let readingBlocks = selectedBlocks(blocks, hint: columnHint)

        var sentences: [Sentence] = []
        var rects: [[CGRect]] = []
        var wordRects: [[CGRect]] = []

        for block in readingBlocks {
            let ordered = orderLines(block)
            let blockLeft = ordered.map(\.rect.minX).min() ?? 0
            let wrapEdge = ordered.map(\.rect.maxX).max() ?? 0

            var text = ""
            var spans: [(range: NSRange, rect: CGRect)] = []
            var wordSpans: [(range: NSRange, rect: CGRect)] = []
            var previous: OCRLine?
            for line in ordered {
                // Space joins a wrapped line into the same sentence; newline
                // starts a new one. UI text has no sentence punctuation, so
                // joining every line made one giant sentence highlighted all
                // over the window (nav labels, poll rows, counts, next post).
                if let previous {
                    text += continuesSentence(previous, line, wrapEdge: wrapEdge, blockLeft: blockLeft)
                        ? " " : "\n"
                }
                let location = (text as NSString).length
                text += line.text
                spans.append((
                    NSRange(location: location, length: (line.text as NSString).length),
                    line.rect
                ))
                wordSpans += line.words.map { word in
                    (
                        NSRange(location: location + word.range.location, length: word.range.length),
                        word.rect
                    )
                }
                previous = line
            }

            for sentence in SentenceIndex.sentences(in: text) {
                sentences.append(sentence)
                rects.append(spans.compactMap { span in
                    NSIntersectionRange(sentence.range, span.range).length > 0 ? span.rect : nil
                })
                let boxes = wordSpans.compactMap { span in
                    NSIntersectionRange(sentence.range, span.range).length > 0 ? span.rect : nil
                }
                // Only trust word geometry when it lines up one-to-one with the
                // sentence's words; otherwise the overlay uses the line rects.
                wordRects.append(boxes.count == sentence.words.count ? boxes : [])
            }
        }
        return Surface(sentences: sentences, rects: rects, wordRects: wordRects)
    }

    /// The blocks that become the reading surface: the one containing the
    /// click that picked the window, or when the click fell in a gutter, the
    /// block with the most words. Text in other columns (sidebars, terminals,
    /// status bars) must not compete for the cursor.
    static func selectedBlocks(_ blocks: [[OCRLine]], hint: CGFloat?) -> [[OCRLine]] {
        guard let hint, !blocks.isEmpty else { return blocks }
        if let containing = blocks.first(where: { block in
            let span = block.reduce(CGRect.null) { CGRectUnion($0, $1.rect) }
            return span.minX <= hint && hint <= span.maxX
        }) {
            return [containing]
        }
        return [blocks.max(by: { wordCount($0) < wordCount($1) }) ?? blocks[0]]
    }

    private static func wordCount(_ block: [OCRLine]) -> Int {
        block.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Whether `line` looks like the next wrapped line of `previous`'s
    /// paragraph rather than a new item: tight spacing, the previous line runs
    /// to the column's right edge, and the two share horizontal space. A stray
    /// bridge line that made several columns one block can only join lines in
    /// its own column, never text from the far side of the window.
    static func continuesSentence(
        _ previous: OCRLine,
        _ line: OCRLine,
        wrapEdge: CGFloat,
        blockLeft: CGFloat
    ) -> Bool {
        let gap = previous.rect.minY - line.rect.maxY
        let tight = gap <= max(previous.rect.height, line.rect.height) * 0.6
        let wrapped = previous.rect.maxX >= wrapEdge - (wrapEdge - blockLeft) * 0.25
        let overlap = min(previous.rect.maxX, line.rect.maxX)
            - max(previous.rect.minX, line.rect.minX)
        let sameColumn = overlap >= min(previous.rect.width, line.rect.width) * 0.5
        return tight && wrapped && sameColumn
    }

    /// Groups lines whose horizontal spans overlap into reading blocks. Columns
    /// sit side by side without overlapping, so each becomes its own block.
    static func columnBlocks(_ lines: [OCRLine]) -> [[OCRLine]] {
        var blocks: [(minX: CGFloat, maxX: CGFloat, lines: [OCRLine])] = []

        for line in lines where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append((line.rect.minX, line.rect.maxX, [line]))
        }
        guard !blocks.isEmpty else { return [] }

        // Merge overlapping spans until the set is stable; OCR lines bridge
        // adjacent columns now and then, and those must join one block.
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in blocks.indices {
                for j in blocks.indices where j > i {
                    if blocks[i].maxX > blocks[j].minX && blocks[j].maxX > blocks[i].minX {
                        blocks[i].lines += blocks[j].lines
                        blocks[i].minX = min(blocks[i].minX, blocks[j].minX)
                        blocks[i].maxX = max(blocks[i].maxX, blocks[j].maxX)
                        blocks.remove(at: j)
                        didMerge = true
                        break outer
                    }
                }
            }
        }
        return blocks.sorted { $0.minX < $1.minX }.map(\.lines)
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
