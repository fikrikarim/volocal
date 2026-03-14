import Foundation

/// Manages LLM inference using llama.cpp via the LlamaContext actor.
@MainActor
final class LLMManager: ObservableObject {
    @Published var response: String = ""
    @Published var isGenerating: Bool = false
    @Published var error: String?
    @Published var tokensPerSecond: Double = 0

    private var llamaContext: LlamaContext?
    private var generationTask: Task<Void, Never>?

    private let systemPrompt = """
    You are Locus, a helpful voice assistant running entirely on-device. \
    Keep responses concise and conversational — typically 1-3 sentences. \
    You're speaking out loud, so avoid markdown, code blocks, or lists. \
    Be friendly, direct, and natural.
    """

    init() {}

    func loadModel(path: String) async throws {
        llamaContext = try LlamaContext.create(path: path, contextSize: 2048)
    }

    func generate(prompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            generationTask = Task {
                guard let ctx = llamaContext else {
                    continuation.finish()
                    return
                }

                await MainActor.run {
                    self.isGenerating = true
                    self.response = ""
                    self.tokensPerSecond = 0
                }

                // Format prompt with system message
                let fullPrompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"

                let startTime = CFAbsoluteTimeGetCurrent()
                var tokenCount = 0

                do {
                    await ctx.clear()
                    try await ctx.completionInit(text: fullPrompt)

                    while !Task.isCancelled {
                        guard let token = await ctx.completionLoop() else { break }

                        tokenCount += 1
                        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                        let tps = elapsed > 0 ? Double(tokenCount) / elapsed : 0

                        continuation.yield(token)

                        await MainActor.run {
                            self.response += token
                            self.tokensPerSecond = tps
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.error = error.localizedDescription
                    }
                }

                await MainActor.run {
                    self.isGenerating = false
                }
                continuation.finish()
            }
        }
    }

    func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    var isModelLoaded: Bool {
        llamaContext != nil
    }
}
