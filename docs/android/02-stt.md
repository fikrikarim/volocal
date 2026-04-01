# Android STT (Speech-to-Text) Research

## iOS Baseline

- **Model**: Parakeet EOU 120M via FluidAudio (CoreML)
- **Size**: ~450 MB
- **WER**: 4.87% (LibriSpeech test-clean)
- **Streaming**: True streaming with 320ms chunks
- **EOU**: Built-in `<EOU>` token, 300ms debounce
- **Runtime**: Apple Neural Engine via CoreML
- **RTF**: 12.48x real-time on iPhone

---

## 1. STT Engine Comparison

### A. sherpa-onnx + Streaming Zipformer -- RECOMMENDED

**Repository**: [github.com/k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)

| Attribute | Details |
|-----------|---------|
| **WER** | 3.15% test-clean, 8.09% test-other (320ms chunks, greedy search) |
| **Model size** | ~253 MB (encoder 250 MB + decoder 2 MB + joiner 1 MB) |
| **Streaming** | True streaming via `OnlineRecognizer` API |
| **EOU detection** | Built-in endpointing with 3 configurable rules |
| **Latency** | RTF 0.04-0.12 on mobile |
| **HW acceleration** | NNAPI (Android 8.1+), Qualcomm QNN EP, XNNPACK |
| **Cross-device** | Excellent. ARM64, ARM32, x86. Tested across all major chipsets |
| **Maintenance** | Very active (releases every few days) |
| **License** | Apache 2.0 |
| **Android API** | Native Kotlin/Java, pre-built APKs, Maven/Gradle |
| **Key stat** | 51x faster than whisper.cpp for same Whisper Tiny model on Android |

**Endpointing rules** (configurable):
1. Silence timeout even without speech (default 2.4s)
2. Trailing silence after speech (default 1.2s) -- **set to 0.3s to match iOS debounce**
3. Max utterance length (default 20s)

**Smaller model option**: `sherpa-onnx-streaming-zipformer-en-20M` -- 20M params, ~24 MB, 3.88% WER. Designed for Cortex A7 (runs on anything).

### B. Moonshine v2 -- STRONG CONTENDER

