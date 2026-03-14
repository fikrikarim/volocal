import SwiftUI

struct TTSTestView: View {
    @StateObject private var ttsManager = TTSManager()
    @State private var inputText = "Hello! I am Locus, your on-device voice assistant."

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Voice picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice")
                        .font(.headline)

                    Picker("Voice", selection: $ttsManager.selectedVoice) {
                        ForEach(TTSManager.voiceNames, id: \.self) { name in
                            Text(name.capitalized).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.horizontal)

                // Text input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Text to speak")
                        .font(.headline)

                    TextEditor(text: $inputText)
                        .frame(height: 120)
                        .padding(8)
                        .background(Color(.systemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                Spacer()

                // Status
                if ttsManager.isSpeaking {
                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.blue)
                                .frame(width: 4, height: CGFloat.random(in: 10...30))
                                .animation(
                                    .easeInOut(duration: 0.3).repeatForever().delay(Double(i) * 0.1),
                                    value: ttsManager.isSpeaking
                                )
                        }
                    }
                    .frame(height: 30)
                }

                // Controls
                HStack(spacing: 20) {
                    Button {
                        Task {
                            await ttsManager.speak(inputText)
                        }
                    } label: {
                        Label("Speak", systemImage: "play.fill")
                            .font(.title3)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputText.isEmpty || ttsManager.isSpeaking)

                    Button {
                        ttsManager.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.title3)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!ttsManager.isSpeaking)
                }

                if let error = ttsManager.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical)
            .navigationTitle("Text-to-Speech")
            .task {
                await ttsManager.initialize()
            }
        }
    }
}
