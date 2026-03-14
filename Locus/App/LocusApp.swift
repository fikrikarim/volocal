import SwiftUI

@main
struct LocusApp: App {
    @StateObject private var modelManager = ModelManager()
    @StateObject private var metrics = SystemMetrics()
    @StateObject private var pipeline = VoicePipeline()

    var body: some Scene {
        WindowGroup {
            if !modelManager.allModelsReady {
                ModelDownloadView()
                    .environmentObject(modelManager)
            } else if !pipeline.isReady {
                ModelLoadingView()
                    .environmentObject(pipeline)
                    .task {
                        pipeline.metrics = metrics
                        metrics.startMonitoring()
                        await pipeline.configure(
                            llmModelPath: modelManager.llmModelPath
                        )
                    }
            } else {
                ContentView()
                    .environmentObject(modelManager)
                    .environmentObject(metrics)
                    .environmentObject(pipeline)
                    .overlay { MetricsOverlay().environmentObject(metrics) }
            }
        }
    }
}
