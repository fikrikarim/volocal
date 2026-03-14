import Foundation
import AVFoundation
import MLXAudioTTS
import MLXAudioCore

/// Wraps mlx-audio-swift for on-device streaming text-to-speech synthesis.
/// Models are auto-downloaded on first initialize() call.
@MainActor
final class TTSManager: ObservableObject {
    @Published var isSpeaking: Bool = false
    @Published var selectedVoice: String = "alba"
    @Published var error: String?

    private var model: (any SpeechGenerationModel)?
    private let player = AudioPlayer()
    private var speakTask: Task<Void, Never>?

    static let voiceNames = [
        "alba", "marius", "javert", "jean",
        "fantine", "cosette", "eponine", "azelma"
    ]

    init() {}

    /// Initialize the TTS engine. Downloads MLX models on first use.
    func initialize() async {
        do {
            model = try await TTS.loadModel(
                modelRepo: "mlx-community/pocket-tts",
                modelType: "pocket_tts"
            )
        } catch {
            self.error = "TTS init failed: \(error.localizedDescription)"
        }
    }

    /// Synthesize text via streaming and play chunks as they arrive.
    func speak(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        speakTask?.cancel()
        player.stopStreaming()

        isSpeaking = true
        error = nil

        let task = Task {
            do {
                guard let model = model else {
                    throw TTSError.engineNotLoaded
                }

                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)

                player.startStreaming(sampleRate: Double(model.sampleRate))

                for try await samples in model.generateSamplesStream(
                    text: text,
                    voice: selectedVoice,
                    refAudio: nil,
                    refText: nil,
                    language: nil
                ) {
                    if Task.isCancelled { break }
                    player.scheduleAudioChunk(samples, withCrossfade: true)
                }

                if !Task.isCancelled {
                    player.finishStreamingInput()
                    // Wait for playback to complete
                    while player.isSpeaking && !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                } else {
                    player.stopStreaming()
                }
            } catch {
                if !Task.isCancelled {
                    self.error = "TTS failed: \(error.localizedDescription)"
                }
            }
            if !Task.isCancelled {
                self.isSpeaking = false
            }
        }
        speakTask = task
        await task.value
    }

    /// Stop all audio playback and cancel in-flight generation.
    func stop() {
        speakTask?.cancel()
        speakTask = nil
        player.stopStreaming()
        isSpeaking = false
    }
}

enum TTSError: LocalizedError {
    case engineNotLoaded

    var errorDescription: String? {
        switch self {
        case .engineNotLoaded:
            return "TTS engine not loaded. Call initialize() first."
        }
    }
}
