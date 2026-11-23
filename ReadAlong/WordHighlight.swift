import CoreGraphics

/// The word-level slice the overlay paints for the reading cursor: the
/// three-word breath group under the voice, the group after it, and the exact
/// word being read. Display only — the sentence stays the tracking unit and
/// none of this moves the cursor (ADR-0005).
struct WordWindow: Equatable {
    static let groupSize = 3

    let current: Range<Int>
    let next: Range<Int>
    let word: Int

    /// `wordCursor` nil means speech has not reached this sentence yet, so the
    /// first group is the one to read.
    static func around(wordCursor: Int?, wordCount: Int) -> WordWindow? {
        guard wordCount > 0 else { return nil }
        let anchor = min(max(wordCursor ?? 0, 0), wordCount - 1)
        let start = anchor / groupSize * groupSize
        let end = min(start + groupSize, wordCount)
        return WordWindow(
            current: start..<end,
            next: end..<min(end + groupSize, wordCount),
            word: anchor
        )
    }
}

/// Merges word rectangles that share a visual line into one band, so a breath
/// group reads as a phrase instead of a row of chips.
enum HighlightBands {
    static func merge(_ rects: [CGRect]) -> [CGRect] {
        var remaining = rects
        var bands: [CGRect] = []

        while !remaining.isEmpty {
            var band = remaining.removeFirst()
            var didMerge = true
            while didMerge {
                didMerge = false
                for (index, rect) in remaining.enumerated()
                where sameLine(band, rect)
                    && gap(band, rect) <= max(band.height, rect.height) * 0.8 {
                    band = band.union(rect)
                    remaining.remove(at: index)
                    didMerge = true
                    break
                }
            }
            bands.append(band)
        }
        return bands
    }

    private static func sameLine(_ left: CGRect, _ right: CGRect) -> Bool {
        let overlap = min(left.maxY, right.maxY) - max(left.minY, right.minY)
        return overlap > min(left.height, right.height) * 0.5
    }

    private static func gap(_ left: CGRect, _ right: CGRect) -> CGFloat {
        max(max(right.minX - left.maxX, left.minX - right.maxX), 0)
    }
}
