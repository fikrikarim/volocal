import Foundation

/// Accumulates streaming LLM tokens and emits complete sentences.
/// Detects sentence boundaries at `.`, `!`, `?` followed by whitespace or end-of-stream.
/// Also splits on `:` and `;` as secondary clause boundaries, and forces split at ~200 chars.
final class SentenceBuffer {
    private var buffer = ""

    /// Called when a complete sentence is ready for TTS
    var onSentenceReady: ((String) -> Void)?

    /// Maximum characters before forcing a split at nearest word boundary
    private let maxChars = 200

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

            let nextIndex = buffer.index(after: range.upperBound)
            if nextIndex < buffer.endIndex {
                buffer = String(buffer[nextIndex...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                buffer = ""
            }
        }

        // Force split if buffer exceeds max length
        if buffer.count > maxChars {
            forceSplitAtWordBoundary()
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
        for i in buffer.indices {
            let char = buffer[i]
            let nextIndex = buffer.index(after: i)
            guard nextIndex < buffer.endIndex else { continue }
            let nextChar = buffer[nextIndex]

            // Primary boundaries: .!?
            if char == "!" || char == "?" {
                if nextChar == " " || nextChar == "\n" || nextChar == "\"" || nextChar == "\u{201D}" {
                    return i..<nextIndex
                }
            }

            // Period: only split if next char is uppercase (avoids Dr., 3.14, U.S.)
            if char == "." {
                if nextChar == " " || nextChar == "\n" {
                    // Check if char after space is uppercase
                    let afterSpace = buffer.index(after: nextIndex)
                    if afterSpace < buffer.endIndex {
                        let charAfter = buffer[afterSpace]
                        if charAfter.isUppercase {
                            return i..<nextIndex
                        }
                    }
                    // Also split on period + quote
                } else if nextChar == "\"" || nextChar == "\u{201D}" {
                    return i..<nextIndex
                }
            }

            // Secondary boundaries: : and ; (clause boundaries)
            if char == ":" || char == ";" {
                if nextChar == " " || nextChar == "\n" {
                    return i..<nextIndex
                }
            }
        }
        return nil
    }

    /// Force a split at the nearest word boundary when buffer is too long.
    private func forceSplitAtWordBoundary() {
        // Find last space before maxChars
        var splitIndex = buffer.startIndex
        for i in buffer.indices {
            if buffer.distance(from: buffer.startIndex, to: i) >= maxChars { break }
            if buffer[i] == " " {
                splitIndex = i
            }
        }

        // If we found a space to split on
        if splitIndex > buffer.startIndex {
            let sentence = String(buffer[buffer.startIndex..<splitIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                onSentenceReady?(sentence)
            }

            let nextIndex = buffer.index(after: splitIndex)
            if nextIndex < buffer.endIndex {
                buffer = String(buffer[nextIndex...])
            } else {
                buffer = ""
            }
        }
    }
}
