import SwiftUI

struct ContentView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        TabView {
            STTTestView()
                .tabItem {
                    Label("STT", systemImage: "mic.fill")
                }

            LLMTestView()
                .tabItem {
                    Label("LLM", systemImage: "brain")
                }

            TTSTestView()
                .tabItem {
                    Label("TTS", systemImage: "speaker.wave.3.fill")
                }

            PipelineView()
                .tabItem {
                    Label("Pipeline", systemImage: "waveform")
                }
        }
    }
}
