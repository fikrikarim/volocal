# Android LLM Runtime Research

## iOS Baseline

- **Model**: Qwen3.5-2B Q4_K_S (~1.26 GB GGUF)
- **Runtime**: llama.cpp with Metal GPU offload (99 layers)
- **Performance**: ~32 tok/s on iPhone 15 (A16)
- **Config**: 2048 context, 512 batch, ChatML prompt format, non-thinking mode

---

## 1. Runtime Options

### A. llama.cpp (Android/NDK) -- RECOMMENDED

The most mature option. Same codebase as iOS. **Same GGUF models work on both platforms.**

**Performance on Android**:

| Device | Chipset | Model | Quant | Backend | tok/s (decode) |
|--------|---------|-------|-------|---------|---------------|
| Xiaomi 14 Pro | SD 8 Gen 3 | 7B | Q4_0 | CPU | ~10.9 |
| Vivo Pad3 Pro | Dimensity 9300 | 7B | Q4_0 | CPU | ~4.3 |
| Pixel 8 Pro | Tensor G3 | 3B | Q4_K_M | CPU | 11.2 |
| Xiaomi Pad6 Pro | SD 8+ Gen 1 | 7B | Q4_0 | CPU | ~8.7 |
| SD 8 Gen 3 device | Adreno 750 | 7B | Q4_0 | OpenCL | ~6.2 |

For a 2B model (vs 7B above), expect ~2-3x higher tok/s on CPU. **SD 8 Gen 3 should achieve ~20-30 tok/s for Qwen3.5-2B.**

**GPU support**:
- **Vulkan**: Supported but problematic. Adreno GPUs can crash. Mali runs slower than CPU. Performance regressions reported. **Not recommended as primary backend.**
- **OpenCL (Adreno)**: Qualcomm-contributed, optimized for Adreno. Best GPU path for Snapdragon. **Only supports Q4_0, f32, f16, q6_K -- not Q4_K_S.** Need separate Q4_0 quantization for GPU mode.
- **QNN (Hexagon NPU)**: Community-maintained via `llama-cpp-qnn-builder`. 7-10x speedup in dev builds. Only per-tensor/per-channel quantization supported.

**Integration**: Official Android example at `examples/llama.android` with JNI bindings. Community libraries: `llama-cpp-kt`, `kotlinllamacpp`, `java-llama.cpp`, `Ai-Core`.

**Build command**:
```bash
cmake \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-28 \
  -DCMAKE_C_FLAGS="-march=armv8.7a" \
  -DCMAKE_CXX_FLAGS="-march=armv8.7a" \
  -DGGML_OPENMP=OFF \
  -DGGML_LLAMAFILE=OFF \
  -B build-android
```

### B. MNN-LLM (Alibaba) -- STRONG ALTERNATIVE

**Claimed performance** (Xiaomi 14, SD 8 Gen 3):
- CPU: 8.6x faster prefill, 2.3x faster decode vs llama.cpp
- GPU (OpenCL): 25.3x faster prefill, 7.1x faster decode vs llama.cpp

Ships full multimodal Android app supporting Qwen2.5, Qwen3, vision/audio models. OpenCL optimized for both Adreno and Mali. DRAM-Flash hybrid storage reduces memory pressure.

**Trade-off**: Model format conversion needed (from GGUF/HuggingFace to MNN format). Different codebase to maintain.

### C. MLC LLM

Built on TVM compiler infrastructure. Designed for mobile GPUs.

- Adreno 750 (SD 8 Gen 3): ~50+ tok/s prefill, ~8.2 tok/s decode (GPU)
- Mali-G720 (Dimensity 9300): Very poor prefill (~1-2 tok/s)
- First inference can freeze system UI 20-50s due to kernel compilation
- Excellent on Adreno, poor on Mali

### D. LiteRT-LM (Google) -- WATCH CLOSELY

