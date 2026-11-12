// Feature: "What's using your Mac" — per-app CPU/memory attribution and a plain-English summary.
import Foundation

// MARK: - Raw process readings (produced by ProcessListProviding)

/// One process as read from the kernel. CPU time is cumulative since the process started.
public struct ProcessSample: Sendable, Equatable {
    public var pid: Int32
    public var parentPID: Int32
    /// The process macOS holds responsible for this one (e.g. Firefox for its plugin-container
    /// helpers). Equals `pid` when unknown.
    public var responsiblePID: Int32
    /// Short executable name, e.g. "plugin-container".
    public var name: String
    /// Full executable path, nil if it could not be read.
    public var executablePath: String?
    /// user + system CPU time in nanoseconds (already converted from Mach ticks).
    public var cpuTimeNanoseconds: UInt64
    /// Physical memory footprint (`ri_phys_footprint`, what Activity Monitor calls "Memory").
    public var memoryFootprintBytes: UInt64
    /// Resident shared *anonymous* memory mapped by this process, keyed by VM object id
    /// (`proc_regioninfo.pri_obj_id`). Empty when not measured. The analyzer uses it to count
    /// memory shared by several processes (e.g. a database's shared buffers) once per group.
    public var sharedMemoryBytesByObject: [UInt32: UInt64]
    /// For interpreters (node, python…), the main script or module name, e.g. "cpu-load.ts";
    /// nil for everything else or when the arguments could not be read.
    public var scriptName: String?
    /// True when this process is a shared-memory candidate whose regions have not been
    /// measured yet, so `memoryFootprintBytes` may still include shared memory counted again.
    public var sharedMemoryPending: Bool

    public init(
        pid: Int32,
        parentPID: Int32,
        responsiblePID: Int32,
        name: String,
        executablePath: String?,
        cpuTimeNanoseconds: UInt64,
        memoryFootprintBytes: UInt64,
        sharedMemoryBytesByObject: [UInt32: UInt64] = [:],
        scriptName: String? = nil,
        sharedMemoryPending: Bool = false
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.responsiblePID = responsiblePID
        self.name = name
        self.executablePath = executablePath
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.memoryFootprintBytes = memoryFootprintBytes
        self.sharedMemoryBytesByObject = sharedMemoryBytesByObject
        self.scriptName = scriptName
        self.sharedMemoryPending = sharedMemoryPending
    }
}

/// Every readable process at one instant.
public struct ProcessListSnapshot: Sendable, Equatable {
    public var timestamp: Date
    /// Monotonic clock (nanoseconds) used for CPU deltas; never use `timestamp` for that.
    public var uptimeNanoseconds: UInt64
    public var processes: [ProcessSample]
    /// Processes that exist but could not be read (owned by root/other users without admin rights).
    public var unreadableProcessCount: Int

    public init(timestamp: Date, uptimeNanoseconds: UInt64, processes: [ProcessSample], unreadableProcessCount: Int) {
        self.timestamp = timestamp
        self.uptimeNanoseconds = uptimeNanoseconds
        self.processes = processes
        self.unreadableProcessCount = unreadableProcessCount
    }
}

// MARK: - Analysed output (produced by UsageAnalyzer, published by InsightsStore)

public enum ConsumerKind: String, Sendable, Equatable {
    /// Grouped under an application bundle (.app).
    case app
    /// A command-line program outside any app bundle (node, python3, postgres…).
    case commandLineTool
    /// A readable macOS service (Spotlight indexing, Time Machine…).
    case systemService
    /// The synthetic "macOS & background services" remainder (unreadable processes etc.).
    case otherSystem
}

/// One member process inside a consumer group.
public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Share of the whole machine's CPU capacity, 0...100.
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }

    public var id: Int32 { pid }
}

/// An app (or tool/service) with all of its processes combined.
public struct ConsumerGroup: Sendable, Equatable, Identifiable {
    /// Stable key: the outermost .app bundle path, "exe:<path>", "name:<name>" or "system:other".
    public var id: String
    /// Human name: "Firefox", "Spotlight indexing", "node", "macOS & background services".
    public var displayName: String
    public var kind: ConsumerKind
    /// Outermost .app bundle path when kind == .app (the UI uses it for the app icon).
    public var bundlePath: String?
    public var processCount: Int
    /// Share of the whole machine's CPU capacity, 0...100, averaged over the analysis window.
    public var cpuPercent: Double
    /// Sum of member footprints.
    public var memoryBytes: UInt64
    /// memoryBytes / physical RAM × 100.
    public var memoryPercent: Double
    /// Members, heaviest first (by memory, then CPU); at most 8.
    public var processes: [ProcessUsage]
    /// True when any member's shared memory is still unmeasured, so `memoryBytes` may be
    /// inflated; such groups are kept out of memory rankings until measured.
    public var sharedMemoryPending: Bool

    public init(
        id: String,
        displayName: String,
        kind: ConsumerKind,
        bundlePath: String?,
        processCount: Int,
        cpuPercent: Double,
        memoryBytes: UInt64,
        memoryPercent: Double,
        processes: [ProcessUsage],
        sharedMemoryPending: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.bundlePath = bundlePath
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryPercent = memoryPercent
        self.processes = processes
        self.sharedMemoryPending = sharedMemoryPending
    }
}

public enum InsightSeverity: String, Sendable, Equatable {
    case info, notice, warning
}

/// One plain-English observation, e.g. "Firefox runs 14 processes; together they use 6.1 GB."
public struct UsageInsight: Sendable, Equatable, Identifiable {
    /// Stable per rule + subject, e.g. "multiprocess:/Applications/Firefox.app".
    public var id: String
    public var severity: InsightSeverity
    /// SF Symbol name for the UI.
    public var symbol: String
    public var text: String

    public init(id: String, severity: InsightSeverity, symbol: String, text: String) {
        self.id = id
        self.severity = severity
        self.symbol = symbol
        self.text = text
    }
}

/// The complete "What's using your Mac" result.
public struct UsageSummary: Sendable, Equatable {
    public var timestamp: Date
    /// One sentence answering "what is using my Mac right now?".
    public var headline: String
    /// At most 4, most important first.
    public var insights: [UsageInsight]
    /// At most 5 groups, highest cpuPercent first (may include the .otherSystem group).
    public var topCPU: [ConsumerGroup]
    /// At most 5 groups, highest memoryBytes first (may include the .otherSystem group).
    public var topMemory: [ConsumerGroup]
    public var measuredProcessCount: Int
    public var unmeasuredProcessCount: Int
    /// Seconds of history the CPU figures are averaged over (≤ InsightsStore.cpuAveragingWindow).
    public var cpuAveragedOverSeconds: Double

    public init(
        timestamp: Date,
        headline: String,
        insights: [UsageInsight],
        topCPU: [ConsumerGroup],
        topMemory: [ConsumerGroup],
        measuredProcessCount: Int,
        unmeasuredProcessCount: Int,
        cpuAveragedOverSeconds: Double
    ) {
        self.timestamp = timestamp
        self.headline = headline
        self.insights = insights
        self.topCPU = topCPU
        self.topMemory = topMemory
        self.measuredProcessCount = measuredProcessCount
        self.unmeasuredProcessCount = unmeasuredProcessCount
        self.cpuAveragedOverSeconds = cpuAveragedOverSeconds
    }
}

/// Reads every accessible process. Must be callable off the main thread.
public protocol ProcessListProviding: Sendable {
    func currentProcessList() throws -> ProcessListSnapshot
}
