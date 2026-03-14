import SwiftUI

struct STTTestView: View {
    @EnvironmentObject var modelManager: ModelManager
    @StateObject private var sttManager = STTManager()
    @State private var simulatedText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Status
                HStack {
                    Circle()
                        .fill(sttManager.isListening ? .green : .gray)
                        .frame(width: 12, height: 12)
                    Text(sttManager.isListening ? "Listening..." : "Tap to start")
                        .foregroundStyle(.secondary)
                }

                // Live partial result
                if !sttManager.partialResult.isEmpty {
                    Text(sttManager.partialResult)
                        .font(.body)
                        .foregroundStyle(.blue)
                        .padding(.horizontal)
                }

                // Transcript history
                ScrollView {
                    Text(sttManager.transcript.isEmpty ? "Transcript will appear here..." : sttManager.transcript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Record button
                Button {
                    if sttManager.isListening {
                        sttManager.stopListening()
                    } else {
                        sttManager.startListening()
                    }
                } label: {
                    Image(systemName: sttManager.isListening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(sttManager.isListening ? .red : .blue)
                }
                .padding(.bottom, 8)

                // Simulate input (for testing without microphone)
                HStack {
                    TextField("Simulate speech...", text: $simulatedText)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        guard !simulatedText.isEmpty else { return }
                        sttManager.simulateTranscript(simulatedText)
                        simulatedText = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)

                if let error = sttManager.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical)
            .navigationTitle("Speech-to-Text")
            .task {
                await sttManager.initialize()
            }
        }
    }
}
