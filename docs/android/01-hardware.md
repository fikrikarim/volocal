# Android Hardware Requirements for On-Device Voice AI

## 1. Minimum Recommended Specs

### RAM

| Tier | Total RAM | Estimated Available for App | Verdict |
|------|-----------|---------------------------|---------|
| 6 GB | ~1.5-2 GB usable | Not enough for 3 concurrent models | **Not viable** |
| 8 GB | ~2.5-3.5 GB usable | Tight but possible with mmap | **Bare minimum** |
| 12 GB | ~4-6 GB usable | Comfortable headroom | **Recommended** |
| 16 GB+ | ~6-8 GB usable | Plenty | **Ideal for development** |

63% of Android devices globally have 6 GB RAM or less. Android's per-app heap limits are manufacturer-defined and much more restrictive than iOS. However, llama.cpp uses mmap for GGUF files, which maps weights into address space without loading them all into physical RAM -- this is essential. Native (NDK) memory allocations bypass the Java heap limit.

**Recommendation**: Target 8 GB RAM minimum, 12 GB RAM recommended. Android's OS + background services consume more RAM (typically 3-5 GB vs iOS's ~3 GB on a 6 GB device), and Android's low-memory killer is more aggressive.

### SoC / Chipset Generations

**Minimum viable chipsets** (can run all three models):

| Vendor | Minimum Generation | NPU TOPS | GPU | Notes |
|--------|-------------------|----------|-----|-------|
| **Qualcomm** | Snapdragon 8 Gen 2 (2023) | ~12 TOPS | Adreno 740 | First with INT4 NPU support |
| **Qualcomm** | Snapdragon 8 Gen 3 (2024) | ~45 TOPS | Adreno 750 | 98% faster NPU than Gen 2 |
| **Qualcomm** | Snapdragon 8 Elite (2025) | ~75 TOPS | Adreno 830 | Best overall; 4.5x faster LLM than Gen 3 |
| **MediaTek** | Dimensity 9300 (2024) | ~37 TOPS (APU 790) | Immortalis-G720 | Runs LLMs up to 33B (quantized) |
| **MediaTek** | Dimensity 9400 (2025) | ~50+ TOPS (APU 890) | Immortalis-G925 | 80% faster LLM prompts than 9300 |
| **Google** | Tensor G4 (2024) | ~2x G3 TPU | Mali-G715 | 2x throughput for INT4; limited public TPU access |
| **Google** | Tensor G5 (2025) | ~60% over G4 | Samsung RDNA-based | First TSMC 3nm Tensor |
| **Samsung** | Exynos 2400 (2024) | 17 TOPS | Xclipse 940 | Adequate NPU, weaker than Qualcomm/MediaTek |
| **Samsung** | Exynos 2500 (2025) | 59 TOPS | Xclipse (RDNA 4) | Major NPU leap |

**Mid-range capable chipsets** (possible with careful optimization):

| Vendor | Chipset | NPU | GPU | Notes |
|--------|---------|-----|-----|-------|
| **Qualcomm** | Snapdragon 7+ Gen 3 | Hexagon (mid-tier) | Adreno 732 | Tight on headroom |
| **Qualcomm** | Snapdragon 8s Gen 3 | Hexagon (flagship-lite) | Adreno 735 | On-device gen AI support |
| **MediaTek** | Dimensity 8300/8400 | APU 780 | Mali-G615 MC6 | Claims 10B parameter support |

### Storage Considerations

- Model storage: ~2.3 GB (same as iOS)
- Working space: ~500 MB for KV cache, temp files
- Minimum free storage: 4-5 GB recommended
- UFS 3.1+ recommended for fast model loading (mmap performance depends on storage read speed)

---

## 2. Recommended Test Devices (2024-2026)

### Flagship Tier (Primary Development Targets)

| Device | SoC | RAM | GPU | NPU | Price | Why |
|--------|-----|-----|-----|-----|-------|-----|
| **Samsung Galaxy S25 Ultra** | SD 8 Elite | 12 GB | Adreno 830 | ~75 TOPS | ~$1,300 | Best Qualcomm NPU + best llama.cpp OpenCL |
| **Samsung Galaxy S24 Ultra** | SD 8 Gen 3 | 12 GB | Adreno 750 | ~45 TOPS | ~$900 used | Verified Adreno OpenCL support |
| **Google Pixel 10 Pro** | Tensor G5 | 12 GB | RDNA-based | 4th gen TPU | ~$1,000 | Tests Google/Tensor path |
| **Google Pixel 9 Pro** | Tensor G4 | 16 GB | Mali-G715 | Google TPU v3 | ~$700 used | 16 GB RAM is generous |
| **OnePlus 13** | SD 8 Elite | 12-16 GB | Adreno 830 | ~75 TOPS | ~$900 | Excellent thermals; 7300 mAh battery |
| **vivo X200 Pro** | Dimensity 9400 | 16 GB | Immortalis-G925 | APU 890 | ~$800 | Best MediaTek flagship |

