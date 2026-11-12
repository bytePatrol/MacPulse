// Render smoke tests for the dashboard and About screen.
import AppKit
import SwiftUI
import XCTest
@testable import MacPulseCore
@testable import MacPulseUI

@MainActor
final class UISmokeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testAboutViewRendersVersionOnePointZero() {
        let about = AboutView()
        assertRenders(about.frame(width: 320, height: 260))
        let text = harvestedText(from: about)
        XCTAssertTrue(text.contains("MacPulse"), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("Version"), "About should label the version. Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("1.0"), "About should show version 1.0. Harvested: \(preview(text))")
    }

    func testDashboardRendersPlaceholderAndPopulatedStates() {
        let provider = FixedMetricsProvider()
        let store = MetricsStore(provider: provider, refreshInterval: 30, historyWindow: 60)
        let placeholder = DashboardView(store: store)
        assertRenders(placeholder.frame(width: 900, height: 640))
        let placeholderText = harvestedText(from: placeholder)
        XCTAssertTrue(
            placeholderText.contains("Collecting data"),
            "nil latest should show the collecting placeholder. Harvested: \(preview(placeholderText))"
        )

        provider.enqueue(sampleSnapshot)
        store.refresh()
        XCTAssertNotNil(store.latest, "fake provider sample should populate MetricsStore")
        XCTAssertEqual(store.cpuHistory.count, 1)
        XCTAssertEqual(store.memoryHistory.count, 1)

        let populated = DashboardView(store: store)
        assertRenders(populated.frame(width: 900, height: 640))
        let populatedText = harvestedText(from: populated)
        XCTAssertTrue(populatedText.contains("Refresh"), "Harvested: \(preview(populatedText))")
        XCTAssertTrue(populatedText.contains("MacPulse"), "Harvested: \(preview(populatedText))")
        XCTAssertFalse(
            populatedText.contains("Collecting data"),
            "populated store should leave the placeholder. Harvested: \(preview(populatedText))"
        )
    }

    /// Regression: the dashboard once had a header Refresh button and a second toolbar Refresh button.
    func testDashboardHasASingleRefreshButton() {
        let store = MetricsStore(provider: FixedMetricsProvider(), refreshInterval: 30, historyWindow: 60)
        let dashboard = DashboardView(store: store)
        assertRenders(dashboard.frame(width: 900, height: 640))
        var strings: [String] = []
        collectMirrorStrings(dashboard, depth: 0, into: &strings)
        let text = strings.joined(separator: "\n")
        let refreshLabels = strings.filter { $0 == "Refresh" }
        XCTAssertEqual(
            refreshLabels.count,
            1,
            "expected one Refresh button (header, ⌘R). Harvested: \(preview(text))"
        )
        XCTAssertTrue(text.contains("arrow.clockwise"), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("Refresh metrics"), "the remaining button should keep its help. Harvested: \(preview(text))")
    }

