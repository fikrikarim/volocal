# Model Download & Onboarding Design

## Status: Design Doc (not yet implemented)

---

## 1. Problem Summary

Locus requires ~1.5 GB of models before it can function:

| Model | Size | Current Source | Current Progress UI |
|-------|------|---------------|-------------------|
| Qwen3.5-2B Q4_K_S (LLM) | ~1.26 GB | Local dev server (broken in prod) | Basic progress bar |
| Parakeet EOU 320ms (STT) | ~120 MB | HuggingFace via FluidAudio | None |
| PocketTTS (TTS) | ~80 MB | HuggingFace via FluidAudio | None |

**Problems with the current implementation:**

1. **LLM download is dev-only.** `ModelManager` downloads from `http://192.168.0.180:8080` in debug and a placeholder `https://download.moonshine.ai` in release. Neither works in production.
2. **STT/TTS have no progress UI.** `STTManager.initialize()` and `TTSManager.initialize()` call `DownloadUtils.downloadRepo` and `PocketTtsManager.initialize()` respectively, but never pass a `progressHandler`. The user sees a spinner with "Loading speech recognition..." while a 120 MB download happens silently.
3. **Downloads are not resumable.** Both the LLM `URLSession.shared.download(from:)` and FluidAudio's `DownloadUtils` use foreground sessions with no resume-data handling. A network interruption means starting over.
4. **No unified tracking.** Three separate subsystems manage their own models in three separate directories (`Documents/models/`, `Documents/models/parakeet-eou-streaming/`, `Caches/fluidaudio/Models/`). There is no single source of truth for "are all models ready?"
5. **No storage management.** Users cannot see how much space models consume or selectively delete them.
6. **Loading screen is vague.** `ModelLoadingView` shows `pipeline.loadingStatus` ("Loading speech recognition...") but no progress fraction. CoreML model compilation can take 10-30 seconds per model and the user has no indication of progress.

---

## 2. Design Principles

1. **One screen, one button.** First-time users see every model, its size, and a single "Download All" action. No config, no decisions.
2. **Show real bytes.** Every download shows bytes received / total expected. No fake progress bars, no indeterminate spinners during multi-minute downloads.
3. **Survive interruptions.** Downloads resume where they left off after app kill, network drop, or device lock.
4. **Load fast, show what's happening.** After download, model compilation/loading can take 10-45 seconds. Show per-model loading status with timing.
5. **Framework-friendly.** The download manager should be reusable. Other apps building on Locus/FluidAudio should be able to drop in the same system with different model definitions.

---

## 3. Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                     LocusApp                              │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │            UnifiedModelManager                      │  │
│  │                                                    │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐ │  │
│  │  │ LLM      │  │ STT      │  │ TTS              │ │  │
│  │  │ Download  │  │ Download  │  │ Download          │ │  │
│  │  │ Task     │  │ Task     │  │ Task             │ │  │
│  │  └──────────┘  └──────────┘  └──────────────────┘ │  │
│  │                                                    │  │
│  │  ┌──────────────────────────────────────────────┐  │  │
│  │  │       BackgroundDownloadSession               │  │  │
│  │  │  (URLSession background config + delegate)   │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Screens:                                                │
│  1. OnboardingDownloadView  (download all models)        │
│  2. ModelLoadingView        (load into memory)           │
│  3. ContentView             (app ready)                  │
└──────────────────────────────────────────────────────────┘
```

### Three-phase onboarding flow

```
┌─────────────┐     ┌──────────────┐     ┌───────────┐
│  Download   │────>│  Load into   │────>│   Ready   │
│  (~1.5 GB)  │     │  Memory      │     │           │
└─────────────┘     └──────────────┘     └───────────┘
   Phase 1             Phase 2              Phase 3
   Network I/O         CPU/ANE work         App usable
   ~2-10 min           ~15-45 sec
```

---

## 4. Model Registry (Single Source of Truth)

Replace the scattered model definitions with a single registry.

```swift
// Models/ModelRegistry.swift

