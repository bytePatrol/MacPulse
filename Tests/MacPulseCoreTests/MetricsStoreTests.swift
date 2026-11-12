// Acceptance tests for MetricsStore sampling, history, and errors.
import XCTest
@testable import MacPulseCore

@MainActor
final class MetricsStoreTests: XCTestCase {
    private let interval: TimeInterval = 0.1

    func testDefaultsAndInit() {
        XCTAssertEqual(MetricsStore.defaultRefreshInterval, 2)
        XCTAssertEqual(MetricsStore.defaultHistoryWindow, 60)

        let provider = ScriptedMetricsProvider()
        let store = MetricsStore(provider: provider, refreshInterval: 0.25, historyWindow: 15)
        XCTAssertEqual(store.refreshInterval, 0.25)
        XCTAssertEqual(store.historyWindow, 15)
        XCTAssertFalse(store.isRunning)
        XCTAssertNil(store.latest)
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.cpuHistory.isEmpty)
        XCTAssertTrue(store.memoryHistory.isEmpty)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testStopBeforeStartIsIdempotent() {
        let provider = ScriptedMetricsProvider()
        let store = makeStore(provider: provider, historyWindow: 60)
        store.stop()
        store.stop()
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertNil(store.latest)
    }

    func testRefreshSetsLatestAndAppendsHistory() {
        let provider = ScriptedMetricsProvider()
        let store = makeStore(provider: provider, historyWindow: 60)
        let first = snapshot(at: 0, cpu: 12.5, used: 250, total: 1_000)
        let second = snapshot(at: 2, cpu: 40, used: 1_500, total: 1_000)
        provider.enqueue(.snapshot(first))
        provider.enqueue(.snapshot(second))

        XCTAssertFalse(store.isRunning)
        store.refresh()
        XCTAssertFalse(store.isRunning, "refresh alone should not start the timer")
        XCTAssertEqual(store.latest, first)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.cpuHistory.map(\.value), [12.5])
        XCTAssertEqual(store.cpuHistory.map(\.timestamp), [first.timestamp])
        XCTAssertEqual(store.cpuHistory.map(\.id), [first.timestamp])
        XCTAssertEqual(store.memoryHistory.map(\.value), [25])
        XCTAssertEqual(store.memoryHistory.map(\.timestamp), [first.timestamp])

