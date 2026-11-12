import AppKit
import SwiftUI
import MacPulseCore

/// Which figure a consumer list ranks and draws its bars by.
public enum ConsumerMetric: Sendable {
    case cpu
    case memory

    var title: String {
        switch self {
        case .cpu: return "Top CPU"
        case .memory: return "Top Memory"
        }
    }

    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        }
    }

    /// Same tints as the CPU and Memory history charts.
    var tint: Color {
        switch self {
        case .cpu: return .blue
        case .memory: return .purple
        }
    }

    var emptyMessage: String {
        switch self {
        case .cpu: return "Nothing is using noticeable CPU right now."
        case .memory: return "No memory readings yet."
        }
    }

    func value(of group: ConsumerGroup) -> String {
        switch self {
        case .cpu: return formatUsagePercent(group.cpuPercent)
        case .memory: return formatMemoryBytes(group.memoryBytes)
        }
    }

    /// What the bar shows, spoken: "18% of total CPU" / "38% of RAM".
    func barDescription(of group: ConsumerGroup) -> String {
        switch self {
        case .cpu: return "\(formatUsagePercent(group.cpuPercent)) of total CPU"
        case .memory: return "\(formatUsagePercent(group.memoryPercent)) of RAM"
        }
    }

    /// Bar fill, 0...1: share of the whole machine's CPU, or share of physical RAM.
    func fraction(of group: ConsumerGroup) -> Double {
        switch self {
        case .cpu: return group.cpuPercent / 100
        case .memory: return group.memoryPercent / 100
        }
    }
}

/// A "Top CPU" or "Top Memory" card. Clicking a row expands its member processes.
public struct ConsumerListView: View {
    public let metric: ConsumerMetric
    public let groups: [ConsumerGroup]

    /// Keyed by group id, so a row stays open across refreshes while it remains in the list.
    @State private var expandedGroupIDs: Set<String> = []

    public init(metric: ConsumerMetric, groups: [ConsumerGroup]) {
        self.metric = metric
        self.groups = groups
    }

    public var body: some View {
        MetricCardContainer(title: metric.title, icon: metric.icon, iconColor: metric.tint) {
            VStack(alignment: .leading, spacing: 12) {
                if groups.isEmpty {
                    Text(metric.emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groups) { group in
                        ConsumerRowView(group: group, metric: metric, isExpanded: expansionBinding(for: group.id))
                    }
                }
            }
            // Lets side-by-side cards share one height.
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroupIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedGroupIDs.insert(id)
                } else {
                    expandedGroupIDs.remove(id)
                }
            }
        )
    }
}

/// One app (or tool/service) row: icon, name, process count, a thin bar and the value.
public struct ConsumerRowView: View {
    public let group: ConsumerGroup
    public let metric: ConsumerMetric
    @Binding private var isExpanded: Bool

    public init(group: ConsumerGroup, metric: ConsumerMetric, isExpanded: Binding<Bool>) {
        self.group = group
        self.metric = metric
        self._isExpanded = isExpanded
    }

    private var canExpand: Bool {
        !group.processes.isEmpty
    }

    private var processCaption: String? {
        // The remainder group may have no unreadable processes behind it; "0 processes" would mislead.
        if group.kind == .otherSystem && group.processCount == 0 {
            return nil
        }
        return formatProcessCount(group.processCount)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canExpand {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    summaryLine
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Hides its processes" : "Shows its processes")
            } else {
                summaryLine
            }

            if canExpand && isExpanded {
                MemberProcessList(group: group)
                    .padding(.leading, 34)
                    .transition(.opacity)
            }
        }
    }

    private var summaryLine: some View {
        HStack(alignment: .center, spacing: 10) {
            ConsumerIcon(group: group)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The name wins space over the process count; the value never shrinks.
                    Text(group.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    if let processCaption {
                        // Whole or not at all: a clipped "2…" would misread as a count.
                        ViewThatFits(in: .horizontal) {
                            Text(processCaption)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            // Not EmptyView: that adds no child, leaving the Text as the fallback.
                            Color.clear
                                .frame(width: 0, height: 0)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(metric.value(of: group))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .fixedSize()
                }

                UsageBar(fraction: metric.fraction(of: group), tint: metric.tint)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                // Hidden rather than removed so every row's bar ends at the same x.
                .opacity(canExpand ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        // Full name for truncated rows; the remainder group explains itself instead.
        .help(group.kind == .otherSystem ? otherSystemHelp : group.displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(accessibilityValueText)
        .accessibilityAddTraits(canExpand ? .isButton : [])
    }

    /// e.g. "Safari, 14 processes".
    private var accessibilityLabelText: String {
        [group.displayName, processCaption]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// e.g. "18% of total CPU, collapsed", "6.1 GB, 38% of RAM, expanded" or
    /// "18% of total CPU, memory still being measured, collapsed".
    private var accessibilityValueText: String {
        var parts: [String] = []
        if metric == .memory {
            parts.append(metric.value(of: group))
        }
        parts.append(metric.barDescription(of: group))
        if group.sharedMemoryPending {
            parts.append("memory still being measured")
        }
        if canExpand {
            parts.append(isExpanded ? "expanded" : "collapsed")
        }
        return parts.joined(separator: ", ")
    }

    private var otherSystemHelp: String {
        "Everything MacPulse can't attribute to an app: system processes that need admin rights to inspect, plus macOS's own CPU and memory overhead."
    }
}

/// The member processes of an expanded group: name, CPU and memory.
private struct MemberProcessList: View {
    let group: ConsumerGroup

    private var hiddenCount: Int {
        max(0, group.processCount - group.processes.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Process")
                Spacer(minLength: 8)
                Text("CPU")
                    .frame(width: 56, alignment: .trailing)
                Text("Memory")
                    .frame(width: 72, alignment: .trailing)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)

            ForEach(group.processes) { process in
                HStack(spacing: 8) {
                    Text(process.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(formatUsagePercent(process.cpuPercent))
                        .frame(width: 56, alignment: .trailing)
                    // Until shared memory is walked, footprints may count it more than once.
                    if group.sharedMemoryPending {
                        Text("measuring…")
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)
                            .help("Shared memory is still being measured")
                    } else {
                        Text(formatMemoryBytes(process.memoryBytes))
                            .frame(width: 72, alignment: .trailing)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(Text(verbatim: "PID \(process.pid)"))
            }

            if hiddenCount > 0 {
                // Verbatim, so the count is in the string itself rather than a "%lld" format argument.
                Text(verbatim: "+ \(hiddenCount) more")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The app's own icon for .app groups; an SF Symbol per kind otherwise.
private struct ConsumerIcon: View {
    let group: ConsumerGroup

    private var symbol: String {
        switch group.kind {
        case .app: return "app"
        case .commandLineTool: return "terminal"
        case .systemService: return "gearshape.2"
        case .otherSystem: return "apple.logo"
        }
    }

    var body: some View {
        Group {
            if group.kind == .app, let bundlePath = group.bundlePath {
                Image(nsImage: AppIconCache.icon(forBundlePath: bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// `NSWorkspace` icon lookups hit the disk; the same few apps are redrawn every refresh.
@MainActor
private enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forBundlePath path: String) -> NSImage {
        if let cached = icons[path] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

/// A thin capsule bar, 0...1.
private struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: fillWidth(in: proxy.size.width))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func fillWidth(in width: CGFloat) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return 0 }
        // Keep tiny values visible as a dot.
        return max(4, width * clamped)
    }
}