### Mid-Range Tier

| Device | SoC | RAM | GPU | NPU | Price | Why |
|--------|-----|-----|-----|-----|-------|-----|
| **Samsung Galaxy A56** | Exynos 2400 | 8-12 GB | Xclipse 940 | 17 TOPS | ~$450 | Tests Exynos path; huge install base |
| **Poco F6 Pro / Redmi K70** | SD 8s Gen 3 | 8-12 GB | Adreno 735 | Hexagon mid | ~$400 | Budget Snapdragon flagship chip |
| **Nothing Phone (3)** | SD 7+ Gen 3 or 8s Gen 3 | 8-12 GB | Adreno 732/735 | Hexagon mid | ~$400-500 | Clean Android |
| **Redmi Note 14 Pro+** | Dimensity 8400 | 8-12 GB | Mali-G720 | APU 780+ | ~$350 | Tests MediaTek mid-range |

### Budget Tier (Questionable Feasibility)

| Device | SoC | RAM | Verdict |
|--------|-----|-----|---------|
| **Samsung Galaxy A35** | Exynos 1380 | 6-8 GB | **Not viable** -- weak NPU, limited RAM |
| **Pixel 8a** | Tensor G3 | 8 GB | **Marginal** -- decent NPU but only 8 GB |
| **Poco X6 Pro** | Dimensity 8300 | 8-12 GB | **Possible** with 12 GB variant |

### Recommended Minimum Dev Device Set

1. **Samsung Galaxy S25 Ultra** (SD 8 Elite) -- primary dev device
2. **Google Pixel 10 Pro** (Tensor G5) -- tests Google/Tensor path
3. **vivo X200 Pro or similar Dimensity 9400** -- tests MediaTek path
4. **Samsung Galaxy A56 or Poco F6 Pro** -- tests mid-range viability

---

## 3. Hardware Fragmentation Challenges

### NPU Access Varies Dramatically

No universal equivalent to Apple's Neural Engine with CoreML.

| Chipset | NPU Access | SDK | Public Access | Maturity |
|---------|-----------|-----|---------------|----------|
| **Qualcomm Hexagon** | QNN SDK (AI Engine Direct) | Free, good docs | Yes | Most mature |
| **MediaTek APU** | NeuroPilot SDK | Requires application | Limited | Good LiteRT integration |
| **Google Tensor TPU** | Private (no public API) | N/A | **No** | Only Google's own apps |
| **Samsung Exynos NPU** | Samsung Neural SDK | Limited | Partially | Least mature for 3rd party |

**Practical implication**: You may need 4 different NPU backends or fall back to CPU/GPU for STT and TTS on unsupported chipsets.

**Google LiteRT** (formerly TFLite) is emerging as the unifying layer -- first-class support for Qualcomm QNN and MediaTek NeuroPilot, with a common `CompiledModel` API. Closest thing to cross-platform NPU abstraction.

### GPU Compute Capabilities

| GPU Family | LLM Backend | Performance | Driver Quality |
|------------|------------|-------------|----------------|
| **Adreno 750/830** (Qualcomm) | OpenCL (official) | Good | Good |
| **Adreno 730 and older** | OpenCL / Vulkan | Mixed | Inconsistent |
| **Immortalis-G925** (ARM) | Vulkan | Best raw compute but poor llama.cpp utilization | Mixed |
| **Mali-G720** (ARM) | Vulkan | Underperforms despite good specs | Poor for ML |
| **Samsung RDNA** (Exynos 2400+) | Vulkan | Good | Good (AMD heritage) |

**Key takeaway**: Adreno GPUs with OpenCL are the safest bet for llama.cpp on Android.

### Memory Management Differences

