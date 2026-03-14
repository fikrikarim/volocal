import Foundation
import AVFoundation
import MLXAudioTTS
import MLXAudioCore
import os

private let logger = Logger(subsystem: "com.locus.app", category: "tts")

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
    private var hasTrackedFirstInference = false
    var metrics: SystemMetrics?

    static let voiceNames = [
        "alba", "marius", "javert", "jean",
        "fantine", "cosette", "eponine", "azelma"
    ]

    init() {}

    /// Initialize the TTS engine. Downloads MLX models on first use,
    /// then runs a dummy generation to force weights into memory.
    func initialize() async {
        do {
            let loadedModel = try await TTS.loadModel(
                modelRepo: "mlx-community/pocket-tts",
                modelType: "pocket_tts"
            )
            self.model = loadedModel

            // Warm up: force MLX to load weights into memory
            logger.info("TTS warmup: running dummy generation...")
            for try await _ in loadedModel.generateSamplesStream(
                text: "Hi",
                voice: "alba",
                refAudio: nil,
                refText: nil,
                language: nil
            ) {
                break  // One chunk is enough to load all weights
            }
            logger.info("TTS warmup done")
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

        let speakTimeout: TimeInterval = 30
        let task = Task {
            do {
                guard let model = model else {
                    throw TTSError.engineNotLoaded
                }

                logger.info("speak start: \"\(text)\"")

                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)

                player.startStreaming(sampleRate: Double(model.sampleRate))

                if !hasTrackedFirstInference {
                    metrics?.beginTracking("TTS (PocketTTS)")
                }

                let genStart = CFAbsoluteTimeGetCurrent()
                var chunkCount = 0

                for try await samples in model.generateSamplesStream(
                    text: text,
                    voice: selectedVoice,
                    refAudio: nil,
                    refText: nil,
                    language: nil
                ) {
                    if !hasTrackedFirstInference {
                        hasTrackedFirstInference = true
                        metrics?.endTracking("TTS (PocketTTS)")
                    }
                    if Task.isCancelled { break }

                    // Timeout: abort if generation takes too long
                    if CFAbsoluteTimeGetCurrent() - genStart > speakTimeout {
                        logger.warning("speak timeout after \(speakTimeout)s, aborting")
                        break
                    }

                    chunkCount += 1
                    logger.debug("chunk \(chunkCount): \(samples.count) samples")
                    player.scheduleAudioChunk(samples, withCrossfade: true)
                }

                logger.info("speak generation done: \(chunkCount) chunks")

                if !Task.isCancelled {
                    if chunkCount > 0 {
                        player.finishStreamingInput()
                        // Wait for playback to complete
                        while player.isSpeaking && !Task.isCancelled {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                    } else {
                        logger.warning("speak produced 0 chunks for: \"\(text)\"")
                        player.stopStreaming()
                    }
                } else {
                    player.stopStreaming()
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("speak failed: \(error.localizedDescription)")
                    self.error = "TTS failed: \(error.localizedDescription)"
                }
            }
            if !Task.isCancelled {
                self.isSpeaking = false
            }
            logger.info("speak end")
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
