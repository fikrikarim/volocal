# Locus: Implementation Plan
## Fully Local Realtime Voice AI — iOS First, Android Later

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    iOS App (Swift)                       │
│                                                         │
│  ┌──────────┐   ┌──────────────┐   ┌─────────────────┐ │
│  │ Mic/VAD  │──▶│ ASR          │──▶│ LLM             │ │
│  │ Silero   │   │ Moonshine    │   │ Qwen3.5-0.8B    │ │
│  │ VAD v5   │   │ Streaming    │   │ via llama.cpp   │ │
│  └──────────┘   │ Small/Medium │   │ (Metal GPU)     │ │
│                 │ (Moonshine   │   └────────┬────────┘ │
│                 │  Swift Pkg)  │            │ tokens    │
│                 └──────────────┘            ▼           │
│                                   ┌─────────────────┐  │
│  ┌──────────┐                     │ Sentence Buffer  │  │
│  │ Speaker  │◀────────────────────│ + TTS            │  │
│  │ AVAudio  │                     │ Pocket TTS       │  │
│  │ Player   │                     │ (Rust/UniFFI)    │  │
│  └──────────┘                     └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Pipeline Flow (Streaming)
1. **Mic** captures audio continuously
2. **Silero VAD** detects speech segments (30ms chunks, <1ms processing)
3. **Moonshine Streaming** transcribes in real-time while user speaks
4. VAD detects end-of-speech → final transcript sent to LLM
5. **Qwen3.5-0.8B** generates response tokens via llama.cpp (streaming)
6. **Sentence buffer** collects tokens until sentence boundary (`.` `!` `?` or clause boundary)
7. **Pocket TTS** synthesizes each sentence chunk → plays immediately
8. Next sentence synthesizes while current one plays (double-buffering)

---

## 2. Framework Decisions

### ASR: Moonshine Swift Package (NOT sherpa-onnx)

**Decision: Use Moonshine's official Swift package directly.**

| Criteria | Moonshine Swift Package | sherpa-onnx | WhisperKit |
|---|---|---|---|
| **Streaming v2 support** | First-class, native | Added via community PR | Whisper streaming |
| **VAD integration** | **Built-in** (all-in-one library) | Silero VAD bundled | Built-in VAD |
| **iOS examples** | `examples/ios/Transcriber` Xcode project | Build from source, complex | Excellent examples |
| **Swift API** | Native Swift, SPM (`moonshine-swift`) | C-based API with Swift wrappers | Pure Swift, SPM |
| **Model format** | ORT flatbuffer (memory-mapped) | ONNX via ONNX Runtime | CoreML (ANE-optimized) |
| **Runtime** | ONNX Runtime | ONNX Runtime | CoreML (Apple Neural Engine) |
| **Maintenance** | Official by Useful Sensors | Community (k2-fsa) | Official by Argmax |
| **Dependencies** | Only ONNX Runtime | ONNX Runtime + more | CoreML only |
| **Latency (Small)** | **148ms** (13.1x faster than Whisper Small) | Same as model chosen | Higher (Whisper arch) |
| **Maturity on iOS** | Newer | Very mature, many platforms | **Most mature for Apple** |

**Why Moonshine over sherpa-onnx and WhisperKit:**
- **Speed**: Moonshine v2 Small is 13.1x faster than Whisper Small with comparable accuracy
- Purpose-built Swift package with iOS example apps
- Simpler dependency tree (just ONNX Runtime)
- Better latency characteristics for real-time voice interaction
- WhisperKit is the most polished iOS experience (pure Swift, CoreML/ANE) but Whisper's architecture has inherently higher latency than Moonshine v2's streaming encoder

**Note:** Moonshine Voice is an all-in-one library — it includes VAD, mic capture, ASR, speaker identification, and intent recognition in a single package. No separate VAD library needed.

**Model choice: Moonshine Streaming Small (123M params)**
- Size: ~125 MB (ORT format)
- Latency: 148ms (13.1x faster than Whisper Small)
- Accuracy: Outperforms Whisper Small, on-par with models 6x larger
- Streaming: Yes — sliding-window attention, bounded latency

