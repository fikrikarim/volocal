import Foundation

/// Central registry of all models used by Volocal.
/// Defines metadata, download sources, and local paths.
enum ModelRegistry {
    /// All model types used in the app
    enum ModelType: String, CaseIterable, Identifiable {
        case llm
        case stt
        case tts

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .llm: return "Language Model"
            case .stt: return "Speech Recognition"
            case .tts: return "Text-to-Speech"
            }
        }

        var icon: String {
            switch self {
            case .llm: return "brain"
            case .stt: return "mic.fill"
            case .tts: return "speaker.wave.3.fill"
            }
        }

        var sizeDescription: String {
            switch self {
            case .llm: return "~1.26 GB"
            case .stt: return "~200 MB"
            case .tts: return "~100 MB"
            }
        }

        var detail: String {
            switch self {
            case .llm: return "Qwen3.5-2B Q4_K_S"
            case .stt: return "Parakeet EOU 320"
            case .tts: return "PocketTTS"
            }
        }
    }

    // MARK: - LLM

    static let llmFilename = "Qwen_Qwen3.5-2B-Q4_K_S.gguf"

    static let llmBaseURL = "https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF/resolve/main"

    static var llmDownloadURL: String {
        "\(llmBaseURL)/\(llmFilename)"
    }

    // MARK: - Paths

    static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var llmModelPath: String? {
        let path = modelsDirectory.appendingPathComponent(llmFilename).path
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > 1024 else { return nil }
        return path
    }
}