    func testMetricCardsAndChartsRenderInBothAppearances() {
        let cpu = CPUCardView(usage: CPUUsage(percent: 23.4))
        let memory = MemoryCardView(
            usage: MemoryUsage(totalBytes: 8 * 1024 * 1024 * 1024, usedBytes: 2 * 1024 * 1024 * 1024)
        )
        let disk = DiskCardView(
            usage: DiskUsage(totalBytes: 1_000_000_000_000, availableBytes: 400_000_000_000)
        )
        let samples = [
            MetricSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000), value: 23.4),
            MetricSample(timestamp: Date(timeIntervalSince1970: 1_700_000_030), value: 40),
        ]
        let charts = CPUHistoryChartView(samples: samples, historyWindow: 60)

        for view in [AnyView(cpu), AnyView(memory), AnyView(disk), AnyView(charts), AnyView(MemoryHistoryChartView(samples: [], historyWindow: 60))] {
            assertRenders(view.frame(width: 360, height: 240))
        }

        let cpuText = harvestedText(from: cpu)
        XCTAssertTrue(cpuText.contains("23%"), "CPU card should show the rounded percent. Harvested: \(preview(cpuText))")
        XCTAssertTrue(cpuText.contains("23.4%"), "CPU card should show the precise percent. Harvested: \(preview(cpuText))")

        let memoryText = harvestedText(from: memory)
        XCTAssertTrue(memoryText.contains("Used"), "Harvested: \(preview(memoryText))")
        XCTAssertTrue(memoryText.contains(formatMemoryBytes(2 * 1024 * 1024 * 1024)), "Harvested: \(preview(memoryText))")

        let diskText = harvestedText(from: disk)
        XCTAssertTrue(diskText.contains("available"), "Harvested: \(preview(diskText))")
        XCTAssertTrue(diskText.contains(formatDiskBytes(400_000_000_000)), "Harvested: \(preview(diskText))")
    }

    func testUsageSummaryPlaceholderRendersInLightAndDark() {
        let store = InsightsStore(
            metrics: nil,
            provider: IdleProcessProvider(),
            refreshInterval: 30,
            cpuAveragingWindow: 10
        )
        let view = UsageSummaryView(store: store).frame(width: 900, height: 480)
        assertRenders(view)
        let text = harvestedText(from: UsageSummaryContentView(summary: nil, lastError: "Process analysis unavailable."))
        XCTAssertTrue(text.contains("What's using your Mac"))
        XCTAssertTrue(text.contains("Analyzing processes…"))
        XCTAssertTrue(text.contains("Process analysis unavailable."))
        XCTAssertTrue(text.contains("exclamationmark.triangle.fill"))
    }

    func testUsageSummaryPopulatedRendersInLightAndDark() async {
        let provider = TwoScanProcessProvider()
        let store = InsightsStore(
            metrics: nil,
            provider: provider,
            refreshInterval: 30,
            cpuAveragingWindow: 10,
            logicalCPUCount: 2,
            physicalMemoryBytes: 10_000
        )
        await store.refreshNow()
        let headline = store.summary?.headline ?? ""
        XCTAssertFalse(headline.isEmpty)
        let view = UsageSummaryView(store: store).frame(width: 900, height: 720)
        assertRenders(view)
        let text = harvestedText(from: view)
        XCTAssertTrue(text.contains(headline), "Harvested: \(preview(text))")
        XCTAssertFalse(text.contains("Analyzing processes…"), "Harvested: \(preview(text))")
    }

    func testUsageCaptionCountsRunningProcesses() {
        let summary = usageSummary(processes: 14, averaged: 10, cpu: 18)
        let card = UsageSummaryCardView(summary: summary).frame(width: 720, height: 280)
        assertRenders(card)
        let text = harvestedText(from: card)
        XCTAssertTrue(text.contains(summary.headline), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("CPU averaged over the last 10 s"), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("based on 14 running processes"), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("Firefox runs 14 separate processes."), "Harvested: \(preview(text))")
    }

    func testConsumerRowShowsSubOnePercentAndExpandedMembers() {
        let quiet = consumerGroup(name: "Notes", cpu: 0.4, processes: 1)
        let quietRow = ConsumerRowView(group: quiet, metric: .cpu, isExpanded: .constant(false))
            .frame(width: 420, height: 64)
        assertRenders(quietRow)
        let quietText = harvestedText(from: quietRow)
        XCTAssertTrue(quietText.contains("<1%"), "0.4% CPU should read <1%. Harvested: \(preview(quietText))")

        let idle = consumerGroup(name: "Notes", cpu: 0, processes: 1)
        let idleText = harvestedText(from: ConsumerRowView(group: idle, metric: .cpu, isExpanded: .constant(false)))
        XCTAssertTrue(idleText.contains("0%"), "Harvested: \(preview(idleText))")
        XCTAssertFalse(idleText.contains("<1%"), "Harvested: \(preview(idleText))")

        var busy = consumerGroup(name: "Safari", cpu: 18, processes: 14, memory: 6_550_000_000)
        busy = ConsumerGroup(
            id: busy.id, displayName: busy.displayName, kind: .app, bundlePath: busy.bundlePath,
            processCount: 10, cpuPercent: 18, memoryBytes: busy.memoryBytes, memoryPercent: busy.memoryPercent,
            processes: (0..<8).map {
                ProcessUsage(pid: Int32($0 + 1), name: "content \($0)", cpuPercent: 1, memoryBytes: 1_000)
            }
        )
        let expanded = ConsumerRowView(group: busy, metric: .memory, isExpanded: .constant(true))
            .frame(width: 480, height: 320)
        assertRenders(expanded)
        let text = harvestedText(from: expanded)
        XCTAssertTrue(text.contains("Process"), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("CPU"), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("Memory"), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("+ 2 more"), "Harvested: \(preview(String(text.suffix(500))))")
        XCTAssertTrue(text.contains("Safari, 10 processes"), "Harvested: \(preview(text))")
        let memoryText = formatMemoryBytes(busy.memoryBytes)
        XCTAssertTrue(
            compact(text).contains(compact(memoryText)),
            "expected \(memoryText.debugDescription). Harvested: \(preview(text))"
        )
    }

    /// Member "measuring…" text lives inside ForEach, which Mirror does not walk.
    /// The row accessibility value is the checkable signal.
    func testPendingRowAnnouncesThatMemoryIsStillBeingMeasured() {
        let pending = ConsumerGroup(
            id: "/tmp/Huge.app",
            displayName: "Huge",
            kind: .app,
            bundlePath: "/tmp/Huge.app",
            processCount: 3,
            cpuPercent: 18,
            memoryBytes: 8_000_000_000,
            memoryPercent: 12,
            processes: [ProcessUsage(pid: 1, name: "postgres", cpuPercent: 18, memoryBytes: 8_000_000_000)],
            sharedMemoryPending: true
        )
        let collapsed = harvestedText(
            from: ConsumerRowView(group: pending, metric: .cpu, isExpanded: .constant(false))
        )
        XCTAssertTrue(
            collapsed.contains("18% of total CPU, memory still being measured, collapsed"),
            "Harvested: \(preview(collapsed))"
        )
        let expanded = harvestedText(
            from: ConsumerRowView(group: pending, metric: .cpu, isExpanded: .constant(true))
        )
        XCTAssertTrue(
            expanded.contains("18% of total CPU, memory still being measured, expanded"),
            "Harvested: \(preview(expanded))"
        )
        XCTAssertTrue(expanded.contains("18%"), "CPU stays visible while memory is unmeasured. Harvested: \(preview(expanded))")

        let measured = harvestedText(
            from: ConsumerRowView(group: consumerGroup(name: "Mail", cpu: 18, processes: 1), metric: .cpu, isExpanded: .constant(false))
        )
        XCTAssertFalse(measured.contains("memory still being measured"), "Harvested: \(preview(measured))")
        XCTAssertTrue(measured.contains("18% of total CPU, collapsed"), "Harvested: \(preview(measured))")
    }

    func testConsumerListsShowEmptyStates() {
        let cpu = ConsumerListView(metric: .cpu, groups: []).frame(width: 360, height: 180)
        let memory = ConsumerListView(metric: .memory, groups: []).frame(width: 360, height: 180)
        assertRenders(cpu)
        assertRenders(memory)
        XCTAssertTrue(harvestedText(from: cpu).contains("Nothing is using noticeable CPU right now."))
        XCTAssertTrue(harvestedText(from: cpu).contains("Top CPU"))
        XCTAssertTrue(harvestedText(from: memory).contains("No memory readings yet."))
        XCTAssertTrue(harvestedText(from: memory).contains("Top Memory"))
    }

    func testRemainderRowOmitsAZeroProcessCount() {
        let remainder = ConsumerGroup(
            id: "system:other",
            displayName: "macOS & background services",
            kind: .otherSystem,
            bundlePath: nil,
            processCount: 0,
            cpuPercent: 12,
            memoryBytes: 0,
            memoryPercent: 0,
            processes: []
        )
        let text = harvestedText(from: ConsumerRowView(group: remainder, metric: .cpu, isExpanded: .constant(false)))
        XCTAssertTrue(text.contains("macOS & background services"), "Harvested: \(preview(text))")
        XCTAssertTrue(text.contains("12%"), "Harvested: \(preview(text))")
        XCTAssertFalse(text.contains("0 processes"), "Harvested: \(preview(text))")
    }

    func testDashboardWithInsightsShowsUsageSectionAndOneRefresh() {
        let metrics = MetricsStore(provider: FixedMetricsProvider(), refreshInterval: 30, historyWindow: 60)
        let insights = InsightsStore(metrics: metrics, provider: IdleProcessProvider(), refreshInterval: 30)
        let dashboard = DashboardView(store: metrics, insights: insights).frame(width: 1040, height: 940)
        assertRenders(dashboard)
        let text = harvestedText(from: dashboard)
        XCTAssertTrue(text.contains("What's using your Mac"), "Harvested: \(preview(text))")

        var labels: [String] = []
        collectMirrorStrings(dashboard, depth: 0, into: &labels)
        XCTAssertEqual(labels.filter { $0 == "Refresh" }.count, 1, "Harvested: \(preview(labels.joined(separator: " | ")))")
    }

    func testDashboardWithoutInsightsHidesUsageSection() {
        let metrics = MetricsStore(provider: FixedMetricsProvider(), refreshInterval: 30, historyWindow: 60)
        let dashboard = DashboardView(store: metrics)
        let text = harvestedText(from: dashboard)
        XCTAssertFalse(text.contains("What's using your Mac"), "Harvested: \(preview(text))")
    }
}

