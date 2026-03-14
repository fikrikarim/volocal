import SwiftUI

struct ModelDownloadView: View {
    @EnvironmentObject var modelManager: ModelManager
    @State private var isDownloading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // App icon area
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.blue)

                    Text("Locus")
                        .font(.largeTitle.bold())

                    Text("On-device voice AI")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                // Model status cards
                VStack(spacing: 16) {
                    ModelStatusRow(
                        name: "Speech Recognition",
                        detail: ModelManager.sttModel.totalSize,
                        icon: "mic.fill",
                        progress: modelManager.sttDownloadProgress,
                        isReady: modelManager.sttReady
                    )

                    ModelStatusRow(
                        name: "Language Model",
                        detail: ModelManager.llmModel.totalSize,
                        icon: "brain",
                        progress: modelManager.llmDownloadProgress,
                        isReady: modelManager.llmReady
                    )
                }
                .padding(.horizontal)

                if let currentDownload = modelManager.currentDownload {
                    Text("Downloading \(currentDownload)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Download button
                Button {
                    isDownloading = true
                    Task {
                        await modelManager.downloadAllModels()
                        isDownloading = false
                    }
                } label: {
                    HStack {
                        if isDownloading {
                            ProgressView()
                                .tint(.white)
                                .padding(.trailing, 4)
                        }
                        Text(isDownloading ? "Downloading..." : "Download Models (~798 MB)")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading || modelManager.allModelsReady)
                .padding(.horizontal)

                if let error = modelManager.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                // Skip button (for development)
                Button("Skip (use placeholder data)") {
                    modelManager.sttReady = true
                    modelManager.llmReady = true
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom)
            }
            .navigationTitle("")
        }
    }
}

// MARK: - Model Status Row

struct ModelStatusRow: View {
    let name: String
    let detail: String
    let icon: String
    let progress: Double
    let isReady: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(isReady ? .green : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text(isReady ? "Ready" : detail)
                        .font(.caption)
                        .foregroundStyle(isReady ? .green : .secondary)
                }

                if progress > 0 && !isReady {
                    ProgressView(value: progress)
                        .tint(.blue)
                }
            }

            if isReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
