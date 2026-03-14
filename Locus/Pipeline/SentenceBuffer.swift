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

    private func findSentenceBoundary() -> Range<String.Index>? {
        // Find sentence-ending punctuation followed by a space or end of string
        for i in buffer.indices {
            let char = buffer[i]
            if char == "." || char == "!" || char == "?" {
                let nextIndex = buffer.index(after: i)
                // Boundary if followed by space, end of string, or quote
                if nextIndex >= buffer.endIndex {
                    // Only emit at true end-of-stream (handled by flush)
                    continue
                }
                let nextChar = buffer[nextIndex]
                if nextChar == " " || nextChar == "\n" || nextChar == "\"" || nextChar == "\u{201D}" {
                    return i..<nextIndex
                }
            }
        }
        return nil
    }
}