@MainActor
private func assertRenders<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
    for scheme in [ColorScheme.light, ColorScheme.dark] {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = renderer.nsImage
        XCTAssertNotNil(image, "ImageRenderer returned nil in \(scheme)", file: file, line: line)
        XCTAssertGreaterThan(image?.size.width ?? 0, 0, "zero-width render in \(scheme)", file: file, line: line)
        XCTAssertGreaterThan(image?.size.height ?? 0, 0, "zero-height render in \(scheme)", file: file, line: line)
    }

    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(host.bounds.isEmpty, file: file, line: line)
}

private func harvestedText(from view: some View) -> String {
    var strings: [String] = []
    collectMirrorStrings(view, depth: 0, into: &strings)
    // `.frame()` is ModifiedContent. Calling its body traps; only MacPulseUI views are expanded.
    let typeName = String(reflecting: type(of: view))
    let head = typeName.split(separator: "<", maxSplits: 1).first.map(String.init) ?? typeName
    if head.contains("MacPulseUI.") {
        collectMirrorStrings(view.body, depth: 0, into: &strings)
    }

    let host = NSHostingView(rootView: AnyView(view))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    collectAppKitText(host, into: &strings)
    return strings.joined(separator: "\n")
}

private func collectMirrorStrings(_ value: Any, depth: Int, into output: inout [String]) {
    if depth > 46 || output.count > 12_000 { return }
    if let string = value as? String {
        if !string.isEmpty { output.append(string) }
        return
    }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        if let child = mirror.children.first {
            collectMirrorStrings(child.value, depth: depth + 1, into: &output)
        }
    } else {
        for child in mirror.children {
            collectMirrorStrings(child.value, depth: depth + 1, into: &output)
        }
    }
    // Nested card and chart text lives in their own `body`, which Mirror does not evaluate.
    // Match only types declared in MacPulseUI. Generic SwiftUI wrappers mention that
    // module in their type arguments, and calling `body` on them traps.
    let typeName = String(reflecting: type(of: value))
    let head = typeName.split(separator: "<", maxSplits: 1).first.map(String.init) ?? typeName
    if depth < 34, head.contains("MacPulseUI."), let view = value as? any View {
        collectMirrorStrings(view.body, depth: depth + 1, into: &output)
    }
}

