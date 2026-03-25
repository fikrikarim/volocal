import Foundation
import AVFoundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.locus.app", category: "stt")

/// Wraps FluidAudio's StreamingEouAsrManager for real-time speech-to-text
/// with native end-of-utterance detection on Apple Neural Engine.
@MainActor
final class STTManager: ObservableObject {
    @Published var transcript: String = ""
    @Published var isListening: Bool = false
    @Published var partialResult: String = ""
    @Published var error: String?

    /// Called when a complete utterance is detected (EOU)
    var onUtteranceCompleted: ((String) -> Void)?

    /// Called when speech is first detected (partial result arrives)
    var onSpeechDetected: (() -> Void)?

    private var asrManager: StreamingEouAsrManager?
    private var audioEngine: AVAudioEngine?
    private var hasFiredSpeechDetected = false

    init() {}

    /// Download Parakeet EOU models from HuggingFace and load into memory.
    func initialize() async {
        do {
            // Download models if not already cached
            let modelsDir = Self.modelsDirectory()
            let modelDir = modelsDir.appendingPathComponent(Repo.parakeetEou320.folderName)

            let encoderPath = modelDir.appendingPathComponent("streaming_encoder.mlmodelc")
            if !FileManager.default.fileExists(atPath: encoderPath.path) {
                logger.info("Downloading Parakeet EOU models...")
                try await DownloadUtils.downloadRepo(.parakeetEou320, to: modelsDir)
                logger.info("Parakeet EOU models downloaded")
            }

            // Create and configure manager
            let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 300)

            await manager.setPartialCallback { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.partialResult = text
                    // Require at least 2 words to trigger speech detection
                    // (filters out echo fragments from TTS output)
                    let wordCount = text.split(separator: " ").count
                    if !self.hasFiredSpeechDetected && wordCount >= 2 {
                        self.hasFiredSpeechDetected = true
                        self.onSpeechDetected?()
                    }
                }
            }

            await manager.setEouCallback { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !finalText.isEmpty else { return }
                    self.transcript = finalText
                    self.partialResult = ""
                    self.hasFiredSpeechDetected = false
                    self.onUtteranceCompleted?(finalText)
                }
            }

            logger.info("Loading Parakeet EOU models from \(modelDir.path)...")
            try await manager.loadModels(modelDir: modelDir)
            self.asrManager = manager
            logger.info("Parakeet EOU ready")
        } catch {
            self.error = "STT init failed: \(error.localizedDescription)"
            logger.error("STT init failed: \(error.localizedDescription)")
        }
    }

    func startListening() {
        guard !isListening, asrManager != nil else {
            if asrManager == nil { error = "STT not initialized" }
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            let manager = asrManager!
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                // Process directly on background — don't route through MainActor
                Task {
                    do {
                        _ = try await manager.process(audioBuffer: buffer)
                    } catch {
                        await MainActor.run {
                            self?.error = "STT error: \(error.localizedDescription)"
                        }
                    }
                }
            }

            engine.prepare()
            try engine.start()

            self.audioEngine = engine
            isListening = true
            transcript = ""
            partialResult = ""
            hasFiredSpeechDetected = false
            error = nil
            logger.info("STT listening started")
        } catch {
            self.error = "Failed to start: \(error.localizedDescription)"
            logger.error("Failed to start listening: \(error.localizedDescription)")
        }
    }

    func stopListening() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isListening = false

        Task {
            // Flush remaining audio before resetting
            _ = try? await asrManager?.finish()
            await asrManager?.reset()
        }

        logger.info("STT listening stopped")
    }

    /// Reset ASR state for next utterance without stopping the mic.
    func resetForNextUtterance() {
        hasFiredSpeechDetected = false
        partialResult = ""
        Task {
            await asrManager?.reset()
        }
    }

    /// Simulate a transcript for testing without a real microphone.
    func simulateTranscript(_ text: String) {
        transcript += text + "\n"
        partialResult = ""
        onUtteranceCompleted?(text)
    }

    // MARK: - Private

    private static func modelsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
