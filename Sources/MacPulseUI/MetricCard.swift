import SwiftUI
import MacPulseCore

/// Reusable card container styled for modern macOS (materials, rounded corners, semantic borders).
public struct MetricCardContainer<Content: View>: View {
    private let title: String
    private let icon: String
    private let iconColor: Color
    private let content: Content

    public init(
        title: String,
        icon: String,
        iconColor: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()
            }

            content
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

/// Dynamic gauge tint color reflecting system load (semantic colors).
private func loadColor(for percent: Double) -> Color {
    switch percent {
    case ..<60:
        return .accentColor
    case ..<85:
        return .orange
    default:
        return .red
    }
}

/// CPU metric card displaying current utilisation percentage and gauge.
public struct CPUCardView: View {
    public let usage: CPUUsage

    public init(usage: CPUUsage) {
        self.usage = usage
    }

    public var body: some View {
        MetricCardContainer(title: "CPU", icon: "cpu", iconColor: loadColor(for: usage.percent)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatPercent(usage.percent))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("utilization")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                Gauge(value: max(0, min(100, usage.percent)), in: 0...100) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .labelsHidden()
                .accessibilityLabel("CPU Load")
                .tint(loadColor(for: usage.percent))

                HStack {
                    Text("System Load")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatPercentPrecise(usage.percent))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Memory metric card displaying used bytes vs total, available bytes, and used percentage.
public struct MemoryCardView: View {
    public let usage: MemoryUsage

    public init(usage: MemoryUsage) {
        self.usage = usage
    }

    public var body: some View {
        MetricCardContainer(title: "Memory", icon: "memorychip", iconColor: loadColor(for: usage.usedPercent)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatPercent(usage.usedPercent))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                Gauge(value: max(0, min(100, usage.usedPercent)), in: 0...100) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .labelsHidden()
                .accessibilityLabel("Memory")
                .tint(loadColor(for: usage.usedPercent))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Used \(formatMemoryBytes(usage.usedBytes)) of \(formatMemoryBytes(usage.totalBytes))")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    HStack {
                        Text("Available:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatMemoryBytes(usage.availableBytes))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Disk metric card displaying used bytes, available bytes, total capacity, and used percentage.
public struct DiskCardView: View {
    public let usage: DiskUsage

    public init(usage: DiskUsage) {
        self.usage = usage
    }

    public var body: some View {
        MetricCardContainer(title: "Disk", icon: "internaldrive", iconColor: loadColor(for: usage.usedPercent)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatPercent(usage.usedPercent))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                Gauge(value: max(0, min(100, usage.usedPercent)), in: 0...100) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .labelsHidden()
                .accessibilityLabel("Disk")
                .tint(loadColor(for: usage.usedPercent))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Used:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatDiskBytes(usage.usedBytes))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("Total: \(formatDiskBytes(usage.totalBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Text("\(formatDiskBytes(usage.availableBytes)) available")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}
