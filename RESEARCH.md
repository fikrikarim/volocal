# Locus: Fully Local Realtime Voice AI on iPhone 15
## Feasibility Research

---

## 1. iPhone 15 Hardware Constraints

| Spec | iPhone 15 (A16 Bionic) | iPhone 15 Pro (A17 Pro) |
|---|---|---|
| Process | TSMC 4nm | TSMC 3nm |
| CPU | 6 cores (2P + 4E) | 6 cores (2P + 4E) |
| GPU | 5 cores | 6 cores |
| Neural Engine | 16 cores, ~17 TOPS | 16 cores, ~35 TOPS |
| RAM | 6 GB LPDDR5 | 8 GB LPDDR5 |
| App memory budget | ~2.5–3.5 GB | ~3.5–4.5 GB |

**Key takeaway:** The base iPhone 15 has ~3 GB usable by an app. All three models (ASR + LLM + TTS) must fit within this budget simultaneously. CoreML supports memory-mapped model files which helps, and Apple's unified memory means no CPU↔GPU copy overhead.

**Practical model size limits (4-bit quantized):**
- iPhone 15: up to ~1.5 GB total model weight comfortably
- iPhone 15 Pro: up to ~2.5 GB total model weight comfortably

---

## 2. ASR: Speech-to-Text

### Parakeet (NVIDIA) — NOT RECOMMENDED for mobile

- **Size:** 600M parameters (~670 MB int8, ~2.5 GB fp32)
- **Architecture:** Conformer encoder + Token-and-Duration Transducer (TDT) decoder
- **Quality:** State-of-the-art WER on English benchmarks
- **Problem for mobile:** Too large. The int8 model is ~670 MB and needs ~2 GB RAM. No official CoreML/iOS support. ONNX export exists but is community-maintained. Would consume a disproportionate share of the memory budget.
- **Verdict:** Server-side model. Not practical for on-device iPhone use.

### Recommended: Moonshine v2 Tiny (Useful Sensors)

- **Size:** ~27M parameters (~50 MB ONNX)
- **Speed:** 50ms latency (5.8x faster than Whisper Tiny), real-time streaming
- **Quality:** 48% lower WER than Whisper Tiny; matches or outperforms Whisper Medium (28x larger)
- **iOS support:** Available via sherpa-onnx with CoreML backend
- **Streaming:** Yes — designed for live transcription with Moonshine v2's ergodic streaming encoder
- **Languages:** English primary; multilingual variants available (Arabic, Chinese, Japanese, Korean, etc.)

### Alternative: WhisperKit (Whisper via CoreML)

WhisperKit by Argmax is the most production-ready Whisper deployment for iOS, with **5.2M monthly downloads**. It provides optimized CoreML packages for the Apple Neural Engine.

- **Whisper Tiny:** 39M params, 77 MB (CoreML) — very fast but lower quality
- **Whisper Base:** 74M params, 147 MB (CoreML) — good speed/quality balance
- **Whisper Small:** 244M params, 216 MB (CoreML quantized) — excellent quality (WER ~3.4% clean)
- WhisperKit adds streaming capabilities, custom vocabulary, and speaker diarization
- Swift Package Manager integration — easiest iOS deployment path

### Alternative: Sherpa-ONNX Streaming Zipformer 20M

- **Size:** ~20M params, ~44 MB (int8 ONNX)
- True real-time streaming (no chunking needed)
- Smallest streaming ASR model available
- Lower accuracy than Whisper/Moonshine

### ASR Recommendation

**Moonshine v2 Tiny** is the top pick for lowest latency + smallest footprint:
- Smallest footprint (~50 MB)
- Fastest inference (50ms latency, real-time streaming)
- Better accuracy than Whisper models many times its size
- Native sherpa-onnx integration with CoreML support

**WhisperKit (Whisper Small, quantized 216 MB)** is the safest production choice:
- Most mature iOS ecosystem (5.2M downloads, Swift package)
- Best accuracy among small models (WER ~3.4%)
- Optimized for Apple Neural Engine
- Slightly larger and higher latency than Moonshine

