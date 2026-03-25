# Volocal

Fully local voice AI assistant for iOS. Everything runs on-device — no cloud, no API keys, no internet required after model download.

**Speech-to-Text → LLM → Text-to-Speech**, all in real-time on your iPhone.

## Features

- **100% on-device** — all inference runs locally using the Neural Engine, GPU, and CPU
- **Real-time voice pipeline** — speak naturally and get voice responses with low latency
- **Barge-in support** — interrupt the AI mid-sentence by speaking
- **Echo cancellation** — Voice Processing AEC prevents the AI from hearing its own output
- **Automatic model download** — first launch downloads all models (~1.5 GB) with per-model progress

## Why This Stack

Running three models simultaneously on a phone means every component competes for the same limited hardware. The key insight behind Volocal's architecture is **distributing compute across all three silicon units** — CPU, GPU, and Neural Engine — so nothing contends.

### Compute distribution

| Component | Compute | Why |
|-----------|---------|-----|
| **STT** (Parakeet EOU) | Neural Engine | CoreML, frees CPU and GPU entirely |
| **LLM** (Qwen3.5-2B) | GPU (Metal) | llama.cpp with full Metal offload, has the GPU to itself |
| **TTS** (PocketTTS) | Neural Engine | CoreML, shares ANE with STT but they rarely overlap |

We originally used [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) for TTS, which runs on the GPU via MLX. This caused GPU contention with the LLM — both fought for Metal compute time during streaming, leading to audio dropouts and hangs. Switching TTS (and STT) to [FluidAudio](https://github.com/FluidInference/FluidAudio) moved both to the Neural Engine via CoreML, giving the LLM exclusive GPU access. This also cut TTS memory by ~55%.

### Model choices

| Component | Model | Size | Runtime |
|-----------|-------|------|---------|
| STT | [Parakeet EOU 320](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml) | ~200 MB | CoreML (ANE) |
| LLM | [Qwen3.5-2B Q4_K_S](https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF) | ~1.26 GB | llama.cpp (Metal GPU) |
| TTS | [PocketTTS](https://huggingface.co/FluidInference/pocket-tts-coreml) | ~100 MB | CoreML (ANE) |

- **Parakeet EOU** over Moonshine/Whisper: 4.87% WER (vs 6.65% Moonshine) at half the parameters, with native end-of-utterance detection built into the model (no separate VAD needed).
- **Qwen3.5-2B** over 0.8B: MMLU-Pro nearly doubles (29.7 → 55.3). The speed cost (~70 → ~32 tok/s) adds ~0.9s to a typical response — worth it for noticeably better conversation quality. Q4_K_S at 1.26 GB fits comfortably in the ~3 GB iOS memory budget.
- **PocketTTS**: Best speech quality at 100M params (1.84% WER, lower than models 7x larger), with voice cloning from 5 seconds of reference audio and ~80ms time-to-first-audio.

### Audio architecture

A single `AVAudioEngine` is shared by STT and TTS, with `setVoiceProcessingEnabled(true)` on both input and output nodes. This enables Apple's hardware acoustic echo cancellation (AEC), so the AI doesn't hear its own voice — critical for barge-in to work without a speaking gate that would block the microphone.

Total memory footprint: ~1.2 GB (well under the ~3 GB iOS app limit on iPhone 15).

## Requirements

- iOS 17.0+
- iPhone with A16 chip or later (iPhone 15+)
- [Xcode 16+](https://developer.apple.com/xcode/)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
## Getting Started

1. **Clone the repo:**
   ```bash
   git clone https://github.com/fikrikarim/volocal.git
   ```

2. **Generate the Xcode project:**
   ```bash
   cd volocal
   xcodegen generate
   ```

3. **Open in Xcode:**
   ```bash
   open Volocal.xcodeproj
   ```

4. **Build and run** on a physical device (Neural Engine is not available in the simulator).

5. On first launch, tap **Download All Models** to fetch the models (~1.5 GB over Wi-Fi recommended).

## Architecture

```
Mic → [SharedAudioEngine] → STTManager → VoicePipeline → LLMManager → SentenceBuffer → TTSManager → Speaker
                                              ↑                                              |
                                              └──── barge-in (interrupt on speech) ──────────┘
```

**SharedAudioEngine** — single `AVAudioEngine` shared by STT and TTS with Voice Processing enabled on both input and output nodes for hardware echo cancellation.

**VoicePipeline** — orchestrates the full loop. Handles turn-taking with revision guards to prevent stale tasks after barge-in. Streams LLM tokens through a sentence buffer for incremental TTS.

**SentenceBuffer** — splits streaming LLM output into speakable sentences at natural boundaries (`.!?:;`) with a 200-character max to keep TTS latency low.

## Project Structure

```
Volocal/
├── App/                  # App entry point, content view, model loading screen
├── Audio/                # SharedAudioEngine (single AVAudioEngine + VP AEC)
├── STT/                  # Speech-to-text (Parakeet EOU via FluidAudio)
├── LLM/                  # Language model (llama.cpp via llama.swift)
├── TTS/                  # Text-to-speech (PocketTTS via FluidAudio)
├── Pipeline/             # Voice pipeline orchestration, sentence buffer, UI
├── Models/               # Model registry, download manager, onboarding UI
└── Debug/                # System metrics overlay (RAM, CPU, thermal)
```

## Dependencies

- [llama.swift](https://github.com/mattt/llama.swift) — Swift bindings for llama.cpp
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — STT (Parakeet EOU) and TTS (PocketTTS) inference

Both are managed via Swift Package Manager.

## License

MIT