private func collectAppKitText(_ view: NSView, into output: inout [String]) {
    if let field = view as? NSTextField, !field.stringValue.isEmpty {
        output.append(field.stringValue)
    }
    if let text = view as? NSTextView, !text.string.isEmpty {
        output.append(text.string)
    }
    if let label = view.accessibilityLabel(), !label.isEmpty {
        output.append(label)
    }
    if let value = view.accessibilityValue() as? String, !value.isEmpty {
        output.append(value)
    }
    for subview in view.subviews {
        collectAppKitText(subview, into: &output)
    }
}

private func compact(_ text: String) -> String {
    text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
}

private func preview(_ text: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " | ")
    return flat.count > 600 ? String(flat.prefix(600)) + "…" : flat
}

private let sampleSnapshot = SystemSnapshot(
    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
    cpu: CPUUsage(percent: 23),
    memory: MemoryUsage(totalBytes: 16 * 1024 * 1024 * 1024, usedBytes: 8 * 1024 * 1024 * 1024),
    disk: DiskUsage(totalBytes: 500 * 1000 * 1000 * 1000, availableBytes: 215 * 1000 * 1000 * 1000)
)

private func usageSummary(processes: Int, averaged: Double, cpu: Double) -> UsageSummary {
    let group = consumerGroup(name: "Firefox", cpu: cpu, processes: processes, memory: 6_100_000_000)
    return UsageSummary(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        headline: "Firefox is the heaviest app right now: 6.1 GB of memory and 18% CPU across \(processes) processes.",
        insights: [
            UsageInsight(
                id: "multiprocess:/tmp/Firefox.app",
                severity: .info,
                symbol: "square.stack.3d.up",
                text: "Firefox runs \(processes) separate processes."
            ),
        ],
        topCPU: [group],
        topMemory: [group],
        measuredProcessCount: processes,
        unmeasuredProcessCount: 0,
        cpuAveragedOverSeconds: averaged
    )
}

