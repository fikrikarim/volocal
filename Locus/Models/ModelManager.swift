import Foundation

/// Manages LLM model download.
/// STT and TTS models are auto-downloaded by their respective managers via FluidAudio.
/// For device testing, run `scripts/serve-models.sh` on your Mac,
/// then tap "Download Models" in the app — it pulls from your local network.
@MainActor
final class ModelManager: ObservableObject {
    @Published var llmDownloadProgress: Double = 0
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
        llmReady
    }

    // MARK: - Model Paths

    private var modelsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    var llmModelPath: String? {
        let path = modelsDirectory.appendingPathComponent("Qwen_Qwen3.5-2B-Q4_K_S.gguf").path
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

    static let llmModel = ModelDefinition(
        name: "Qwen3.5-2B Q4_K_S (LLM)",
        files: [
            ModelFile(
                url: "\(baseURL)/Qwen_Qwen3.5-2B-Q4_K_S.gguf",
                relativePath: "Qwen_Qwen3.5-2B-Q4_K_S.gguf"
            ),
        ],
        totalSize: "~1.26 GB"
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
        llmReady = llmModelPath != nil
    }

    // MARK: - Download

    func downloadAllModels() async {
        await triggerLocalNetworkPermission()

        if !llmReady {
            await downloadModel(Self.llmModel) { [weak self] p in self?.llmDownloadProgress = p }
            checkExistingModels()
        }
    }

    /// Sends a small probe request to trigger the local network permission dialog.
    private func triggerLocalNetworkPermission() async {
        guard let probeURL = URL(string: Self.baseURL) else { return }

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

    private func downloadModel(
        _ definition: ModelDefinition,
        updateProgress: @escaping (Double) -> Void
    ) async {
        currentDownload = definition.name
        updateProgress(0)

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
    func deleteAllModels() {
        try? fileManager.removeItem(at: modelsDirectory)
        createModelsDirectory()
        llmReady = false
        llmDownloadProgress = 0
    }
}