/// Every model Locus needs, with download metadata.
enum LocusModel: String, CaseIterable, Identifiable {
    case llm
    case stt
    case tts

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .llm: return "Language Model"
        case .stt: return "Speech Recognition"
        case .tts: return "Text to Speech"
        }
    }

    var icon: String {
        switch self {
        case .llm: return "brain"
        case .stt: return "waveform"
        case .tts: return "speaker.wave.2"
        }
    }

    /// Approximate download size in bytes (used for UI before server headers arrive).
    var estimatedBytes: Int64 {
        switch self {
        case .llm: return 1_350_000_000  // ~1.26 GB GGUF
        case .stt: return  125_000_000   // ~120 MB CoreML models
        case .tts: return   85_000_000   // ~80 MB CoreML models
        }
    }

    var estimatedSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
    }
}
```

### Production download URLs for the LLM

The LLM is a single `.gguf` file. Host it on HuggingFace under your own repo (e.g., `locus-ai/Qwen3.5-2B-Q4_K_S-GGUF`) or use the community quantization directly:

```
https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF/resolve/main/Qwen_Qwen3.5-2B-Q4_K_S.gguf
```

For STT/TTS, FluidAudio's `DownloadUtils.downloadRepo` already resolves HuggingFace URLs correctly. We just need to thread the `progressHandler` through.

---

## 5. Unified Download Manager

### Core design decisions

**Q: URLSession background downloads vs. foreground?**
A: Use **`URLSession` with `background` configuration** for the LLM file. This is the only iOS mechanism that survives app suspension, device lock, and low-memory kills. For the STT/TTS models (many small CoreML files), delegate to FluidAudio's existing `DownloadUtils` but pass through progress handlers. FluidAudio uses foreground sessions internally, which is fine for files under 30 MB each -- the total STT+TTS download takes under 60 seconds on a decent connection.

**Q: On-Demand Resources (ODR) or App Thinning?**
A: No. ODR has a 512 MB per-tag limit (LLM is 1.26 GB) and requires hosting through Apple's CDN, which means App Store submission delays for model updates. App Thinning doesn't help since all users need the same models. HuggingFace hosting gives us instant model updates without app review.

**Q: Resume support?**
A: URLSession background downloads automatically resume after network interruptions -- the OS manages this. For FluidAudio downloads, the existing `DownloadUtils.downloadRepo` already skips files that exist on disk (line 361 of DownloadUtils.swift: `if FileManager.default.fileExists(atPath: destPath.path) { continue }`), so re-calling it after a partial download resumes at the file level.

### Implementation

```swift
// Models/UnifiedModelManager.swift

import Foundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.locus.app", category: "models")

/// Tracks download + readiness state for one model.
struct ModelState: Identifiable {
    let model: LocusModel
    var id: String { model.id }

    /// Download progress: 0.0 (not started) to 1.0 (complete).
    var downloadProgress: Double = 0
    /// Bytes downloaded so far (for display).
    var bytesDownloaded: Int64 = 0
    /// Total expected bytes (-1 if unknown).
    var bytesTotal: Int64 = -1
    /// True when file is on disk and verified.
    var isDownloaded: Bool = false
    /// True when loaded into memory and ready to use.
    var isLoaded: Bool = false
    /// Human-readable status ("Downloading...", "Compiling...", etc.)
    var status: String?
    /// Error message if download/load failed.
    var error: String?

    /// Computed size label using real bytes when available.
    var sizeLabel: String {
        if bytesTotal > 0 {
            return ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
        }
        return model.estimatedSizeLabel
    }

    var progressLabel: String {
        if isLoaded { return "Ready" }
        if isDownloaded { return "Downloaded" }
        if downloadProgress > 0 && downloadProgress < 1 {
            let downloaded = ByteCountFormatter.string(
                fromByteCount: bytesDownloaded, countStyle: .file)
            let total = sizeLabel
            return "\(downloaded) / \(total)"
        }
        return sizeLabel
    }
}

@MainActor
final class UnifiedModelManager: ObservableObject {

    // MARK: - Published state

    @Published var models: [LocusModel: ModelState] = [:]
    @Published var isDownloading = false
    @Published var isLoading = false
    @Published var globalError: String?

    /// True when every model is on disk.
    var allDownloaded: Bool {
        LocusModel.allCases.allSatisfy { models[$0]?.isDownloaded == true }
    }

