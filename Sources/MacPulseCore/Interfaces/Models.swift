import Foundation

/// App-wide constants shared by the UI, the app bundle, and tests.
public enum MacPulseInfo {
    public static let appName = "MacPulse"
    public static let version = "1.0"
}

/// Whole-system CPU utilisation across all cores.
public struct CPUUsage: Sendable, Equatable {
    /// 0...100. Non-idle ticks / total ticks since the previous reading.
    public var percent: Double

    public init(percent: Double) {
        self.percent = percent
    }
}

/// Physical memory (RAM) usage, measured like Activity Monitor's "Memory Used".
public struct MemoryUsage: Sendable, Equatable {
    /// Installed physical memory (ProcessInfo.physicalMemory).
    public var totalBytes: UInt64
    /// App memory + wired + compressed.
    public var usedBytes: UInt64
    /// Memory the compressor saves: bytes of app memory stored compressed minus the RAM the
    /// compressor occupies. Per-process footprints count compressed memory at full size, so
    /// they can sum to up to `usedBytes + compressedSavingsBytes`.
    public var compressedSavingsBytes: UInt64

    public init(totalBytes: UInt64, usedBytes: UInt64, compressedSavingsBytes: UInt64 = 0) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.compressedSavingsBytes = compressedSavingsBytes
    }

    public var availableBytes: UInt64 { totalBytes > usedBytes ? totalBytes - usedBytes : 0 }
    /// 0...100.
    public var usedPercent: Double {
        totalBytes == 0 ? 0 : min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }
}

/// Usage of the startup volume ("/").
public struct DiskUsage: Sendable, Equatable {
    public var totalBytes: UInt64
    /// Space available for important usage (matches Finder's "Available", includes purgeable).
    public var availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    /// 0...100.
    public var usedPercent: Double {
        totalBytes == 0 ? 0 : min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }
}

/// One complete reading of all metrics, taken at `timestamp`.
public struct SystemSnapshot: Sendable, Equatable {
    public var timestamp: Date
    public var cpu: CPUUsage
    public var memory: MemoryUsage
    public var disk: DiskUsage

    public init(timestamp: Date, cpu: CPUUsage, memory: MemoryUsage, disk: DiskUsage) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
    }
}

/// A single point on a history chart. `value` is a percentage, 0...100.
public struct MetricSample: Sendable, Equatable, Identifiable {
    public var timestamp: Date
    public var value: Double

    public init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }

    public var id: Date { timestamp }
}

public enum MetricsError: Error, Equatable, Sendable {
    /// A Mach/kernel call returned a non-success code.
    case kernelCallFailed(call: String, code: Int32)
    /// Volume capacity could not be read.
    case volumeInfoUnavailable(path: String)
}