---

## 3. LLM: Language Model

### Qwen3.5-0.8B — GOOD CHOICE

- **Size:** 0.8B parameters
  - Q4_K_M: ~500 MB disk
  - Q8: ~900 MB disk
- **Architecture:** Hybrid with Gated Delta Networks + sparse MoE for efficient inference
- **Multimodal:** Natively multimodal (text + vision), though vision adds size
- **Speed estimate on A16:** ~15–25 tokens/sec (Q4_K_M via llama.cpp with Metal)
- **Memory:** ~600–800 MB runtime (Q4_K_M)
- **Quality:** Strong for its size class; matches larger Qwen3 models on many benchmarks
- **iOS deployment:** llama.cpp supports Qwen architecture with Metal acceleration

### Alternatives Considered

| Model | Params | Q4 Size | Estimated t/s (A16) | Notes |
|---|---|---|---|---|
| **Qwen3.5-0.8B** | 0.8B | ~500 MB | ~15–25 | Best quality/size ratio, multimodal |
| Gemma 3 1B | 1B | ~600 MB | ~12–20 | Good quality, Google distillation |
| Llama 3.2 1B | 1.2B | ~700 MB | ~12–18 | Most tunable, largest ecosystem |
| SmolLM2 1.7B | 1.7B | ~1 GB | ~10–15 | Specialized math/code data |
| Phi-4-mini 3.8B | 3.8B | ~2.2 GB | ~8–12 | Higher quality but too large for base iPhone 15 |

### LLM Recommendation

**Qwen3.5-0.8B at Q4_K_M** is a solid choice:
- Fits comfortably in memory (~500 MB)
- Fast enough for perceived real-time (~15–25 t/s)
- Best benchmark scores in the sub-1B class
- Good llama.cpp support

**Alternative worth considering:** Llama 3.2 1B if you plan to fine-tune for a specific use case (largest fine-tuning ecosystem).

---

## 4. TTS: Text-to-Speech

### Pocket TTS (Kyutai) — EXCELLENT CHOICE

- **Size:** 100M parameters (90M generative + 10M codec decoder)
  - Disk: ~200–400 MB (depending on precision)
- **Architecture:** Continuous Audio Language Models (CALM) — predicts audio directly without discrete tokenization
- **Speed:** RTF ~0.17 on M4 CPU (6x faster than real-time, 2 cores, no GPU)
- **Latency:** First audio chunk in ~200ms, sub-50ms for subsequent chunks
- **Quality:** Lowest WER (1.84%) among competitors including 7x larger models
- **Voice cloning:** Yes — 5 seconds of reference audio
- **iOS deployment:** Community ONNX export available; also has Rust/WASM port. MLX backend for Apple Silicon exists (macOS only, but ONNX path works for iOS)
- **Streaming:** Yes — produces audio chunks incrementally

### Alternatives Considered

| Model | Params | Size | RTF (CPU) | Quality | iOS Ready |
|---|---|---|---|---|---|
| **Pocket TTS** | 100M | ~200–400 MB | 0.17 (6x RT) | Excellent (1.84% WER) | ONNX ✓ |
| Kokoro-82M | 82M | ~80 MB (q8) | Fast (~96x RT on GPU, ~1x on mobile CPU) | Very good | ONNX ✓, sherpa-onnx ✓ |
| Piper (high) | ~60M | ~100 MB | Very fast | Good | ONNX ✓, sherpa-onnx ✓ |
| Piper (medium) | ~30M | ~60 MB | Fastest | Decent | ONNX ✓, sherpa-onnx ✓ |
| Sesame CSM-1B | 1B | ~2–4 GB | Slow | Excellent | Too large |

### TTS Recommendation

