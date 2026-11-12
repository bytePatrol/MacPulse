import Foundation
import Observation

/// Publishes the "What's using your Mac" summary. Scans processes off the main actor every
/// `refreshInterval` seconds and averages per-app CPU over the last `cpuAveragingWindow` seconds.
@MainActor
@Observable
public final class InsightsStore {
    nonisolated public static let defaultRefreshInterval: TimeInterval = 2
    nonisolated public static let defaultCPUAveragingWindow: TimeInterval = 10

    /// Latest summary; nil until the first analysis completes.
    public private(set) var summary: UsageSummary?
    /// Readable message from the last failed scan; cleared on the next success.
    public private(set) var lastError: String?
    /// True between `start()` and `stop()`.
    public private(set) var isRunning = false

    public let refreshInterval: TimeInterval
    public let cpuAveragingWindow: TimeInterval

    private let metrics: MetricsStore?
    private let provider: any ProcessListProviding
    private let logicalCPUCount: Int
    private let physicalMemoryBytes: UInt64
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var analysisID: UUID?
    @ObservationIgnored private var history: [ProcessListSnapshot] = []

    /// - Parameter metrics: source of system-wide CPU/RAM totals for the "macOS & background
    ///   services" remainder; nil omits that group.
    public init(
        metrics: MetricsStore?,
        provider: any ProcessListProviding = LiveProcessListProvider(),
        refreshInterval: TimeInterval = InsightsStore.defaultRefreshInterval,
        cpuAveragingWindow: TimeInterval = InsightsStore.defaultCPUAveragingWindow,
        logicalCPUCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.metrics = metrics
        self.provider = provider
        self.logicalCPUCount = logicalCPUCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.refreshInterval = refreshInterval
        self.cpuAveragingWindow = cpuAveragingWindow
    }

    deinit {
        timer?.invalidate()
        analysisTask?.cancel()
    }

    /// Analyses immediately, then every `refreshInterval` seconds. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops periodic analysis. Idempotent.
    public func stop() {
        timer?.invalidate()
        timer = nil
        analysisTask?.cancel()
        analysisTask = nil
        analysisID = nil
        isRunning = false
    }

    /// Requests one analysis now without blocking (coalesced if one is already running).
    public func refresh() { _ = beginAnalysis() }

    /// Performs one analysis and returns after `summary`/`lastError` are updated.
    public func refreshNow() async { await beginAnalysis().value }

    private func beginAnalysis() -> Task<Void, Never> {
        if let analysisTask { return analysisTask }
        let id = UUID()
        analysisID = id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.analyze(id: id)
        }
        analysisTask = task
        return task
    }

    private func analyze(id: UUID) async {
        defer {
            // A stopped scan may complete after a replacement has started.
            // It must neither publish nor clear the replacement's task handle.
            if analysisID == id {
                analysisTask = nil
                analysisID = nil
            }
        }
        do {
            // Reserve the final 100 ms of the 1.5 s startup budget for grouping
            // and publication after the asynchronous shared-memory warm-up.
            let initialDeadline = DispatchTime.now().uptimeNanoseconds + 1_400_000_000
            var snapshots = history
            snapshots.append(try await scan())
            if history.isEmpty {
                // The default is 500 ms. Short custom windows still get two
                // readings that fit inside that window instead of fabricated CPU.
                let delay = min(0.5, max(0, cpuAveragingWindow / 2))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                snapshots.append(try await scan())
                if let live = provider as? LiveProcessListProvider, let newest = snapshots.last {
                    snapshots[snapshots.count - 1] = try await live.initialMemorySnapshot(newest, deadline: initialDeadline)
                }
            }
            try Task.checkCancellation()
            guard analysisID == id, let newest = snapshots.last else { return }
            let window = max(0, cpuAveragingWindow)
            snapshots.removeAll {
                $0.uptimeNanoseconds > newest.uptimeNanoseconds
                    || Double(newest.uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000 > window
            }
            let oldest = snapshots.first ?? newest
            let cpu = UsageAnalyzer.cpuPercentByPID(from: oldest, to: newest, logicalCPUCount: logicalCPUCount)
            let groups = UsageAnalyzer.groupConsumers(processes: newest.processes,
                cpuPercentByPID: cpu, physicalMemoryBytes: physicalMemoryBytes)
            let span = Double(newest.uptimeNanoseconds - oldest.uptimeNanoseconds) / 1_000_000_000
            var system = metrics?.latest
            if let metrics, system != nil {
                let samples = metrics.cpuHistory.filter {
                    $0.timestamp >= oldest.timestamp && $0.timestamp <= newest.timestamp
                }
                if !samples.isEmpty {
                    system?.cpu.percent = samples.reduce(0) { $0 + $1.value } / Double(samples.count)
                }
            }
            summary = UsageAnalyzer.summarize(groups: groups, system: system,
                measuredProcessCount: newest.processes.count,
                unmeasuredProcessCount: newest.unreadableProcessCount,
                cpuAveragedOverSeconds: span, timestamp: newest.timestamp)
            history = snapshots
            lastError = nil
        } catch is CancellationError {
            // stop() cancels publication without turning it into a user error.
        } catch {
            guard !Task.isCancelled, analysisID == id else { return }
            if let error = error as? MetricsError {
                switch error {
                case let .kernelCallFailed(call, code):
                    lastError = "Process analysis unavailable: \(call) failed (code \(code))."
                case let .volumeInfoUnavailable(path):
                    lastError = "Process analysis unavailable for \(path)."
                }
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    private func scan() async throws -> ProcessListSnapshot {
        let provider = self.provider
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try provider.currentProcessList()
        }
        return try await withTaskCancellationHandler(operation: {
            let snapshot = try await task.value
            try Task.checkCancellation()
            return snapshot
        }, onCancel: { task.cancel() })
    }
}
