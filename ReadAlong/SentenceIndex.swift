import Foundation
import NaturalLanguage

struct Sentence: Equatable {
    let text: String
    let range: NSRange
    let words: [String]
}

enum SentenceIndex {
    /// Splits text into sentences and normalizes each into matching words.
    static func sentences(in text: String) -> [Sentence] {
        guard !text.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [Sentence] = []

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                result.append(Sentence(
                    text: sentence,
                    range: NSRange(range, in: text),
                    words: words(in: sentence)
                ))
            }
            return true
        }

        if result.isEmpty {
            return fallbackSentences(in: text)
        }
        return result
    }

    /// Word tokens with their ranges: letters and digits form a word,
    /// apostrophes stay inside it, everything else splits. OCR word boxes and
    /// sentence words must agree, so both go through this one rule.
    static func wordRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = string.startIndex

        while index < string.endIndex {
            let character = string[index]
            let isWordCharacter = character.isLetter || character.isNumber
                || character == "'" || character == "’"
            if isWordCharacter {
                if start == nil { start = index }
            } else if let wordStart = start {
                ranges.append(wordStart..<index)
                start = nil
            }
            index = string.index(after: index)
        }
        if let wordStart = start {
            ranges.append(wordStart..<string.endIndex)
        }
        return ranges
    }

    static func words(in string: String) -> [String] {
        wordRanges(in: string).map { range in
            String(string[range])
                .lowercased()
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "’", with: "")
        }
    }

    private static func fallbackSentences(in text: String) -> [Sentence] {
        var result: [Sentence] = []
        let nsText = text as NSString
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: .bySentences) { substring, range, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.append(Sentence(text: trimmed, range: range, words: words(in: trimmed)))
        }
        if result.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(Sentence(
                    text: trimmed,
                    range: NSRange(location: 0, length: nsText.length),
                    words: words(in: trimmed)
                ))
            }
        }
        return result
    }
}