    /// True when every model is loaded into memory.
    var allReady: Bool {
        LocusModel.allCases.allSatisfy { models[$0]?.isLoaded == true }
    }

    /// Aggregate download progress (byte-weighted).
    var totalDownloadProgress: Double {
        let totalEstimated = LocusModel.allCases.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        let totalDownloaded = LocusModel.allCases.reduce(Int64(0)) { sum, m in
            let state = models[m]
            guard let s = state else { return sum }
            if s.isDownloaded { return sum + m.estimatedBytes }
            return sum + s.bytesDownloaded
        }
        return Double(totalDownloaded) / Double(totalEstimated)
    }

    /// Total download size label.
    var totalSizeLabel: String {
        let total = LocusModel.allCases.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Disk space used by all downloaded models.
    var diskSpaceUsed: Int64 {
        var total: Int64 = 0
        // LLM
        if let path = llmFilePath {
            total += fileSize(atPath: path)
        }
        // STT models directory
        total += directorySize(at: sttModelsDirectory)
        // TTS models directory
        total += directorySize(at: ttsModelsDirectory)
        return total
    }

    // MARK: - File Paths

    private let fileManager = FileManager.default

    private var documentsModelsDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    private var sttModelsDirectory: URL {
        documentsModelsDir
    }

    private var ttsModelsDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("fluidaudio/Models", isDirectory: true)
    }

    /// Path to the downloaded LLM GGUF file, or nil if not present.
    var llmFilePath: String? {
        let path = documentsModelsDir
            .appendingPathComponent("Qwen_Qwen3.5-2B-Q4_K_S.gguf").path
        guard fileManager.fileExists(atPath: path),
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > 1024 else { return nil }
        return path
    }

    /// Path to STT model directory, or nil if models not present.
    var sttModelDir: URL? {
        let dir = sttModelsDirectory
            .appendingPathComponent(Repo.parakeetEou320.folderName)
        let encoder = dir.appendingPathComponent("streaming_encoder.mlmodelc")
        guard fileManager.fileExists(atPath: encoder.path) else { return nil }
        return dir
    }

    // MARK: - Lifecycle

    init() {
        // Initialize state for every model
        for model in LocusModel.allCases {
            models[model] = ModelState(model: model)
        }
        try? fileManager.createDirectory(
            at: documentsModelsDir, withIntermediateDirectories: true)
        checkExistingModels()
    }

    private func checkExistingModels() {
        models[.llm]?.isDownloaded = llmFilePath != nil
        models[.stt]?.isDownloaded = sttModelDir != nil

        // TTS: check if PocketTTS models exist in cache
        let ttsRepoDir = ttsModelsDirectory
            .appendingPathComponent(Repo.pocketTts.folderName)
        let ttsReady = ModelNames.PocketTTS.requiredModels.allSatisfy { model in
            fileManager.fileExists(
                atPath: ttsRepoDir.appendingPathComponent(model).path)
        }
        models[.tts]?.isDownloaded = ttsReady

        // Update progress for already-downloaded models
        for model in LocusModel.allCases {
            if models[model]?.isDownloaded == true {
                models[model]?.downloadProgress = 1.0
            }
        }
    }

    // MARK: - Download All

    func downloadAll() async {
        isDownloading = true
        globalError = nil

        // Download in parallel: LLM is the bottleneck, STT/TTS are small.
        async let llmResult: () = downloadLLM()
        async let sttResult: () = downloadSTT()
        async let ttsResult: () = downloadTTS()

        _ = await (llmResult, sttResult, ttsResult)

        checkExistingModels()
        isDownloading = false
    }

    /// Retry a single failed model.
    func retry(_ model: LocusModel) async {
        models[model]?.error = nil
        models[model]?.downloadProgress = 0

        switch model {
        case .llm: await downloadLLM()
        case .stt: await downloadSTT()
        case .tts: await downloadTTS()
        }
        checkExistingModels()
    }

    // MARK: - LLM Download (Background URLSession)

    /// Production HuggingFace URL for the GGUF file.
    private static let llmURL = URL(string:
        "https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF/resolve/main/Qwen_Qwen3.5-2B-Q4_K_S.gguf"
    )!

