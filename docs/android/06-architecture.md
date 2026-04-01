# Android App Architecture & Tech Stack

## 1. Language Choice: Kotlin + C++/NDK Hybrid

### What Stays in Kotlin
- All UI (Jetpack Compose)
- State management (ViewModel + StateFlow)
- Pipeline orchestration (VoicePipeline equivalent)
- Model download management
- Application lifecycle

### What Needs C++ / NDK
- **LLM inference**: llama.cpp compiles natively via CMake. Official Android example with JNI bindings.
- **Audio I/O**: Oboe (C++) for low-latency, deterministic audio.
- **STT inference**: sherpa-onnx runs ONNX Runtime in C++ with pre-built Android JNI bindings.
- **TTS inference**: sherpa-onnx bundles TTS engines with same JNI interface.

**JNI overhead**: ~2-5 microseconds per call. Negligible -- crossing JNI per audio buffer (~20ms chunks) and per LLM token (~30-50ms apart), not per sample.

---

## 2. Kotlin Coroutines vs Swift Async/Await

| Swift | Kotlin | Notes |
|-------|--------|-------|
| `async/await` | `suspend` functions | Nearly identical semantics |
| `Task { }` | `launch { }` / `async { }` | Kotlin separates fire-and-forget from result-bearing |
| `Task.isCancelled` | `isActive` / `ensureActive()` | Cooperative cancellation in both |
| `AsyncStream` | `Flow` / `callbackFlow` | Flow is more powerful (cold streams, operators) |
| Swift `actor` | `Mutex` + confined dispatcher | Kotlin lacks built-in actors |
| `@MainActor` | `Dispatchers.Main` / `viewModelScope` | Same concept |
| `withTaskGroup` | `coroutineScope { launch {} }` | Structured concurrency in both |

---

## 3. State Management

### ViewModel + StateFlow (= ObservableObject + @Published)

```kotlin
class VoicePipelineViewModel : ViewModel() {
    private val _state = MutableStateFlow(PipelineState.IDLE)
    val state: StateFlow<PipelineState> = _state.asStateFlow()

    private val _conversationHistory = MutableStateFlow<List<ConversationMessage>>(emptyList())
    val conversationHistory: StateFlow<List<ConversationMessage>> = _conversationHistory.asStateFlow()

    private var turnRevision = AtomicInteger(0)

    sealed class PipelineState {
        object Idle : PipelineState()
        object Listening : PipelineState()
        object Processing : PipelineState()
        object Speaking : PipelineState()
    }
}
```

In Compose, `collectAsState()` replaces SwiftUI's `@Published` observation:

```kotlin
@Composable
fun PipelineScreen(viewModel: VoicePipelineViewModel) {
    val state by viewModel.state.collectAsState()
    val history by viewModel.conversationHistory.collectAsState()
}
```

### State Machine

```kotlin
fun toggleListening() {
    when (_state.value) {
        is PipelineState.Idle -> startListening()
        is PipelineState.Listening -> stopListening()
        is PipelineState.Processing, is PipelineState.Speaking -> interrupt()
    }
}
```

### Turn Revision Guards (Barge-in)

```kotlin
private fun handleUtterance(text: String) {
    val myRevision = turnRevision.incrementAndGet()
    generationJob?.cancel()

    generationJob = viewModelScope.launch {
        _state.value = PipelineState.Processing
        llmManager.generate(history).collect { token ->
            if (myRevision != turnRevision.get()) return@collect
            // process token...
        }
    }
}
```

### Dependency Injection: Koin

Simpler than Hilt for project of this size. No annotation processing overhead. Works with KMP if needed later.

---

## 4. Model Management

### Storage Location

**Use `context.filesDir`** (internal app storage):
- No permissions required
- Scoped storage compliant
- Auto-cleaned on uninstall
- Path: `/data/data/com.volocal.app/files/models/`

**Check space before download**:
```kotlin
val storageManager = context.getSystemService(StorageManager::class.java)
val uuid = storageManager.getUuidForPath(modelsDir)
val available = storageManager.getAllocatableBytes(uuid)
if (available < REQUIRED_BYTES) { /* show error */ }
```

### Download Management: WorkManager

```kotlin
class ModelDownloadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        setForeground(createForegroundInfo()) // persistent notification
        val modelType = inputData.getString("model_type")!!

        okHttpClient.newCall(request).execute().use { response ->
            val total = response.body!!.contentLength()
            var downloaded = 0L
            response.body!!.source().use { source ->
                file.sink().buffer().use { sink ->
                    var read: Long
                    while (source.read(sink.buffer, 8192).also { read = it } != -1L) {
                        downloaded += read
                        setProgress(workDataOf("progress" to (downloaded.toDouble() / total)))
                    }
                }
            }
        }
        return Result.success()
    }
}
```

