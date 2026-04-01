# Volocal Android Port: Research Overview

> Research conducted 2026-03-26. Covers hardware requirements, runtime selection, audio architecture, and app design for porting Volocal from iOS to Android.

## Documents

| Doc | Topic |
|-----|-------|
| [01-hardware.md](01-hardware.md) | Android hardware requirements, recommended test devices, chipset ML acceleration |
| [02-stt.md](02-stt.md) | Speech-to-Text engine comparison, runtime benchmarks, EOU detection strategy |
| [03-llm.md](03-llm.md) | LLM runtime comparison, llama.cpp on Android, GPU acceleration landscape |
| [04-tts.md](04-tts.md) | Text-to-Speech engine comparison, streaming architecture, audio output pipeline |
| [05-audio.md](05-audio.md) | Audio capture/playback, echo cancellation, barge-in implementation |
| [06-architecture.md](06-architecture.md) | App architecture, tech stack, memory management, build system, testing |

## iOS Baseline (What We're Porting)

```
Mic -> [SharedAudioEngine] -> STTManager -> VoicePipeline -> LLMManager -> SentenceBuffer -> TTSManager -> Speaker
                                                ^                                              |
                                                +---- barge-in (interrupt on speech) ----------+
```

| Component | iOS Model | Size | Chip | Runtime |
|-----------|-----------|------|------|---------|
| STT | Parakeet EOU 320 | ~450 MB | Neural Engine (ANE) | CoreML via FluidAudio |
| LLM | Qwen3.5-2B Q4_K_S | ~1.26 GB | GPU (Metal) | llama.cpp |
| TTS | PocketTTS | ~600 MB | Neural Engine (ANE) | CoreML via FluidAudio |

- Total model size: ~2.3 GB, runtime memory: ~1.2 GB
- Target: iPhone 15+ (A16, 6 GB RAM, ~3 GB available for app)
- Key iOS advantage: ANE lets STT and TTS run on dedicated silicon while LLM has exclusive GPU access via Metal

## Recommended Android Stack (Summary)

| Component | iOS (Current) | Android (Recommended) |
|-----------|--------------|----------------------|
| STT | Parakeet EOU via FluidAudio (CoreML/ANE) | **Streaming Zipformer via sherpa-onnx** (ONNX Runtime) |
| LLM | Qwen3.5-2B via llama.cpp (Metal GPU) | **Qwen3.5-2B via llama.cpp** (Vulkan/OpenCL/CPU) |
| TTS | PocketTTS via FluidAudio (CoreML/ANE) | **Phase 1: Piper via sherpa-onnx** / Phase 2: PocketTTS ONNX |
| Audio | AVAudioEngine + VP AEC | **Oboe (C++) + VoiceCommunication AEC** |
| UI | SwiftUI | **Jetpack Compose** |
| State | ObservableObject + @Published | **ViewModel + StateFlow** |
| Async | Swift async/await + Task | **Kotlin coroutines + Job** |
| DI | N/A | **Koin** |
| Downloads | URLSession | **WorkManager + OkHttp** |
| Storage | Documents directory | **context.filesDir** |

## Hardware Requirements

- **Minimum**: 8 GB RAM, Snapdragon 8 Gen 2 / Dimensity 9300
- **Recommended**: 12 GB RAM, Snapdragon 8 Elite / Dimensity 9400
- **Budget tier**: Not viable (< SD 8s Gen 3 cannot reliably run all 3 models)

## Biggest Challenges vs iOS

| Challenge | Severity | Mitigation |
|-----------|----------|------------|
| No unified NPU API (vs CoreML) | High | ONNX Runtime + NNAPI abstraction, CPU fallback |
| AEC quality varies by device | High | Platform AEC + WebRTC AECm fallback |
| GPU inference fragmented | Medium | CPU default for LLM, optional OpenCL for Adreno |
| No PocketTTS port | Medium | Piper first, PocketTTS ONNX via sherpa-onnx later |
| Memory pressure (aggressive LMK) | Medium | Foreground service + mmap + onTrimMemory |
| Thermal throttling varies | Low | Monitor thermal state, reduce batch size |

## Estimated Engineering Effort

- iOS codebase: ~2,200 lines of Swift
- Android estimate: ~4,000-6,000 lines of Kotlin + ~1,000-2,000 lines of C++ (JNI, audio)
- Software ecosystem fragmentation means 3-5x more engineering effort than the iOS version
- sherpa-onnx handles the heaviest lift (STT + TTS with pre-built Android bindings)
- llama.cpp's Android support is mature with an official example app
- Hardest part: getting audio/AEC right across diverse devices
