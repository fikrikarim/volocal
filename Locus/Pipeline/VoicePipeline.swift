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
    @Published var loadingStatus: String?
    @Published var isReady: Bool = false

    let sttManager = STTManager()
    let llmManager = LLMManager()
    let ttsManager = TTSManager()
    private let sentenceBuffer = SentenceBuffer()

    private var generationTask: Task<Void, Never>?
    private var sentenceQueue: [String] = []
    private var speakingTask: Task<Void, Never>?

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

    var metrics: SystemMetrics?

    func configure(llmModelPath: String?) async {
        loadingStatus = "Loading speech recognition..."
        metrics?.beginTracking("STT (Parakeet EOU)")
        await sttManager.initialize()
        metrics?.endTracking("STT (Parakeet EOU)")

        loadingStatus = "Loading language model..."
        if let path = llmModelPath {
            metrics?.beginTracking("LLM (llama.cpp)")
            try? await llmManager.loadModel(path: path)
            metrics?.endTracking("LLM (llama.cpp)")
        }

        loadingStatus = "Loading text-to-speech..."
        ttsManager.metrics = metrics
        await ttsManager.initialize()

        loadingStatus = nil
        isReady = true
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
        speakingTask?.cancel()
        speakingTask = nil
        sentenceQueue.removeAll()
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
        guard state == .listening else { return }

        let userMessage = ConversationMessage(role: .user, text: text)
        conversationHistory.append(userMessage)
        currentTranscript = text

        sttManager.stopListening()
        state = .processing
        currentResponse = ""
        sentenceBuffer.reset()
        sentenceQueue.removeAll()

        generationTask = Task {
            for await token in llmManager.generate(prompt: text, history: conversationHistory) {
                guard !Task.isCancelled else { break }
                currentResponse += token
                sentenceBuffer.append(token)
            }

            if !Task.isCancelled {
                sentenceBuffer.flush()

                let assistantMessage = ConversationMessage(role: .assistant, text: currentResponse)
                conversationHistory.append(assistantMessage)

                // Wait for all queued sentences to finish speaking
                while speakingTask != nil && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }

                if !Task.isCancelled {
                    state = .listening
                    sttManager.startListening()
                }
            }
        }
    }

    private func handleSentence(_ sentence: String) {
        sentenceQueue.append(sentence)
        processNextSentence()
    }

    private func processNextSentence() {
        guard speakingTask == nil, !sentenceQueue.isEmpty else { return }
        let sentence = sentenceQueue.removeFirst()
        state = .speaking
        speakingTask = Task {
            await ttsManager.speak(sentence)
            speakingTask = nil
            processNextSentence()
        }
    }
}