**Observe progress**:
```kotlin
WorkManager.getInstance(context)
    .getWorkInfoByIdLiveData(workId)
    .asFlow()
    .collect { info ->
        val progress = info.progress.getDouble("progress", 0.0)
        _modelStates.update { it + (modelType to ModelState.Downloading(progress)) }
    }
```

Benefits:
- Survives process death and device restarts
- Persistent notification with progress (required Android 12+)
- Parallel downloads (one Worker per model)
- Uses `ForegroundServiceType.DATA_SYNC`

---

## 5. Memory Management

### Android vs iOS Memory Model

| | iOS (iPhone 15) | Android (flagship) |
|--|----------------|-------------------|
| App budget | ~3 GB (Jetsam) | ~256-512 MB Java heap |
| Native heap | Same pool | **Separate, much larger** |
| Enforcement | Hard kill | OOM for Java; native = physical RAM |

**Critical**: Java heap limit does NOT apply to native C++ allocations. llama.cpp, ONNX Runtime, and Oboe allocate in native memory, bounded only by physical RAM.

### Strategies

1. **`android:largeHeap="true"`** in AndroidManifest.xml -- doubles/triples Java heap
2. **All model loading in C++/native** -- mmap for GGUF, ONNX Runtime native heap
3. **Monitor memory**: `Debug.getNativeHeapAllocatedSize()` + `ActivityManager.MemoryInfo`
4. **Handle `onTrimMemory`**: Release caches on `TRIM_MEMORY_RUNNING_LOW`, unload models on `TRIM_MEMORY_COMPLETE`
5. **Foreground service during conversation** -- elevates process priority vs OOM killer

### Expected Memory Footprint

