import Foundation

/// Orchestrates the full voice pipeline: STT -> LLM -> TTS
/// Listens for completed utterances from STT, generates LLM responses,
/// buffers into sentences, and sends to TTS for playback.
@MainActor
final class VoicePipeline: ObservableObject {
    @Published var state: PipelineState = .idle
    @Published var conversationHistory: [ConversationMessage] = []
    @Published var currentTranscript: String = ""
    @Published var currentResponse: String = ""

    let sttManager = STTManager()
    let llmManager = LLMManager()
    let ttsManager = TTSManager()
    private let sentenceBuffer = SentenceBuffer()

    private var generationTask: Task<Void, Never>?

    enum PipelineState: Equatable {
        case idle
        case listening
        case processing
        case speaking

        var label: String {
            switch self {
            case .idle: return "Tap to start"
            case .listening: return "Listening..."
            case .processing: return "Thinking..."
            case .speaking: return "Speaking..."
            }
        }
    }

    init() {
        setupCallbacks()
    }

    func configure(sttModelPath: String?, llmModelPath: String?) async {
        if let path = sttModelPath {
            sttManager.configure(modelPath: path)
        }
        if let path = llmModelPath {
            try? await llmManager.loadModel(path: path)
        }
        await ttsManager.initialize()
    }

    func toggleListening() {
        switch state {
        case .idle:
            startListening()
        case .listening:
            stopListening()
        case .processing, .speaking:
            interrupt()
        }
    }

    // MARK: - Pipeline Control

    private func startListening() {
        state = .listening
        currentTranscript = ""
        sttManager.startListening()
    }

    private func stopListening() {
        sttManager.stopListening()
        state = .idle
    }

    private func interrupt() {
        ttsManager.stop()
        llmManager.stopGeneration()
        generationTask?.cancel()
        generationTask = nil
        sentenceBuffer.reset()
        currentResponse = ""

        state = .listening
        sttManager.startListening()
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        sttManager.onUtteranceCompleted = { [weak self] text in
            Task { @MainActor in
                self?.handleUtterance(text)
            }
        }

        sentenceBuffer.onSentenceReady = { [weak self] sentence in
            Task { @MainActor in
                self?.handleSentence(sentence)
            }
        }
    }

    private func handleUtterance(_ text: String) {
        let userMessage = ConversationMessage(role: .user, text: text)
        conversationHistory.append(userMessage)
        currentTranscript = text

        sttManager.stopListening()
        state = .processing
        currentResponse = ""
        sentenceBuffer.reset()

        generationTask = Task {
            for await token in llmManager.generate(prompt: text) {
                guard !Task.isCancelled else { break }
                currentResponse += token
                sentenceBuffer.append(token)
            }

            if !Task.isCancelled {
                sentenceBuffer.flush()

                let assistantMessage = ConversationMessage(role: .assistant, text: currentResponse)
                conversationHistory.append(assistantMessage)

                // Wait for TTS to finish, then resume listening
                while ttsManager.isSpeaking {
                    try? await Task.sleep(for: .milliseconds(100))
                }

                state = .listening
                sttManager.startListening()
            }
        }
    }

    private func handleSentence(_ sentence: String) {
        state = .speaking
        Task {
            await ttsManager.speak(sentence)
        }
    }
}
