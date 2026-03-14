import Foundation

/// Accumulates streaming LLM tokens and emits complete sentences.
/// Detects sentence boundaries at `.`, `!`, `?` followed by whitespace or end-of-stream.
final class SentenceBuffer {
    private var buffer = ""
    private let sentenceEndings: CharacterSet = CharacterSet(charactersIn: ".!?")

    /// Called when a complete sentence is ready for TTS
    var onSentenceReady: ((String) -> Void)?

    /// Add a token to the buffer. May trigger onSentenceReady if a sentence boundary is found.
    func append(_ token: String) {
        buffer += token

        // Look for sentence boundaries
        while let range = findSentenceBoundary() {
            let sentence = String(buffer[buffer.startIndex...range.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !sentence.isEmpty {
                onSentenceReady?(sentence)
            }

            // Remove the emitted sentence from the buffer
            let nextIndex = buffer.index(after: range.upperBound)
            if nextIndex < buffer.endIndex {
                buffer = String(buffer[nextIndex...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                buffer = ""
            }
        }
    }

    /// Flush any remaining text in the buffer (call at end of generation)
    func flush() {
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            onSentenceReady?(remaining)
        }
        buffer = ""
    }

    /// Reset the buffer
    func reset() {
        buffer = ""
    }

    // MARK: - Private

    /// Max words before forcing a chunk even without punctuation
    private let maxWordsBeforeFlush = 12

    private func findSentenceBoundary() -> Range<String.Index>? {
        // Priority 1: sentence-ending punctuation
        for i in buffer.indices {
            let char = buffer[i]
            if char == "." || char == "!" || char == "?" {
                let nextIndex = buffer.index(after: i)
                if nextIndex >= buffer.endIndex { continue }
                let nextChar = buffer[nextIndex]
                if nextChar == " " || nextChar == "\n" || nextChar == "\"" || nextChar == "\u{201D}" {
                    return i..<nextIndex
                }
            }
        }

        // Priority 2: clause boundary (comma, semicolon, colon, dash) if buffer is getting long
        let wordCount = buffer.split(separator: " ").count
        if wordCount >= 6 {
            for i in buffer.indices {
                let char = buffer[i]
                if char == "," || char == ";" || char == ":" || char == "—" || char == "-" {
                    let nextIndex = buffer.index(after: i)
                    if nextIndex < buffer.endIndex && buffer[nextIndex] == " " {
                        return i..<nextIndex
                    }
                }
            }
        }

        // Priority 3: force flush after too many words to avoid long silences
        if wordCount >= maxWordsBeforeFlush {
            // Find the last space to break on a word boundary
            if let lastSpace = buffer.lastIndex(of: " ") {
                return lastSpace..<buffer.index(after: lastSpace)
            }
        }

        return nil
    }
}
