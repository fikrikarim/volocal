# Volocal

Fully local voice AI assistant for iOS. Everything runs on-device — no cloud, no API keys, no internet required after model download.

**Speech-to-Text → LLM → Text-to-Speech**, all in real-time on your iPhone.

## Features

- **100% on-device** — all inference runs locally using the Neural Engine, GPU, and CPU
- **Real-time voice pipeline** — speak naturally and get voice responses with low latency
- **Barge-in support** — interrupt the AI mid-sentence by speaking
- **Echo cancellation** — Voice Processing AEC prevents the AI from hearing its own output
- **Automatic model download** — first launch downloads all models (~1.5 GB) with per-model progress

## Models

| Component | Model | Size | Runtime |
|-----------|-------|------|---------|
| STT | [Parakeet EOU 320](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m) | ~200 MB | CoreML (ANE) |
| LLM | [Qwen3.5-2B Q4_K_S](https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF) | ~1.26 GB | llama.cpp (Metal GPU) |
| TTS | [PocketTTS](https://huggingface.co/fluidaudio/pocket-tts) | ~100 MB | CoreML (ANE) |

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
- [FluidAudio](https://github.com/FluidAudio/FluidAudio) — STT (Parakeet EOU) and TTS (PocketTTS) inference

Both are managed via Swift Package Manager.

## License

MIT
