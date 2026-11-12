import SwiftUI
import Charts
import MacPulseCore

/// A Swift Charts line/area chart displaying metric history over a sliding time window.
public struct HistoryChartView: View {
    public let title: String
    public let icon: String
    public let tintColor: Color
    public let samples: [MetricSample]
    public let historyWindow: TimeInterval

    public init(
        title: String,
        icon: String,
        tintColor: Color = .accentColor,
        samples: [MetricSample],
        historyWindow: TimeInterval = 60
    ) {
        self.title = title
        self.icon = icon
        self.tintColor = tintColor
        self.samples = samples
        self.historyWindow = max(1, historyWindow)
    }

    private var currentSample: MetricSample? {
        samples.last
    }

    private var xDomain: ClosedRange<Date> {
        let end = currentSample?.timestamp ?? Date()
        let start = end.addingTimeInterval(-historyWindow)
        return start...end
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [tintColor.opacity(0.35), tintColor.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerView

            if samples.isEmpty {
                emptyStateView
            } else {
                chartView
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tintColor)
                .frame(width: 24, height: 24)
                .background(tintColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            if let current = currentSample {
                Text(formatPercent(current.value))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.xyaxis.line")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No history samples yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var chartView: some View {
        Chart {
            ForEach(samples) { (sample: MetricSample) in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Percentage", sample.value)
                )
                .foregroundStyle(gradient)
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Percentage", sample.value)
                )
                .foregroundStyle(tintColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text("\(intVal)%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minHeight: 180)
        .animation(.easeInOut(duration: 0.25), value: samples)
    }
}

/// Swift Charts line/area chart specialized for CPU history.
public struct CPUHistoryChartView: View {
    public let samples: [MetricSample]
    public let historyWindow: TimeInterval

    public init(samples: [MetricSample], historyWindow: TimeInterval = 60) {
        self.samples = samples
        self.historyWindow = historyWindow
    }

    public var body: some View {
        HistoryChartView(
            title: "CPU History",
            icon: "chart.line.uptrend.xyaxis",
            tintColor: .blue,
            samples: samples,
            historyWindow: historyWindow
        )
    }
}

/// Swift Charts line/area chart specialized for Memory history.
public struct MemoryHistoryChartView: View {
    public let samples: [MetricSample]
    public let historyWindow: TimeInterval

    public init(samples: [MetricSample], historyWindow: TimeInterval = 60) {
        self.samples = samples
        self.historyWindow = historyWindow
    }

    public var body: some View {
        HistoryChartView(
            title: "Memory History",
            icon: "memorychip",
            tintColor: .purple,
            samples: samples,
            historyWindow: historyWindow
        )
    }
}