**Pocket TTS** is the best choice if you want top quality + voice cloning:
- Best-in-class speech quality at 100M params
- Real-time on CPU (no GPU needed)
- Voice cloning from 5 seconds of audio
- Streaming output for low latency

**Kokoro-82M** is the safer/easier alternative:
- Smaller after quantization (~80 MB)
- Already integrated into sherpa-onnx (easier iOS deployment)
- ~10 sec generation takes ~8 sec on smartphone (borderline real-time)
- No voice cloning

**Piper** is the fallback if memory is very tight:
- Smallest footprint (60–100 MB)
- Most mature mobile deployment story via sherpa-onnx
- Lower quality than Pocket TTS or Kokoro

---

## 5. Full Pipeline: Memory & Latency Budget

### Memory Budget (iPhone 15, ~3 GB available)

| Component | Model | Size in RAM |
|---|---|---|
| ASR | Moonshine v2 Tiny | ~50–80 MB |
| LLM | Qwen3.5-0.8B Q4_K_M | ~600–800 MB |
| TTS | Pocket TTS | ~200–400 MB |
| Runtime overhead | sherpa-onnx + llama.cpp + app | ~100–200 MB |
| **Total** | | **~950 MB – 1.5 GB** |

**Verdict: FITS COMFORTABLY.** Even in the worst case, the pipeline uses less than half the available app memory. Leaves room for audio buffers, UI, and OS overhead.

### Latency Budget (target: <2 seconds end-to-end)

| Stage | Estimated Latency |
|---|---|
| VAD (end-of-speech detection) | ~200–300 ms |
| ASR (Moonshine streaming) | ~50–300 ms |
| LLM first token | ~200–500 ms |
| TTS first audio chunk | ~200 ms |
| **Total to first audio** | **~650 ms – 1.3 s** |

**Verdict: ACHIEVABLE.** With streaming pipeline (ASR→LLM→TTS all streaming), the user hears the first word of the response within ~1 second. This feels real-time for a voice assistant.

### Critical: Streaming Pipeline Design

```
Mic → [VAD] → [Moonshine Streaming ASR] → partial text
                                              ↓
                                    [Qwen3.5-0.8B via llama.cpp]
                                              ↓ streaming tokens
                                    [buffer until sentence boundary]
                                              ↓
                                    [Pocket TTS] → Speaker
```

Each stage streams into the next. Don't wait for full transcription before starting LLM, and don't wait for full LLM output before starting TTS.

---

## 6. Deployment Approach

### Native iOS App (RECOMMENDED)

- **LLM:** llama.cpp with Metal GPU acceleration — proven on iOS, active community
- **ASR + TTS:** sherpa-onnx — has iOS examples, CocoaPods/SPM support, CoreML backend
- **Pocket TTS:** ONNX export → run via ONNX Runtime with CoreML execution provider
- **Existing references:** LLM Farm app (open-source iOS LLM runner), sherpa-onnx iOS examples

### WebApp (NOW VIABLE but harder)

- **WebGPU:** Enabled by default in iOS 26 / Safari 26 (shipping 2026). Previously unavailable on iOS.
- **Before iOS 26:** Only WASM CPU inference — 3-10x slower than native, impractical for LLMs
- **With iOS 26 WebGPU:** Running LLMs in browser becomes viable via web-llm or Transformers.js
- **Pocket TTS:** Already has WASM/browser ports (wasm-pocket-tts, ONNX Runtime Web)
- **Tradeoff:** Simpler distribution (no App Store) but ~30-50% slower than native, less control over memory

### Recommendation

**Start with native iOS app** for best performance and reliability. The WebApp path is now viable with iOS 26 WebGPU but will always be slower than native.

---

## 7. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Thermal throttling | 20–40% perf drop after 30–60s sustained use | Short interactions; adaptive quality |
| iOS memory kills (Jetsam) | App crash | Memory-mapped models; aggressive cleanup; stay under 2 GB |
| LLM quality (0.8B) | Weak reasoning vs cloud models | Fine-tune for your use case; keep scope narrow |
| Pocket TTS iOS integration | No official iOS SDK yet | Use ONNX export path; fallback to Kokoro/Piper via sherpa-onnx |
| Battery drain | Heavy sustained inference | Limit session length; optimize idle state |