        store.refresh()
        XCTAssertEqual(store.latest, second)
        XCTAssertEqual(store.cpuHistory.map(\.value), [12.5, 40])
        XCTAssertEqual(store.memoryHistory.map(\.value), [25, 100], "used > total stays clamped at 100%")
        XCTAssertEqual(provider.callCount, 2)
    }

    func testRefreshTrimsHistoryRelativeToLatestTimestamp() {
        let provider = ScriptedMetricsProvider()
        let store = makeStore(provider: provider, historyWindow: 60)
        // Timestamps are far from Date() so trimming must use the snapshot clock.
        provider.enqueue(.snapshot(snapshot(at: 0, cpu: 1)))
        provider.enqueue(.snapshot(snapshot(at: 59, cpu: 2)))
        provider.enqueue(.snapshot(snapshot(at: 60, cpu: 3)))
        provider.enqueue(.snapshot(snapshot(at: 120, cpu: 4)))

        store.refresh()
        store.refresh()
        store.refresh()
        XCTAssertEqual(store.cpuHistory.map(\.value), [1, 2, 3])

        store.refresh()
        // Cutoff is latest − 60s, inclusive: t=60 stays, t=59 is strictly older.
        XCTAssertEqual(store.latest?.cpu.percent, 4)
        XCTAssertEqual(store.cpuHistory.map(\.value), [3, 4])
        XCTAssertEqual(store.memoryHistory.map(\.value), [10, 10])

        provider.enqueue(.snapshot(snapshot(at: 120.001, cpu: 5)))
        store.refresh()
        XCTAssertEqual(store.cpuHistory.map(\.value), [4, 5])
    }

    func testZeroHistoryWindowKeepsOnlyTheLatestSample() {
        let provider = ScriptedMetricsProvider()
        let store = makeStore(provider: provider, historyWindow: 0)
        provider.enqueue(.snapshot(snapshot(at: 10, cpu: 8)))
        provider.enqueue(.snapshot(snapshot(at: 11, cpu: 9)))
        store.refresh()
        store.refresh()
        XCTAssertEqual(store.cpuHistory.map(\.value), [9])
        XCTAssertEqual(store.memoryHistory.count, 1)
    }

    func testRefreshFailurePreservesDataAndSuccessClearsError() {
        let provider = ScriptedMetricsProvider()
        let store = makeStore(provider: provider, historyWindow: 60)

        provider.enqueue(.metricsError(.kernelCallFailed(call: "host_statistics", code: 7)))
        store.refresh()
        XCTAssertNil(store.latest)
        XCTAssertTrue(store.cpuHistory.isEmpty)
        XCTAssertTrue(store.memoryHistory.isEmpty)
        XCTAssertTrue(store.lastError?.contains("host_statistics") == true, "lastError was \(store.lastError ?? "nil")")
        XCTAssertTrue(store.lastError?.contains("7") == true, "lastError was \(store.lastError ?? "nil")")

        let kept = snapshot(at: 5, cpu: 15, used: 20, total: 100)
        provider.enqueue(.snapshot(kept))
        store.refresh()
        XCTAssertEqual(store.latest, kept)
        XCTAssertNil(store.lastError)
        let cpuHistory = store.cpuHistory
        let memoryHistory = store.memoryHistory

        provider.enqueue(.metricsError(.volumeInfoUnavailable(path: "/missing")))
        store.refresh()
        XCTAssertEqual(store.latest, kept)
        XCTAssertEqual(store.cpuHistory, cpuHistory)
        XCTAssertEqual(store.memoryHistory, memoryHistory)
        XCTAssertTrue(store.lastError?.contains("/missing") == true, "lastError was \(store.lastError ?? "nil")")
        XCTAssertFalse(store.lastError?.isEmpty == true)

        provider.enqueue(.message("sensor offline"))
        store.refresh()
        XCTAssertEqual(store.latest, kept)
        XCTAssertEqual(store.cpuHistory, cpuHistory)
        XCTAssertTrue(store.lastError?.contains("sensor offline") == true, "lastError was \(store.lastError ?? "nil")")

        provider.enqueue(.snapshot(snapshot(at: 6, cpu: 16, used: 20, total: 100)))
        store.refresh()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.latest?.cpu.percent, 16)
        XCTAssertEqual(store.cpuHistory.count, cpuHistory.count + 1)
    }

    func testStartSamplesImmediatelyAndRepeats() {
        let provider = ScriptedMetricsProvider()
        provider.autoconfigure = { snapshot(at: Date().timeIntervalSince1970, cpu: 11) }
        let store = makeStore(provider: provider, historyWindow: 60)

        store.start()
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(provider.callCount, 1, "start() should sample once before returning")
        XCTAssertNotNil(store.latest)
        XCTAssertNil(store.lastError)

        let started = Date()
        pump(0.65)
        store.stop()
        let elapsed = Date().timeIntervalSince(started)
        let count = provider.callCount
        XCTAssertGreaterThanOrEqual(count, 4, "expected repeats at \(interval)s, got \(count) in \(elapsed)s")
        let upper = Int(elapsed / interval) + 4
        XCTAssertLessThanOrEqual(count, upper, "sampled too fast: \(count) calls in \(elapsed)s (limit \(upper))")
    }

    func testStartAndStopAreIdempotent() {
        let provider = ScriptedMetricsProvider()
        provider.autoconfigure = { snapshot(at: Date().timeIntervalSince1970, cpu: 4) }
        let store = makeStore(provider: provider, historyWindow: 60)

        store.start()
        store.start()
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(provider.callCount, 1, "a second start() must not sample again")

        let started = Date()
        pump(0.7)
        let elapsed = Date().timeIntervalSince(started)
        let count = provider.callCount
        store.stop()
        store.stop()
        XCTAssertFalse(store.isRunning)
        XCTAssertGreaterThanOrEqual(count, 4, "timer should still be running once, got \(count)")
        let upper = Int(elapsed / interval) + 4
        XCTAssertLessThanOrEqual(
            count,
            upper,
            "start() twice looks like two timers: \(count) calls in \(elapsed)s (limit \(upper))"
        )
        XCTAssertEqual(provider.callCount, count, "stop() should not take another sample")
    }

    func testStopHaltsSampling() {
        let provider = ScriptedMetricsProvider()
        provider.autoconfigure = { snapshot(at: Date().timeIntervalSince1970, cpu: 6) }
        let store = makeStore(provider: provider, historyWindow: 60)
        store.start()
        pump(0.35)
        store.stop()
        XCTAssertFalse(store.isRunning)
        pump(0.12)
        let settled = provider.callCount
        pump(0.55)
        XCTAssertEqual(provider.callCount, settled, "samples continued after stop()")
        XCTAssertGreaterThanOrEqual(settled, 2)
    }

    func testRestartAfterStopSamplesAgain() {
        let provider = ScriptedMetricsProvider()
        provider.autoconfigure = { snapshot(at: Date().timeIntervalSince1970, cpu: 7) }
        let store = makeStore(provider: provider, historyWindow: 60)
        store.start()
        XCTAssertEqual(provider.callCount, 1)
        store.stop()
        let stopped = provider.callCount
        store.start()
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(provider.callCount, stopped + 1)
        store.stop()
        XCTAssertFalse(store.isRunning)
    }

    func testBackToBackLiveRefreshDoesNotAppendZeroCPUSample() throws {
        let spinner = CPUSpinner()
        defer { spinner.stopAndJoin() }
        spinner.start()

        let store = MetricsStore(
            provider: LiveSystemMetricsProvider(),
            refreshInterval: 30,
            historyWindow: 60
        )
        store.refresh()
        let first = try XCTUnwrap(store.cpuHistory.first).value
        XCTAssertGreaterThan(first, 0, "the loaded baseline should not be 0%, got \(first)")
        spinner.requestStop()

        store.refresh()
        XCTAssertEqual(store.cpuHistory.count, 2)
        XCTAssertEqual(
            store.cpuHistory[1].value,
            first,
            "a second refresh inside 250 ms must reuse the CPU reading, not append 0%"
        )
        XCTAssertGreaterThan(store.cpuHistory[1].value, 0)
        XCTAssertEqual(store.latest?.cpu.percent, first)
    }

    func testFailedStartKeepsRunningAndLaterSuccessClearsError() {
        let provider = ScriptedMetricsProvider()
        provider.enqueue(.message("sensor offline"))
        provider.autoconfigure = { snapshot(at: Date().timeIntervalSince1970, cpu: 3, used: 10, total: 100) }
        let store = makeStore(provider: provider, historyWindow: 60)

        store.start()
        XCTAssertTrue(store.isRunning)
        XCTAssertNil(store.latest)
        XCTAssertTrue(store.lastError?.contains("sensor offline") == true)

        pump(0.45)
        store.stop()
        XCTAssertGreaterThan(provider.callCount, 1)
        XCTAssertNotNil(store.latest)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.cpuHistory.isEmpty)
    }

    private func makeStore(provider: ScriptedMetricsProvider, historyWindow: TimeInterval) -> MetricsStore {
        MetricsStore(provider: provider, refreshInterval: interval, historyWindow: historyWindow)
    }

    /// Pumps the main run loop in `.common` mode, which is where the store timer is registered.
    private func pump(_ seconds: TimeInterval) {
        XCTAssertTrue(Thread.isMainThread)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let slice = min(0.05, deadline.timeIntervalSinceNow)
            if slice <= 0 { break }
            // Timers registered in `.common` fire while the loop runs in `.default`.
            // `.common` itself is not a mode the run loop can be entered in.
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(slice))
        }
    }
}

