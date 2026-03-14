import SwiftUI

struct LLMTestView: View {
    @EnvironmentObject var modelManager: ModelManager
    @StateObject private var llmManager = LLMManager()
    @State private var inputText = ""
    @State private var isModelLoaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Status bar
                HStack {
                    Circle()
                        .fill(isModelLoaded ? .green : .orange)
                        .frame(width: 12, height: 12)
                    Text(isModelLoaded ? "Model loaded" : "Model not loaded")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if llmManager.tokensPerSecond > 0 {
                        Text(String(format: "%.1f tok/s", llmManager.tokensPerSecond))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                // Response area
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(llmManager.response.isEmpty ? "Response will appear here..." : llmManager.response)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .id("response")
                    }
                    .frame(maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .onChange(of: llmManager.response) {
                        proxy.scrollTo("response", anchor: .bottom)
                    }
                }

                // Input area
                HStack {
                    TextField("Ask something...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(llmManager.isGenerating)

                    if llmManager.isGenerating {
                        Button {
                            llmManager.stopGeneration()
                        } label: {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            sendMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal)

                if let error = llmManager.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .navigationTitle("LLM")
            .task {
                await loadModel()
            }
        }
    }

    private func sendMessage() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        inputText = ""

        Task {
            for await _ in llmManager.generate(prompt: prompt) {
                // Tokens are accumulated in llmManager.response
            }
        }
    }

    private func loadModel() async {
        guard let path = modelManager.llmModelPath else { return }
        do {
            try await llmManager.loadModel(path: path)
            isModelLoaded = true
        } catch {
            llmManager.error = "Failed to load model: \(error.localizedDescription)"
        }
    }
}
