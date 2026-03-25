import Foundation
import AVFoundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.locus.app", category: "tts")

/// Wraps FluidAudio's PocketTtsManager for on-device streaming text-to-speech.
/// Models are auto-downloaded on first initialize() call.
@MainActor
final class TTSManager: ObservableObject {
    @Published var isSpeaking: Bool = false
    @Published var selectedVoice: String = "alba"
    @Published var error: String?

    private var engine: PocketTtsManager?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var speakTask: Task<Void, Never>?
    private var hasTrackedFirstInference = false
    private var queuedBuffers = 0
    var metrics: SystemMetrics?

    private let sampleRate = Double(PocketTtsConstants.audioSampleRate) // 24000

    static let voiceNames = [
        "alba", "marius", "javert", "jean",
        "fantine", "cosette", "eponine", "azelma"
    ]

    init() {}

    /// Initialize the TTS engine. Downloads CoreML models on first use,
    /// then runs a dummy generation to warm up.
    func initialize() async {
        do {
            let manager = PocketTtsManager()
            try await manager.initialize()
            self.engine = manager

            // Warm up: force CoreML to compile models
            logger.info("TTS warmup: running dummy generation...")
            let stream = try await manager.synthesizeStreaming(text: "Hi", voice: "alba")
            for try await _ in stream {
                break // One frame is enough
            }
            logger.info("TTS warmup done")
        } catch {
            self.error = "TTS init failed: \(error.localizedDescription)"
        }
    }

    /// Synthesize text via streaming and play frames as they arrive.
    func speak(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        speakTask?.cancel()
        stopAudioEngine()

        isSpeaking = true
        error = nil

        let speakTimeout: TimeInterval = 30
        let task = Task {
            do {
                guard let engine = engine else {
                    throw TTSError.engineNotLoaded
                }

                logger.info("speak start: \"\(text)\"")

                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
                try session.setActive(true)

                try startAudioEngine()

                if !hasTrackedFirstInference {
                    metrics?.beginTracking("TTS (PocketTTS)")
                }

                let genStart = CFAbsoluteTimeGetCurrent()
                var chunkCount = 0

                let stream = try await engine.synthesizeStreaming(
                    text: text,
                    voice: selectedVoice,
                    temperature: 0.4
                )

                for try await frame in stream {
                    if !hasTrackedFirstInference {
                        hasTrackedFirstInference = true
                        metrics?.endTracking("TTS (PocketTTS)")
                    }
                    if Task.isCancelled { break }

                    if CFAbsoluteTimeGetCurrent() - genStart > speakTimeout {
                        logger.warning("speak timeout after \(speakTimeout)s, aborting")
                        break
                    }

                    chunkCount += 1
                    logger.debug("chunk \(chunkCount): \(frame.samples.count) samples")
                    scheduleAudioFrame(frame.samples)
                }

                logger.info("speak generation done: \(chunkCount) chunks")

                if !Task.isCancelled {
                    if chunkCount > 0 {
                        // Wait for playback to complete
                        while queuedBuffers > 0 && !Task.isCancelled {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("speak failed: \(error.localizedDescription)")
                    self.error = "TTS failed: \(error.localizedDescription)"
                }
            }
            stopAudioEngine()
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
        stopAudioEngine()
        isSpeaking = false
    }

    // MARK: - Audio Engine

    private func startAudioEngine() throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        node.play()

        self.audioEngine = engine
        self.playerNode = node
        self.queuedBuffers = 0
    }

    private func stopAudioEngine() {
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        queuedBuffers = 0
    }

    private func scheduleAudioFrame(_ samples: [Float]) {
        guard let node = playerNode else { return }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        queuedBuffers += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor in
                self?.queuedBuffers = max((self?.queuedBuffers ?? 1) - 1, 0)
            }
        }
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