Successor to MediaPipe LLM Inference API. Remarkable benchmarks:
- S24 Ultra (Gemma3-1B, GPU): 1,876.5 tok/s prefill, 44.57 tok/s decode
- S25 Ultra (Gemma3-1B, NPU): 5,836.6 tok/s prefill, 84.8 tok/s decode

Currently alpha (v0.9.0-alpha03). Limited model support. Does not support GGUF. When stable with Qwen support, could become the best option.

### E. ExecuTorch (Meta)

Meta's production framework (1.0 GA, October 2025). Used in Instagram, WhatsApp, Messenger.
- Llama 3.2 1B on S24+ (Arm CPU + KleidiAI): 350+ tok/s prefill
- QNN backend underperforms vs Qualcomm's native solution
- Requires PyTorch export workflow (not GGUF)

### F. ONNX Runtime GenAI (Microsoft)
- Limited mobile benchmarks. Less mature mobile ecosystem.

### G. PowerInfer-2 (Research)
- First to run 47B model on smartphone at 11.68 tok/s
- 27.8x faster than llama.cpp for sparse models
- Research-grade, not production-ready

---

## 2. Comparative Matrix

| Runtime | Decode tok/s (2B, flagship) | GPU | NPU | GGUF | Kotlin/Java | Maturity |
|---------|---------------------------|-----|-----|------|-------------|----------|
| **llama.cpp** | 15-20 (CPU) | OpenCL (Adreno), Vulkan (unstable) | QNN (community) | Native | JNI/JNA libs | Production |
| **MNN-LLM** | 30-45 (est., 2.3x llama.cpp) | OpenCL (optimized) | DRAM-Flash hybrid | Convert | Native app | Production |
| **MLC LLM** | 8-15 (GPU) | OpenCL (Adreno good, Mali poor) | No | Convert | tvm4j | Mature |
| **LiteRT-LM** | 44-85 (GPU/NPU) | Built-in | Qualcomm/MediaTek | No | Kotlin native | Alpha |
| **ExecuTorch** | 10-20 (QNN) | Vulkan, QNN | QNN | No | Java/C++ | GA (1.0) |
| **ONNX RT GenAI** | 5-10 (est.) | NNAPI, XNNPACK | NNAPI | No | Android lib | Mature |

---

## 3. Model Recommendations for Android

### Can Qwen3.5-2B Run on Mid-Range Android?

**Yes.** At 1.26 GB (Q4_K_S), with 1.5x memory multiplier for KV cache/activations, runtime memory is ~1.9 GB. Fits on any device with 6+ GB RAM.

| Tier | Example SoC | Expected tok/s | Viability |
|------|-------------|---------------|-----------|
| Flagship (12+ GB) | SD 8 Gen 3, Dimensity 9300 | 20-30 | Comparable to iPhone 15 |
| Upper mid-range (8 GB) | SD 7+ Gen 2, Dimensity 8300 | 12-18 | Very usable for voice |
| Mid-range (6 GB) | SD 695, Dimensity 7200 | 5-10 | Borderline |
| Low-end | SD 680 | 2-5 | Too slow |

### Adaptive Model Selection

| Device Tier | RAM | Model | Size | Expected tok/s |
|-------------|-----|-------|------|---------------|
| Flagship (12+ GB) | 12-16 GB | Qwen3.5-2B Q4_K_M | 1.4 GB | 20-30 |
| High-end (8 GB) | 8 GB | Qwen3.5-2B Q4_K_S | 1.26 GB | 15-20 |
| Mid-range (6 GB) | 6 GB | Qwen3 1.5B Q4_K_S | ~0.9 GB | 10-15 |
| Entry (4 GB) | 4 GB | Qwen3 0.6B Q4_0 | ~0.4 GB | 8-12 |

### Best Quantization Formats

1. **Q4_K_M**: Best quality/speed balance. 5x throughput of FP16 with only 8.5% perplexity increase.
2. **Q4_K_S**: Slightly smaller, marginally lower quality. Current choice is good.
3. **Q4_0**: Fastest format. **Only format optimized for Adreno OpenCL.** Use when GPU acceleration matters.
4. **Q8_0**: Avoid -- 2x larger with marginal quality improvement.

