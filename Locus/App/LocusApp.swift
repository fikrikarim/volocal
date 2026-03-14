import SwiftUI

@main
struct LocusApp: App {
    @StateObject private var modelManager = ModelManager()

    var body: some Scene {
        WindowGroup {
            if modelManager.allModelsReady {
                ContentView()
                    .environmentObject(modelManager)
            } else {
                ModelDownloadView()
                    .environmentObject(modelManager)
            }
        }
    }
}