---

## 8. Recommended Stack (Final)

| Component | Primary Choice | Fallback |
|---|---|---|
| **ASR** | Moonshine v2 Tiny (~50 MB) | WhisperKit Small quantized (~216 MB CoreML) |
| **LLM** | Qwen3.5-0.8B Q4_K_M (~500 MB) | Llama 3.2 1B Q4_K_M (~700 MB) |
| **TTS** | Pocket TTS via ONNX (~200-400 MB) | Kokoro-82M via sherpa-onnx (~80 MB) |
| **LLM Runtime** | llama.cpp (Metal) | — |
| **ASR/TTS Runtime** | sherpa-onnx (CoreML) | ONNX Runtime directly |
| **Platform** | Native iOS (Swift) | WebApp (iOS 26+ with WebGPU) |

### Total Memory: ~1–1.5 GB (well within iPhone 15's ~3 GB app budget)
### Expected Latency: ~0.7–1.3 seconds to first audio response
### Feasibility: ✅ FEASIBLE

---

## 9. Sources

### iPhone 15 / iOS ML
- [Apple CoreML On-Device Llama](https://machinelearning.apple.com/research/core-ml-on-device-llama)
- [Practical GGUF Quantization Guide for iPhone and Mac](https://enclaveai.app/blog/2025/11/12/practical-quantization-guide-iphone-mac-gguf/)
- [On-Device LLMs: State of the Union, 2026](https://v-chandra.github.io/on-device-llms/)

### ASR Models
- [Moonshine GitHub](https://github.com/moonshine-ai/moonshine)
- [Moonshine v2 Paper](https://arxiv.org/html/2602.12241)
- [Offline Speech Transcription Benchmark (VoicePing)](https://voiceping.net/en/blog/research-offline-speech-transcription-benchmark/)
- [NVIDIA Parakeet TDT 0.6B](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [Best Open Source STT Models 2026 (Northflank)](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
- [WhisperKit CoreML Models (Argmax)](https://huggingface.co/argmaxinc/whisperkit-coreml)
- [Parakeet ONNX Community Export](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx)
- [Sherpa-ONNX Streaming Zipformer 20M](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17)

### LLM Models
- [Qwen3.5-0.8B on HuggingFace](https://huggingface.co/Qwen/Qwen3.5-0.8B)
- [Qwen3.5 on Ollama](https://ollama.com/library/qwen3.5:0.8b)
- [Qwen Speed Benchmarks](https://qwen.readthedocs.io/en/latest/getting_started/speed_benchmark.html)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [Small LLM Benchmark Comparison (DistilLabs)](https://www.distillabs.ai/blog/we-benchmarked-12-small-language-models-across-8-tasks-to-find-the-best-base-model-for-fine-tuning)

### TTS Models
- [Pocket TTS GitHub](https://github.com/kyutai-labs/pocket-tts)
- [Pocket TTS Technical Report](https://kyutai.org/pocket-tts-technical-report)
- [Pocket TTS Blog Post](https://kyutai.org/blog/2026-01-13-pocket-tts)
- [Kokoro-82M ONNX](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX)
- [Kokoro On-Device Guide](https://www.nimbleedge.com/blog/how-to-run-kokoro-tts-model-on-device/)
- [Piper TTS](https://github.com/rhasspy/piper)

### Deployment
- [sherpa-onnx (k2-fsa)](https://github.com/k2-fsa/sherpa-onnx)
- [WebGPU in iOS 26](https://appdevelopermagazine.com/webgpu-in-ios-26/)
- [Safari 26 Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-26-release-notes)
- [Running Pocket TTS in Browser](https://dev.to/soasme/running-text-to-speech-fully-in-the-browser-with-pockettts-2b0m)
