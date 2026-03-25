import SwiftUI

struct ContentView: View {
    @EnvironmentObject var modelManager: UnifiedModelManager

    var body: some View {
        TabView {
            PipelineView()
                .tabItem {
                    Label("Pipeline", systemImage: "waveform")
                }

            #if DEBUG
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
            #endif
        }
    }
}
