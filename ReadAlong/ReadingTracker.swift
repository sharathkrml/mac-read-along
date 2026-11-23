import Foundation

/// The core reading tracker. Sentence is the unit; multi-word evidence is the
/// only thing that moves the cursor (ADR-0003).
@MainActor
final class ReadingTracker {
    private(set) var sentences: [Sentence] = []
    private(set) var cursor: Int?
    var onChange: (() -> Void)?

    private var committedWords: [String] = []
    private var partialWords: [String] = []

    var currentSentence: Sentence? {
        guard let cursor, sentences.indices.contains(cursor) else { return nil }
        return sentences[cursor]
    }

    var nextSentence: Sentence? {
        guard let cursor, sentences.indices.contains(cursor + 1) else { return nil }
        return sentences[cursor + 1]
    }

    func load(sentences: [Sentence]) {
        self.sentences = sentences
        cursor = nil
        committedWords = []
        partialWords = []
        onChange?()
    }

    func resetPosition() {
        cursor = nil
        committedWords = []
        partialWords = []
        onChange?()
    }

    func handle(_ update: TranscriptUpdate) {
        let incoming = SentenceIndex.words(in: update.text)
        if update.isFinal {
            committedWords.append(contentsOf: incoming)
            if committedWords.count > 200 {
                committedWords.removeFirst(committedWords.count - 200)
            }
            partialWords = []
        } else {
            partialWords = incoming
        }
        advance()
    }

    private struct Candidate {
        let index: Int
        let length: Int
        let distance: Int
    }

    private func advance() {
        let spoken = Array((committedWords + partialWords).suffix(40))
        guard !spoken.isEmpty, !sentences.isEmpty else { return }
        let recent = Array(spoken.suffix(12))

        if cursor == nil {
            if let best = bestCandidate(in: recent, excluding: nil) {
                setCursor(best.index)
            }
            return
        }

        if let best = bestCandidate(in: recent, excluding: cursor) {
            setCursor(best.index)
            return
        }

        guard let cursor, let current = currentSentence, endsSentence(current, in: recent) else {
            return
        }
        let next = min(cursor + 1, sentences.count - 1)
        if next != cursor {
            setCursor(next)
        }
    }

    private func bestCandidate(in recent: [String], excluding: Int?) -> Candidate? {
        var candidates: [Candidate] = []

        for (index, sentence) in sentences.enumerated() {
            guard !sentence.words.isEmpty else { continue }
            if let excluded = excluding, excluded == index { continue }
            guard let length = matchLength(of: sentence, tail: recent) else { continue }
            if length < 3 && length < sentence.words.count { continue }
            let distance = excluding.map { abs($0 - index) } ?? index
            candidates.append(Candidate(index: index, length: length, distance: distance))
        }

        return candidates.max { left, right in
            if left.length != right.length { return left.length < right.length }
            if left.distance != right.distance { return left.distance > right.distance }
            return left.index > right.index
        }
    }

    /// Longest suffix of the recent speech that appears contiguously in the sentence.
    private func matchLength(of sentence: Sentence, tail: [String]) -> Int? {
        let maximum = min(6, tail.count, sentence.words.count)
        guard maximum > 0 else { return nil }

        for length in stride(from: maximum, through: 1, by: -1) {
            let needle = Array(tail.suffix(length))
            if containsRun(needle, in: sentence.words) {
                return length
            }
        }
        return nil
    }

    private func endsSentence(_ sentence: Sentence, in recent: [String]) -> Bool {
        let length = min(3, sentence.words.count)
        guard length > 0, recent.count >= length else { return false }
        let needle = Array(sentence.words.suffix(length))
        return containsRun(needle, in: recent)
    }

    private func containsRun(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where !Self.fuzzyEqual(needle[offset], haystack[start + offset]) {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    private func setCursor(_ index: Int) {
        guard cursor != index else { return }
        cursor = index
        onChange?()
    }

    static func fuzzyEqual(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        guard left.count >= 4, right.count >= 4, abs(left.count - right.count) <= 1 else { return false }
        return editDistance(left, right) <= 1
    }

    static func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
