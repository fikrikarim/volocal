import SwiftUI

struct ModelLoadingView: View {
    @EnvironmentObject var pipeline: VoicePipeline

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text(pipeline.loadingStatus ?? "Preparing...")
                .font(.headline)

            Text("Loading models into memory")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let error = pipeline.currentError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