**Critical note**: For Adreno GPU acceleration via OpenCL, you **must** use Q4_0.

### Key Optimizations
- KV cache q4_0 (instead of f16): ~3x inference speed, minimal quality impact
- `intra_op_num_threads = min(cpu_count, 4)`, `inter_op_num_threads = 1`
- Runtime device detection: `ActivityManager.getMemoryInfo()` for RAM, `Build.SOC_MODEL` for chipset

---

## 4. GPU Acceleration Landscape

### Vulkan Compute
- Available Android 7.0+ (API 24+)
- Cross-platform but **immature for ML inference on mobile**
- Performance varies wildly by GPU vendor and driver version
- ExecuTorch has best Vulkan compute delegate

### OpenCL
- **Adreno (Qualcomm)**: Best supported. Qualcomm actively contributes to llama.cpp OpenCL. Most reliable GPU path.
- **Mali (ARM)**: Poor real-world inference performance. Loading times 7x longer than llama.cpp CPU. ALU utilization is poor.
- **PowerVR**: Minimal support.

### P95 Latency Variance by Chipset

| Chipset | GPU | P95 Variance |
|---------|-----|-------------|
| SD 8 Gen 2 | Adreno 740 | +/-12% (reliable) |
| Tensor G3 | Mali-G715 | +/-15% (acceptable) |
| Dimensity 9200 | Mali-G715 | +/-38% (unreliable) |
| Exynos 2400 | Xclipse 940 | +/-52% (avoid GPU) |

---

## 5. Recommendation

### Primary: llama.cpp (CPU) + Adreno OpenCL Optional

**Rationale**: Maximum code sharing with iOS. Same GGUF models, same inference logic, same prompt templates. The iOS `LlamaContext.swift` maps 1:1 to JNI C++ code.

**Plan**:
1. Cross-compile llama.cpp with Android NDK (ARM64)
2. Use Q4_K_S for CPU inference (existing model works unchanged)
3. Optionally offer Q4_0 variant for Adreno OpenCL GPU acceleration
4. JNI wrapper mirroring Swift actor pattern
5. Adaptive model selection based on device capabilities

**Expected performance**: 15-25 tok/s on flagship Android (vs 32 tok/s on iPhone 15). Acceptable for 1-3 sentence voice responses.

### If CPU Performance Is Insufficient: MNN-LLM

2.3x faster decode than llama.cpp on same hardware. Worth benchmarking. Trade-off: model format conversion and different codebase.

### When Stable: LiteRT-LM

84.8 tok/s decode with NPU on S25 Ultra. Watch for stable release with Qwen support.

---

## Sources

- [On-Device LLMs: State of the Union, 2026](https://v-chandra.github.io/on-device-llms/)
- [LLM Performance Benchmarking on Mobile](https://arxiv.org/html/2410.03613v3)
- [MNN-LLM: Fast LLM Deployment on Mobile](https://arxiv.org/html/2506.10443v1)
- [Qualcomm OpenCL Backend in llama.cpp](https://www.qualcomm.com/developer/blog/2024/11/introducing-new-opn-cl-gpu-backend-llama-cpp-for-qualcomm-adreno-gpu)
- [llama.cpp Android Build Docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md)
- [llama.cpp OpenCL Backend Docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md)
- [llama-cpp-qnn-builder (QNN Backend)](https://github.com/chraac/llama-cpp-qnn-builder)
- [LiteRT-LM GitHub](https://github.com/google-ai-edge/LiteRT-LM)
- [ExecuTorch](https://executorch.ai/)
- [MLC LLM Android SDK](https://llm.mlc.ai/docs/deploy/android.html)
- [Alibaba MNN GitHub](https://github.com/alibaba/MNN)
- [PowerInfer-2](https://powerinfer.ai/v2/)