| Component | iOS | Android (estimated) |
|-----------|-----|-------------------|
| LLM (Qwen3.5-2B Q4_K_S) | ~700 MB | ~700 MB (mmap'd, same binary) |
| STT | ~250 MB | ~200-300 MB (ONNX, native heap) |
| TTS | ~250 MB | ~150-300 MB (ONNX, native heap) |
| App + framework | ~50 MB | ~80-120 MB (Java heap) |
| **Total** | **~1.2 GB** | **~1.1-1.4 GB** |

Works on 8+ GB. Mid-range 6 GB tight but feasible. Budget 4 GB will struggle.

---

## 6. Hardware Contention Strategy

On iOS: STT/TTS -> ANE, LLM -> GPU (Metal). On Android:

- **LLM** -> GPU (Vulkan/OpenCL) or CPU
- **STT** -> CPU (XNNPACK) or NPU (NNAPI on Snapdragon)
- **TTS** -> CPU (XNNPACK) or NPU

STT and TTS don't overlap in pipeline (STT listens, then LLM generates, then TTS speaks). For barge-in (STT active during TTS), both run on CPU but STT is lightweight -- works fine on 8-core SoCs.

On Snapdragon 8 Elite+, LiteRT Qualcomm NPU accelerator can offload STT/TTS to NPU (100x faster than CPU), replicating ANE strategy. But CPU must be fallback for other chipsets.

---

## 7. Cross-Platform Considerations

### KMP (Kotlin Multiplatform)

**What could be shared**: SentenceBuffer, ConversationModel, ModelRegistry, state machine definitions (~10-15% of codebase).

**What cannot be shared**: UI, audio engine, ML inference wrappers, model downloads, system metrics (~80%+).

**Verdict: Not worth it for V1.** KMP adds build complexity for minimal benefit. Reconsider if significant shared business logic grows.

### Shared C++ Core

llama.cpp is already shared (same source, same GGUF). Keep thin JNI wrappers around C++ inference engines -- industry standard pattern.

---

## 8. Build System

### Gradle Configuration

```kotlin
// app/build.gradle.kts
android {
    namespace = "com.volocal.app"
    compileSdk = 35

    defaultConfig {
        minSdk = 26  // Android 8.0 -- Oboe AAudio
        targetSdk = 35
        ndk { abiFilters += "arm64-v8a" }
    }

    buildFeatures { compose = true }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

dependencies {
    // Compose
    implementation(platform("androidx.compose:compose-bom:2025.01.00"))
    implementation("androidx.compose.material3:material3")

    // ViewModel + lifecycle
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // WorkManager for downloads
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // DI
    implementation("io.insert-koin:koin-android:4.0.0")
    implementation("io.insert-koin:koin-compose:4.0.0")

    // sherpa-onnx (pre-built AAR)
    implementation("com.k2fsa.sherpa:onnx:1.12.32")
}
```

### CMake for Native Libraries

```cmake
# src/main/cpp/CMakeLists.txt
cmake_minimum_required(VERSION 3.22.1)
project(volocal-native)

set(CMAKE_CXX_STANDARD 17)

add_subdirectory(llama.cpp)
find_package(oboe REQUIRED CONFIG)

add_library(volocal-jni SHARED
    jni/llm_bridge.cpp
    jni/audio_bridge.cpp
)

target_link_libraries(volocal-jni
    llama
    oboe::oboe
    log
    android
)
```

### Model Packaging

**Do NOT bundle in APK** (Play Store limit: 150 MB + 2 GB asset packs). Download on first launch, same as iOS onboarding. Same HuggingFace URLs work. Same GGUF files work cross-platform.

---

## 9. Testing Strategy

### Unit Tests
- **SentenceBuffer, state machine**: Standard JUnit 5 (pure Kotlin, no Android deps)
- **ViewModel**: `kotlinx-coroutines-test` with `TestDispatcher` for state transitions
- **JNI bridge**: Google Test via CMake's `ctest`

### Instrumented Tests (On-Device)
- Load actual models, run known prompt, verify output (`@LargeTest`)
- Verify AEC available, audio session setup, buffer conversion
- Memory assertions: `Debug.getNativeHeapAllocatedSize()` under threshold

### Firebase Test Lab
- Real physical devices (Pixel 8a, Galaxy S24, etc.)
- Test on diverse chipsets (Snapdragon, Exynos, Tensor, MediaTek)
- Jetpack Macrobenchmark for performance metrics

### Key Metrics to Track
- **LLM**: tokens/second, time to first token
- **STT**: real-time factor, word error rate
- **TTS**: time to first audio frame, synthesis time
- **Memory**: peak native heap, peak Java heap
- **Thermal**: sustained performance under repeated conversations

---

## 10. Project Structure

```
volocal-android/
├── app/
│   ├── src/main/
│   │   ├── java/com/volocal/app/
│   │   │   ├── App.kt                     # Application + Koin
│   │   │   ├── ui/
│   │   │   │   ├── PipelineScreen.kt       # Main conversation UI
│   │   │   │   ├── OnboardingScreen.kt     # Model download
│   │   │   │   └── MetricsOverlay.kt       # Debug overlay
│   │   │   ├── pipeline/
│   │   │   │   ├── VoicePipelineViewModel.kt
│   │   │   │   ├── PipelineState.kt
│   │   │   │   └── SentenceBuffer.kt
│   │   │   ├── llm/
│   │   │   │   └── LlmManager.kt          # JNI bridge to llama.cpp
│   │   │   ├── stt/
│   │   │   │   └── SttManager.kt          # sherpa-onnx STT wrapper
│   │   │   ├── tts/
│   │   │   │   └── TtsManager.kt          # sherpa-onnx TTS wrapper
│   │   │   ├── audio/
│   │   │   │   └── SharedAudioEngine.kt   # Oboe/AudioTrack + AEC
│   │   │   ├── models/
│   │   │   │   ├── ModelRegistry.kt
│   │   │   │   ├── ModelDownloadWorker.kt
│   │   │   │   └── UnifiedModelManager.kt
│   │   │   └── debug/
│   │   │       └── SystemMetrics.kt
│   │   ├── cpp/
│   │   │   ├── CMakeLists.txt
│   │   │   ├── llama.cpp/                  # git submodule
│   │   │   └── jni/
│   │   │       └── llm_bridge.cpp
│   │   └── AndroidManifest.xml
│   └── build.gradle.kts
├── benchmark/                               # Macrobenchmark module
├── gradle/
└── build.gradle.kts
```

---

## 11. Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| No PocketTTS on Android | High | Phase 1: Piper. Phase 2: PocketTTS ONNX via sherpa-onnx |
| No EOU in Parakeet ONNX | Medium | Silero VAD + silence timeout. Tune debounce with real conversations |
| AEC varies by device | Medium | Test 10+ devices. WebRTC AEC3 fallback. Device blocklist |
| GPU contention | Medium | CPU fallback for LLM. Runtime GPU detection |
| Memory on 6 GB devices | Medium | Profile early on mid-range. Offer smaller LLM (Qwen 0.5B) |
| Fragmentation | Low-Med | minSdk 26, Firebase Test Lab for Snapdragon/Exynos/Tensor/MediaTek |

---

## Sources

- [llama.cpp Android docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md)
- [sherpa-onnx (STT + TTS)](https://github.com/k2-fsa/sherpa-onnx)
- [Google Oboe](https://github.com/google/oboe)
- [Picovoice AI Voice Assistant for Android](https://picovoice.ai/blog/ai-voice-assistant-for-android-powered-by-local-llm/)
- [Kotlin coroutines vs Swift async/await](https://medium.com/@IchBinAJ/a-comparative-analysis-of-coroutines-in-kotlin-and-async-await-in-swift-510f56157182)
- [WorkManager patterns](https://medium.com/@hiren6997/workmanager-in-2025-5-patterns-that-actually-work-in-production-fde952c0d095)
- [Android memory management](https://developer.android.com/topic/performance/memory-overview)
- [KMP status](https://developer.android.com/kotlin/multiplatform)
- [LiteRT NPU acceleration](https://developers.googleblog.com/unlocking-peak-performance-on-qualcomm-npu-with-litert/)
- [Firebase Test Lab](https://firebase.google.com/docs/test-lab)
- [Jetpack Macrobenchmark](https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview)
