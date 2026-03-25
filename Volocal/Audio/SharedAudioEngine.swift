import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: "com.volocal.app", category: "audio")

/// Shared state between MainActor and the real-time audio thread.
/// @unchecked Sendable because Bool load/store is atomic on ARM64
/// and AsyncStream.Continuation.yield() is thread-safe.
final class AudioBridge: @unchecked Sendable {
    /// Speaking gate — true while TTS is playing. Audio thread reads, MainActor writes.
    var isSpeaking: Bool = false

    /// STT buffer continuation — set by STTManager on MainActor, yielded from audio thread.
    var inputContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
}

/// Single shared AVAudioEngine for both STT input and TTS output.
/// VP (Voice Processing) is enabled when input capture starts, providing hardware AEC.
@MainActor
final class SharedAudioEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var error: String?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var queuedBuffers = 0
    private var inputCaptureActive = false

    /// Thread-safe bridge between MainActor and the real-time audio thread.
    let bridge = AudioBridge()

    let ttsFormat: AVAudioFormat

    init() {
        ttsFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000, // PocketTTS sample rate
            channels: 1,
            interleaved: false
        )!
    }

    /// Whether TTS is currently playing.
    var isSpeaking: Bool { bridge.isSpeaking }

    // MARK: - Lifecycle

    /// Start the audio engine for TTS playback. Call once during app init.
    func start() {
        guard engine == nil else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try session.setActive(true)

            let eng = AVAudioEngine()

            // Set up player node for TTS output
            let player = AVAudioPlayerNode()
            eng.attach(player)
            eng.connect(player, to: eng.mainMixerNode, format: ttsFormat)

            eng.prepare()
            try eng.start()
            player.play()

            self.engine = eng
            self.playerNode = player
            self.isRunning = true

            logger.info("SharedAudioEngine started (TTS ready)")
        } catch {
            self.error = "Audio engine start failed: \(error.localizedDescription)"
            logger.error("SharedAudioEngine start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        endInputCapture()
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        isRunning = false
        queuedBuffers = 0
        bridge.isSpeaking = false
        bridge.inputContinuation = nil
        logger.info("SharedAudioEngine stopped")
    }

    // MARK: - STT (Input Capture)

    /// Start capturing mic input with Voice Processing AEC.
    /// Briefly restarts the engine to install the tap with a valid format.
    func beginInputCapture() {
        guard let eng = engine, !inputCaptureActive else { return }

        do {
            // Stop engine to reconfigure audio graph with VP + input tap
            playerNode?.stop()
            eng.stop()

            let inputNode = eng.inputNode

            // Enable VP on both input and output for hardware AEC.
            // Must be set while engine is stopped.
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                try eng.outputNode.setVoiceProcessingEnabled(true)
                logger.info("Voice processing AEC enabled")
            } catch {
                logger.warning("Voice processing not available: \(error.localizedDescription)")
            }

            // Install tap — format: nil lets VP set the correct format.
            // Engine is stopped so the graph can be modified safely.
            let audioBridge = self.bridge
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
                // No speaking gate — VP handles echo cancellation.
                // Mic stays active during TTS for barge-in (voice interruption).

                // Copy buffer — the original may be reused by the audio engine
                guard let copy = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: buffer.frameLength
                ) else { return }
                copy.frameLength = buffer.frameLength
                if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                    for ch in 0..<Int(buffer.format.channelCount) {
                        dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
                    }
                }

                audioBridge.inputContinuation?.yield(copy)
            }

            // Restart engine with VP + tap configured
            eng.prepare()
            try eng.start()
            playerNode?.play()

            inputCaptureActive = true
            logger.info("Input capture started with VP AEC")
        } catch {
            logger.error("Failed to start input capture: \(error.localizedDescription)")
            self.error = "Mic capture failed: \(error.localizedDescription)"
        }
    }

    /// Stop capturing mic input. Engine keeps running for TTS.
    func endInputCapture() {
        guard let eng = engine, inputCaptureActive else { return }
        eng.inputNode.removeTap(onBus: 0)
        inputCaptureActive = false
        bridge.inputContinuation = nil
        logger.info("Input capture stopped")
    }

    // MARK: - TTS (Playback)

    /// Schedule a TTS audio buffer for playback.
    func scheduleTTSBuffer(_ samples: [Float]) {
        guard let node = playerNode else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: ttsFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        queuedBuffers += 1
        bridge.isSpeaking = true

        node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.queuedBuffers = max(self.queuedBuffers - 1, 0)
                if self.queuedBuffers == 0 {
                    self.bridge.isSpeaking = false
                }
            }
        }
    }

    /// Stop all TTS playback immediately.
    func stopPlayback() {
        playerNode?.stop()
        playerNode?.play()
        queuedBuffers = 0
        bridge.isSpeaking = false
    }

    /// Wait for all queued TTS buffers to finish playing.
    func waitForPlaybackCompletion() async {
        while queuedBuffers > 0 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { break }
        }
    }
}