    private func downloadLLM() async {
        guard models[.llm]?.isDownloaded != true else { return }
        models[.llm]?.status = "Downloading..."

        let destination = documentsModelsDir
            .appendingPathComponent("Qwen_Qwen3.5-2B-Q4_K_S.gguf")

        // Check for partial download (resume data)
        let partialPath = destination.appendingPathExtension("partial")

        do {
            // Use delegate-based download for byte-level progress.
            // For production, consider moving this to a URLSession background
            // configuration for survival across app suspension. The background
            // session approach is outlined in Section 7.
            let delegate = ProgressDelegate { [weak self] bytesWritten, totalExpected in
                Task { @MainActor in
                    guard let self else { return }
                    self.models[.llm]?.bytesDownloaded = bytesWritten
                    if totalExpected > 0 {
                        self.models[.llm]?.bytesTotal = totalExpected
                        self.models[.llm]?.downloadProgress =
                            Double(bytesWritten) / Double(totalExpected)
                    }
                }
            }

            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }

            let request = URLRequest(
                url: Self.llmURL,
                timeoutInterval: 3600  // 1 hour for large file
            )

            let (tempURL, response) = try await session.download(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw DownloadError.httpError(code)
            }

            // Atomic move to final destination
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: tempURL, to: destination)

            // Clean up partial file if it exists
            try? fileManager.removeItem(at: partialPath)