private func snapshot(
    at time: TimeInterval,
    cpu: Double,
    used: UInt64 = 10,
    total: UInt64 = 100
) -> SystemSnapshot {
    SystemSnapshot(
        timestamp: Date(timeIntervalSince1970: time),
        cpu: CPUUsage(percent: cpu),
        memory: MemoryUsage(totalBytes: total, usedBytes: used),
        disk: DiskUsage(totalBytes: 2_000, availableBytes: 500)
    )
}

private enum ScriptedResult: Sendable {
    case snapshot(SystemSnapshot)
    case metricsError(MetricsError)
    case message(String)
}

private struct ScriptedFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private final class ScriptedMetricsProvider: SystemMetricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ScriptedResult] = []
    private var callTimes: [Date] = []
    var autoconfigure: (@Sendable () -> SystemSnapshot)?

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callTimes.count
    }

    func enqueue(_ result: ScriptedResult) {
        lock.lock()
        queue.append(result)
        lock.unlock()
    }

    func currentSnapshot() throws -> SystemSnapshot {
        lock.lock()
        callTimes.append(Date())
        let next = queue.isEmpty ? nil : queue.removeFirst()
        let auto = autoconfigure
        lock.unlock()

        if let next {
            switch next {
            case let .snapshot(snapshot):
                return snapshot
            case let .metricsError(error):
                throw error
            case let .message(message):
                throw ScriptedFailure(message: message)
            }
        }
        if let auto {
            return auto()
        }
        throw ScriptedFailure(message: "no scripted sample")
    }
}
