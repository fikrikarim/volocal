import Foundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.locus.app", category: "models")

/// Unified model manager tracking download state for all 3 models (LLM, STT, TTS).
/// Downloads LLM from HuggingFace, STT and TTS via FluidAudio with progress.
@MainActor
final class UnifiedModelManager: ObservableObject {
    @Published var modelStates: [ModelRegistry.ModelType: ModelState] = [:]
    @Published var error: String?

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case error(String)

        var isReady: Bool {
            if case .downloaded = self { return true }
            return false
        }

        var progress: Double {
            if case .downloading(let p) = self { return p }
            if case .downloaded = self { return 1.0 }
            return 0
        }
    }

    var allModelsReady: Bool {
        ModelRegistry.ModelType.allCases.allSatisfy { modelStates[$0]?.isReady == true }
    }

    var llmModelPath: String? {
        ModelRegistry.llmModelPath
    }

    init() {
        checkExistingModels()
    }

    private func checkExistingModels() {
        // LLM: check if GGUF file exists
        if ModelRegistry.llmModelPath != nil {
            modelStates[.llm] = .downloaded
        } else {
            modelStates[.llm] = .notDownloaded
        }

        // STT: check if Parakeet EOU models exist
        let sttDir = ModelRegistry.modelsDirectory.appendingPathComponent(Repo.parakeetEou320.folderName)
        let encoderPath = sttDir.appendingPathComponent("streaming_encoder.mlmodelc")
        if FileManager.default.fileExists(atPath: encoderPath.path) {
            modelStates[.stt] = .downloaded
        } else {
            modelStates[.stt] = .notDownloaded
        }

        // TTS: check if PocketTTS models exist in its cache directory
        if Self.pocketTTSModelsExist() {
            modelStates[.tts] = .downloaded
        } else {
            modelStates[.tts] = .notDownloaded
        }
    }

    /// Check if PocketTTS models are cached.
    /// PocketTTS stores models at ~/Library/Caches/fluidaudio/Models/pocket-tts/
    private static func pocketTTSModelsExist() -> Bool {
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }
        let repoDir = cachesDir
            .appendingPathComponent("fluidaudio")
            .appendingPathComponent("Models")
            .appendingPathComponent("pocket-tts")

        // Check for a key model file
        let condStepPath = repoDir.appendingPathComponent("cond_step.mlmodelc")
        return FileManager.default.fileExists(atPath: condStepPath.path)
    }

    // MARK: - Download

    func downloadAllModels() async {
        await withTaskGroup(of: Void.self) { group in
            if modelStates[.llm]?.isReady != true {
                group.addTask { await self.downloadLLM() }
            }
            if modelStates[.stt]?.isReady != true {
                group.addTask { await self.downloadSTT() }
            }
            if modelStates[.tts]?.isReady != true {
                group.addTask { await self.downloadTTS() }
            }
        }
    }

    func retryModel(_ type: ModelRegistry.ModelType) async {
        modelStates[type] = .notDownloaded
        error = nil

        switch type {
        case .llm: await downloadLLM()
        case .stt: await downloadSTT()
        case .tts: await downloadTTS()
        }
    }

    // MARK: - LLM Download (traditional downloadTask with progress)

    /// Known LLM file size for progress fallback (Q4_K_S = 1,261,854,880 bytes).
    private static let llmExpectedBytes: Int64 = 1_261_854_880

    private func downloadLLM() async {
        modelStates[.llm] = .downloading(progress: 0)

        let destination = ModelRegistry.modelsDirectory.appendingPathComponent(ModelRegistry.llmFilename)

        if FileManager.default.fileExists(atPath: destination.path) {
            modelStates[.llm] = .downloaded
            return
        }

        guard let url = URL(string: ModelRegistry.llmDownloadURL) else {
            modelStates[.llm] = .error("Invalid URL")
            return
        }

        let expectedBytes = Self.llmExpectedBytes

        // Use traditional downloadTask + continuation (not async download API)
        // because the async API may not reliably call delegate progress methods.
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            let delegate = LLMDownloadDelegate(
                onProgress: { [weak self] bytesWritten, totalExpected in
                    let total = totalExpected > 0 ? totalExpected : expectedBytes
                    let fraction = Double(bytesWritten) / Double(total)
                    Task { @MainActor in
                        self?.modelStates[.llm] = .downloading(progress: min(fraction, 1.0))
                    }
                },
                onComplete: { tempURL, error in
                    if let error {
                        continuation.resume(returning: .failure(error))
                    } else if let tempURL {
                        continuation.resume(returning: .success(tempURL))
                    } else {
                        continuation.resume(returning: .failure(URLError(.badServerResponse)))
                    }
                }
            )

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            // Store session on delegate to prevent deallocation
            delegate.session = session

            let request = URLRequest(url: url, timeoutInterval: 3600)
            session.downloadTask(with: request).resume()
        }

        switch result {
        case .success(let tempURL):
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                modelStates[.llm] = .downloaded
                logger.info("LLM downloaded successfully")
            } catch {
                modelStates[.llm] = .error(error.localizedDescription)
                self.error = "LLM download failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            modelStates[.llm] = .error(error.localizedDescription)
            self.error = "LLM download failed: \(error.localizedDescription)"
            logger.error("LLM download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - STT Download (FluidAudio with progress)

    private func downloadSTT() async {
        modelStates[.stt] = .downloading(progress: 0)

        do {
            try await DownloadUtils.downloadRepo(.parakeetEou320, to: ModelRegistry.modelsDirectory) { [weak self] progress in
                Task { @MainActor in
                    self?.modelStates[.stt] = .downloading(progress: progress.fractionCompleted)
                }
            }
            modelStates[.stt] = .downloaded
            logger.info("STT models downloaded successfully")
        } catch {
            modelStates[.stt] = .error(error.localizedDescription)
            self.error = "STT download failed: \(error.localizedDescription)"
            logger.error("STT download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - TTS Download (FluidAudio PocketTTS with progress)

    private func downloadTTS() async {
        modelStates[.tts] = .downloading(progress: 0)

        do {
            _ = try await PocketTtsResourceDownloader.ensureModels { [weak self] progress in
                Task { @MainActor in
                    self?.modelStates[.tts] = .downloading(progress: progress.fractionCompleted)
                }
            }
            modelStates[.tts] = .downloaded
            logger.info("TTS models downloaded successfully")
        } catch {
            modelStates[.tts] = .error(error.localizedDescription)
            self.error = "TTS download failed: \(error.localizedDescription)"
            logger.error("TTS download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    func deleteAllModels() {
        try? FileManager.default.removeItem(at: ModelRegistry.modelsDirectory)
        try? FileManager.default.createDirectory(at: ModelRegistry.modelsDirectory, withIntermediateDirectories: true)
        // Also clear PocketTTS cache
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let ttsCache = cachesDir.appendingPathComponent("fluidaudio")
            try? FileManager.default.removeItem(at: ttsCache)
        }
        checkExistingModels()
    }
}

// MARK: - URLSession Download Delegate for LLM progress

private final class LLMDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Int64, Int64) -> Void
    let onComplete: (URL?, Error?) -> Void
    // Hold session reference to prevent deallocation during download
    var session: URLSession?
    private var hasCompleted = false

    init(
        onProgress: @escaping (Int64, Int64) -> Void,
        onComplete: @escaping (URL?, Error?) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
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
        // Copy to temp location before URLSession cleans up
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        try? FileManager.default.moveItem(at: location, to: tempURL)
        finish(tempURL: tempURL, error: nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(tempURL: nil, error: error)
        }
    }

    private func finish(tempURL: URL?, error: Error?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        session?.finishTasksAndInvalidate()
        session = nil
        onComplete(tempURL, error)
    }
}
