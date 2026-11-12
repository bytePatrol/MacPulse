import SwiftUI
import MacPulseCore

/// The "What's using your Mac" dashboard section.
public struct UsageSummaryView: View {
    private let store: InsightsStore

    public init(store: InsightsStore) {
        self.store = store
    }

    public var body: some View {
        UsageSummaryContentView(summary: store.summary, lastError: store.lastError)
    }
}

/// The section's content for a given summary; `UsageSummaryView` feeds it from the store.
/// Shows "Analyzing processes…" while `summary` is nil.
public struct UsageSummaryContentView: View {
    public let summary: UsageSummary?
    public let lastError: String?

    public init(summary: UsageSummary?, lastError: String? = nil) {
        self.summary = summary
        self.lastError = lastError
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What's using your Mac")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Helper processes are combined into the app that owns them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let lastError {
                    Label {
                        Text(lastError)
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(lastError)
                    .padding(.top, 2)
                }
            }

            if let summary {
                UsageSummaryCardView(summary: summary)

                AdaptiveColumnsLayout(minColumnWidth: 320, spacing: 16) {
                    ConsumerListView(metric: .cpu, groups: summary.topCPU)
                    ConsumerListView(metric: .memory, groups: summary.topMemory)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing processes…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                )
            }
        }
    }
}

/// Headline, insight rows and the analysis caption.
public struct UsageSummaryCardView: View {
    public let summary: UsageSummary

    public init(summary: UsageSummary) {
        self.summary = summary
    }

    /// Says "running processes", not "processes analyzed", so the count isn't read as apps.
    private var caption: String {
        let count = summary.measuredProcessCount
        let processes = count == 1 ? "1 running process" : "\(count.formatted()) running processes"
        return "CPU averaged over the last \(formatAveragingWindow(summary.cpuAveragedOverSeconds)) · based on \(processes)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Between the section title (title2) and the card titles (headline) in the hierarchy.
            Text(summary.headline)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !summary.insights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.insights) { insight in
                        InsightRow(insight: insight)
                    }
                }
            }

            Divider()

            Text(caption)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}

private struct InsightRow: View {
    let insight: UsageInsight

    private var tint: Color {
        switch insight.severity {
        case .info: return .secondary
        case .notice: return .blue
        case .warning: return .orange
        }
    }

    private var severityLabel: String {
        switch insight.severity {
        case .info: return "Info"
        case .notice: return "Notice"
        case .warning: return "Warning"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: insight.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityLabel(severityLabel)

            Text(insight.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays its subviews out side by side in equal-width, equal-height columns, or stacks them
/// when the width can't give every column `minColumnWidth`. Unlike `ViewThatFits`, switching
/// keeps each subview's identity, so expanded rows stay expanded.
struct AdaptiveColumnsLayout: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard !subviews.isEmpty else { return (.zero, []) }
        let count = CGFloat(subviews.count)
        let gaps = spacing * (count - 1)
        let totalWidth: CGFloat
        if let width, width.isFinite {
            totalWidth = width
        } else {
            totalWidth = minColumnWidth * count + gaps
        }

        let columnWidth = (totalWidth - gaps) / count
        if columnWidth >= minColumnWidth {
            let rowHeight = subviews
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
            let frames = subviews.indices.map { index in
                CGRect(
                    x: CGFloat(index) * (columnWidth + spacing),
                    y: 0,
                    width: columnWidth,
                    height: rowHeight
                )
            }
            return (CGSize(width: totalWidth, height: rowHeight), frames)
        }

        var frames: [CGRect] = []
        var y: CGFloat = 0
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: totalWidth, height: nil)).height
            frames.append(CGRect(x: 0, y: y, width: totalWidth, height: height))
            y += height + spacing
        }
        return (CGSize(width: totalWidth, height: y - spacing), frames)
    }
}

#if DEBUG
/// Preview-only processes: a multi-process browser, an IDE with a busy compiler helper, a CLI
/// tool with a child database, Spotlight and WindowServer. CPU time advances 2 s per scan.
final class PreviewProcessListProvider: ProcessListProviding, @unchecked Sendable {
    private struct Spec {
        var pid: Int32
        var responsiblePID: Int32
        var name: String
        var path: String
        /// CPU cores' worth of time this process burns.
        var cores: Double
        var memoryMB: UInt64
        var scriptName: String? = nil
    }

