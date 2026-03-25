# Locus Architecture Recommendations
## Extracted from mlx-audio-swift, WhisperKit, and Pipecat

---

## 1. Executive Summary

After analyzing three production-grade voice AI codebases and comparing them against our current Locus implementation, this document identifies specific architectural improvements. The current Locus pipeline is functional but has structural weaknesses in audio session management, error handling, interruption robustness, state machine design, and component decoupling that would prevent it from being a reliable framework.

**Priority order:**
1. Single audio engine (critical -- causes real bugs today)
2. Proper state machine with revision guards
3. Protocol-based component abstraction
4. Typed error system
5. Frame-based pipeline communication
6. Model lifecycle state machine
7. Audio filter pipeline for echo cancellation

---

## 2. Critical Issue: Dual Audio Engine

### The Problem

Locus currently creates **separate AVAudioEngine instances** for STT (microphone input) and TTS (audio output). This causes:

- Audio session conflicts when both are active simultaneously
- Route changes that reset one engine when the other reconfigures
- Echo from TTS output feeding back into the STT microphone tap
- Unpredictable behavior on audio interruptions (phone calls, Siri)

### What mlx-audio-swift Does (The Right Pattern)

mlx-audio-swift's `AudioEngine` class uses **a single AVAudioEngine** for both input capture and output playback:

```swift
// mlx-audio-swift: ONE engine, shared input + output
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let streamingPlayer = AVAudioPlayerNode()

    func setup() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)   // AEC!

        let output = engine.outputNode
        try output.setVoiceProcessingEnabled(true)   // AEC!

        engine.connect(streamingPlayer, to: output, format: nil)

        // Install input tap -- gated by speaking state
        let speakingGate = speakingGate
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            guard !speakingGate.get() else { return }  // Suppress during TTS
            continuation.yield(chunk)
        }

        engine.prepare()
    }
}
```

Key insights:
- `setVoiceProcessingEnabled(true)` on both input AND output nodes enables Apple's built-in acoustic echo cancellation (AEC)
- A `BooleanGate` (lock-free, `@unchecked Sendable`) suppresses mic input while TTS is playing
- The engine is set up once and started/stopped as a unit
- Configuration change notifications are observed to auto-restart

### Recommended Change for Locus

Replace the separate engines in STTManager and TTSManager with a single `AudioEngine` actor that both managers share:

```swift
@MainActor
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let speakingGate = AtomicBool(false)

    private let capturedChunksStream: AsyncStream<AudioChunk>
    private let capturedChunksContinuation: AsyncStream<AudioChunk>.Continuation

    var capturedChunks: AsyncStream<AudioChunk> { capturedChunksStream }

    func setup() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let output = engine.outputNode
        try output.setVoiceProcessingEnabled(true)

        engine.attach(playerNode)
        engine.connect(playerNode, to: output, format: nil)

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            guard let self, !self.speakingGate.value else { return }
            self.capturedChunksContinuation.yield(buf.asAudioChunk())
        }
        engine.prepare()
    }

    func beginSpeaking() { speakingGate.value = true }
    func endSpeaking() { speakingGate.value = false; playerNode.stop() }

    func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { ... }
    }
}
```

STTManager and TTSManager both receive a reference to this shared engine. STT consumes `capturedChunks`. TTS calls `scheduleBuffer()`.

---

## 3. State Machine with Revision Guards

### The Problem

Our current `VoicePipeline` uses a simple enum for state but lacks **revision guards** to prevent stale tasks from corrupting state. Consider:

1. User speaks -> pipeline enters `.processing`
2. LLM starts generating -> enters `.speaking`
3. User barges in -> `interrupt()` called, state goes to `.listening`
4. The old generation task's continuation runs `state = .listening` again -- but this is from a **stale turn**

### What mlx-audio-swift Does

The `ConversationController` uses **integer revision counters** to guard against stale callbacks:

