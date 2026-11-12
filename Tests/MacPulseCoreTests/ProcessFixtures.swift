// Fixture builders for process-attribution tests.
import Foundation
@testable import MacPulseCore

func processSample(
    pid: Int32,
    parentPID: Int32 = 1,
    responsiblePID: Int32? = nil,
    name: String,
    executablePath: String? = nil,
    cpuTimeNanoseconds: UInt64 = 0,
    memoryFootprintBytes: UInt64 = 0,
    sharedMemoryBytesByObject: [UInt32: UInt64] = [:],
    scriptName: String? = nil,
    sharedMemoryPending: Bool = false
) -> ProcessSample {
    ProcessSample(
        pid: pid,
        parentPID: parentPID,
        responsiblePID: responsiblePID ?? pid,
        name: name,
        executablePath: executablePath,
        cpuTimeNanoseconds: cpuTimeNanoseconds,
        memoryFootprintBytes: memoryFootprintBytes,
        sharedMemoryBytesByObject: sharedMemoryBytesByObject,
        scriptName: scriptName,
        sharedMemoryPending: sharedMemoryPending
    )
}

func processSnapshot(
    uptimeNanoseconds: UInt64,
    processes: [ProcessSample],
    unreadableProcessCount: Int = 0,
    timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ProcessListSnapshot {
    ProcessListSnapshot(
        timestamp: timestamp,
        uptimeNanoseconds: uptimeNanoseconds,
        processes: processes,
        unreadableProcessCount: unreadableProcessCount
    )
}

func makeSystem(cpu: Double, used: UInt64, total: UInt64, savings: UInt64 = 0) -> SystemSnapshot {
    SystemSnapshot(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        cpu: CPUUsage(percent: cpu),
        memory: MemoryUsage(totalBytes: total, usedBytes: used, compressedSavingsBytes: savings),
        disk: DiskUsage(totalBytes: 1_000, availableBytes: 400)
    )
}

func makeGroup(
    id: String,
    name: String,
    kind: ConsumerKind = .app,
    bundlePath: String? = nil,
    processCount: Int = 1,
    cpu: Double,
    memory: UInt64,
    physical: UInt64 = 10_000,
    processes: [ProcessUsage]? = nil,
    sharedMemoryPending: Bool = false
) -> ConsumerGroup {
    let members = processes ?? [
        ProcessUsage(pid: 1, name: name, cpuPercent: cpu, memoryBytes: memory),
    ]
    return ConsumerGroup(
        id: id,
        displayName: name,
        kind: kind,
        bundlePath: bundlePath ?? (kind == .app ? id : nil),
        processCount: processCount,
        cpuPercent: cpu,
        memoryBytes: memory,
        memoryPercent: physical == 0 ? 0 : Double(memory) / Double(physical) * 100,
        processes: members,
        sharedMemoryPending: sharedMemoryPending
    )
}

/// Same formatter the analyzer uses for headline memory text.
func analyzerMemoryText(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
}

func analyzerProcessText(_ count: Int) -> String {
    "\(count) \(count == 1 ? "process" : "processes")"
}

func summarize(
    _ groups: [ConsumerGroup],
    system: SystemSnapshot? = nil,
    measured: Int = 1,
    unmeasured: Int = 0,
    averaged: Double = 10,
    at date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> UsageSummary {
    UsageAnalyzer.summarize(
        groups: groups,
        system: system,
        measuredProcessCount: measured,
        unmeasuredProcessCount: unmeasured,
        cpuAveragedOverSeconds: averaged,
        timestamp: date
    )
}

final class ScriptedProcessListProvider: ProcessListProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Result<ProcessListSnapshot, Error>] = []
    private var repeating: Result<ProcessListSnapshot, Error>?
    private var callCountStorage = 0
    private var mainThreadCalls = 0
    /// Blocks inside the first call until `release` is signaled.
    var blockFirstCall = false
    private var didBlock = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    var callsOnMainThread: Int {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadCalls
    }

    func enqueue(_ snapshot: ProcessListSnapshot) {
        lock.lock()
        pending.append(.success(snapshot))
        lock.unlock()
    }

    func enqueueFailure(_ error: Error) {
        lock.lock()
        pending.append(.failure(error))
        lock.unlock()
    }

    func repeatLast(_ snapshot: ProcessListSnapshot) {
        lock.lock()
        repeating = .success(snapshot)
        lock.unlock()
    }

    func currentProcessList() throws -> ProcessListSnapshot {
        let shouldBlock: Bool
        lock.lock()
        callCountStorage += 1
        if Thread.isMainThread { mainThreadCalls += 1 }
        shouldBlock = blockFirstCall && !didBlock
        if shouldBlock { didBlock = true }
        lock.unlock()

        if shouldBlock {
            entered.signal()
            release.wait()
        }

        lock.lock()
        let result: Result<ProcessListSnapshot, Error>
        if !pending.isEmpty {
            result = pending.removeFirst()
        } else if let repeating {
            result = repeating
        } else {
            result = .failure(MetricsError.kernelCallFailed(call: "no scripted snapshot", code: -1))
        }
        lock.unlock()
        return try result.get()
    }
}