            models[.llm]?.downloadProgress = 1.0
            models[.llm]?.isDownloaded = true
            models[.llm]?.status = "Downloaded"
            logger.info("LLM download complete")

        } catch {
            models[.llm]?.error = error.localizedDescription
            models[.llm]?.status = "Failed"
            logger.error("LLM download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - STT Download (FluidAudio)

    private func downloadSTT() async {
        guard models[.stt]?.isDownloaded != true else { return }
        models[.stt]?.status = "Downloading..."

        do {
            try await DownloadUtils.downloadRepo(
                .parakeetEou320,
                to: sttModelsDirectory,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        // FluidAudio progress is 0-0.5 for download, 0.5-1.0
                        // for compile. We only track download here.
                        let dlProgress = min(progress.fractionCompleted * 2, 1.0)
                        self.models[.stt]?.downloadProgress = dlProgress

                        switch progress.phase {
                        case .listing:
                            self.models[.stt]?.status = "Finding files..."
                        case .downloading(let completed, let total):
                            self.models[.stt]?.status =
                                "Downloading (\(completed)/\(total) files)"
                            self.models[.stt]?.bytesDownloaded =
                                Int64(dlProgress * Double(LocusModel.stt.estimatedBytes))
                        case .compiling(let name):
                            if !name.isEmpty {
                                self.models[.stt]?.status = "Verifying \(name)"
                            }
                        }
                    }
                }
            )

            models[.stt]?.downloadProgress = 1.0
            models[.stt]?.isDownloaded = true
            models[.stt]?.status = "Downloaded"
            logger.info("STT download complete")

        } catch {
            models[.stt]?.error = error.localizedDescription
            models[.stt]?.status = "Failed"
            logger.error("STT download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - TTS Download (FluidAudio)

    private func downloadTTS() async {
        guard models[.tts]?.isDownloaded != true else { return }
        models[.tts]?.status = "Downloading..."

        do {
            // Use PocketTtsResourceDownloader which handles the cache directory
            // and model verification. We need to add progressHandler support.
            try await DownloadUtils.downloadRepo(
                .pocketTts,
                to: ttsModelsDirectory,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        let dlProgress = min(progress.fractionCompleted * 2, 1.0)
                        self.models[.tts]?.downloadProgress = dlProgress

                        switch progress.phase {
                        case .listing:
                            self.models[.tts]?.status = "Finding files..."
                        case .downloading(let completed, let total):
                            self.models[.tts]?.status =
                                "Downloading (\(completed)/\(total) files)"
                        case .compiling:
                            self.models[.tts]?.status = "Verifying..."
                        }
                    }
                }
            )

            models[.tts]?.downloadProgress = 1.0
            models[.tts]?.isDownloaded = true
            models[.tts]?.status = "Downloaded"
            logger.info("TTS download complete")

        } catch {
            models[.tts]?.error = error.localizedDescription
            models[.tts]?.status = "Failed"
            logger.error("TTS download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Storage Management

    func deleteModel(_ model: LocusModel) {
        switch model {
        case .llm:
            if let path = llmFilePath {
                try? fileManager.removeItem(atPath: path)
            }
        case .stt:
            let dir = sttModelsDirectory
                .appendingPathComponent(Repo.parakeetEou320.folderName)
            try? fileManager.removeItem(at: dir)
        case .tts:
            let dir = ttsModelsDirectory
                .appendingPathComponent(Repo.pocketTts.folderName)
            try? fileManager.removeItem(at: dir)
        }

        models[model]?.isDownloaded = false
        models[model]?.isLoaded = false
        models[model]?.downloadProgress = 0
        models[model]?.bytesDownloaded = 0
        models[model]?.error = nil
        models[model]?.status = nil
    }

    func deleteAllModels() {
        for model in LocusModel.allCases {
            deleteModel(model)
        }
    }

    // MARK: - Helpers

    private func fileSize(atPath path: String) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Progress Delegate

/// Lightweight URLSession delegate for byte-level download progress.
private final class ProgressDelegate: NSObject,
    URLSessionDownloadDelegate, Sendable
{
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Required by protocol; the async API handles the file.
    }
}

enum DownloadError: LocalizedError {
    case httpError(Int)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "Download failed (HTTP \(code))"
        case .fileNotFound(let name):
            return "File not found: \(name)"
        }
    }
}
```

---

## 6. Onboarding Download UI

```swift
// Models/OnboardingDownloadView.swift

import SwiftUI

struct OnboardingDownloadView: View {
    @EnvironmentObject var modelManager: UnifiedModelManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App branding
            VStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)
                Text("Locus")
                    .font(.largeTitle.bold())
                Text("On-device voice AI")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Per-model status cards
            VStack(spacing: 12) {
                ForEach(LocusModel.allCases) { model in
                    ModelDownloadRow(
                        state: modelManager.models[model]
                            ?? ModelState(model: model)
                    ) {
                        Task { await modelManager.retry(model) }
                    }
                }
            }
            .padding(.horizontal)

            // Aggregate progress
            if modelManager.isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: modelManager.totalDownloadProgress)
                        .tint(.blue)
                    Text("Overall: \(Int(modelManager.totalDownloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            Spacer()

            // Download button
            Button {
                Task { await modelManager.downloadAll() }
            } label: {
                HStack {
                    if modelManager.isDownloading {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 4)
                    }
                    Text(buttonLabel)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(modelManager.isDownloading || modelManager.allDownloaded)
            .padding(.horizontal)

            // Error display
            if let error = modelManager.globalError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            // Wi-Fi recommendation
            if !modelManager.allDownloaded && !modelManager.isDownloading {
                Label(
                    "Wi-Fi recommended (\(modelManager.totalSizeLabel) download)",
                    systemImage: "wifi"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom)
            }
        }
    }

    private var buttonLabel: String {
        if modelManager.allDownloaded { return "All Models Ready" }
        if modelManager.isDownloading { return "Downloading..." }

        // Count how many need downloading
        let remaining = LocusModel.allCases.filter {
            modelManager.models[$0]?.isDownloaded != true
        }
        if remaining.count < LocusModel.allCases.count {
            return "Resume Downloads"
        }
        return "Download Models (\(modelManager.totalSizeLabel))"
    }
}

// MARK: - Per-Model Row

struct ModelDownloadRow: View {
    let state: ModelState
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.model.icon)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(state.model.displayName)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text(state.progressLabel)
                        .font(.caption)
                        .foregroundStyle(state.isDownloaded ? .green : .secondary)
                }

                // Show progress bar during download
                if state.downloadProgress > 0
                    && state.downloadProgress < 1
                    && !state.isDownloaded
                {
                    ProgressView(value: state.downloadProgress)
                        .tint(.blue)
                }

                // Show sub-status
                if let status = state.status, !state.isDownloaded {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Error with retry
                if let error = state.error {
                    HStack {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Retry", action: onRetry)
                            .font(.caption2.bold())
                    }
                }
            }

            if state.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var iconColor: Color {
        if state.isDownloaded { return .green }
        if state.error != nil { return .red }
        if state.downloadProgress > 0 { return .blue }
        return .secondary
    }
}
```

---

## 7. Background Download Session (LLM)

For the 1.26 GB LLM file, a true `URLSession` background download configuration ensures the download continues even if the user switches apps or the device locks. This is the recommended production approach for files over ~100 MB.

```swift
// Models/BackgroundDownloadManager.swift