```swift
private var incompleteTimeoutRevision: Int = 0
private var llmTurnRevision: Int = 0

private func cancelLLMTurnTask() {
    llmTurnRevision += 1        // Bump revision
    llmTurnTask?.cancel()
    llmTurnTask = nil
}

private func startLLMTurnTask(prompt: String, source: String, ...) {
    cancelLLMTurnTask()
    let revision = llmTurnRevision  // Capture current revision
    llmTurnTask = Task { @MainActor [weak self] in
        guard let self else { return }
        await self.requestTurnAwareResponse(...)
        // ONLY proceed if our revision is still current
        guard revision == self.llmTurnRevision else { return }
        self.llmTurnTask = nil
    }
}
```

### Recommended Change for Locus

Add a turn revision counter to VoicePipeline:

```swift
@MainActor
final class VoicePipeline: ObservableObject {
    private var turnRevision: Int = 0

    private func interrupt() {
        turnRevision += 1  // Invalidate all in-flight work
        ttsManager.stop()
        llmManager.stopGeneration()
        generationTask?.cancel()
        speakingTask?.cancel()
        // ...
        state = .listening
    }

    private func handleUtterance(_ text: String) {
        turnRevision += 1
        let myRevision = turnRevision
        // ...
        generationTask = Task {
            for await token in llmManager.generate(...) {
                guard !Task.isCancelled, myRevision == turnRevision else { break }
                // process token
            }
            guard myRevision == turnRevision else { return }
            // finalize
        }
    }
}
```

---

## 4. Protocol-Based Component Abstraction

### What WhisperKit Does

WhisperKit defines protocols for every pipeline component, allowing injection and testing:

```swift
public protocol AudioProcessing { ... }
public protocol FeatureExtracting { ... }
public protocol AudioEncoding { ... }
public protocol TextDecoding { ... }
public protocol SegmentSeeking { ... }

open class WhisperKit {
    public var audioProcessor: any AudioProcessing
    public var featureExtractor: any FeatureExtracting
    public var audioEncoder: any AudioEncoding
    public var textDecoder: any TextDecoding
    public var segmentSeeker: any SegmentSeeking
}
```

And the config object allows injecting any implementation:

```swift
open class WhisperKitConfig {
    public var audioProcessor: (any AudioProcessing)?
    public var textDecoder: (any TextDecoding)?
    // ...
}
```

### Recommended Change for Locus

Define protocols for our three core components:

```swift
protocol STTProviding: AnyObject {
    var onUtteranceCompleted: ((String) -> Void)? { get set }
    var onSpeechDetected: (() -> Void)? { get set }
    func initialize() async
    func startListening()
    func stopListening()
    func resetForNextUtterance()
}

protocol LLMProviding: AnyObject {
    func loadModel(path: String) async throws
    func generate(prompt: String, history: [ConversationMessage]) -> AsyncStream<String>
    func stopGeneration()
    var isModelLoaded: Bool { get }
}

protocol TTSProviding: AnyObject {
    func initialize() async
    func speak(_ text: String) async
    func stop()
}

struct VoicePipelineConfig {
    var sttProvider: any STTProviding = STTManager()
    var llmProvider: any LLMProviding = LLMManager()
    var ttsProvider: any TTSProviding = TTSManager()
    var systemPrompt: String = "You are Locus..."
}
```

This enables:
- Unit testing with mock providers
- Swapping models at runtime (e.g., different STT for different languages)
- Users of the framework providing their own implementations

---

## 5. Typed Error System

### The Problem

Locus currently stores errors as `String?` properties. This makes programmatic error handling impossible.

### What WhisperKit Does

WhisperKit uses a comprehensive `@frozen` error enum:

```swift
@frozen
public enum WhisperError: Error, LocalizedError, Equatable {
    case tokenizerUnavailable(String)
    case modelsUnavailable(String)
    case audioProcessingFailed(String)
    case decodingFailed(String)
    case microphoneUnavailable(String)
    case initializationError(String)
    // Each case carries a contextual message
}
```

