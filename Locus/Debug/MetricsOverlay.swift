import SwiftUI

/// Always-visible compact debug overlay showing real-time system metrics.
struct MetricsOverlay: View {
    @EnvironmentObject var metrics: SystemMetrics

    var body: some View {
        HStack(spacing: 6) {
            Label("\(metrics.memoryMB, specifier: "%.0f") MB", systemImage: "memorychip")
            Text("·")
            Label("\(metrics.cpuPercent, specifier: "%.0f")%", systemImage: "cpu")
            Text("·")
            Text(metrics.thermalStateLabel)
                .foregroundStyle(thermalColor)
        }
        .font(.caption2.monospacedDigit())
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private var thermalColor: Color {
        switch metrics.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}
