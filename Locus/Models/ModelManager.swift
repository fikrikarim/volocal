import Foundation

/// Manages ML model paths for STT and LLM.
/// For device testing, run `scripts/serve-models.sh` on your Mac,
/// then tap "Download Models" in the app — it pulls from your local network.
/// TTS models are managed by FluidAudio (auto-downloaded to Caches/fluidaudio/).
@MainActor
final class ModelManager: ObservableObject {
    @Published var sttDownloadProgress: Double = 0
    @Published var llmDownloadProgress: Double = 0
    @Published var sttReady: Bool = false
    @Published var llmReady: Bool = false
    @Published var currentDownload: String?
    @Published var error: String?

    private let fileManager = FileManager.default

    // MARK: - Local server for dev (run scripts/serve-models.sh on your Mac)
    // Change this IP to your Mac's local IP address.
    #if DEBUG
    static let baseURL = "http://192.168.0.180:8080"
    #else
    static let baseURL = "https://download.moonshine.ai"
    #endif

    var allModelsReady: Bool {
        sttReady && llmReady
    }

    // MARK: - Model Paths

    private var modelsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    var sttModelPath: String? {
        let dir = modelsDirectory.appendingPathComponent("moonshine-medium-streaming")
        if fileManager.fileExists(atPath: dir.appendingPathComponent("encoder.ort").path) {
            return dir.path
        }
        return nil
    }

    var llmModelPath: String? {
        let path = modelsDirectory.appendingPathComponent("Qwen3.5-0.8B-Q4_K_M.gguf").path
        guard fileManager.fileExists(atPath: path),
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > 1024 else { return nil }
        return path
    }

    // MARK: - Model Definitions

    struct ModelFile {
        let url: String
        let relativePath: String
    }

    struct ModelDefinition {
        let name: String
        let files: [ModelFile]
        let totalSize: String
    }

    static let sttModel = ModelDefinition(
        name: "Moonshine Medium Streaming (STT)",
        files: [
            ModelFile(url: "\(baseURL)/moonshine-medium-streaming/encoder.ort",
                      relativePath: "moonshine-medium-streaming/encoder.ort"),
            ModelFile(url: "\(baseURL)/moonshine-medium-streaming/decoder_kv.ort",
                      relativePath: "moonshine-medium-streaming/decoder_kv.ort"),
            ModelFile(url: "\(baseURL)/moonshine-medium-streaming/cross_kv.ort",
                      relativePath: "moonshine-medium-streaming/cross_kv.ort"),
            ModelFile(url: "\(baseURL)/moonshine-medium-streaming/frontend.ort",
                      relativePath: "moonshine-medium-streaming/frontend.ort"),
            ModelFile(url: "\(baseURL)/moonshine-medium-streaming/adapter.ort",
                      relativePath: "moonshine-medium-streaming/adapter.ort"),
            ModelFile(url: "\(baseURL)/moonshine-medium-streaming/tokenizer.bin",
                      relativePath: "moonshine-medium-streaming/tokenizer.bin"),
            ModelFile(url: "\(baseURL)/moonshine-medium-streaming/streaming_config.json",
                      relativePath: "moonshine-medium-streaming/streaming_config.json"),
        ],
        totalSize: "~290 MB"
    )

    static let llmModel = ModelDefinition(
        name: "Qwen3.5-0.8B Q4_K_M (LLM)",
        files: [
            ModelFile(
                url: "\(baseURL)/Qwen3.5-0.8B-Q4_K_M.gguf",
                relativePath: "Qwen3.5-0.8B-Q4_K_M.gguf"
            ),
        ],
        totalSize: "~508 MB"
    )

    // MARK: - Initialization

    init() {
        createModelsDirectory()
        checkExistingModels()
    }

    private func createModelsDirectory() {
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    private func checkExistingModels() {
        sttReady = sttModelPath != nil
        llmReady = llmModelPath != nil
    }

    // MARK: - Download

    func downloadAllModels() async {
        // Probe request to trigger iOS local network permission dialog.
        // The first request always fails while the dialog is showing,
        // so we do a throwaway request and wait for the user to tap Allow.
        await triggerLocalNetworkPermission()

        let models: [(ModelDefinition, ReferenceWritableKeyPath<ModelManager, Double>, ReferenceWritableKeyPath<ModelManager, Bool>)] = [
            (Self.sttModel, \.sttDownloadProgress, \.sttReady),
            (Self.llmModel, \.llmDownloadProgress, \.llmReady),
        ]

        for (definition, progressPath, readyPath) in models {
            if self[keyPath: readyPath] { continue }
            await downloadModel(definition) { [weak self] p in self?[keyPath: progressPath] = p }
            checkExistingModels()
        }
    }

    /// Sends a small probe request to trigger the local network permission dialog.
    /// Retries until the request succeeds (user tapped Allow) or gives up after 30s.
    private func triggerLocalNetworkPermission() async {
        guard let probeURL = URL(string: Self.baseURL) else { return }

        for attempt in 0..<15 {
            do {
                let (_, response) = try await URLSession.shared.data(from: probeURL)
                if let http = response as? HTTPURLResponse, http.statusCode > 0 {
                    return // Permission granted, server reachable
                }
            } catch {
                // -1009 = offline/local network prohibited — dialog is showing
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func downloadModel(
        _ definition: ModelDefinition,
        updateProgress: @escaping (Double) -> Void
    ) async {
        currentDownload = definition.name
        updateProgress(0)

        // Prepare directories and filter to files that need downloading
        var toDownload: [(url: URL, destination: URL)] = []
        for file in definition.files {
            let destinationURL = modelsDirectory.appendingPathComponent(file.relativePath)
            let destinationDir = destinationURL.deletingLastPathComponent()
            try? fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destinationURL.path) { continue }
            guard let url = URL(string: file.url) else { continue }
            toDownload.append((url: url, destination: destinationURL))
        }

        if toDownload.isEmpty {
            updateProgress(1.0)
            currentDownload = nil
            return
        }

        // Download all files concurrently
        let total = toDownload.count
        let completed = Counter()

        await withTaskGroup(of: Void.self) { group in
            for file in toDownload {
                group.addTask {
                    do {
                        let (tempURL, response) = try await URLSession.shared.download(from: file.url)
                        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                            await MainActor.run { self.error = "HTTP \(http.statusCode) for \(file.url.lastPathComponent)" }
                            return
                        }
                        try FileManager.default.moveItem(at: tempURL, to: file.destination)
                    } catch {
                        await MainActor.run { self.error = "Failed: \(file.url.lastPathComponent)" }
                    }
                    let done = await completed.increment()
                    await MainActor.run { updateProgress(Double(done) / Double(total)) }
                }
            }
        }

        updateProgress(1.0)
        currentDownload = nil
    }

}

/// Thread-safe counter for tracking concurrent download progress.
private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

extension ModelManager {
    /// Delete all downloaded models to re-download
    func deleteAllModels() {
        try? fileManager.removeItem(at: modelsDirectory)
        createModelsDirectory()
        sttReady = false
        llmReady = false
        sttDownloadProgress = 0
        llmDownloadProgress = 0
    }
}
