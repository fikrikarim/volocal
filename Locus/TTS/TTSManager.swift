import Foundation
import AVFoundation

/// Wraps PocketTTSSwift for on-device text-to-speech synthesis.
/// Requires pocket-tts-ios XCFramework (run scripts/setup.sh first).
@MainActor
final class TTSManager: ObservableObject {
    @Published var isSpeaking: Bool = false
    @Published var selectedVoiceIndex: UInt32 = 0
    @Published var error: String?

    private var ttsEngine: PocketTTSSwift?
    private var audioPlayer: AVAudioPlayer?
    private var audioQueue: [Data] = []
    private var isPlaying = false
    private var playbackTask: Task<Void, Never>?

    static let voiceNames = [
        "Alba", "Marius", "Javert", "Jean",
        "Fantine", "Cosette", "Eponine", "Azelma"
    ]

    init() {}

    /// Initialize the TTS engine with the path to Pocket TTS model files.
    func configure(modelPath: String) async {
        let engine = PocketTTSSwift(modelPath: modelPath)
        do {
            try await engine.load()
            try await engine.configure(.default)
            self.ttsEngine = engine
        } catch {
            self.error = "TTS init failed: \(error.localizedDescription)"
        }
    }

    /// Synthesize text and play it immediately.
    func speak(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isSpeaking = true
        error = nil

        do {
            guard let engine = ttsEngine else {
                throw TTSError.engineNotLoaded
            }

            // Update voice selection
            let config = PocketTTSSwift.Config(voiceIndex: selectedVoiceIndex)
            try await engine.configure(config)

            // Synthesize
            let result = try await engine.synthesize(text: text)
            await play(audioData: result.audioData)
        } catch {
            self.error = "TTS failed: \(error.localizedDescription)"
            isSpeaking = false
        }
    }

    /// Synthesize with streaming for lower latency. Plays audio chunks as they arrive.
    func speakStreaming(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let engine = ttsEngine else {
            error = "TTS engine not loaded"
            return
        }

        isSpeaking = true
        error = nil

        do {
            let config = PocketTTSSwift.Config(voiceIndex: selectedVoiceIndex)
            try await engine.configure(config)

            for try await chunk in await engine.synthesizeStreaming(text: text) {
                if chunk.isFinal { break }
                queueAudio(chunk.audioData)
            }
        } catch {
            self.error = "TTS streaming failed: \(error.localizedDescription)"
        }

        // Wait for audio queue to drain
        while isPlaying {
            try? await Task.sleep(for: .milliseconds(50))
        }
        isSpeaking = false
    }

    /// Queue audio data for sequential playback.
    func queueAudio(_ data: Data) {
        audioQueue.append(data)
        if !isPlaying {
            playNext()
        }
    }

    /// Stop all audio playback and cancel synthesis.
    func stop() {
        if let engine = ttsEngine {
            Task { await engine.cancel() }
        }
        audioPlayer?.stop()
        audioPlayer = nil
        audioQueue.removeAll()
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        isSpeaking = false
    }

    // MARK: - Private

    private func play(audioData: Data) async {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            audioPlayer = try AVAudioPlayer(data: audioData)
            audioPlayer?.play()

            while audioPlayer?.isPlaying == true {
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            self.error = "Playback failed: \(error.localizedDescription)"
        }
        isSpeaking = false
    }

    private func playNext() {
        guard !audioQueue.isEmpty else {
            isPlaying = false
            return
        }

        isPlaying = true
        let data = audioQueue.removeFirst()

        playbackTask = Task {
            await play(audioData: data)
            playNext()
        }
    }
}

enum TTSError: LocalizedError {
    case engineNotLoaded

    var errorDescription: String? {
        switch self {
        case .engineNotLoaded:
            return "TTS engine not loaded. Ensure model files are downloaded."
        }
    }
}