### Recommended Change for Locus

```swift
@frozen
public enum LocusError: Error, LocalizedError {
    // Pipeline errors
    case pipelineNotReady(String = "Pipeline not initialized")
    case componentNotLoaded(component: String)

    // STT errors
    case sttInitFailed(underlying: Error)
    case microphoneUnavailable
    case audioSessionFailed(underlying: Error)

    // LLM errors
    case modelLoadFailed(path: String, underlying: Error)
    case generationFailed(underlying: Error)
    case contextOverflow

    // TTS errors
    case ttsInitFailed(underlying: Error)
    case synthesisTimedOut(seconds: TimeInterval)
    case audioPlaybackFailed(underlying: Error)

    // Model management errors
    case downloadFailed(model: String, underlying: Error)
    case modelNotFound(path: String)

    public var errorDescription: String? { ... }
}
```

---

## 6. Frame-Based Pipeline Communication (Pipecat Pattern)

### What Pipecat Does

Pipecat's core insight is that **all data flows as typed frames** through the pipeline:

```python
class Frame: ...              # Base
class SystemFrame(Frame): ... # High priority, not affected by interruptions
class DataFrame(Frame): ...   # Normal data, cancelled by interruptions
class ControlFrame(Frame): ...# Control signals, processed in order

class AudioRawFrame:           # Mixin for audio data
    audio: bytes
    sample_rate: int
    num_channels: int

class OutputAudioRawFrame(DataFrame, AudioRawFrame): ...
class TTSAudioRawFrame(OutputAudioRawFrame): ...

# Interruption handling via frame types
class InterruptionFrame(SystemFrame): ...
class CancelFrame(SystemFrame): ...
class StartFrame(SystemFrame): ...
class EndFrame(SystemFrame): ...

# Marker mixin
class UninterruptibleFrame: ...  # Data frames that survive interruptions
```

And processors are linked in a chain:

```python
pipeline = Pipeline([
    transport.input(),    # Audio in
    stt_service,          # STT
    context_aggregator,   # Builds LLM context
    llm_service,          # LLM
    tts_service,          # TTS
    transport.output()    # Audio out
])
```

Frames flow downstream (input -> output) and upstream (output -> input), with each processor having a `process_frame(frame, direction)` method.

### Recommended Lightweight Adaptation for Locus

