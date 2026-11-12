import Foundation

/// Reads whole-system CPU usage. Implementations are stateful (they keep the previous
/// tick counts) and must be safe to call from any thread.
public protocol CPUUsageProviding: Sendable {
    func currentCPUUsage() throws -> CPUUsage
}

public protocol MemoryUsageProviding: Sendable {
    func currentMemoryUsage() throws -> MemoryUsage
}

public protocol DiskUsageProviding: Sendable {
    func currentDiskUsage() throws -> DiskUsage
}

/// Produces a complete `SystemSnapshot`. `MetricsStore` depends only on this protocol,
/// so tests can inject a fake provider. The shipping app uses `LiveSystemMetricsProvider`.
public protocol SystemMetricsProviding: Sendable {
    func currentSnapshot() throws -> SystemSnapshot
}
