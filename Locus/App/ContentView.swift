import SwiftUI

struct ContentView: View {
    @EnvironmentObject var modelManager: UnifiedModelManager

    var body: some View {
        PipelineView()
    }
}
