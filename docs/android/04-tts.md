# Android TTS (Text-to-Speech) Research

## iOS Baseline

- **Model**: PocketTTS (Kyutai Labs), 100M params
- **Size**: ~600 MB CoreML
- **Latency**: ~80ms to first audio
- **Output**: 24kHz float32 mono, streaming frames
- **Features**: 8 voices, temperature control (0.4), voice cloning from 5-second clip
- **Runtime**: Apple Neural Engine via CoreML

---

## 1. TTS Engine Comparison

### A. Piper TTS -- PHASE 1 RECOMMENDATION

**Repository**: [github.com/rhasspy/piper](https://github.com/rhasspy/piper) (archived) -> [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl)

| Attribute | Details |
|-----------|---------|
| **Quality** | Good for size. Medium/high models are clearly synthetic but pleasant |
| **Size** | int8 ~22 MB, fp16 ~38 MB, fp32 ~75 MB |
| **Latency** | RTF ~0.19 (fp16), ~0.28 (fp32). Sub-200ms TTFA on modern phone CPUs |
| **Streaming** | Yes -- streams raw PCM to stdout |
| **HW accel** | CPU-only (no GPU/NNAPI needed due to small model) |
| **Cross-device** | Excellent. Runs on RPi, Android. ~500 MB RAM |
| **Voices** | 100+ across 30+ languages |
| **Voice cloning** | No |
| **Sample rate** | 16 kHz (low/x_low) or 22.05 kHz (medium/high) |
| **License** | GPL-3.0 (piper1-gpl) / MIT (original archived) |
| **Android** | Via sherpa-onnx with pre-built APKs and TTS engine integration |

### B. Kokoro-82M

**Repository**: [huggingface.co/hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)

| Attribute | Details |
|-----------|---------|
| **Quality** | Excellent. Ranked #1 on TTS Arena, beating XTTS v2 (467M), MetaVoice (1.2B) |
| **Size** | fp32 ~330 MB, int8 ~128 MB, quantized < 80 MB |
| **Latency** | ~8 seconds for 10s audio on Android smartphones (before optimization). RTF ~1.88 (fp32 CPU) |
| **Streaming** | Partial. 1-2s TTFA with OpenAI-compatible server. Not frame-level native |
| **Cross-device** | Good on desktop/laptop. Slow on mid-range Android |
| **Voices** | 10+ voicepacks, style mixing |
| **Voice cloning** | No |
| **Sample rate** | 24 kHz |
| **License** | Apache 2.0 |
| **Android** | Via sherpa-onnx or [Kokoro-82M-Android](https://github.com/puff-dayo/Kokoro-82M-Android) demo (GPL-3.0) |

### C. PocketTTS ONNX -- PHASE 2 (FEATURE PARITY)

**Repository**: [github.com/KevinAHM/pocket-tts-onnx-export](https://github.com/KevinAHM/pocket-tts-onnx-export)

| Attribute | Details |
|-----------|---------|
| **Quality** | High. Same model as iOS. Natural prosody, good voice cloning fidelity |
| **Size** | FP32 ~475 MB, INT8 ~200 MB (5 ONNX models) |
| **Latency** | ~200ms TTFA on M4 MacBook. RTFx ~4.0x (INT8), ~2.8x (FP32) on 16-core CPU |
| **Streaming** | Yes. Stateful AR with KV-cache. Adaptive chunking |
| **HW accel** | CPU via ONNX Runtime |
| **Voices** | Voice cloning from any audio reference + built-in voices |
| **Voice cloning** | **Yes** -- zero-shot from audio reference |
| **Sample rate** | 24 kHz |
| **License** | MIT |
| **Android** | **sherpa-onnx has added PocketTTS support** |

INT8 model breakdown: flow_lm_main 76 MB, mimi_decoder 23 MB, mimi_encoder 73 MB, flow_lm_flow 10 MB, text_conditioner 16 MB.

On Snapdragon 8 Gen 2 (8 cores), expect RTFx ~1.5-2.5x -- still real-time.

### D. KittenTTS

**Repository**: [github.com/KittenML/KittenTTS](https://github.com/KittenML/KittenTTS)

| Attribute | Details |
|-----------|---------|
| **Quality** | Good for size, rapidly improving |
| **Size** | Nano 15M/25 MB, Micro 40M/41 MB, Mini 80M/80 MB |
| **Latency** | RTF ~0.69 (fp16 Nano on Colab CPU). Struggles on weak ARM cores |
| **Streaming** | Yes |
| **Voices** | 8 built-in |
| **Voice cloning** | Not documented |
| **Sample rate** | 24 kHz |
| **License** | Apache 2.0 |
| **Android** | Via sherpa-onnx (kitten-nano, kitten-mini) |

### E. Matcha-TTS

| Attribute | Details |
|-----------|---------|
| **Quality** | Good. Clean speech, less expressive than AR models |
| **Size** | Acoustic ~71 MB + vocoder (Vocos) ~52 MB = ~123 MB total |
| **Latency** | **Fastest in benchmarks.** RTF ~0.163 (fp32 + vocos). 4.8x speedup with ONNX optimization |
| **Streaming** | Not natively (non-AR generates full utterance) |
| **Voices** | Single-speaker models (LJSpeech, Baker Chinese). Multi-speaker VCTK variant |
| **Voice cloning** | No |
| **Sample rate** | 22.05 kHz |
| **License** | MIT |
| **Android** | Via sherpa-onnx (matcha-icefall models) |

### F. Supertonic (Supertone Inc.)

| Attribute | Details |
|-----------|---------|
| **Quality** | Good at 2-3 inference steps |
| **Size** | 66M params. Ultra-lightweight |
| **Latency** | RTF 0.006 (M4 Pro). **Official Android/iOS examples run "fluently" on 2023+ flagships** |
| **Streaming** | Not documented. Diffusion models generate full utterances |
| **Voices** | 10+ styles (M1-M5, F1-F5) |
| **Voice cloning** | No |
| **Sample rate** | 24 kHz |
| **License** | Open-source via HuggingFace |
| **Android** | **Official Java/Android examples provided** |

### G. NeuTTS Air (Neuphonic)

| Attribute | Details |
|-----------|---------|
| **Quality** | Natural-sounding |
| **Size** | Air ~360M active params, Nano ~120M active |
| **Latency** | Galaxy A25 5G: 20-45 tok/s (Q4_0). Desktop iMac M4: 111-195 tok/s |
| **Streaming** | Yes |
| **Voices** | Voice cloning from 3-second reference |
| **Voice cloning** | **Yes** -- zero-shot from 3-15s clip |
| **Sample rate** | 24 kHz |
| **License** | Air: Apache 2.0, Nano: NeuTTS Open License 1.0 |
| **Android** | No explicit SDK yet. GGUF format suggests llama.cpp-style deployment possible |

### H. Picovoice Orca (Commercial)

| Attribute | Details |
|-----------|---------|
| **Quality** | Production quality. 8 languages |
| **Latency** | **130ms FTTS** (best in class). 210ms voice assistant response time |
| **Streaming** | **True streaming** from LLM token stream |
| **Voice cloning** | No |
| **License** | **Proprietary.** Free tier: 100K chars/month |
| **Android** | Official Android SDK with AudioTrack streaming tutorial |

### I. Others

- **eSpeak-NG**: Formant synthesis, ~2-5 MB, robotic quality. Only useful for accessibility.
- **Android System TTS**: No streaming capability (`TextToSpeech` requires complete text). Not recommended.
- **CosyVoice2-0.5B**: Excellent quality (MOS 5.53), voice cloning, but 0.5B params too large for mobile.
- **Chatterbox Turbo**: 350M params, MIT, beats ElevenLabs in blind tests. No Android SDK.

---

## 2. CPU Speed Benchmarks

From KittenTTS benchmark (Colab CPU, single thread):

| Model | RTF | Size | Notes |
|-------|-----|------|-------|
| **MatchaTTS fp32 + Vocos** | **0.163** | 71+52 MB | Fastest overall |
| **Piper fp16** | **0.192** | 38 MB | Best speed/size ratio |
| Piper fp32 | 0.276 | 75 MB | |
| Piper int8 | 0.523 | 22 MB | Smallest |
| KittenTTS fp16 | 0.693 | 23 MB | |
| Kokoro fp32 | 1.880 | 330 MB | Slowest, highest quality |
| Kokoro int8 | 3.564 | 128 MB | INT8 actually slower |

**RTF < 1.0 = faster than real-time.** On mid-range Android phones (SD 6-series), expect ~2-4x worse than Colab CPU.

---

## 3. Runtime Comparison

### ONNX Runtime Mobile -- RECOMMENDED

- Most TTS models target ONNX format
- NNAPI EP for GPU/NPU delegation
- Size: 10-15 MB default, reducible to 4-5 MB with operator stripping
- Java/Kotlin API: `com.microsoft.onnxruntime:onnxruntime-android`

### sherpa-onnx -- RECOMMENDED FRAMEWORK

- Built on ONNX Runtime, provides complete TTS pipeline for Android
- Pre-built APKs, TTS engine integration
- Supports Piper + Kokoro + VITS + Matcha + KittenTTS + PocketTTS
- C++ core with JNI bridge to Java/Kotlin
- Apache 2.0 license

---

## 4. Streaming Architecture

### Sentence-Level Streaming (matching iOS architecture)

```
LLM tokens -> SentenceBuffer (Kotlin port) -> TTS Engine -> Audio Output
```

1. LLM streams tokens -> `SentenceBuffer` splits at `.!?:;` boundaries
2. Each sentence -> TTS synthesize
3. Each audio frame -> audio output for immediate playback
4. Barge-in: user speech interrupts TTS

### Audio Output Options

**Oboe (C++) -- Lowest latency**
- `PerformanceMode::LowLatency` + `SharingMode::Exclusive`
- Callback-based: `onAudioReady()` on high-priority thread
- Works across Android 4.1+
- Best for frame-by-frame streaming from C++ TTS engines

**AudioTrack (Java/Kotlin) -- Simpler**
- `setPerformanceMode(PERFORMANCE_MODE_LOW_LATENCY)`
- Higher latency than Oboe but simpler from Kotlin
- Streaming mode: write PCM chunks as they arrive

**Oboe via JNI -- Best of both worlds**
- sherpa-onnx already uses this pattern: C++ core + JNI bridge
- TTS inference + audio output both in C++

### Latency Optimizations

1. **Sentence-level pipelining**: Start TTS on first sentence while LLM still generates
2. **Model warmup**: Pre-run dummy inference at startup
3. **Thread tuning**: `intra_op_num_threads = min(cpu_count, 4)`, `inter_op_num_threads = 1` (2x speedup)
4. **Buffer management**: Ring buffer of pre-allocated PCM buffers
5. **INT8 quantization**: ~4x RTFx vs ~2.8x for FP32, negligible quality loss
6. **Prefetch next sentence**: Synthesize N+1 while playing N
7. **Audio buffer size**: Target 10ms on Oboe exclusive mode

---

## 5. Recommendation: Two-Phase Approach

### Phase 1: Ship Fast with Piper via sherpa-onnx

- Proven Android deployment, pre-built APKs
- RTF ~0.2 ensures real-time even on mid-range
- 100+ voices, 30+ languages
- Trade-off: No voice cloning (fixed voice selection)

### Phase 2: PocketTTS ONNX for Feature Parity

- sherpa-onnx has added PocketTTS support
- INT8 quantized ~200 MB with voice cloning, streaming, temperature control
- Same model as iOS = consistent voice quality across platforms
- Test RTFx on target devices (expect ~1.5-4x depending on chipset)
- Fall back to Piper on low-end devices

### Alternative: Supertonic (if voice cloning not critical)

- Official Android Java examples
- 66M params, blazing fast
- No voice cloning

---

## 6. Quality/Speed Trade-offs Summary

| Priority | Model | Quality | Speed | Size | Voice Clone |
|----------|-------|---------|-------|------|-------------|
| Max speed, tiny size | Piper fp16 medium | Good | RTF 0.19 | 38 MB | No |
| Best quality + cloning | PocketTTS INT8 | Excellent | RTFx ~4x | 200 MB | Yes |
| Best quality, no cloning | Kokoro INT8 | Excellent | RTF ~1.9 | 128 MB | No |
| Ultra-tiny | KittenTTS Nano | Fair-Good | RTF 0.69 | 25 MB | No |
| Fastest possible | MatchaTTS + Vocos | Good | RTF 0.16 | 123 MB | No |

---

## Sources

- [Piper TTS GitHub](https://github.com/rhasspy/piper)
- [sherpa-onnx GitHub](https://github.com/k2-fsa/sherpa-onnx)
- [PocketTTS ONNX on HuggingFace](https://huggingface.co/KevinAHM/pocket-tts-onnx)
- [PocketTTS ONNX Export](https://github.com/KevinAHM/pocket-tts-onnx-export)
- [Kokoro-82M Android Demo](https://github.com/puff-dayo/Kokoro-82M-Android)
- [KittenTTS CPU Benchmark](https://github.com/KittenML/KittenTTS/issues/40)
- [Picovoice TTS Latency Benchmark](https://github.com/Picovoice/tts-latency-benchmark)
- [Supertonic TTS](https://github.com/supertone-inc/supertonic)
- [NeuTTS](https://github.com/neuphonic/neutts)
- [Oboe Low Latency Audio](https://developer.android.com/games/sdk/oboe/low-latency-audio)
- [Chatterbox TTS](https://github.com/resemble-ai/chatterbox)
