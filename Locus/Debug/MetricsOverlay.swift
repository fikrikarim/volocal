import SwiftUI

/// Compact debug overlay showing real-time memory and CPU stats.
/// Tap to expand and see per-component memory breakdown.
struct MetricsOverlay: View {
    @EnvironmentObject var metrics: SystemMetrics
    @State private var expanded = true

    var body: some View {
        if metrics.isVisible {
            VStack(alignment: .leading, spacing: 4) {
                // Compact bar — always visible
                HStack(spacing: 8) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                    Text("\(metrics.memoryMB, specifier: "%.0f") MB")
                        .font(.caption2.monospacedDigit())

                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text("\(metrics.cpuPercent, specifier: "%.0f")%")
                        .font(.caption2.monospacedDigit())

                    Spacer()

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { expanded.toggle() } }

                // Expanded: per-component breakdown
                if expanded {
                    Divider()

                    if metrics.componentMemory.isEmpty {
                        Text("No models loaded")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(metrics.componentMemory.sorted(by: { $0.key < $1.key }), id: \.key) { name, mb in
                            HStack {
                                Text(name)
                                    .font(.caption2)
                                Spacer()
                                if mb < 0 {
                                    Text("loading...")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("\(mb, specifier: "%.0f") MB")
                                        .font(.caption2.monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(true)
        }
    }
}
