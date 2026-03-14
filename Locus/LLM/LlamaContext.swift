import Foundation
import LlamaSwift

// MARK: - Batch Helpers (from official llama.cpp SwiftUI example)

private func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llama_batch_add(
    _ batch: inout llama_batch,
    _ id: llama_token,
    _ pos: llama_pos,
    _ seq_ids: [llama_seq_id],
    _ logits: Bool
) {
    batch.token[Int(batch.n_tokens)] = id
    batch.pos[Int(batch.n_tokens)] = pos
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
    for i in 0..<seq_ids.count {
        batch.seq_id[Int(batch.n_tokens)]![i] = seq_ids[i]
    }
    batch.logits[Int(batch.n_tokens)] = logits ? 1 : 0
    batch.n_tokens += 1
}

// MARK: - LlamaContext Actor

/// Thread-safe actor wrapping the llama.cpp C API for on-device LLM inference.
/// Based on the official llama.cpp SwiftUI example (LibLlama.swift).
actor LlamaContext {
    private var model: OpaquePointer
    private var context: OpaquePointer
    private var vocab: OpaquePointer
    private var sampling: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch
    private var tokensList: [llama_token]
    private var nCur: Int32 = 0
    private var nDecode: Int32 = 0
    private var isDone: Bool = false

    /// Create a new LlamaContext by loading a GGUF model file.
    static func create(path: String, contextSize: UInt32 = 2048) throws -> LlamaContext {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 99 // Offload all layers to Metal GPU
        #endif

        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw LlamaContextError.modelLoadFailed
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextSize
        ctxParams.n_batch = 512
        let threadCount = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        ctxParams.n_threads = threadCount
        ctxParams.n_threads_batch = threadCount

        guard let context = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            throw LlamaContextError.contextCreationFailed
        }

        return LlamaContext(model: model, context: context)
    }

    private init(model: OpaquePointer, context: OpaquePointer) {
        self.model = model
        self.context = context
        self.tokensList = []
        self.batch = llama_batch_init(512, 0, 1)
        self.vocab = llama_model_get_vocab(model)

        // Set up sampler chain: temperature -> top-k -> top-p -> distribution
        let sparams = llama_sampler_chain_default_params()
        self.sampling = llama_sampler_chain_init(sparams)!
        llama_sampler_chain_add(self.sampling, llama_sampler_init_temp(0.4))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_dist(1234))
    }

    deinit {
        llama_sampler_free(sampling)
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    /// Tokenize and evaluate the prompt, preparing for token generation.
    func completionInit(text: String) throws {
        let utf8 = text.utf8CString

        // First call with nil buffer returns negative required count
        let requiredTokens = utf8.withUnsafeBufferPointer { buffer in
            llama_tokenize(vocab, buffer.baseAddress, Int32(buffer.count - 1), nil, 0, true, true)
        }
        let nTokens = abs(requiredTokens)
        guard nTokens > 0 else {
            throw LlamaContextError.decodeFailed
        }

        tokensList = Array(repeating: llama_token(), count: Int(nTokens))
        let actualCount = utf8.withUnsafeBufferPointer { buffer in
            llama_tokenize(vocab, buffer.baseAddress, Int32(buffer.count - 1),
                          &tokensList, nTokens, true, true)
        }
        tokensList = Array(tokensList.prefix(Int(actualCount)))

        let nCtx = llama_n_ctx(context)
        guard tokensList.count <= nCtx else {
            throw LlamaContextError.promptTooLong
        }

        llama_batch_clear(&batch)

        for (i, token) in tokensList.enumerated() {
            llama_batch_add(&batch, token, Int32(i), [0], i == tokensList.count - 1)
        }

        guard llama_decode(context, batch) >= 0 else {
            throw LlamaContextError.decodeFailed
        }

        nCur = Int32(tokensList.count)
        nDecode = 0
        isDone = false
    }

    /// Generate the next token. Returns the decoded text, or nil if generation is complete.
    func completionLoop() -> String? {
        guard !isDone else { return nil }

        let newTokenId = llama_sampler_sample(sampling, context, batch.n_tokens - 1)

        // Check for end of generation
        if llama_vocab_is_eog(vocab, newTokenId) {
            isDone = true
            return nil
        }

        // Convert token to text
        let bufSize = 128
        var buf = [CChar](repeating: 0, count: bufSize)
        let nChars = llama_token_to_piece(vocab, newTokenId, &buf, Int32(bufSize), 0, false)

        guard nChars >= 0 else {
            isDone = true
            return nil
        }

        let text = String(cString: buf)

        // Prepare next batch
        llama_batch_clear(&batch)
        llama_batch_add(&batch, newTokenId, nCur, [0], true)

        nDecode += 1
        nCur += 1

        if llama_decode(context, batch) != 0 {
            isDone = true
            return nil
        }

        return text
    }

    /// Check if generation is complete.
    var generationDone: Bool {
        isDone
    }

    /// Clear the context for a new conversation turn.
    func clear() {
        if let memory = llama_get_memory(context) {
            llama_memory_clear(memory, false)
        }
        nCur = 0
        nDecode = 0
        isDone = false
    }
}

// MARK: - Errors

enum LlamaContextError: LocalizedError {
    case modelLoadFailed
    case contextCreationFailed
    case promptTooLong
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Failed to load GGUF model file"
        case .contextCreationFailed:
            return "Failed to create llama.cpp context"
        case .promptTooLong:
            return "Prompt exceeds context window"
        case .decodeFailed:
            return "Token decode failed"
        }
    }
}
