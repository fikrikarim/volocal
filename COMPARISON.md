# Locus: Component Comparison & Optimization Research

*Date: 2026-03-15*

---

## Table of Contents

1. [LLM Quantization: Qwen3.5-0.8B GGUF](#1-llm-quantization-qwen35-08b-gguf)
2. [LLM Model Size: Qwen3.5-2B vs 0.8B](#2-llm-model-size-qwen35-2b-vs-08b)
3. [STT: Moonshine Medium Streaming vs Parakeet EOU 120M](#3-stt-moonshine-medium-streaming-vs-parakeet-eou-120m)
4. [TTS: mlx-audio-swift vs FluidAudio](#4-tts-mlx-audio-swift-vs-fluidaudio)
5. [Architecture: Compute Distribution](#5-architecture-compute-distribution)
6. [Recommendations](#6-recommendations)
7. [References](#7-references)

---

## 1. LLM Quantization: Qwen3.5-0.8B GGUF

### Current Setup

- Model: Qwen3.5-0.8B
- Quantization: Q4_K_M (~533 MB)
- Runtime memory: ~600 MB
- Backend: llama.cpp with Metal/GPU offload

### Why Quantization Matters More for Small Models

With only 0.8B parameters, each weight carries more information relative to the total. Quantization to Q4 on a 70B model barely affects quality, but on 0.8B the impact is measurable. The model's benchmark scores (MMLU-Pro 29.7, IFEval 52.1) are already modest — preserving precision matters for coherent voice assistant responses.

### Available Quantizations

| Quant | Provider | File Size | Quality Level | Notes |
|---|---|---|---|---|
| BF16 | - | 1.52 GB | Reference | Full precision |
| Q8_0 | bartowski/unsloth | 812 MB | Extremely high | Negligible quality loss |
| Q6_K_L | bartowski | 730 MB | Very high | Q8_0 embed/output weights |
| Q6_K | bartowski/unsloth | 639-670 MB | Very high | Near perfect |
| UD-Q5_K_XL | unsloth | 607 MB | High | Dynamic 2.0 quant; 12+ community spaces |
| Q5_K_M | bartowski/unsloth | 590-630 MB | High | Strong quality retention |
| Q5_K_L | bartowski | 690 MB | High | Q8_0 embed/output |
| Q4_K_L | bartowski | 620 MB | Good | Q8_0 embed/output |
| UD-Q4_K_XL | unsloth | 559 MB | Good+ | Dynamic quant, better than Q4_K_M |
| **Q4_K_M** | **bartowski/unsloth** | **533 MB** | **Good** | **Current choice** |
| Q4_K_S | bartowski/unsloth | 508 MB | Good | Slightly smaller |
| IQ4_XS | bartowski | 500 MB | Decent | imatrix-based |
| Q3_K_M | bartowski/unsloth | 470 MB | Low | Noticeable quality drop |
| Q2_K | bartowski | 440 MB | Very low | Not recommended for 0.8B |

### Memory Budget Analysis

| Component | Memory |
|---|---|
| STT (Moonshine) | ~125 MB |
| LLM (Q4_K_M, current) | ~600 MB |
| TTS (PocketTTS) | ~230 MB |
| Runtimes + App | ~150 MB |
| **Total** | **~1.1 GB** |
| **iOS limit** | **3.0 GB** |
| **Headroom** | **~1.9 GB** |

### Recommended Upgrade Path

| | Current (Q4_K_M) | Recommended (Q6_K_L) | Alternative (Q5_K_M) |
|---|---|---|---|
| File size | 533 MB | 730 MB | 590 MB |
| Runtime memory | ~600 MB | ~800 MB | ~650 MB |
| Quality | Good | Very high | High |
| Speed impact | baseline | -5-10% (~37 tok/s) | -3% (~39 tok/s) |
| Total app memory | ~1.1 GB | ~1.3 GB | ~1.2 GB |
| Headroom remaining | ~1.9 GB | ~1.7 GB | ~1.8 GB |

**Top picks:**
1. **Q6_K_L** (bartowski) — Near-lossless, Q8_0 embedding/output layers critical for small models
2. **Q6_K** — Excellent quality, 90 MB smaller than Q6_K_L
3. **UD-Q5_K_XL** (unsloth) — Dynamic 2.0 quantization, most popular community choice
4. **Q5_K_M** — Safe conservative upgrade, only ~100 MB more than current

### Non-Thinking Mode Notes

No separate Qwen3.5-0.8B variant exists for non-thinking mode. The base model defaults to non-thinking. For llama.cpp, pre-filling the assistant turn with `<think>\n</think>\n` is the standard technique (already implemented in the app).

The 0.8B model is noted by Qwen as "more prone to entering thinking loops" — the `presence_penalty=2.0` parameter helps, as does the pre-fill approach.

---

## 2. LLM Model Size: Qwen3.5-2B vs 0.8B

### The Question

Is Qwen3.5-2B at a lower quantization (squeezed to fit in memory) better than Qwen3.5-0.8B at a higher quantization (maximizing precision)? This is a critical architecture decision for a voice assistant.

### Benchmark Comparison (Non-Thinking Mode)

The quality gap between 0.8B and 2B is massive:

| Benchmark | 0.8B | 2B | Delta | % Improvement |
|---|---|---|---|---|
| **MMLU-Pro** | 29.7 | 55.3 | +25.6 | **+86%** |
| **MMLU-Redux** | 48.5 | 69.2 | +20.7 | +43% |
| **IFEval** (instruction following) | 52.1 | 61.2 | +9.1 | +17% |
| **SuperGPQA** | 16.9 | 30.4 | +13.5 | +80% |
| **MMMLU** | 34.1 | 56.9 | +22.8 | +67% |
| **C-Eval** | 46.4 | 65.2 | +18.8 | +41% |

For thinking mode (reference only):

| Benchmark | 0.8B | 2B | Delta | % Improvement |
|---|---|---|---|---|
| MMLU-Pro | 42.3 | 66.5 | +24.2 | +57% |
| GPQA | 11.9 | 51.6 | +39.7 | **+334%** |
| IFEval | 44.0 | 78.6 | +34.6 | +79% |
| TAU2-Bench | 11.6 | 48.8 | +37.2 | +321% |

MMLU-Pro nearly doubles from 0.8B to 2B. IFEval (instruction following, critical for a voice assistant) improves by 17%. These gaps are far larger than what quantization degrades.

### Qwen3.5-2B Quantization Options

| Quant | File Size | Est. Runtime Memory | Fits in Budget? |
|---|---|---|---|
| IQ2_M | 840 MB | ~950 MB | Yes |
| Q2_K | 1.00 GB | ~1.1 GB | Yes |
| Q3_K_S | 1.11 GB | ~1.25 GB | Yes |
| **Q3_K_M** | **1.15 GB** | **~1.3 GB** | **Yes** |
| Q3_K_L | 1.19 GB | ~1.35 GB | Yes |
| **Q4_K_S** | **1.26 GB** | **~1.4 GB** | **Yes** |
| Q4_K_M | 1.33 GB | ~1.5 GB | Tight |
| Q5_K_S | 1.43 GB | ~1.6 GB | Risky |
| Q6_K | 1.63 GB | ~1.8 GB | No |
| Q8_0 | 2.02 GB | ~2.2 GB | No |

Memory budget: ~3 GB total iOS limit, minus STT (~125 MB), TTS (~230 MB), runtime (~150 MB) = ~2.5 GB for LLM. Safe working target is ~1.6-1.8 GB for the LLM to avoid jetsam.

Note: Qwen3.5's hybrid DeltaNet/Attention architecture (18 DeltaNet + 6 full attention layers out of 24) has a smaller KV cache than pure transformers. At 2048 context with 6 attention layers: ~6 MB KV cache overhead.

### Head-to-Head: 2B Q4_K_S vs 0.8B Q6_K_L

| Factor | 0.8B Q6_K_L | 2B Q3_K_M | 2B Q4_K_S |
|---|---|---|---|
| MMLU-Pro (est. after quant) | ~29.7 | ~52-55 | ~54-55 |
| IFEval (est. after quant) | ~52.1 | ~59-61 | ~60-61 |
| File size | 730 MB | 1.15 GB | 1.26 GB |
| Runtime memory | ~800 MB | ~1.3 GB | ~1.4 GB |
| Speed (est. tok/s, A17 Pro) | ~55 | ~35 | ~32 |
| 50-token response time | ~1.0s | ~1.5s | ~1.6s |
| Memory safety margin | High | Good | Moderate |
| Quantization risk | Very low | Low | Low |

Q3 quantization typically degrades quality by only 1-5% relative. So even after Q3 quantization, the 2B model (~52-55 MMLU-Pro) vastly outperforms 0.8B at any quantization (~29.7 MMLU-Pro).

### Speed Trade-off

Estimated on iPhone 15/16 (A17/A18, ~40 GB/s memory bandwidth):

| Configuration | File Size | Est. tok/s | Time for 50-token response |
|---|---|---|---|
| 0.8B Q4_K_M (current) | 533 MB | ~70-75 | ~0.7s |
| 0.8B Q6_K_L | 730 MB | ~50-55 | ~1.0s |
| 2B Q3_K_M | 1.15 GB | ~33-35 | ~1.5s |
| **2B Q4_K_S** | **1.26 GB** | **~30-32** | **~1.6s** |
| 2B Q4_K_M | 1.33 GB | ~28-30 | ~1.7s |

For 1-3 sentence voice responses (30-80 tokens), going from ~0.7s to ~1.6s is noticeable but still conversational. The quality improvement is worth this trade-off.

### Arguments For 2B at Lower Quant

- Benchmark gap is enormous (40-86% improvement). Quantization degrades only 1-5%. Net quality is still vastly better.
- For a 2B model, Q3_K_M is not "extreme" — it's within llama.cpp's reliable range. Danger zone is Q2 and below.
- The hybrid DeltaNet/Attention architecture may be more resilient to quantization than pure transformers (linear attention layers have simpler weight structures).
- IFEval 61.2 vs 52.1 means noticeably better instruction following — critical for a voice assistant.

### Arguments For 0.8B at Higher Quant

- Higher per-parameter precision = fewer quantization artifacts (garbled output, repetition, drift).
- ~2x faster inference (55 vs 32 tok/s). Lower latency to first token.
- Less memory pressure = more headroom for longer conversations and OS stability.
- More predictable behavior.

### Thinking Loop Issues

Both 0.8B and 2B model cards contain **identical warnings** about thinking loops. The pre-fill `<think>\n</think>\n` approach and `presence_penalty=2.0` mitigate this equally for both sizes.

### Verdict

**2B Q4_K_S is the recommended choice.** The quality improvement (MMLU-Pro nearly doubles) far outweighs the speed cost (~0.9s slower for a 50-token response). Q4-level quantization is well-proven and reliable.

Optimal strategy:
1. **Primary**: 2B Q4_K_S (1.26 GB, ~1.4 GB runtime) — best quality/memory trade-off
2. **Fallback**: 2B Q3_K_M (1.15 GB, ~1.3 GB runtime) — if Q4_K_S causes memory pressure
3. **Avoid**: Q2_K and below — quality degradation becomes severe at 2-bit for instruction following

---

## 3. STT: Moonshine Medium Streaming vs Parakeet EOU 120M

### Overview

| Dimension | Moonshine Medium Streaming | Parakeet EOU 120M (FluidInference) |
|---|---|---|
| Parameters | 245M | 120M |
| Download size | ~290 MB (7 ONNX files) | Smaller (half params + CoreML quantization) |
| Inference backend | ONNX Runtime (CPU) | CoreML (Apple Neural Engine) |
| Languages | 8 (AR, ZH, EN, JA, KO, ES, UK, VI) | English only |

### Accuracy

| Metric | Moonshine | Parakeet EOU 120M |
|---|---|---|
| English WER | 6.65% | **4.87%** (320ms chunks) / 8.29% (160ms chunks) |
| vs Whisper Large v3 | Beats 7.44% with 6x fewer params | Comparable; 4.87% is strong for 120M |

Parakeet EOU is significantly more accurate in English (4.87% vs 6.65%) with half the parameters.

### Latency

| Metric | Moonshine | Parakeet EOU 120M |
|---|---|---|
| Update interval | Configurable (app uses 300ms) | Configurable: 160ms, 320ms, 1600ms chunks |
| RTFx | Not published | 12.48x at 320ms, 4.78x at 160ms (M2) |
| Cold start | Instant (ONNX loads directly) | ~3.4s CoreML compilation (iPhone 16 Pro Max), ~162ms warm |

Both are well within real-time.

### End-of-Utterance Detection

| Feature | Moonshine | Parakeet EOU 120M |
|---|---|---|
| Mechanism | External VAD (silence-based heuristic) | **Native model-level EOU** (trained to predict end-of-utterance tokens) |
| Accuracy | Relies on silence duration | Semantically aware utterance boundaries |
| Configuration | Via MicTranscriber VAD settings | `eouDebounceMs: 1280` with dedicated `setEouCallback` |

Parakeet's EOU detection is architecturally native — the model is trained to predict end-of-utterance, yielding more semantically meaningful boundaries than silence-based VAD.

### Streaming API

| Feature | Moonshine | Parakeet EOU 120M |
|---|---|---|
| Events | `LineStarted`, `LineTextChanged`, `LineCompleted` | `StreamingEouAsrManager` with incremental `process(audioBuffer:)` |
| VAD | Built-in (Moonshine's own) | Separate Silero VAD v6 (1230x RTFx, 96% accuracy) |

### iOS Performance

| Feature | Moonshine | Parakeet EOU 120M |
|---|---|---|
| Compute target | CPU (ONNX Runtime) | **ANE (Apple Neural Engine)** |
| Power draw | Higher (CPU inference) | **Lower (ANE optimized for sustained ML)** |
| GPU contention | None (CPU) | None (ANE) |
| CPU contention | **Yes — competes with app logic** | None |

### Trade-offs

**Moonshine advantages:**
- Multilingual (8 languages vs English-only)
- Already integrated — no migration work
- No CoreML compilation step on first use
- Broader platform support (Android, RPi, IoT)

**Parakeet EOU advantages:**
- Better English accuracy (4.87% vs 6.65%) at half the parameters
- Runs on ANE (frees CPU and GPU for other tasks)
- Native end-of-utterance detection (model-level, not silence heuristic)
- Lower power consumption
- Same SDK (FluidAudio) handles both STT and TTS

---

## 4. TTS: mlx-audio-swift vs FluidAudio

### Current Setup

- Framework: mlx-audio-swift
- Model: PocketTTS (`mlx-community/pocket-tts`)
- Backend: MLX (Metal/GPU)
- 8 voices: alba, marius, javert, jean, fantine, cosette, eponine, azelma
- Streaming: `generateSamplesStream` → `AudioPlayer.scheduleAudioChunk` with crossfade

### Model Support

| Feature | mlx-audio-swift | FluidAudio |
|---|---|---|
| PocketTTS | Yes (155M, 8 voices) | Yes (155M) |
| Kokoro | No | Yes (82M, **48 voices**, SSML) |
| Other models | Qwen3-TTS, Soprano, VyvoTTS, Orpheus, Marvis TTS | — |
| Total models | 6 | 2 (production-optimized for CoreML) |

### Streaming

| Feature | mlx-audio-swift | FluidAudio |
|---|---|---|
| PocketTTS streaming | Yes (async chunk stream) | Yes (~80ms to first audio) |
| Kokoro streaming | N/A | No (batch generation) |
| First audio latency | Not published | **~80ms** (PocketTTS) |

### Memory and Performance

| Metric | mlx-audio-swift | FluidAudio |
|---|---|---|
| Backend | MLX (Metal/GPU) | **CoreML (ANE)** |
| Kokoro peak RAM | **3.37 GB** | **1.50 GB** (55% less) |
| Kokoro RTFx | 23.8x | 23.2x (nearly identical speed) |
| PocketTTS performance | Not benchmarked | ~80ms to first audio |
| GPU contention | **Competes with llama.cpp for GPU** | **None — runs on ANE** |
| Power draw | Higher (GPU) | Lower (ANE) |

The 55% RAM reduction (3.37 GB → 1.50 GB for Kokoro) is dramatic. For PocketTTS the absolute numbers are smaller, but the compute contention issue remains.

### Dependencies

| | mlx-audio-swift | FluidAudio |
|---|---|---|
| Transitive packages | ~30 (mlx-swift, swift-nio, async-http-client, swift-crypto, swift-certificates, etc.) | Lightweight (CoreML is a system framework) |
| Metal shader compilation | Required (runtime) | Not needed |
| HuggingFace download | Yes (on first use) | Auto-download to `Caches/fluidaudio/` |

### Trade-offs

**mlx-audio-swift advantages:**
- Already integrated and working
- Broader model variety (6 TTS models)
- Well-understood streaming pipeline with crossfade
- Active open-source community (MLX ecosystem)

**FluidAudio advantages:**
- 55% less peak RAM for equivalent models
- Runs on ANE — no GPU contention with llama.cpp
- Lower power consumption for sustained use
- Dramatically fewer SPM dependencies
- Kokoro: 48 voices + SSML pronunciation control
- PocketTTS: published ~80ms first-audio latency
- Single SDK for both STT and TTS

---

## 5. Architecture: Compute Distribution

### Current Architecture (GPU Contention)

| Component | Compute Unit |
|---|---|
| STT (Moonshine) | CPU |
| LLM (llama.cpp) | **GPU/Metal** |
| TTS (mlx-audio-swift) | **GPU/Metal** ← contention |

LLM and TTS compete for the same GPU. When the pipeline is speaking while the LLM is still generating, both fight for Metal compute time. This likely contributes to the "speaking but no audio" hangs.

### Proposed Architecture (No Contention)

| Component | Compute Unit |
|---|---|
| STT (Parakeet EOU) | **ANE** |
| LLM (llama.cpp) | **GPU/Metal** (has GPU to itself) |
| TTS (FluidAudio PocketTTS) | **ANE** |

All three compute units (CPU, GPU, ANE) are utilized. No contention. Lower power. Less memory.

### Memory Impact

| | Current | FluidInference + 0.8B Q6_K_L | FluidInference + 2B Q4_K_S |
|---|---|---|---|
| STT | ~125 MB (Moonshine CPU) | ~80 MB (Parakeet ANE, est.) | ~80 MB (Parakeet ANE, est.) |
| LLM | ~600 MB (0.8B Q4_K_M) | ~800 MB (0.8B Q6_K_L) | ~1.4 GB (2B Q4_K_S) |
| TTS | ~230 MB (PocketTTS MLX) | ~150 MB (PocketTTS CoreML, est.) | ~150 MB (PocketTTS CoreML, est.) |
| Runtime | ~150 MB | ~120 MB (fewer deps) | ~120 MB (fewer deps) |
| **Total** | **~1.1 GB** | **~1.15 GB** | **~1.75 GB** |

The 2B model brings total to ~1.75 GB — still well under the 3 GB limit and feasible thanks to the memory savings from migrating STT/TTS to CoreML/ANE.

---

## 6. Recommendations

### Priority 1: LLM Model Upgrade (Biggest Impact)

Switch from Qwen3.5-0.8B Q4_K_M to **Qwen3.5-2B Q4_K_S**. MMLU-Pro nearly doubles (29.7 → ~55), IFEval improves 17%. The speed cost (~70 → ~32 tok/s) adds ~0.9s to a typical response — acceptable for conversational use. Total app memory goes from ~1.1 GB to ~1.6 GB, still well under the 3 GB limit.

If 2B causes memory pressure: fall back to **2B Q3_K_M** (1.15 GB). If 2B is too slow: use **0.8B Q6_K_L** (730 MB) for near-lossless quality at the current model size.

### Priority 2: TTS Migration to FluidAudio (High Impact)

Migrate from mlx-audio-swift to FluidAudio for TTS. This:
- Eliminates GPU contention with llama.cpp (moves TTS to ANE)
- Reduces TTS memory footprint by ~55%
- Removes ~30 transitive dependencies
- May fix the "speaking but no audio" hangs (GPU contention)
- Frees up memory headroom for the larger 2B LLM

### Priority 3: STT Migration to Parakeet EOU (If English-Only is Acceptable)

Migrate from Moonshine to Parakeet EOU 120M. This:
- Improves English WER from 6.65% to 4.87%
- Halves STT parameters (245M → 120M)
- Moves STT to ANE (frees CPU)
- Adds native end-of-utterance detection
- Uses same FluidAudio SDK as TTS

**Trade-off**: Loses multilingual support (8 languages → English only).

---

## 7. References

### Qwen3.5-0.8B

- Model card: https://huggingface.co/Qwen/Qwen3.5-0.8B
- bartowski GGUF: https://huggingface.co/bartowski/Qwen_Qwen3.5-0.8B-GGUF
- unsloth GGUF: https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF
- lmstudio-community GGUF: https://huggingface.co/lmstudio-community/Qwen3.5-0.8B-GGUF

### Qwen3.5-2B

- Model card: https://huggingface.co/Qwen/Qwen3.5-2B
- bartowski GGUF: https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF
- unsloth GGUF: https://huggingface.co/unsloth/Qwen3.5-2B-GGUF

### Moonshine

- moonshine-swift SPM: https://github.com/moonshine-ai/moonshine-swift
- Moonshine model: https://huggingface.co/usefulsensors/moonshine
- Moonshine paper / benchmarks: https://github.com/usefulsensors/moonshine

### FluidInference

- Documentation: https://docs.fluidinference.com/introduction
- FluidAudio SPM: https://github.com/FluidInference/FluidAudio
- Parakeet EOU benchmark: https://docs.fluidinference.com (STT section)
- Kokoro vs MLX comparison: https://docs.fluidinference.com (TTS section)

### mlx-audio-swift

- Repository: https://github.com/lucasnewman/mlx-audio-swift
- PocketTTS model: https://huggingface.co/mlx-community/pocket-tts
- MLX framework: https://github.com/ml-explore/mlx-swift

### PocketTTS

- Original model: https://github.com/niclas-music/PocketTTS
- MLX port: https://huggingface.co/mlx-community/pocket-tts