**Repository**: [github.com/moonshine-ai/moonshine](https://github.com/moonshine-ai/moonshine)

| Model | WER (LS clean) | WER (LS other) | Avg WER | Size (ONNX) |
|-------|---------------|----------------|---------|-------------|
| Tiny (34M) | 4.49% | 12.09% | 12.01% | ~190 MB |
| Small (123M) | 2.49% | 6.78% | 7.84% | ~400 MB |
| Medium (245M) | 2.08% | 5.00% | 6.65% | ~800 MB |

- True streaming via ergodic sliding-window self-attention encoder (v2)
- Response latency: 50ms (Tiny), 148ms (Small), 258ms (Medium) on Apple M3
- **No built-in EOU** -- requires external VAD
- License: MIT
- Available through sherpa-onnx

### C. Whisper.cpp

**Repository**: [github.com/ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)

| Attribute | Details |
|-----------|---------|
| **WER** | Tiny ~7.7%, Small ~4.3% |
| **Size** | Tiny ~31 MB (ggml), Base ~77 MB, Small ~245 MB |
| **Streaming** | **NOT natively streaming** -- must process in chunks |
| **EOU** | None built-in |
| **Android perf** | RTF 3.52 for Tiny on Galaxy S10 -- **51x slower than sherpa-onnx** |
| **HW accel** | ARM NEON only, no NNAPI/NPU on Android |
| **License** | MIT |
| **Verdict** | **Not recommended** for Android real-time streaming |

### D. Google On-Device SpeechRecognizer

| Attribute | Details |
|-----------|---------|
| **Quality** | Varies by device/manufacturer |
| **Size** | Pre-installed |
| **Streaming** | Yes, supports partial results |
| **EOU** | Built-in |
| **Latency** | 150-250ms setup on modern devices, up to 950ms on older |
| **Cross-device** | **Major inconsistency.** Samsung uses own implementation. Some require internet despite "offline" mode |
| **License** | Proprietary (GMS) |
| **Verdict** | **Not recommended** -- no control over model, inconsistent behavior |

### E. Vosk

| Attribute | Details |
|-----------|---------|
| **WER** | ~8-12% (English small) |
| **Size** | Small ~50 MB, Large ~1.8 GB |
| **Streaming** | Yes |
| **Maintenance** | Being superseded by sherpa-onnx (same research group, k2-fsa) |
| **License** | Apache 2.0 |
| **Verdict** | Legacy option. Use sherpa-onnx instead |

### F. Mozilla DeepSpeech
- **Discontinued June 2025. Do not use.**

### G. SenseVoice Small (FunAudioLLM)

| Attribute | Details |
|-----------|---------|
| **Quality** | Excellent for Chinese/Cantonese, good for English |
| **Size** | ~240 MB |
| **Streaming** | Pseudo-streaming only (chunked offline inference) |
| **Latency** | 70ms for 10s audio (15x faster than Whisper Large) -- batch, not streaming |
| **Android** | Available via sherpa-onnx. RTF 0.06 on Galaxy S10 |
| **License** | Apache 2.0 |
| **Verdict** | Great for multilingual batch recognition. Not suitable for true streaming |

---

## 2. Runtime/Inference Engine Comparison

### ONNX Runtime Mobile -- RECOMMENDED

- Best overall for speech models on Android
- Supports NNAPI EP, Qualcomm QNN EP (direct NPU), XNNPACK
- 51x faster than whisper.cpp for same model
- Both sherpa-onnx and Moonshine use it
- AAR adds ~10-15 MB to app

### TensorFlow Lite / LiteRT

- New LiteRT QNN Accelerator: up to 100x CPU speedup on SD 8 Elite NPU
- Fewer speech models available in TFLite format
- Model conversion overhead

### ncnn / MNN
- Limited speech model ecosystem. Not recommended for STT.

### Hardware Delegate Compatibility

| Delegate | Snapdragon | MediaTek | Exynos | Tensor |
|----------|-----------|----------|--------|--------|
| NNAPI | Yes | Yes | Yes | Yes |
| QNN (direct NPU) | Yes (best) | No | No | No |
| LiteRT QNN | Yes | Yes (NeuroPilot) | Partial | Yes |
| XNNPACK (CPU) | Yes | Yes | Yes | Yes |

**Recommendation**: ONNX Runtime with NNAPI default, QNN EP for Snapdragon optimization, XNNPACK fallback.

---

## 3. Can We Use Parakeet on Android?

**No, not with true streaming.** The Parakeet EOU model's cache-aware streaming architecture requires CoreML-specific runtime support. sherpa-onnx confirmed that Parakeet TDT models are "designed as offline transducer models and not architected for true streaming." Pseudo-streaming (re-sending growing buffer) gets progressively slower.

**NexaAI mobile-optimized Parakeet TDT 0.6B v3**: Exists on HuggingFace targeting Qualcomm NPU, but CC BY-NC 4.0 (non-commercial only) and benchmarks are scarce.

---

## 4. End-of-Utterance Detection Strategy

### Option A: sherpa-onnx Built-in Endpointing -- RECOMMENDED

- Uses transducer blank-token trailing silence detection
- Three configurable rules (see above)
- Set `rule2.min-trailing-silence = 0.3` to match iOS 300ms debounce
- Zero additional overhead
- Already integrated into `OnlineRecognizer` Kotlin API

### Option B: Silero VAD (if using non-streaming model)

- Android library: [github.com/gkonovalov/android-vad](https://github.com/gkonovalov/android-vad) (v2.0.10)
- 1.8 MB ONNX model, processes 30ms chunks in ~1ms
- Configurable `silenceDurationMs` (default 300ms) and `speechDurationMs` (default 50ms)
- Very accurate DNN-based detection

### Option C: WebRTC VAD

- Available in same android-vad library
- Only 158 KB, extremely fast
- Lower accuracy than Silero (GMM-based)
- Requires Android API 21+

### Option D: Combined VAD + Non-Streaming Model

If using high-accuracy non-streaming model (SenseVoice, Parakeet TDT):
1. Run Silero VAD continuously to detect speech segments
2. On end of speech, send buffered audio to non-streaming model
3. Higher latency but potentially better accuracy

---

## 5. Summary Comparison

| Solution | WER (LS clean) | Size | True Streaming | EOU Built-in | Android RTF | License |
|----------|---------------|------|----------------|-------------|-------------|---------|
| **sherpa-onnx + Zipformer** | **3.15%** | ~253 MB | Yes | Yes | 0.07-0.12 | Apache 2.0 |
| Moonshine v2 Small | 2.49% | ~400 MB | Yes | No (need VAD) | ~0.05-0.10 | MIT |
| Moonshine v2 Tiny | 4.49% | ~190 MB | Yes | No (need VAD) | 0.05 | MIT |
| Whisper Tiny (sherpa-onnx) | ~7.7% | ~100 MB | Pseudo | No | 0.07 | MIT |
| Whisper Tiny (whisper.cpp) | ~7.7% | ~31 MB | Pseudo | No | 3.52 | MIT |
| Google SpeechRecognizer | Varies | Pre-installed | Yes | Yes | Varies | Proprietary |
| Vosk | ~8-12% | 50-1800 MB | Yes | Basic | Moderate | Apache 2.0 |
| SenseVoice Small | Good | ~240 MB | Pseudo | No | 0.06 | Apache 2.0 |

## Recommendation

**Start with sherpa-onnx + Streaming Zipformer** for closest parity with iOS Parakeet EOU:
- True streaming (chunk-by-chunk processing)
- Built-in endpoint detection (via blank-token silence)
- Similar chunk size (320ms)
- Similar debounce (configurable trailing silence)
- ~253 MB model (vs ~450 MB on iOS)
- WER 3.15% (vs 4.87% on iOS) -- actually better
- Kotlin/Java API ready

---

## Sources

- [sherpa-onnx GitHub](https://github.com/k2-fsa/sherpa-onnx)
- [Moonshine GitHub](https://github.com/moonshine-ai/moonshine)
- [Moonshine v2 Paper](https://arxiv.org/html/2602.12241v1)
- [VoicePing Offline Benchmark (16 models)](https://voiceping.net/en/blog/research-offline-speech-transcription-benchmark/)
- [sherpa-onnx Streaming Zipformer Models](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html)
- [sherpa-onnx Android Documentation](https://k2-fsa.github.io/sherpa/onnx/android/index.html)
- [sherpa-onnx Endpointing Configuration](https://k2-fsa.github.io/sherpa/python/streaming_asr/endpointing.html)
- [android-vad (Silero/WebRTC VAD)](https://github.com/gkonovalov/android-vad)
- [Parakeet TDT Streaming Limitation (sherpa-onnx issue #2918)](https://github.com/k2-fsa/sherpa-onnx/issues/2918)
- [Icefall Streaming Zipformer WER Results](https://github.com/k2-fsa/icefall/blob/master/egs/librispeech/ASR/RESULTS.md)
