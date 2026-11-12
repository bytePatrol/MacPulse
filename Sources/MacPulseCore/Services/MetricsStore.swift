import Foundation
import Observation

/// The single source of truth the UI observes. Samples the provider every
/// `refreshInterval` seconds and keeps `historyWindow` seconds of CPU/memory history.
@MainActor
@Observable
public final class MetricsStore {
    nonisolated public static let defaultRefreshInterval: TimeInterval = 2
    nonisolated public static let defaultHistoryWindow: TimeInterval = 60

    /// Most recent successful snapshot, nil until the first one succeeds.
    public private(set) var latest: SystemSnapshot?
    /// CPU % samples, oldest first, covering at most `historyWindow` seconds.
    public private(set) var cpuHistory: [MetricSample] = []
    /// Memory used % samples, oldest first, covering at most `historyWindow` seconds.
    public private(set) var memoryHistory: [MetricSample] = []
    /// Human-readable message from the last failed sample; cleared on the next success.
    public private(set) var lastError: String?
    /// True between `start()` and `stop()`.
    public private(set) var isRunning = false

    public let refreshInterval: TimeInterval
    public let historyWindow: TimeInterval

    private let provider: any SystemMetricsProviding
    @ObservationIgnored private var timer: Timer?

    public init(
        provider: any SystemMetricsProviding = LiveSystemMetricsProvider(),
        refreshInterval: TimeInterval = MetricsStore.defaultRefreshInterval,
        historyWindow: TimeInterval = MetricsStore.defaultHistoryWindow
    ) {
        self.provider = provider
        self.refreshInterval = refreshInterval
        self.historyWindow = historyWindow
    }

    deinit {
        timer?.invalidate()
    }

    /// Takes a sample immediately, then every `refreshInterval` seconds. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            // Registered only on the main run loop, including menu/tracking modes.
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops periodic sampling. Idempotent.
    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// Takes one sample now (used by the Refresh button and by the timer).
    public func refresh() {
        do {
            let snapshot = try provider.currentSnapshot()
            latest = snapshot
            cpuHistory.append(MetricSample(timestamp: snapshot.timestamp, value: snapshot.cpu.percent))
            memoryHistory.append(MetricSample(timestamp: snapshot.timestamp, value: snapshot.memory.usedPercent))
            let cutoff = snapshot.timestamp.addingTimeInterval(-historyWindow)
            cpuHistory.removeAll { $0.timestamp < cutoff }
            memoryHistory.removeAll { $0.timestamp < cutoff }
            lastError = nil
        } catch let error as MetricsError {
            switch error {
            case let .kernelCallFailed(call, code):
                lastError = "System metrics unavailable: \(call) failed (code \(code))."
            case let .volumeInfoUnavailable(path):
                lastError = "Disk capacity unavailable for \(path)."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