- **Low-memory killer (LMK)**: Android actively kills background apps when memory is low
- **No guaranteed memory**: Available memory fluctuates based on OEM bloatware and background services
- **Java heap limits**: Typically 256-512 MB. Irrelevant since model loading uses native (NDK) memory
- **mmap is essential**: llama.cpp already uses mmap for GGUF -- OS pages in only what is needed
- **`onTrimMemory` callbacks**: Must handle `TRIM_MEMORY_RUNNING_LOW` (release KV cache) and `TRIM_MEMORY_COMPLETE` (unload models)

### Thermal Throttling

| Chipset | 15-min Sustained | 60-min Sustained | Notes |
|---------|-----------------|------------------|-------|
| **SD 8 Elite** | ~74-83% of peak | ~77% | Good sustained performance |
| **SD 8 Gen 3** | ~70-80% | ~65-70% | Throttles more |
| **Dimensity 9400** | ~75-85% | ~75% | Generally better thermals |
| **Tensor G4** | ~60-70% | ~55-65% | Known for aggressive throttling |
| **Tensor G5** | Improved | ~70% | Better with TSMC 3nm |
| **Exynos 2400** | ~65-75% | ~60% | Samsung fab runs hotter |

Mitigation: Run LLM at lower priority during TTS playback, dynamically reduce batch size under thermal pressure, monitor `PowerManager.THERMAL_STATUS_*` callbacks.

---

## 4. Chipset-Specific ML Acceleration

### Qualcomm QNN / Hexagon DSP
- **TOPS**: 45 (8 Gen 3) to 75+ (8 Elite)
- Most mature mobile AI SDK; official llama.cpp OpenCL backend for Adreno GPU
- QNN supports ONNX Runtime and LiteRT
- Demonstrated 1000+ tok/s prefill on Hexagon NPU
- **Weakness**: OpenCL backend only optimized for Q4_0 (not Q4_K_S)

### MediaTek NeuroPilot
- **TOPS**: 37 (Dimensity 9300) to 50+ (Dimensity 9400)
- Up to 12x CPU / 10x GPU speedup
- LiteRT NeuroPilot Accelerator provides unified API
- **Weakness**: SDK requires application; GPU (Mali) has poor llama.cpp utilization

### Google Tensor TPU
- **No public API for third-party apps.** Only Google's apps can access it directly.
- If you use Gemini Nano as LLM, you get TPU acceleration -- but lose model control
- Third-party must use NNAPI/LiteRT which may or may not delegate to TPU

### Samsung Exynos NPU
- **TOPS**: 17 (Exynos 2400) to 59 (Exynos 2500)
- Least accessible NPU SDK for third-party developers
- Limited documentation

### Recommendation

Target **Qualcomm QNN/Adreno as primary path**. Use **LiteRT as the NPU abstraction layer** (covers Qualcomm + MediaTek). Fall back to **CPU (ARM NEON)** for everything else.

---

## Sources

- [On-Device LLMs: State of the Union, 2026](https://v-chandra.github.io/on-device-llms/)
- [Qualcomm: OpenCL GPU Backend in llama.cpp for Adreno](https://www.qualcomm.com/developer/blog/2024/11/introducing-new-opn-cl-gpu-backend-llama-cpp-for-qualcomm-adreno-gpu)
- [Google LiteRT + Qualcomm NPU](https://developers.googleblog.com/unlocking-peak-performance-on-qualcomm-npu-with-litert/)
- [LLM Performance Benchmarking on Mobile](https://arxiv.org/html/2410.03613v3)
- [MediaTek Dimensity 9400 NPU Benchmark](https://www.gsmarena.com/mediatek_dimensity_9400s_npu_obliterates_the_competition_in_ai_benchmark-news-64856.php)
- [LiteRT NeuroPilot for MediaTek](https://www.marktechpost.com/2025/12/09/google-litert-neuropilot-stack-turns-mediatek-dimensity-npus-into-first-class-targets-for-on-device-llms/)
- [Google Tensor G5 vs G4 Benchmarks](https://gadgets.beebom.com/guides/google-tensor-g5-vs-tensor-g4-benchmark-specs/)
- [Samsung Exynos 2500](https://semiconductor.samsung.com/processor/mobile-processor/exynos-2500/)
- [Snapdragon 8 Elite Benchmarks and Thermals](https://beebom.com/snapdragon-8-elite-benchmarks/)
- [Android Memory Management](https://developer.android.com/topic/performance/memory-overview)
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
- [Geekbench AI and the State of the NPU](https://creativestrategies.com/research/geekbench-ai-and-state-of-npu/)