**Fallback: Moonshine Streaming Medium (245M params)**
- Size: ~250 MB
- Latency: 258ms (43.7x faster than Whisper Large v3)
- Accuracy: Outperforms Whisper Large v3
- Use if higher accuracy is needed and memory allows

### VAD: Moonshine Voice Built-in VAD

**Decision: Use Moonshine Voice's built-in VAD — no separate dependency needed.**

Moonshine Voice is an all-in-one library that handles the entire audio pipeline:
- **Microphone capture**
- **Voice Activity Detection** (breaks continuous audio into speech segments)
- **Speech-to-Text** (streaming ASR)
- **Speaker identification**
- **Intent recognition**

This eliminates the need for a separate VAD library like Silero VAD. The VAD runs every 30ms with a configurable averaging window (default 0.5s), tightly integrated with the ASR pipeline — it segments audio into phrases and triggers transcription when speech ends.

**VAD role in the pipeline:**
1. Detects speech onset → Moonshine starts streaming ASR internally
2. Detects end-of-speech → finalizes ASR transcript, we send to LLM
3. Detects user interruption → we stop TTS playback, restart listening

**Fallback (only if finer VAD control is needed):**
- [Silero VAD v6 CoreML](https://huggingface.co/FluidInference/silero-vad-coreml) — 2 MB, <0.2ms per chunk
- [RealTimeCutVADLibrary](https://github.com/helloooideeeeea/RealTimeCutVADLibrary) — Swift, includes WebRTC noise suppression

### LLM: llama.cpp via Swift Package

**Decision: Use llama.cpp with a Swift wrapper for Metal-accelerated inference.**

| Option | Maturity | Swift API | iOS Min | Notes |
|---|---|---|---|---|
| **llama.cpp XCFramework** | High | C++ interop | iOS 17+ | Official SPM, pre-compiled binary target |
| llmfarm_core.swift | High | Native Swift | iOS 16+ | Wraps llama.cpp, used in LLMFarm app |
| llama.swift (mattt) | Medium | Native Swift | iOS 17+ | Semantic versioning, re-exports XCFramework |
| LocalLLMClient | New (2025) | Native Swift | iOS 17+ | Unified API for llama.cpp + MLX backends |
| AnyLanguageModel | New (2025) | Native Swift | iOS 17+ | Drop-in for Apple Foundation Models API; supports llama.cpp, MLX, CoreML, cloud |
| MLX Swift | High | Native Swift | iOS 17+ | **Apple's own framework — now works on iOS** (since WWDC 2025) |
| MLC LLM | Medium | Swift SDK | Yes | TVM-compiled, OpenAI-compatible API |

**Recommended approach:**
1. **Primary: [llama.swift](https://github.com/mattt/llama.swift)** — Semantically versioned Swift access to llama.cpp via official XCFramework. Clean API, proper SPM versioning (avoids `unsafeFlags` issue).
2. **Alternative: [AnyLanguageModel](https://github.com/mattt/AnyLanguageModel)** — Drop-in replacement for Apple's Foundation Models framework. Lets you swap between llama.cpp, MLX, CoreML, and cloud backends with minimal code changes. Future-proof.
3. **Also viable: MLX Swift** — Apple's own ML framework now runs on iOS (WWDC 2025). On M-series chips, MLX achieves 21-87% higher throughput than llama.cpp. On A-series (iPhone), performance is comparable. Uses MLX-format models from `mlx-community` on HuggingFace.

**Model: Qwen3.5-0.8B Q4_K_M GGUF**
- Size: ~500 MB disk, ~600-800 MB runtime
- Speed: ~30-50 tokens/sec on A16 Bionic (Metal) for 0.8B model
- Format: GGUF (standard for llama.cpp) or MLX format (for MLX backend)
- Architecture: Fully supported by llama.cpp; MLX-community has pre-quantized Qwen3.5 models

### TTS: Pocket TTS via pocket-tts-ios (Rust/UniFFI)

**Decision: Use [pocket-tts-ios](https://github.com/UnaMentis/pocket-tts-ios) — the community iOS port with pre-built XCFramework.**

Key details:
- **Runtime:** Candle ML framework (Rust) compiled to iOS XCFramework
- **Swift bindings:** UniFFI-generated, native Swift API
- **Model size:** 225 MB (main weights) + 60 KB (tokenizer) + 4.2 MB (voice embeddings) ≈ **~230 MB total**
- **Voices:** 8 built-in voices (Alba, Marius, Javert, Jean, Fantine, Cosette, Eponine, Azelma)
- **Voice cloning:** Supported with 5 seconds of reference audio
- **Streaming:** Overlap-add streaming synthesis for low-latency audio
- **Quality:** Best-in-class 1.84% WER, outperforms models 7x larger
- **Speed:** RTF ~0.17 on M4 CPU (6x faster than real-time)

**Swift usage:**
```swift
let engine = try PocketTTSEngine(modelPath: modelDir)
let config = TTSConfig(
    voiceIndex: 0,        // 0-7 for built-in voices
    temperature: 0.8,
    speed: 1.0
)
let result = try engine.synthesize(text: "Hello!", config: config)
// result.audioData contains WAV bytes
```

**Fallback: Kokoro-82M via sherpa-onnx**
- Smaller (~80 MB quantized)
- Already integrated in sherpa-onnx with iOS support
- Lower quality than Pocket TTS, no voice cloning

---

## 3. Memory Budget (iPhone 15, ~3 GB available)

| Component | Framework | Model | Size |
|---|---|---|---|
| ASR + VAD | Moonshine Voice | Streaming Small (built-in VAD) | ~125 MB |
| LLM | llama.cpp / llmfarm_core | Qwen3.5-0.8B Q4_K_M | ~600 MB |
| TTS | pocket-tts-ios | Pocket TTS | ~230 MB |
| Runtimes | ONNX Runtime + Candle + Metal | — | ~100 MB |
| App + buffers | SwiftUI + audio buffers | — | ~50 MB |
| **Total** | | | **~1.1 GB** |

**Headroom: ~1.9 GB remaining** — very comfortable. Could upgrade to Moonshine Medium (~250 MB) if accuracy needs warrant it.

---

## 4. Latency Budget

| Stage | Component | Expected Latency |
|---|---|---|
| Speech detection | Moonshine VAD (built-in) | ~30 ms per chunk |
| End-of-speech | Moonshine VAD averaging | ~200-500 ms |
| ASR transcription | Moonshine Streaming Small | ~148 ms |
| LLM first token | Qwen3.5-0.8B Q4_K_M | ~200-500 ms |
| Sentence accumulation | Buffer ~5-15 tokens | ~300-700 ms |
| TTS first audio | Pocket TTS streaming | ~200 ms |
| **Total to first audio** | | **~1.1 – 2.0 s** |

With aggressive pipelining (start LLM before ASR fully completes), target is **~1 second** to first audio.

---

## 5. iOS Project Structure

```
Locus/
├── Locus.xcodeproj
├── Locus/
│   ├── App/
│   │   ├── LocusApp.swift              # App entry point
│   │   └── ContentView.swift           # Main UI
│   ├── Audio/
│   │   ├── AudioSessionManager.swift   # AVAudioSession setup
│   │   ├── AudioRecorder.swift         # Mic capture (AVAudioEngine)
│   │   └── AudioPlayer.swift           # Playback (AVAudioPlayerNode)
│   ├── Pipeline/
│   │   ├── VoicePipeline.swift         # Orchestrates ASR→LLM→TTS
│   │   ├── ASRManager.swift            # Moonshine Voice wrapper (VAD + ASR)
│   │   ├── LLMManager.swift            # llama.cpp wrapper
│   │   ├── TTSManager.swift            # Pocket TTS wrapper
│   │   └── SentenceBuffer.swift        # Collects tokens → sentences
│   ├── Models/
│   │   └── ConversationModel.swift     # Chat history, state
│   └── Resources/
│       ├── moonshine-streaming-small/  # ASR model files (.ort)
│       ├── qwen3.5-0.8b-q4_k_m.gguf   # LLM model file
│       └── pocket-tts/                 # TTS model + voices
├── Packages/
│   ├── moonshine-swift (SPM dependency)
│   ├── llmfarm_core.swift (SPM dependency)
│   └── pocket-tts-ios (XCFramework)
└── Tests/
```

### Dependencies (Swift Package Manager)

```swift
// Package.swift / Xcode dependencies
dependencies: [
    // ASR - Moonshine official Swift package
    .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", from: "1.0.0"),

    // LLM - llama.cpp via semantically versioned Swift wrapper
    .package(url: "https://github.com/mattt/llama.swift.git", from: "1.0.0"),
    // OR for multi-backend support (llama.cpp + MLX + CoreML):
    // .package(url: "https://github.com/mattt/AnyLanguageModel.git", from: "0.1.0"),

    // TTS - Pocket TTS iOS (add as XCFramework binary target)
    // Download from https://github.com/UnaMentis/pocket-tts-ios/releases

    // VAD - Included in Moonshine Voice (no separate dependency needed)
]
```

---

## 6. Implementation Phases

### Phase 1: Audio Foundation (Week 1)
- Set up Xcode project with SwiftUI
- Implement `AudioSessionManager` — configure AVAudioSession for simultaneous record + play
- Implement `AudioRecorder` — capture mic audio via AVAudioEngine, output PCM float32 at 16kHz
- Implement `AudioPlayer` — play WAV/PCM audio chunks with AVAudioPlayerNode
- Test: record and play back audio

### Phase 2: ASR Integration (Week 2)
- Integrate Moonshine Voice Swift package via SPM
- Download Moonshine Streaming Small model (.ort files)
- Implement `ASRManager` using Moonshine Voice's all-in-one API:
  - Moonshine handles mic capture, VAD, and streaming ASR internally
  - Configure VAD parameters (silence threshold, min speech/silence duration)
  - Handle speech segment callbacks (onset, partial transcript, final transcript)
  - Handle end-of-speech events → trigger LLM pipeline
- Reference: `examples/ios/Transcriber` Xcode project in Moonshine repo
- Test: speak into mic → see real-time transcript on screen with VAD segmentation

### Phase 3: LLM Integration (Week 3)
- Integrate llama.swift (or AnyLanguageModel) via SPM
- Download Qwen3.5-0.8B Q4_K_M GGUF model
- Implement `LLMManager`:
  - Load model with Metal acceleration
  - System prompt configuration
  - Streaming token generation (async sequence)
  - Conversation history management
- Test: type text → see streaming LLM response

### Phase 4: TTS Integration (Week 4)
- Integrate pocket-tts-ios XCFramework
- Download Pocket TTS model files
- Implement `TTSManager`:
  - Initialize engine with model path and voice config
  - Synthesize text → WAV audio data
  - Voice selection (8 built-in + voice cloning)
- Implement `SentenceBuffer`:
  - Collect streaming LLM tokens
  - Detect sentence boundaries (`.` `!` `?` `,` + configurable)
  - Emit complete sentences for TTS
- Test: type text → hear spoken response

### Phase 5: Pipeline Integration (Week 5)
- Implement `VoicePipeline` — wire ASR → LLM → TTS
- Streaming pipeline:
  1. ASR transcribes while user speaks
  2. On end-of-speech, send transcript to LLM
  3. LLM streams tokens to SentenceBuffer
  4. SentenceBuffer emits sentences to TTS
  5. TTS synthesizes and plays audio (double-buffered)
- Handle interruption (user speaks while AI is talking)
- Test: full voice conversation loop

### Phase 6: UI & Polish (Week 6)
- Conversation UI (chat bubbles with transcripts)
- Voice activity indicator (animated waveform)
- Model download/management UI (on first launch)
- Settings: voice selection, speed, model choice
- Memory monitoring and graceful degradation
- Battery optimization (stop inference when idle)

### Phase 7: Model Distribution (Week 7)
- Models are too large for App Store bundle (~1 GB total)
- Implement on-demand model download:
  - Host models on CDN or use HuggingFace Hub
  - Download progress UI
  - Store in app's Documents directory
  - Verify checksums
- Consider offering model quality tiers:
  - "Fast" — Moonshine Tiny + Qwen Q4 + Pocket TTS = ~800 MB download
  - "Balanced" — Moonshine Small + Qwen Q4 + Pocket TTS = ~860 MB download
  - "Quality" — Moonshine Medium + Qwen Q4 + Pocket TTS = ~980 MB download

---

## 7. Android Plan

### Cross-Platform Components

The key insight: **all three core libraries already support Android.**

| Component | iOS Framework | Android Equivalent | Shared |
|---|---|---|---|
| ASR + VAD | Moonshine Voice Swift | Moonshine Voice Android (Java/Kotlin) | Same ORT models, same all-in-one API |
| LLM | llama.swift / llama.cpp | llama.cpp Android (JNI + Kotlin) | Same GGUF model |
| TTS | pocket-tts-ios (Rust/UniFFI) | pocket-tts (Rust/UniFFI for Android) | Same Rust core + models |

### Android Architecture

```
Android App (Kotlin)
├── Moonshine Android SDK (ONNX Runtime + NNAPI)
│   └── moonshine-streaming-small.ort
├── llama.cpp Android (JNI, Vulkan GPU acceleration)
│   └── qwen3.5-0.8b-q4_k_m.gguf
└── Pocket TTS (Rust compiled for Android via UniFFI/JNI)
    └── pocket-tts model files
```

### Android-Specific Considerations

1. **GPU acceleration:**
   - llama.cpp supports **Vulkan** on Android (vs Metal on iOS)
   - Qualcomm contributed an **OpenCL backend** optimized for Adreno GPUs — best path for Snapdragon devices
   - ONNX Runtime supports **NNAPI** execution provider on Android
   - Performance varies widely across chipsets (Snapdragon, MediaTek, Exynos)
   - **CPU with ARM NEON** is the most reliable fallback across all Android devices

2. **Target devices:**
   - Minimum: Snapdragon 8 Gen 1 (or equivalent), 8 GB RAM
   - Recommended: Snapdragon 8 Gen 2+, 12 GB RAM
   - Android gives more RAM to apps than iOS (~4-6 GB available)

3. **Moonshine on Android:**
   - Official Android folder in repo: `examples/android/`
   - Java/Kotlin bindings via the C++ core library + JNI
   - Pre-built `android-examples.tar.gz` available from Moonshine releases
   - Same ORT model files work across platforms

4. **llama.cpp on Android:**
   - Mature Android support via JNI
   - Multiple Kotlin binding options:
     - [kotlinllamacpp](https://github.com/ljcamargo/kotlinllamacpp) — designed for ARM Android
     - [Ai-Core](https://github.com/Siddhesh2377/Ai-Core) — self-contained AAR with native `.so`
     - [llama-cpp-kt](https://github.com/hurui200320/llama-cpp-kt) — Kotlin wrapper via JNA
   - Same GGUF model files work across platforms
   - Community apps: [ChatterUI](https://github.com/Vali-98/ChatterUI), [Maid](https://github.com/Mobile-Artificial-Intelligence/maid)

5. **Pocket TTS on Android:**
   - Rust core compiles for Android targets (aarch64-linux-android)
   - UniFFI can generate Kotlin bindings (same approach as Swift)
   - Same model files work across platforms

6. **VAD on Android:**
   - Moonshine Voice Android SDK includes built-in VAD (same as iOS)
   - Same all-in-one library handles mic capture, VAD, and ASR

### Cross-Platform Strategy

**Phase 1 (Months 1-2): iOS native app** — Build and polish the iOS version first.

**Phase 2 (Month 3): Android native app** — Port the pipeline logic to Kotlin. The ML models and Rust TTS core are identical; only the platform wrappers change.

**Alternative: Flutter (strongest cross-platform story)**
- sherpa-onnx has a [Flutter package](https://pub.dev/packages/sherpa_onnx) covering ASR + TTS + VAD
- llama.cpp has Flutter packages: `flutter_llama`, `llama_cpp_dart`, `llm_llamacpp`
- [Maid](https://github.com/Mobile-Artificial-Intelligence/maid) is a real-world Flutter app proving this stack works across 6 platforms
- Tradeoff: faster cross-platform development vs less native control

**Alternative: Kotlin Multiplatform (KMP)**
- Experimental llama.cpp KMP bindings exist (shared iOS + Android code)
- sherpa-onnx Kotlin and Swift APIs are parallel, making `expect/actual` feasible
- More mature than Flutter for sharing business logic while keeping native UI

**Alternative: [Cactus](https://github.com/cactus-compute/cactus) (Y Combinator-backed)**
- Single SDK for iOS, Android, macOS, and wearables
- Uses proprietary `.cact` model format (converted from GGUF) optimized for mobile battery/RAM
- Claims <100ms latency with zero-copy memory mapping
- SDKs: React Native, Flutter, Kotlin Multiplatform, Swift
- Supports Qwen, Gemma, Llama, DeepSeek, Phi, Mistral
- Worth evaluating but adds vendor dependency

**Recommendation: Native first**, Flutter only if maintaining two codebases becomes unsustainable

---

## 8. Risk Mitigations

| Risk | Mitigation |
|---|---|
| **Pocket TTS XCFramework stability** | pocket-tts-ios is community-maintained. Fallback: Kokoro-82M via sherpa-onnx (proven iOS integration). |
| **Moonshine Swift package compatibility** | Pin to specific version. Fallback: Use Moonshine via sherpa-onnx instead. |
| **llama.cpp SPM build issues** | Known Obj-C++ compilation issues with raw Package.swift. Use llama.swift (XCFramework binary target, proper versioning) or AnyLanguageModel. |
| **Memory pressure on iPhone 15** | Total ~1.1 GB leaves 1.9 GB headroom. Monitor with `os_proc_available_memory()`. Unload TTS model when recording, unload ASR when generating. |
| **Thermal throttling** | Limit continuous conversation to ~2-3 min. Show thermal warning. Reduce model quality tier dynamically. |
| **Model download size (~1 GB)** | On-demand download with progress UI. Offer "Fast" tier (~800 MB) as default. |
| **Qwen3.5-0.8B quality** | For simple Q&A and conversation, 0.8B is adequate. System prompt engineering is critical. If quality is insufficient, consider Llama 3.2 1B (slightly larger). |

---

## 9. Dependency Summary

### iOS

| Dependency | Type | Source | Purpose |
|---|---|---|---|
| moonshine-swift | SPM | github.com/moonshine-ai/moonshine-swift | VAD + ASR (all-in-one) |
| llama.swift | SPM | github.com/mattt/llama.swift | LLM inference (Metal) |
| pocket-tts-ios | XCFramework | github.com/UnaMentis/pocket-tts-ios | TTS (Rust/Candle) |
| ONNX Runtime | Transitive (via Moonshine) | microsoft/onnxruntime | ASR runtime |

### Models (downloaded on first launch)

| Model | Size | Source |
|---|---|---|
| Moonshine Streaming Small | ~125 MB | HuggingFace: UsefulSensors/moonshine-streaming-small |
| Qwen3.5-0.8B Q4_K_M | ~500 MB | HuggingFace: Qwen/Qwen3.5-0.8B-GGUF |
| Pocket TTS | ~230 MB | HuggingFace: kyutai/pocket-tts |
| **Total download** | **~855 MB** | |

---

## 10. Sources

### ASR — Moonshine
- [Moonshine GitHub](https://github.com/moonshine-ai/moonshine)
- [Moonshine Swift Package](https://github.com/moonshine-ai/moonshine-swift)
- [Moonshine v2 Paper](https://arxiv.org/abs/2602.12241)
- [Moonshine Streaming Medium on HF](https://huggingface.co/UsefulSensors/moonshine-streaming-medium)
- [Announcing Moonshine Voice (Blog)](https://petewarden.com/2026/02/13/announcing-moonshine-voice/)
- [iOS Transcriber Example](https://github.com/moonshine-ai/moonshine/tree/main/examples/ios)

### LLM — llama.cpp / MLX
- [llama.cpp GitHub](https://github.com/ggml-org/llama.cpp)
- [llama.cpp Swift Package Index](https://swiftpackageindex.com/ggml-org/llama.cpp)
- [llama.swift (mattt)](https://github.com/mattt/llama.swift) — semantically versioned XCFramework wrapper
- [AnyLanguageModel](https://github.com/mattt/AnyLanguageModel) — multi-backend (llama.cpp, MLX, CoreML, cloud)
- [LocalLLMClient](https://github.com/tattn/LocalLLMClient) — unified API for llama.cpp + MLX
- [llmfarm_core.swift](https://github.com/guinmoon/llmfarm_core.swift)
- [LLMFarm iOS App](https://github.com/guinmoon/LLMFarm)
- [MLX Swift GitHub](https://github.com/ml-explore/mlx-swift) — Apple's ML framework, now on iOS
- [WWDC 2025 - Get Started with MLX](https://developer.apple.com/videos/play/wwdc2025/315/)
- [Comparative Study: MLX vs MLC-LLM vs llama.cpp](https://arxiv.org/pdf/2511.05502)
- [Qwen3.5-0.8B on HuggingFace](https://huggingface.co/Qwen/Qwen3.5-0.8B)
- [Qwen3.5 llama.cpp Integration](https://qwen.readthedocs.io/en/latest/run_locally/llama.cpp.html)

### TTS — Pocket TTS
- [Pocket TTS GitHub](https://github.com/kyutai-labs/pocket-tts)
- [pocket-tts-ios (iOS port)](https://github.com/UnaMentis/pocket-tts-ios)
- [Pocket TTS iOS Port Article](https://medium.com/@sirfifer/using-ai-to-port-an-incredible-new-tts-model-to-ios-pockettts-for-ios-c40a2fbf308b)
- [Pocket TTS Technical Report](https://kyutai.org/pocket-tts-technical-report)
- [Pocket TTS Rust Crate](https://lib.rs/crates/pocket-tts)
- [Pocket TTS ONNX Export](https://github.com/KevinAHM/pocket-tts-onnx-export) — INT8 total ~198 MB
- [Kokoro sherpa-onnx Integration](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html)

### VAD
- [Silero VAD GitHub](https://github.com/snakers4/silero-vad)
- [Silero VAD CoreML](https://huggingface.co/FluidInference/silero-vad-coreml) — pre-converted, ready for Swift
- [RealTimeCutVADLibrary (iOS)](https://github.com/helloooideeeeea/RealTimeCutVADLibrary)
- [ios-vad](https://github.com/baochuquan/ios-vad) — WebRTC + Silero + Yamnet
- [Best VAD Comparison 2026 (Picovoice)](https://picovoice.ai/blog/best-voice-activity-detection-vad/)

### Cross-Platform / Android
- [sherpa-onnx GitHub](https://github.com/k2-fsa/sherpa-onnx)
- [sherpa-onnx Flutter Package](https://pub.dev/packages/sherpa_onnx)
- [sherpa-onnx iOS Swift Guide](https://carlosmbe.medium.com/running-speech-models-with-swift-using-sherpa-onnx-for-apple-development-d31fdbd0898f)
- [sherpa-onnx Android Build](https://k2-fsa.github.io/sherpa/onnx/android/build-sherpa-onnx.html)
- [Cactus Compute](https://github.com/cactus-compute/cactus) — cross-platform mobile LLM SDK
- [kotlinllamacpp](https://github.com/ljcamargo/kotlinllamacpp) — llama.cpp Kotlin bindings for Android
- [Maid (Flutter)](https://github.com/Mobile-Artificial-Intelligence/maid) — cross-platform local LLM app
- [Qualcomm OpenCL backend for llama.cpp](https://www.qualcomm.com/developer/blog/2024/11/introducing-new-opn-cl-gpu-backend-llama-cpp-for-qualcomm-adreno-gpu)
