import SwiftUI
import MacPulseCore

public struct DashboardView: View {
    private let store: MetricsStore
    /// "What's using your Mac" source; the section is hidden when nil.
    private let insights: InsightsStore?

    public init(store: MetricsStore, insights: InsightsStore? = nil) {
        self.store = store
        self.insights = insights
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                // Header with app name and Refresh button
                HStack(alignment: .center) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path.ecg.rectangle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)

                        Text(MacPulseInfo.appName)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                    }

                    Spacer()

                    Button(action: {
                        store.refresh()
                        insights?.refresh()
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh metrics (⌘R)")
                    .buttonStyle(.bordered)
                }

                // Unobtrusive error display
                if let error = store.lastError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.headline)

                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                }

                // Main content: either placeholder or real metric cards & charts
                if let snapshot = store.latest {
                    // Metric Cards Row
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 220), spacing: 16),
                            GridItem(.flexible(minimum: 220), spacing: 16),
                            GridItem(.flexible(minimum: 220), spacing: 16)
                        ],
                        spacing: 16
                    ) {
                        CPUCardView(usage: snapshot.cpu)
                        MemoryCardView(usage: snapshot.memory)
                        DiskCardView(usage: snapshot.disk)
                    }

                    // Swift Charts Row
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 320), spacing: 16),
                            GridItem(.flexible(minimum: 320), spacing: 16)
                        ],
                        spacing: 16
                    ) {
                        CPUHistoryChartView(samples: store.cpuHistory, historyWindow: store.historyWindow)
                        MemoryHistoryChartView(samples: store.memoryHistory, historyWindow: store.historyWindow)
                    }
                } else {
                    // Placeholder state while waiting for the first snapshot
                    VStack(spacing: 16) {
                        Spacer(minLength: 40)
                        ProgressView()
                            .controlSize(.large)
                        Text("Collecting data…")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Sampling system metrics...")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: .infinity, minHeight: 400)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                    )
                }

                // "What's using your Mac": independent of the metrics placeholder above.
                if let insights {
                    UsageSummaryView(store: insights)
                        .padding(.top, 8)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#if DEBUG
private struct PreviewSystemMetricsProvider: SystemMetricsProviding {
    func currentSnapshot() throws -> SystemSnapshot {
        SystemSnapshot(
            timestamp: Date(),
            cpu: CPUUsage(percent: 28.5),
            memory: MemoryUsage(totalBytes: 16 * 1024 * 1024 * 1024, usedBytes: 10 * 1024 * 1024 * 1024),
            disk: DiskUsage(totalBytes: 500 * 1000 * 1000 * 1000, availableBytes: 215 * 1000 * 1000 * 1000)
        )
    }
}

#Preview("Dashboard") {
    let store = MetricsStore(provider: PreviewSystemMetricsProvider())
    let insights = InsightsStore(metrics: store, provider: PreviewProcessListProvider())
    return DashboardView(store: store, insights: insights)
        .frame(width: 1040, height: 940)
        .onAppear {
            store.start()
            insights.start()
        }
}
#endif
