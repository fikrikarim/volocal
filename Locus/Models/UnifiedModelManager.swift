import Foundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.locus.app", category: "models")

/// Unified model manager tracking download state for all 3 models (LLM, STT, TTS).
/// LLM is downloaded from HuggingFace, STT via FluidAudio, TTS auto-downloaded by PocketTTS.
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
        // Only LLM needs explicit download. STT/TTS are handled by FluidAudio on init.
        modelStates[.llm]?.isReady == true
    }

    var llmModelPath: String? {
        ModelRegistry.llmModelPath
    }

    /// Aggregate download progress across all models
    var totalProgress: Double {
        let states = ModelRegistry.ModelType.allCases.map { modelStates[$0] ?? .notDownloaded }
        let total = states.reduce(0.0) { $0 + $1.progress }
        return total / Double(states.count)
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

        // STT: check if Parakeet models exist
        let sttDir = ModelRegistry.modelsDirectory.appendingPathComponent(Repo.parakeetEou320.folderName)
        let encoderPath = sttDir.appendingPathComponent("streaming_encoder.mlmodelc")
        if FileManager.default.fileExists(atPath: encoderPath.path) {
            modelStates[.stt] = .downloaded
        } else {
            modelStates[.stt] = .notDownloaded
        }

        // TTS: PocketTTS auto-downloads on initialize(), mark as ready if cached
        // PocketTTS stores models in its own cache directory
        modelStates[.tts] = .downloaded // PocketTTS handles its own download
    }

    // MARK: - Download

    func downloadAllModels() async {
        #if DEBUG
        await triggerLocalNetworkPermission()
        #endif

        // Download LLM
        if modelStates[.llm]?.isReady != true {
            await downloadLLM()
        }

        // Download STT
        if modelStates[.stt]?.isReady != true {
            await downloadSTT()
        }

        // TTS is auto-downloaded by PocketTtsManager.initialize()
    }

    func retryModel(_ type: ModelRegistry.ModelType) async {
        modelStates[type] = .notDownloaded
        error = nil

        switch type {
        case .llm: await downloadLLM()
        case .stt: await downloadSTT()
        case .tts: break // Auto-managed
        }
    }

    private func downloadLLM() async {
        modelStates[.llm] = .downloading(progress: 0)

        let destination = ModelRegistry.modelsDirectory.appendingPathComponent(ModelRegistry.llmFilename)

        // Skip if already exists
        if FileManager.default.fileExists(atPath: destination.path) {
            modelStates[.llm] = .downloaded
            return
        }

        guard let url = URL(string: ModelRegistry.llmDownloadURL) else {
            modelStates[.llm] = .error("Invalid URL")
            return
        }

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                modelStates[.llm] = .error("HTTP \(http.statusCode)")
                return
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            modelStates[.llm] = .downloaded
            logger.info("LLM downloaded successfully")
        } catch {
            modelStates[.llm] = .error(error.localizedDescription)
            self.error = "LLM download failed: \(error.localizedDescription)"
            logger.error("LLM download failed: \(error.localizedDescription)")
        }
    }

    private func downloadSTT() async {
        modelStates[.stt] = .downloading(progress: 0)

        do {
            try await DownloadUtils.downloadRepo(.parakeetEou320, to: ModelRegistry.modelsDirectory)
            modelStates[.stt] = .downloaded
            logger.info("STT models downloaded successfully")
        } catch {
            modelStates[.stt] = .error(error.localizedDescription)
            self.error = "STT download failed: \(error.localizedDescription)"
            logger.error("STT download failed: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// Sends a small probe request to trigger the local network permission dialog.
    private func triggerLocalNetworkPermission() async {
        guard let probeURL = URL(string: ModelRegistry.llmBaseURL) else { return }

        for _ in 0..<15 {
            do {
                let (_, response) = try await URLSession.shared.data(from: probeURL)
                if let http = response as? HTTPURLResponse, http.statusCode > 0 {
                    return
                }
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    #endif

    func deleteAllModels() {
        try? FileManager.default.removeItem(at: ModelRegistry.modelsDirectory)
        try? FileManager.default.createDirectory(at: ModelRegistry.modelsDirectory, withIntermediateDirectories: true)
        checkExistingModels()
    }
}