    private static let specs: [Spec] = [
        Spec(pid: 501, responsiblePID: 501, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", cores: 0.4, memoryMB: 900),
        Spec(pid: 502, responsiblePID: 501, name: "com.apple.WebKit.WebContent", path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", cores: 0.6, memoryMB: 2_200),
        Spec(pid: 503, responsiblePID: 501, name: "com.apple.WebKit.WebContent", path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", cores: 0.3, memoryMB: 1_400),
        Spec(pid: 504, responsiblePID: 501, name: "com.apple.WebKit.GPU", path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU", cores: 0.2, memoryMB: 600),
        Spec(pid: 601, responsiblePID: 601, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode", cores: 0.3, memoryMB: 2_100),
        Spec(pid: 602, responsiblePID: 601, name: "swift-frontend", path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", cores: 1.6, memoryMB: 1_100),
        Spec(pid: 701, responsiblePID: 701, name: "node", path: "/opt/homebrew/bin/node", cores: 0.2, memoryMB: 300, scriptName: "cpu-load.ts"),
        Spec(pid: 702, responsiblePID: 701, name: "postgres", path: "/opt/homebrew/bin/postgres", cores: 0.05, memoryMB: 120),
        Spec(pid: 801, responsiblePID: 801, name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores", cores: 0.5, memoryMB: 250),
        Spec(pid: 802, responsiblePID: 802, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cores: 0.25, memoryMB: 400),
    ]

    private let lock = NSLock()
    private var scans: UInt64 = 0

    func currentProcessList() throws -> ProcessListSnapshot {
        lock.lock()
        scans += 1
        let elapsed = scans * 2_000_000_000
        lock.unlock()

        let processes = Self.specs.map { spec in
            ProcessSample(
                pid: spec.pid,
                parentPID: 1,
                responsiblePID: spec.responsiblePID,
                name: spec.name,
                executablePath: spec.path,
                cpuTimeNanoseconds: UInt64(Double(elapsed) * spec.cores),
                memoryFootprintBytes: spec.memoryMB * 1_048_576,
                scriptName: spec.scriptName
            )
        }
        return ProcessListSnapshot(
            timestamp: Date(),
            uptimeNanoseconds: elapsed,
            processes: processes,
            unreadableProcessCount: 312
        )
    }
}

private let previewGiB: UInt64 = 1_073_741_824

private func previewGroup(
    id: String,
    name: String,
    kind: ConsumerKind,
    bundlePath: String? = nil,
    processCount: Int,
    cpuPercent: Double,
    memoryGB: Double,
    processes: [ProcessUsage] = []
) -> ConsumerGroup {
    let bytes = UInt64(memoryGB * Double(previewGiB))
    return ConsumerGroup(
        id: id,
        displayName: name,
        kind: kind,
        bundlePath: bundlePath,
        processCount: processCount,
        cpuPercent: cpuPercent,
        memoryBytes: bytes,
        memoryPercent: Double(bytes) / Double(16 * previewGiB) * 100,
        processes: processes
    )
}

private let previewSafari = previewGroup(
    id: "/Applications/Safari.app",
    name: "Safari",
    kind: .app,
    bundlePath: "/Applications/Safari.app",
    processCount: 14,
    cpuPercent: 18,
    memoryGB: 6.1,
    processes: [
        ProcessUsage(pid: 502, name: "com.apple.WebKit.WebContent", cpuPercent: 7.2, memoryBytes: 2_300_000_000),
        ProcessUsage(pid: 503, name: "com.apple.WebKit.WebContent", cpuPercent: 3.1, memoryBytes: 1_500_000_000),
        ProcessUsage(pid: 501, name: "Safari", cpuPercent: 5.8, memoryBytes: 950_000_000),
        ProcessUsage(pid: 504, name: "com.apple.WebKit.GPU", cpuPercent: 1.5, memoryBytes: 640_000_000),
        ProcessUsage(pid: 505, name: "com.apple.WebKit.Networking", cpuPercent: 0.4, memoryBytes: 210_000_000),
    ]
)

private let previewXcode = previewGroup(
    id: "/Applications/Xcode.app",
    name: "Xcode",
    kind: .app,
    bundlePath: "/Applications/Xcode.app",
    processCount: 3,
    cpuPercent: 23,
    memoryGB: 3.2,
    processes: [
        ProcessUsage(pid: 601, name: "Xcode", cpuPercent: 3.9, memoryBytes: 2_200_000_000),
        ProcessUsage(pid: 602, name: "swift-frontend", cpuPercent: 18.6, memoryBytes: 1_150_000_000),
        ProcessUsage(pid: 603, name: "SourceKitService", cpuPercent: 0.5, memoryBytes: 90_000_000),
    ]
)

private let previewOther = previewGroup(
    id: "system:other",
    name: "macOS & background services",
    kind: .otherSystem,
    processCount: 312,
    cpuPercent: 4,
    memoryGB: 2.4
)

private let previewNode = previewGroup(
    id: "exe:/opt/homebrew/bin/node|cpu-load.ts",
    name: "node (cpu-load.ts)",
    kind: .commandLineTool,
    processCount: 2,
    cpuPercent: 3,
    memoryGB: 0.4,
    processes: [
        ProcessUsage(pid: 701, name: "node", cpuPercent: 2.5, memoryBytes: 310_000_000),
        ProcessUsage(pid: 702, name: "postgres", cpuPercent: 0.2, memoryBytes: 125_000_000),
    ]
)

private let previewSummary = UsageSummary(
    timestamp: Date(),
    headline: "Safari is using the most memory (6.1 GB across 14 processes), and Xcode is using the most CPU (23%).",
    insights: [
        UsageInsight(id: "memory-pressure:/Applications/Safari.app", severity: .warning, symbol: "memorychip", text: "Memory is nearly full (88%). Quitting Safari would free about 6.1 GB."),
        UsageInsight(id: "background-task:svc:spotlight", severity: .info, symbol: "clock.arrow.circlepath", text: "Spotlight indexing is running in the background. This is usually temporary."),
        UsageInsight(id: "multiprocess:/Applications/Safari.app", severity: .info, symbol: "square.stack.3d.up", text: "Safari runs 14 separate processes (tabs, extensions and helpers). MacPulse combines them: 6.1 GB in total."),
        UsageInsight(id: "dominant-helper:/Applications/Xcode.app", severity: .notice, symbol: "arrow.down.right.circle", text: "Most of Xcode's CPU is from swift-frontend."),
    ],
    topCPU: [
        previewXcode,
        previewSafari,
        previewGroup(id: "svc:spotlight", name: "Spotlight indexing", kind: .systemService, processCount: 4, cpuPercent: 6, memoryGB: 0.3),
        previewOther,
        previewNode,
    ],
    topMemory: [
        previewSafari,
        previewXcode,
        previewOther,
        previewGroup(id: "/System/Applications/Mail.app", name: "Mail", kind: .app, bundlePath: "/System/Applications/Mail.app", processCount: 1, cpuPercent: 0.4, memoryGB: 0.9),
        previewNode,
    ],
    measuredProcessCount: 938,
    unmeasuredProcessCount: 312,
    cpuAveragedOverSeconds: 10
)

#Preview("What's using your Mac") {
    ScrollView {
        UsageSummaryContentView(summary: previewSummary)
            .padding(24)
    }
    .frame(width: 1040, height: 760)
}

#Preview("Narrow (stacked lists)") {
    ScrollView {
        UsageSummaryContentView(summary: previewSummary)
            .padding(24)
    }
    .frame(width: 560, height: 1100)
}

#Preview("Analyzing, with error") {
    UsageSummaryContentView(summary: nil, lastError: "Couldn't read the process list.")
        .padding(24)
        .frame(width: 800)
}

#Preview("Expanded row") {
    ConsumerRowView(group: previewSafari, metric: .memory, isExpanded: .constant(true))
        .padding(16)
        .frame(width: 420)
}

#Preview("Expanded row, shared memory pending") {
    var pending = previewNode
    pending.sharedMemoryPending = true
    return ConsumerRowView(group: pending, metric: .cpu, isExpanded: .constant(true))
        .padding(16)
        .frame(width: 420)
}

#Preview("Live store, fake processes") {
    let store = InsightsStore(metrics: nil, provider: PreviewProcessListProvider())
    return ScrollView {
        UsageSummaryView(store: store)
            .padding(24)
    }
    .frame(width: 1040, height: 760)
    .task { await store.refreshNow() }
}
#endif
