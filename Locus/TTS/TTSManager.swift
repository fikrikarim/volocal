import Foundation
import AVFoundation
import FluidAudio

/// Wraps FluidAudio's PocketTtsManager for on-device text-to-speech synthesis.
/// Models are auto-downloaded on first initialize() call.
@MainActor
final class TTSManager: ObservableObject {
    @Published var isSpeaking: Bool = false
    @Published var selectedVoice: String = "alba"
    @Published var error: String?

    private var ttsEngine: PocketTtsManager?
    private var audioPlayer: AVAudioPlayer?

    static let voiceNames = ["alba", "azelma", "cosette", "javert"]

    init() {}

    /// Initialize the TTS engine. FluidAudio auto-downloads CoreML models on first use.
    func initialize() async {
        let engine = PocketTtsManager()
        do {
            try await engine.initialize()
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

            let audioData = try await engine.synthesize(
                text: text,
                voice: selectedVoice,
                temperature: 0.7
            )
            await play(audioData: audioData)
        } catch {
            self.error = "TTS failed: \(error.localizedDescription)"
            isSpeaking = false
        }
    }

    /// Stop all audio playback.
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
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