import Foundation
import os

/// Manages URLSession background downloads for large model files.
/// Must be initialized early in the app lifecycle (AppDelegate or @main init)
/// so the OS can redeliver completed download events.
final class BackgroundDownloadManager: NSObject, @unchecked Sendable {

    static let shared = BackgroundDownloadManager()

    private let sessionID = "com.locus.app.model-download"
    private let logger = Logger(subsystem: "com.locus.app", category: "bg-download")
    private var session: URLSession!

    /// Called on main thread when a download finishes (success or failure).
    var onDownloadFinished: ((URL?, Error?) -> Void)?

    /// Called periodically with (bytesWritten, totalExpected).
    var onProgress: ((Int64, Int64) -> Void)?

    /// System completion handler for background session events.
    /// Must be called after all events are delivered.
    var backgroundCompletionHandler: (() -> Void)?

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(
            withIdentifier: sessionID)
        config.isDiscretionary = false           // Download immediately
        config.sessionSendsLaunchEvents = true   // Wake app on completion
        config.allowsCellularAccess = true       // Let user decide via system settings
        session = URLSession(
            configuration: config, delegate: self, delegateQueue: nil)
    }

    func startDownload(from url: URL) {
        // Cancel any existing tasks first
        session.getAllTasks { [weak self] tasks in
            tasks.forEach { $0.cancel() }
            let request = URLRequest(url: url, timeoutInterval: 7200)
            self?.session.downloadTask(with: request).resume()
            self?.logger.info("Background download started: \(url.lastPathComponent)")
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }
}

extension BackgroundDownloadManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Must move file synchronously -- temp file is deleted after return.
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = docs.appendingPathComponent("models", isDirectory: true)
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let destination = modelsDir.appendingPathComponent(
            downloadTask.originalRequest?.url?.lastPathComponent
            ?? "model.gguf")
        try? fm.removeItem(at: destination)
        do {
            try fm.moveItem(at: location, to: destination)
            logger.info("Background download saved to \(destination.lastPathComponent)")
            DispatchQueue.main.async {
                self.onDownloadFinished?(destination, nil)
            }
        } catch {
            logger.error("Failed to move downloaded file: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.onDownloadFinished?(nil, error)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        DispatchQueue.main.async {
            self.onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            logger.error("Background download error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.onDownloadFinished?(nil, error)
            }
        }
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
```

**App delegate hookup** (required for background session redelivery):

```swift
// In LocusApp.swift or a UIApplicationDelegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == "com.locus.app.model-download" {
            BackgroundDownloadManager.shared.backgroundCompletionHandler =
                completionHandler
        }
    }
}
```

---

## 8. Updated Model Loading View

After all downloads complete, replace the vague spinner with per-model loading status:

```swift
// App/ModelLoadingView.swift (updated)

import SwiftUI

struct ModelLoadingView: View {
    @EnvironmentObject var pipeline: VoicePipeline

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text(pipeline.loadingStatus ?? "Preparing...")
                .font(.headline)

