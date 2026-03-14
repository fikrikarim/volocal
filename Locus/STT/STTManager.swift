import Foundation
import AVFoundation
import MoonshineVoice

/// Wraps MoonshineVoice's MicTranscriber for real-time speech-to-text with built-in VAD.
@MainActor
final class STTManager: ObservableObject {
    @Published var transcript: String = ""
    @Published var isListening: Bool = false
    @Published var partialResult: String = ""
    @Published var error: String?

    /// Called when a complete utterance is detected (VAD end-of-speech)
    var onUtteranceCompleted: ((String) -> Void)?

    private var micTranscriber: MicTranscriber?
    private var lines: [TranscriptLine] = []

    init() {}

    /// Initialize the transcriber with the path to Moonshine model files.
    /// modelPath should point to a directory containing the .ort model files.
    func configure(modelPath: String) {
        do {
            micTranscriber = try MicTranscriber(
                modelPath: modelPath,
                modelArch: .mediumStreaming,
                updateInterval: 0.3,
                sampleRate: 16000,
                channels: 1,
                bufferSize: 1024
            )

            micTranscriber?.addListener { [weak self] event in
                Task { @MainActor in
                    self?.handleEvent(event)
                }
            }
        } catch {
            self.error = "STT init failed: \(error.localizedDescription)"
        }
    }

    func startListening() {
        guard !isListening, let micTranscriber else {
            error = "Transcriber not configured"
            return
        }

        do {
            try micTranscriber.start()
            isListening = true
            transcript = ""
            partialResult = ""
            lines = []
            error = nil
        } catch {
            self.error = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stopListening() {
        try? micTranscriber?.stop()
        isListening = false
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: TranscriptEvent) {
        if event is LineStarted {
            // New speech segment detected by VAD
            lines.append(event.line)
            partialResult = event.line.text
        } else if event is LineTextChanged {
            // Partial transcript update (streaming)
            if !lines.isEmpty {
                lines[lines.count - 1] = event.line
            }
            partialResult = event.line.text
        } else if event is LineCompleted {
            // Final transcript for this utterance
            let finalText = event.line.text
            if finalText.isEmpty {
                // Empty line = silence detected, remove placeholder
                if !lines.isEmpty {
                    lines.removeLast()
                }
            } else {
                if !lines.isEmpty {
                    lines[lines.count - 1] = event.line
                }
                transcript = lines.map(\.text).joined(separator: "\n")
                partialResult = ""

                // Notify pipeline that a complete utterance is ready
                onUtteranceCompleted?(finalText)
            }
        } else if let errorEvent = event as? TranscriptError {
            error = "STT error: \(errorEvent.error.localizedDescription)"
        }
    }

    /// Simulate a transcript for testing without a real microphone.
    func simulateTranscript(_ text: String) {
        transcript += text + "\n"
        partialResult = ""
        onUtteranceCompleted?(text)
    }
}
