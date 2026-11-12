// InsightsStore against a scripted process provider.
import XCTest
@testable import MacPulseCore

@MainActor
final class InsightsStoreTests: XCTestCase {
    private let firefoxPath = "/tmp/macpulse-fixtures/Firefox.app/Contents/MacOS/firefox"

    func testDefaultsStopAndRefreshDoNotCrash() {
        let provider = ScriptedProcessListProvider()
        let store = makeStore(provider)
        XCTAssertEqual(InsightsStore.defaultRefreshInterval, 2)
        XCTAssertEqual(InsightsStore.defaultCPUAveragingWindow, 10)
        XCTAssertEqual(store.refreshInterval, 30)
        XCTAssertEqual(store.cpuAveragingWindow, 10)
        XCTAssertNil(store.summary)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isRunning)
        store.stop()
        store.stop()
        store.refresh()
        XCTAssertFalse(store.isRunning)
        XCTAssertNil(store.summary)
    }

    func testFirstRefreshPublishesCPUFromTwoOffMainScans() async {
        let provider = ScriptedProcessListProvider()
        provider.enqueue(firefoxSnapshot(uptime: 1_000_000_000, cpu: 0, memory: 4_000, at: 1_000))
        provider.enqueue(firefoxSnapshot(uptime: 2_000_000_000, cpu: 1_000_000_000, memory: 4_000, at: 1_001))
        let store = makeStore(provider)
        await store.refreshNow()
        let firefox = store.summary?.topCPU.first { $0.displayName == "Firefox" }
        XCTAssertEqual(provider.callsOnMainThread, 0)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(firefox?.cpuPercent ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(store.summary?.cpuAveragedOverSeconds ?? -1, 1, accuracy: 0.001)
        XCTAssertNil(store.lastError)
    }

    func testCPUAveragesFromTheOldestRetainedSnapshot() async {
        let provider = ScriptedProcessListProvider()
        provider.enqueue(firefoxSnapshot(uptime: 1_000_000_000, cpu: 0, memory: 4_000, at: 1_000))
        provider.enqueue(firefoxSnapshot(uptime: 2_000_000_000, cpu: 1_000_000_000, memory: 4_000, at: 1_001))
        provider.enqueue(firefoxSnapshot(uptime: 5_000_000_000, cpu: 2_000_000_000, memory: 4_000, at: 1_004))
        let store = makeStore(provider)
        await store.refreshNow()
        await store.refreshNow()
        let firefox = store.summary?.topCPU.first { $0.displayName == "Firefox" }
        let summary = store.summary
        XCTAssertEqual(firefox?.cpuPercent ?? -1, 25, accuracy: 0.01)
        XCTAssertEqual(summary?.cpuAveragedOverSeconds ?? -1, 4, accuracy: 0.001)
    }

    func testErrorKeepsTheSummaryThenClears() async {
        let provider = ScriptedProcessListProvider()
        provider.enqueue(firefoxSnapshot(uptime: 1_000_000_000, cpu: 0, memory: 1_000, at: 1_000))
        provider.enqueue(firefoxSnapshot(uptime: 2_000_000_000, cpu: 1_000_000_000, memory: 1_000, at: 1_001))
        let store = makeStore(provider)
        await store.refreshNow()
        let original = store.summary
        XCTAssertNotNil(original)

        provider.enqueueFailure(MetricsError.kernelCallFailed(call: "proc_listallpids", code: 1))
        await store.refreshNow()
        XCTAssertEqual(store.summary, original)
        XCTAssertEqual(store.lastError, "Process analysis unavailable: proc_listallpids failed (code 1).")

        provider.enqueue(firefoxSnapshot(uptime: 3_000_000_000, cpu: 1_500_000_000, memory: 8_000, at: 1_002))
        await store.refreshNow()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.summary?.topCPU.first { $0.displayName == "Firefox" }?.memoryBytes, 8_000)
        XCTAssertNotEqual(store.summary, original)
    }

    func testStartAndStopAreIdempotent() async {
        let provider = ScriptedProcessListProvider()
        let snapshot = firefoxSnapshot(uptime: 2_000_000_000, cpu: 1_000_000_000, memory: 1_000, at: 1_001)
        provider.enqueue(firefoxSnapshot(uptime: 1_000_000_000, cpu: 0, memory: 1_000, at: 1_000))
        provider.enqueue(snapshot)
        provider.repeatLast(snapshot)
        let store = makeStore(provider)
        store.start()
        await waitUntil { provider.callCount >= 2 }
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertTrue(store.isRunning)
        store.start()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertTrue(store.isRunning)
        store.stop()
        XCTAssertFalse(store.isRunning)
        store.stop()
        XCTAssertFalse(store.isRunning)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(provider.callCount, 2)
    }

    func testRefreshCoalescesOntoTheInFlightAnalysis() async {
        let provider = ScriptedProcessListProvider()
        provider.blockFirstCall = true
        provider.enqueue(firefoxSnapshot(uptime: 1_000_000_000, cpu: 0, memory: 1_000, at: 1_000))
        provider.enqueue(firefoxSnapshot(uptime: 2_000_000_000, cpu: 1_000_000_000, memory: 1_000, at: 1_001))
        let store = makeStore(provider)
        defer { provider.release.signal() }

        let first = Task { await store.refreshNow() }
        await waitUntil { provider.callCount >= 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let second = Task { await store.refreshNow() }
        store.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.callCount, 1)
        provider.release.signal()
        await first.value
        await second.value
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertNotNil(store.summary)
    }

    func testStopCancelsPublication() async {
        let provider = ScriptedProcessListProvider()
        provider.blockFirstCall = true
        provider.enqueue(firefoxSnapshot(uptime: 1_000_000_000, cpu: 0, memory: 1_000, at: 1_000))
        provider.repeatLast(firefoxSnapshot(uptime: 2_000_000_000, cpu: 1_000_000_000, memory: 1_000, at: 1_001))
        let store = makeStore(provider)
        defer { provider.release.signal() }

        let task = Task { await store.refreshNow() }
        await waitUntil { provider.callCount >= 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.stop()
        provider.release.signal()
        await task.value
        XCTAssertNil(store.summary)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isRunning)
    }

    /// System samples inside the process span average to X, per-process CPU sums to Y,
    /// and the remainder is max(0, X − Y). A 100% sample on either side of the span stays out.
    func testRemainderCPUMatchesHistoryMeanInsideTheProcessSpan() async throws {
        let provider = ScriptedProcessListProvider()
        provider.enqueue(firefoxSnapshot(uptime: 10_000_000_000, cpu: 0, memory: 4_000, at: 1_000))
        provider.enqueue(firefoxSnapshot(uptime: 14_000_000_000, cpu: 800_000_000, memory: 4_000, at: 1_400))
        let metrics = makeMetrics([
            (900, 100),
            (1_000, 20),
            (1_200, 40),
            (1_400, 60),
            (1_500, 100),
        ])
        XCTAssertEqual(metrics.cpuHistory.map(\.value), [100, 20, 40, 60, 100])

        let store = makeStore(provider, metrics: metrics)
        await store.refreshNow()

        let summary = try XCTUnwrap(store.summary)
        XCTAssertEqual(summary.topCPU.first { $0.displayName == "Firefox" }?.cpuPercent ?? -1, 10, accuracy: 0.01)
        let remainder = try XCTUnwrap(summary.topCPU.first { $0.id == "system:other" })
        XCTAssertEqual(remainder.cpuPercent, 30, accuracy: 0.01)
        XCTAssertEqual(remainder.memoryBytes, 0)
        XCTAssertEqual(summary.cpuAveragedOverSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(metrics.latest?.cpu.percent, 100, "averaging the window must not replace latest")
        XCTAssertEqual(metrics.cpuHistory.map(\.value), [100, 20, 40, 60, 100])
    }

    func testRemainderCPUClampsWhenGroupsExceedTheWindowMean() async throws {
        let provider = ScriptedProcessListProvider()
        provider.enqueue(firefoxSnapshot(uptime: 10_000_000_000, cpu: 0, memory: 4_000, at: 1_000))
        provider.enqueue(firefoxSnapshot(uptime: 14_000_000_000, cpu: 4_000_000_000, memory: 4_000, at: 1_400))
        let metrics = makeMetrics([
            (900, 100),
            (1_000, 30),
            (1_400, 50),
            (1_500, 100),
        ])
        let store = makeStore(provider, metrics: metrics)
        await store.refreshNow()

        let summary = try XCTUnwrap(store.summary)
        XCTAssertEqual(summary.topCPU.first { $0.displayName == "Firefox" }?.cpuPercent ?? -1, 50, accuracy: 0.01)
        XCTAssertFalse(summary.topCPU.contains { $0.id == "system:other" })
        XCTAssertFalse(summary.topMemory.contains { $0.id == "system:other" })
        XCTAssertEqual(metrics.latest?.cpu.percent, 100)
    }

    func testRemainderCPUFallsBackToLatestWhenTheSpanHasNoSamples() async throws {
        let provider = ScriptedProcessListProvider()
        provider.enqueue(firefoxSnapshot(uptime: 10_000_000_000, cpu: 0, memory: 4_000, at: 1_000))
        provider.enqueue(firefoxSnapshot(uptime: 14_000_000_000, cpu: 800_000_000, memory: 4_000, at: 1_400))
        let metrics = makeMetrics([
            (900, 100),
            (1_500, 80),
        ])
        let store = makeStore(provider, metrics: metrics)
        await store.refreshNow()

        let summary = try XCTUnwrap(store.summary)
        let remainder = try XCTUnwrap(summary.topCPU.first { $0.id == "system:other" })
        XCTAssertEqual(remainder.cpuPercent, 70, accuracy: 0.01)
        XCTAssertEqual(metrics.latest?.cpu.percent, 80)
    }

    private func makeStore(_ provider: ScriptedProcessListProvider, metrics: MetricsStore? = nil) -> InsightsStore {
        InsightsStore(
            metrics: metrics,
            provider: provider,
            refreshInterval: 30,
            cpuAveragingWindow: 10,
            logicalCPUCount: 2,
            physicalMemoryBytes: 10_000
        )
    }

    private func makeMetrics(_ samples: [(TimeInterval, Double)], used: UInt64 = 4_000) -> MetricsStore {
        let provider = QueuedMetricsProvider()
        for sample in samples {
            provider.enqueue(SystemSnapshot(
                timestamp: Date(timeIntervalSince1970: sample.0),
                cpu: CPUUsage(percent: sample.1),
                memory: MemoryUsage(totalBytes: 10_000, usedBytes: used),
                disk: DiskUsage(totalBytes: 2_000, availableBytes: 500)
            ))
        }
        let metrics = MetricsStore(provider: provider, refreshInterval: 60, historyWindow: 3_600)
        for _ in samples {
            metrics.refresh()
        }
        return metrics
    }

    private func firefoxSnapshot(uptime: UInt64, cpu: UInt64, memory: UInt64, at time: TimeInterval) -> ProcessListSnapshot {
        processSnapshot(
            uptimeNanoseconds: uptime,
            processes: [
                processSample(
                    pid: 42,
                    name: "firefox",
                    executablePath: firefoxPath,
                    cpuTimeNanoseconds: cpu,
                    memoryFootprintBytes: memory
                ),
            ],
            timestamp: Date(timeIntervalSince1970: time)
        )
    }

    private func waitUntil(timeout: TimeInterval = 4, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class QueuedMetricsProvider: SystemMetricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [SystemSnapshot] = []

    func enqueue(_ snapshot: SystemSnapshot) {
        lock.lock()
        queue.append(snapshot)
        lock.unlock()
    }

    func currentSnapshot() throws -> SystemSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else {
            throw MetricsError.kernelCallFailed(call: "no scripted snapshot", code: -1)
        }
        return queue.removeFirst()
    }
}