We don't need Pipecat's full generality (it's designed for cloud pipelines with many services), but adopting typed events would improve our pipeline:

```swift
enum PipelineEvent {
    // Data events (flow downstream)
    case audioInput(samples: [Float], sampleRate: Int)
    case transcription(text: String, isFinal: Bool)
    case llmToken(String)
    case llmComplete(fullText: String)
    case ttsAudio(samples: [Float])

    // Control events (can flow both directions)
    case interruptionRequested(source: InterruptionSource)
    case pipelineStarted
    case pipelineStopped
    case error(LocusError)

    // State events
    case speechDetected
    case silenceDetected
    case modelLoadProgress(component: String, progress: Double)
}

enum InterruptionSource {
    case userSpeech
    case userTap
    case systemAudioInterruption
}
```

This replaces the current callback-based approach with a more traceable, debuggable event flow.

---

## 7. Model Lifecycle State Machine

### What WhisperKit Does

WhisperKit has a well-defined `ModelState` enum shared across all components:

```swift
@frozen
public enum ModelState {
    case unloading
    case unloaded
    case loading
    case loaded
    case prewarming
    case prewarmed
    case downloading
    case downloaded

    public var isBusy: Bool {
        switch self {
        case .loading, .prewarming, .downloading, .unloading: return true
        default: return false
        }
    }
}

public typealias ModelStateCallback = (_ oldState: ModelState?, _ newState: ModelState) -> Void
```

With state transitions:
```
unloaded -> downloading -> downloaded -> loading -> loaded
unloaded -> prewarming -> prewarmed
loaded   -> unloading  -> unloaded
```

### What WhisperKit Does for Prewarming

WhisperKit has a "prewarm" concept: load each CoreML model individually to trigger compilation/specialization, then unload it, before loading all models together. This keeps peak memory low:

> "The peak memory usage during compilation is reduced because only one model is kept in memory at any given point."

### Recommended Change for Locus

```swift
@frozen
public enum ComponentState: CustomStringConvertible {
    case unloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case loaded
    case warming
    case ready    // Loaded + warmed up
    case failed(LocusError)

    public var isReady: Bool { self == .ready }
    public var isBusy: Bool {
        switch self {
        case .downloading, .loading, .warming: return true
        default: return false
        }
    }
}

@MainActor
final class VoicePipeline: ObservableObject {
    @Published var sttState: ComponentState = .unloaded
    @Published var llmState: ComponentState = .unloaded
    @Published var ttsState: ComponentState = .unloaded

    var isReady: Bool {
        sttState.isReady && llmState.isReady && ttsState.isReady
    }
}
```

---

## 8. Interruption Strategy Pattern

### What Pipecat Does

Pipecat separates interruption **detection** from interruption **policy** via a strategy pattern:

```python
class BaseInterruptionStrategy(ABC):
    async def append_audio(self, audio: bytes, sample_rate: int): ...
    async def append_text(self, text: str): ...

    @abstractmethod
    async def should_interrupt(self) -> bool: ...

    @abstractmethod
    async def reset(self): ...

class MinWordsInterruptionStrategy(BaseInterruptionStrategy):
    def __init__(self, *, min_words: int):
        self._min_words = min_words
        self._text = ""

    async def should_interrupt(self) -> bool:
        return len(self._text.split()) >= self._min_words
```

### What mlx-audio-swift Does

mlx-audio-swift uses a **semantic VAD** with SmartTurn endpoint detection. It combines:
1. RMS energy threshold to detect speech start
2. Apple's `SpeechAnalyzer` for transcription
3. A SmartTurn ML model that predicts whether the user is done speaking
4. Hang-time (0.9s silence) as fallback

The SmartTurn model is particularly clever -- it uses audio features to predict turn completion, cutting response latency significantly.

### Recommended Change for Locus

Our current approach (require 2+ words to trigger barge-in) is a reasonable heuristic but should be formalized:

```swift
protocol InterruptionStrategy {
    func onPartialTranscript(_ text: String)
    func onAudioLevel(_ rmsLevel: Float)
    func shouldInterrupt() -> Bool
    func reset()
}

struct MinWordsInterruptionStrategy: InterruptionStrategy {
    let minWords: Int
    private var accumulatedText = ""

    mutating func onPartialTranscript(_ text: String) {
        accumulatedText = text
    }

    func shouldInterrupt() -> Bool {
        accumulatedText.split(separator: " ").count >= minWords
    }

    mutating func reset() { accumulatedText = "" }
}

// Future: ML-based strategy using SmartTurn model
struct SmartTurnInterruptionStrategy: InterruptionStrategy { ... }
```

---

## 9. Echo Cancellation

### What mlx-audio-swift Does

Three layers of echo suppression:

1. **Apple Voice Processing**: `setVoiceProcessingEnabled(true)` on both input and output nodes provides hardware-accelerated acoustic echo cancellation.

2. **Speaking Gate**: A lock-free boolean that suppresses mic input capture entirely while TTS is playing:
   ```swift
   private final class BooleanGate: @unchecked Sendable {
       private let lock: OSAllocatedUnfairLock<Bool>
       func get() -> Bool { lock.withLock { $0 } }
       func set(_ value: Bool) { lock.withLock { $0 = value } }
   }
   ```

3. **Microphone muting**: `engine.inputNode.isVoiceProcessingInputMuted` can be toggled without stopping the engine.

### What Pipecat Does

Pipecat provides a `BaseAudioFilter` abstraction for noise reduction/echo cancellation. Various implementations (Krisp, RNNoise, Koala) can be plugged in before the audio reaches the VAD and STT.

### Our Current Approach

Locus uses a word-count threshold (2+ words) on STT partial results to ignore echo fragments. This is fragile.

### Recommended Approach

1. **Primary**: Use `setVoiceProcessingEnabled(true)` via the shared AudioEngine (requires single engine -- see section 2)
2. **Secondary**: Speaking gate to suppress mic capture during TTS output
3. **Tertiary**: Keep the word-count threshold as a safety net, but rely on hardware AEC

---

## 10. Audio Session Management

### What mlx-audio-swift Does

```swift
// Set up ONCE at start, with proper configuration
let session = AVAudioSession.sharedInstance()
try session.setActive(false)
try session.setCategory(.playAndRecord, mode: .voiceChat,
                         policy: .default, options: [.defaultToSpeaker])
try session.setPreferredIOBufferDuration(0.02)  // 20ms buffers for low latency
try session.setActive(true)
```

Key: `mode: .voiceChat` enables voice processing optimizations. The IO buffer duration is set to 20ms for low latency.

### Our Current Problem

Both STTManager and TTSManager independently configure the audio session:
```swift
// In STTManager.startListening():
try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
try session.setActive(true)

// In TTSManager.speak():
try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
try session.setActive(true)
```

This redundant configuration can cause glitches when one component reconfigures while the other is active.

### Recommended Change

Configure the audio session ONCE in the shared AudioEngine's `setup()` method. Neither STTManager nor TTSManager should touch AVAudioSession directly.

---

## 11. AsyncStream Patterns

### What mlx-audio-swift Does

Uses `AsyncStream.makeStream()` with bounded buffering for audio capture:

```swift
let stream = AsyncStream.makeStream(
    of: AudioChunk.self,
    bufferingPolicy: .bufferingNewest(8)  // Drop old chunks if consumer is slow
)
```

This prevents memory buildup if the consumer (VAD/STT) falls behind.

### Our Current Approach

We use a closure callback from the input tap to `Task { await manager.process(audioBuffer:) }`. This creates an unbounded number of Tasks that could pile up.

### Recommended Change

Use a bounded AsyncStream for audio chunks flowing from the engine to STT:

```swift
let (stream, continuation) = AsyncStream.makeStream(
    of: AVAudioPCMBuffer.self,
    bufferingPolicy: .bufferingNewest(8)
)

// In input tap:
continuation.yield(buffer)

// In STT consumer:
for await buffer in stream {
    try await asrManager.process(audioBuffer: buffer)
}
```

---

## 12. Smart Turn Detection

### What mlx-audio-swift Does

The `SemanticVAD` combines multiple signals to determine when a user has finished speaking:

1. **RMS threshold** for speech activity detection
2. **Apple SpeechTranscriber** for real-time transcription
3. **SmartTurn ML model** that analyzes audio to predict turn completion
4. **Hang-time fallback** (0.9s of silence)

The SmartTurn model can short-circuit the hang time, reducing latency:

```swift
if smartTurnDetectedEndpoint() {
    print("SmartTurn detected endpoint, short-circuiting hang time")
    return .stopped(transcription: transcription)
}
```

### Recommended Future Enhancement

Our Parakeet EOU model already handles end-of-utterance detection. But we could add a SmartTurn-style model as an additional signal to reduce perceived latency. The architecture should support pluggable turn detection strategies.

---

## 13. Configuration Change Handling

### What mlx-audio-swift Does

Both `AudioEngine` and `AudioPlayer` observe `AVAudioEngineConfigurationChange` notifications to auto-recover:

```swift
configurationChangeObserver = Task { [weak self] in
    for await _ in NotificationCenter.default.notifications(
        named: .AVAudioEngineConfigurationChange
    ) {
        if !engine.isRunning {
            try engine.start()
        }
    }
}
```

### Our Current State

Locus does not handle audio configuration changes at all. If a Bluetooth headset connects/disconnects, or a phone call interrupts, the audio engine may silently stop.

### Recommended Change

Add configuration change handling to the shared AudioEngine.

---

## 14. Concurrency Model

### What mlx-audio-swift Does

- `ConversationController` is `@MainActor @Observable` (not `ObservableObject`)
- `SemanticVAD` is an `actor` (for thread safety without MainActor bottleneck)
- `TranscriptState` is a private `actor`
- `BooleanGate` uses `OSAllocatedUnfairLock` for lock-free thread safety
- Audio processing runs on `Task(priority: .userInitiated)` to avoid blocking the main thread

### What WhisperKit Does

- `AudioStreamTranscriber` is a public `actor`
- Heavy compute (VAD, feature extraction) runs off the main thread
- Model loading is async with progress callbacks

### Recommended Concurrency Changes for Locus

1. **STTManager**: The ASR processing should NOT dispatch through `Task { @MainActor }` in the audio tap callback. Instead, use an AsyncStream that a background task consumes:
   ```swift
   // Bad (current): Task { try await manager.process(audioBuffer: buffer) }
   // Good: continuation.yield(buffer)  // In tap, non-blocking
   // Then a dedicated Task processes the stream
   ```

2. **VoicePipeline**: Keep `@MainActor` for UI state, but dispatch heavy work to background tasks.

3. **LlamaContext**: Already an `actor`, which is correct.

---

## 15. Summary of Recommended Architecture

```
                    LocusApp
                       |
                 VoicePipeline (@MainActor, ObservableObject)
                 /     |       \
            STT      LLM      TTS          <-- Protocol-based
           (any      (any     (any
           STT       LLM      TTS
           Providing) Providing) Providing)
                \      |      /
                 AudioEngine (@MainActor)   <-- Single shared engine
                       |
              AVAudioEngine (one instance)
               /              \
          inputNode         outputNode + playerNode
          (mic tap)         (TTS playback)
          voiceProcessing   voiceProcessing
          enabled           enabled
```

**Data flow:**
```
Mic -> AudioEngine.capturedChunks -> STTManager -> onUtteranceCompleted
    -> VoicePipeline.handleUtterance -> LLMManager.generate (AsyncStream<String>)
    -> SentenceBuffer -> TTSManager.speak -> AudioEngine.scheduleBuffer
```

**Interruption flow:**
```
STTManager.onSpeechDetected -> InterruptionStrategy.shouldInterrupt()
    -> if true: VoicePipeline.interrupt()
        -> turnRevision += 1
        -> TTSManager.stop() -> AudioEngine.endSpeaking()
        -> LLMManager.stopGeneration()
        -> state = .listening
```

---

## 16. Priority Implementation Order

| Priority | Change | Effort | Impact |
|----------|--------|--------|--------|
| P0 | Single shared AudioEngine with VoiceProcessing AEC | Medium | Fixes echo, audio conflicts |
| P0 | Turn revision guards | Small | Fixes stale state corruption |
| P1 | Typed error system (LocusError) | Small | Enables error recovery |
| P1 | ComponentState lifecycle enum | Small | Better loading UX |
| P1 | Audio session configure-once | Small | Eliminates glitches |
| P1 | AsyncStream for audio tap (bounded) | Small | Prevents Task pileup |
| P2 | Protocol-based component abstraction | Medium | Enables testing/swapping |
| P2 | InterruptionStrategy protocol | Small | Extensible barge-in |
| P2 | AVAudioEngineConfigurationChange handling | Small | Resilience to BT/calls |
| P3 | PipelineEvent typed events | Medium | Better debugging/tracing |
| P3 | Model prewarming (WhisperKit pattern) | Medium | Lower peak memory |
| P3 | SmartTurn endpoint detection | Large | Lower response latency |