            // Show which specific model is loading
            if let detail = pipeline.loadingDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Show loading timeline
            VStack(spacing: 8) {
                LoadingStepRow(
                    label: "Speech Recognition",
                    icon: "waveform",
                    state: pipeline.sttLoadState
                )
                LoadingStepRow(
                    label: "Language Model",
                    icon: "brain",
                    state: pipeline.llmLoadState
                )
                LoadingStepRow(
                    label: "Text to Speech",
                    icon: "speaker.wave.2",
                    state: pipeline.ttsLoadState
                )
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

enum LoadState {
    case pending
    case loading
    case done(TimeInterval)  // seconds it took
    case failed(String)
}

struct LoadingStepRow: View {
    let label: String
    let icon: String
    let state: LoadState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(iconColor)

            Text(label)
                .font(.subheadline)

            Spacer()

            switch state {
            case .pending:
                Text("Waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                    .scaleEffect(0.7)
            case .done(let seconds):
                Text(String(format: "%.1fs", seconds))
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var iconColor: Color {
        switch state {
        case .pending: return .secondary
        case .loading: return .blue
        case .done: return .green
        case .failed: return .red
        }
    }
}
```

---

## 9. Updated VoicePipeline

Add structured loading state tracking:

```swift
// In VoicePipeline.swift, add these properties:

@Published var loadingDetail: String?
@Published var sttLoadState: LoadState = .pending
@Published var llmLoadState: LoadState = .pending
@Published var ttsLoadState: LoadState = .pending

func configure(llmModelPath: String?) async {
    // Phase 1: STT
    sttLoadState = .loading
    loadingStatus = "Loading speech recognition..."
    loadingDetail = "Compiling CoreML models for Neural Engine"

    let sttStart = CFAbsoluteTimeGetCurrent()
    await sttManager.initialize()
    let sttElapsed = CFAbsoluteTimeGetCurrent() - sttStart
    sttLoadState = .done(sttElapsed)

    // Phase 2: LLM
    llmLoadState = .loading
    loadingStatus = "Loading language model..."
    loadingDetail = "Mapping 1.26 GB model into memory"

    let llmStart = CFAbsoluteTimeGetCurrent()
    if let path = llmModelPath {
        try? await llmManager.loadModel(path: path)
    }
    let llmElapsed = CFAbsoluteTimeGetCurrent() - llmStart
    llmLoadState = .done(llmElapsed)

    // Phase 3: TTS
    ttsLoadState = .loading
    loadingStatus = "Loading text to speech..."
    loadingDetail = "Compiling CoreML models + warming voice cache"

    let ttsStart = CFAbsoluteTimeGetCurrent()
    await ttsManager.initialize()
    let ttsElapsed = CFAbsoluteTimeGetCurrent() - ttsStart
    ttsLoadState = .done(ttsElapsed)

    // Done
    loadingStatus = nil
    loadingDetail = nil
    isReady = true
}
```

---

## 10. Updated App Entry Point

```swift
// App/LocusApp.swift (updated)

import SwiftUI

@main
struct LocusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var modelManager = UnifiedModelManager()
    @StateObject private var metrics = SystemMetrics()
    @StateObject private var pipeline = VoicePipeline()

    var body: some Scene {
        WindowGroup {
            if !modelManager.allDownloaded {
                // Phase 1: Download models
                OnboardingDownloadView()
                    .environmentObject(modelManager)
            } else if !pipeline.isReady {
                // Phase 2: Load into memory
                ModelLoadingView()
                    .environmentObject(pipeline)
                    .task {
                        pipeline.metrics = metrics
                        metrics.startMonitoring()
                        await pipeline.configure(
                            llmModelPath: modelManager.llmFilePath
                        )
                    }
            } else {
                // Phase 3: App ready
                ContentView()
                    .environmentObject(modelManager)
                    .environmentObject(metrics)
                    .environmentObject(pipeline)
                    .overlay { MetricsOverlay().environmentObject(metrics) }
            }
        }
    }
}
```

---

## 11. Storage Management View

Accessible from Settings, lets users see space usage and delete individual models:

```swift
// Models/StorageManagementView.swift

import SwiftUI

struct StorageManagementView: View {
    @EnvironmentObject var modelManager: UnifiedModelManager
    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: LocusModel?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total space used")
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: modelManager.diskSpaceUsed,
                        countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Models") {
                ForEach(LocusModel.allCases) { model in
                    let state = modelManager.models[model]
                    HStack {
                        Image(systemName: model.icon)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                            Text(model.estimatedSizeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if state?.isDownloaded == true {
                            Button(role: .destructive) {
                                modelToDelete = model
                                showDeleteConfirmation = true
                            } label: {
                                Text("Delete")
                                    .font(.caption)
                            }
                        } else {
                            Text("Not downloaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Delete All Models", role: .destructive) {
                    modelToDelete = nil
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle("Storage")
        .confirmationDialog(
            "Delete model?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let model = modelToDelete {
                Button("Delete \(model.displayName)", role: .destructive) {
                    modelManager.deleteModel(model)
                }
            } else {
                Button("Delete All Models", role: .destructive) {
                    modelManager.deleteAllModels()
                }
            }
        } message: {
            Text("You will need to re-download the model before using the app.")
        }
    }
}
```

---

## 12. File & Directory Layout

After implementation, the project structure under `Locus/Models/` would be:

```
Locus/Models/
  LocusModel.swift              // Model enum + metadata (Section 4)
  UnifiedModelManager.swift     // Core download manager (Section 5)
  BackgroundDownloadManager.swift // Background URLSession (Section 7)
  OnboardingDownloadView.swift  // Download screen (Section 6)
  StorageManagementView.swift   // Settings storage UI (Section 11)
  ModelDownloadRow.swift        // Reusable row component

Locus/App/
  LocusApp.swift                // Updated entry point (Section 10)
  ModelLoadingView.swift        // Updated loading screen (Section 8)
  AppDelegate.swift             // Background session handler

Locus/Pipeline/
  VoicePipeline.swift           // Updated with LoadState tracking (Section 9)
```

**Files to delete:**
- `Locus/Models/ModelManager.swift` (replaced by `UnifiedModelManager.swift`)
- `Locus/Models/ModelDownloadView.swift` (replaced by `OnboardingDownloadView.swift`)

---

## 13. Migration Path

### Phase 1: Minimum viable (unblocks production)

1. Replace `ModelManager.baseURL` with the HuggingFace URL for the LLM.
2. Thread `progressHandler` through STT/TTS initialization to surface download progress.
3. Build the unified `OnboardingDownloadView` with per-model progress rows.

This is a 1-2 day change. The LLM download just changes the URL. The STT/TTS progress is a matter of passing closures through -- FluidAudio's `DownloadUtils.downloadRepo` already supports `progressHandler`.

### Phase 2: Background downloads

4. Add `BackgroundDownloadManager` for the LLM file.
5. Add `AppDelegate` with `handleEventsForBackgroundURLSession`.
6. Test: start download, lock device, wait 5 minutes, unlock. Verify download continued.

### Phase 3: Polish

7. Add `StorageManagementView` accessible from app settings.
8. Add "Downloading over cellular" warning using `NWPathMonitor`.
9. Add SHA256 checksum verification for the LLM file after download.
10. Consider pre-downloading on app install via `BGProcessingTask` (iOS 13+).

---

## 14. Key Technical Notes

### Why not bundle models in the app binary?

The App Store has a 200 MB cellular download limit (4 GB total). A 1.5 GB model would make the app too large for cellular install and significantly increase review times. Downloading on first launch is the standard approach used by every on-device AI app (ChatGPT offline, Whisper apps, Google Translate).

### SHA256 verification

For the LLM GGUF file, compute a SHA256 hash after download and compare against a known-good hash compiled into the app. This guards against CDN corruption and man-in-the-middle attacks:

```swift
import CryptoKit

func verifySHA256(at url: URL, expected: String) throws -> Bool {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let hash = SHA256.hash(data: data)
    let actual = hash.compactMap { String(format: "%02x", $0) }.joined()
    return actual == expected
}
```

For FluidAudio models, the framework's `downloadRepo` already verifies that all required model directories and `coremldata.bin` files exist after download.

### Network monitoring

Use `NWPathMonitor` to:
1. Warn before downloading over cellular.
2. Pause/resume UI (not the download itself -- background URLSession handles that).
3. Show "Waiting for network..." when offline.

```swift
import Network

let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { path in
    DispatchQueue.main.async {
        self.isConnected = path.status == .satisfied
        self.isExpensive = path.isExpensive  // cellular/hotspot
    }
}
monitor.start(queue: DispatchQueue(label: "network-monitor"))
```

### Why parallel downloads?

The LLM is 1.26 GB from a single HuggingFace URL. STT is ~10 small CoreML files. TTS is ~10 small CoreML files. Downloading all three in parallel means the total time is roughly `max(llm_time, stt_time, tts_time)` instead of `sum(...)`. Since the LLM dominates, STT+TTS complete "for free" during the LLM download. The user sees all three progress bars advancing simultaneously, which feels faster and more responsive.