private func consumerGroup(name: String, cpu: Double, processes: Int, memory: UInt64 = 1_000) -> ConsumerGroup {
    ConsumerGroup(
        id: "/tmp/\(name).app",
        displayName: name,
        kind: .app,
        bundlePath: "/tmp/\(name).app",
        processCount: processes,
        cpuPercent: cpu,
        memoryBytes: memory,
        memoryPercent: 1,
        processes: [ProcessUsage(pid: 1, name: name, cpuPercent: cpu, memoryBytes: memory)]
    )
}

private final class IdleProcessProvider: ProcessListProviding, @unchecked Sendable {
    func currentProcessList() throws -> ProcessListSnapshot {
        throw MetricsError.kernelCallFailed(call: "idle", code: -1)
    }
}

private final class TwoScanProcessProvider: ProcessListProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func currentProcessList() throws -> ProcessListSnapshot {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        let cpu: UInt64 = call == 1 ? 0 : 1_000_000_000
        let uptime: UInt64 = call == 1 ? 1_000_000_000 : 2_000_000_000
        return ProcessListSnapshot(
            timestamp: Date(timeIntervalSince1970: TimeInterval(1_000 + call)),
            uptimeNanoseconds: uptime,
            processes: [
                ProcessSample(
                    pid: 42,
                    parentPID: 1,
                    responsiblePID: 42,
                    name: "firefox",
                    executablePath: "/tmp/macpulse-fixtures/Firefox.app/Contents/MacOS/firefox",
                    cpuTimeNanoseconds: cpu,
                    memoryFootprintBytes: 4_000
                ),
            ],
            unreadableProcessCount: 0
        )
    }
}

private final class FixedMetricsProvider: SystemMetricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: SystemSnapshot?

    func enqueue(_ snapshot: SystemSnapshot) {
        lock.lock()
        queued = snapshot
        lock.unlock()
    }

    func currentSnapshot() throws -> SystemSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if let queued { return queued }
        throw MetricsError.kernelCallFailed(call: "no sample", code: -1)
    }
}
