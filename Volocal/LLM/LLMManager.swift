import Foundation
import os

private let logger = Logger(subsystem: "com.volocal.app", category: "llm")

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
    You are Volocal, a helpful voice assistant running entirely on-device. \
    Keep responses concise and conversational — typically 1-3 sentences. \
    You're speaking out loud, so avoid markdown, code blocks, or lists. \
    Be friendly, direct, and natural.
    """

    init() {}

    func loadModel(path: String) async throws {
        llamaContext = try LlamaContext.create(path: path, contextSize: 2048)
    }

    /// Generate response from conversation history.
    /// History should already contain the latest user message.
    func generate(history: [ConversationMessage] = []) -> AsyncStream<String> {
        // Cancel any previous generation first
        generationTask?.cancel()
        generationTask = nil

        return AsyncStream { continuation in
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

                // Build multi-turn ChatML prompt from history
                var fullPrompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
                for message in history {
                    let role = message.role == .user ? "user" : "assistant"
                    fullPrompt += "<|im_start|>\(role)\n\(message.text)<|im_end|>\n"
                }
                // Pre-fill past <think> block to force non-thinking mode
                fullPrompt += "<|im_start|>assistant\n<think>\n</think>\n"

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

                        #if DEBUG
                        let hex = token.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
                        logger.debug("token[\(tokenCount)]: \"\(token)\" hex=[\(hex)]")
                        #endif

                        // Strip non-ASCII characters
                        let cleaned = String(token.unicodeScalars.filter { $0.isASCII })
                        guard !cleaned.isEmpty else { continue }

                        continuation.yield(cleaned)

                        await MainActor.run {
                            self.response += cleaned
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
