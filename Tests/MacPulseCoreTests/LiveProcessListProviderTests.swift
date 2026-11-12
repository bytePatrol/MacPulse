// Live process-list checks, including Mach time and the saturated-load attribution.
import Darwin
import XCTest
@testable import MacPulseCore

final class LiveProcessListProviderTests: XCTestCase {
    func testScanIncludesThisProcessWithFootprintNameAndPath() throws {
        let snapshot = try LiveProcessListProvider().currentProcessList()
        let me = try XCTUnwrap(snapshot.processes.first { $0.pid == getpid() })
        XCTAssertGreaterThan(me.memoryFootprintBytes, 0)
        let expected = currentExecutablePath()
        let actual = try XCTUnwrap(me.executablePath)
        XCTAssertEqual(URL(fileURLWithPath: actual).resolvingSymlinksInPath().path, expected)
        let base = URL(fileURLWithPath: expected).lastPathComponent
        XCTAssertFalse(me.name.isEmpty)
        XCTAssertTrue(base == me.name || base.hasPrefix(me.name), "name \(me.name) executable \(base)")
        XCTAssertGreaterThanOrEqual(snapshot.unreadableProcessCount, 0)
        XCTAssertGreaterThan(snapshot.uptimeNanoseconds, 0)
    }

    func testScanUptimeIsMonotonicAndWorksOffTheMainThread() async throws {
        let first = try LiveProcessListProvider().currentProcessList()
        let second = try await Task.detached {
            try LiveProcessListProvider().currentProcessList()
        }.value
        XCTAssertGreaterThan(second.uptimeNanoseconds, first.uptimeNanoseconds)
        XCTAssertGreaterThanOrEqual(second.unreadableProcessCount, 0)
    }

    func testScanFinishesWithin150msUnlessTheMachineIsSaturated() throws {
        let started = DispatchTime.now().uptimeNanoseconds
        _ = try LiveProcessListProvider().currentProcessList()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        if elapsed >= 150_000_000 {
            let cpu = (try? LiveCPUUsageProvider().currentCPUUsage().percent) ?? 0
            if cpu >= 90 {
                throw XCTSkip("CPU already saturated by other processes (baseline \(String(format: "%.1f", cpu))%)")
            }
        }
        XCTAssertLessThan(elapsed, 150_000_000, "scan took \(Double(elapsed) / 1_000_000) ms")
    }

    /// Catches a missing Mach-tick conversion. On this Mac the timebase is 125/3,
    /// so raw ticks are about 42× smaller than nanoseconds.
    func testSelfCPUTimeGrowsAndMatchesGetrusage() throws {
        let before = try selfCPU()
        burnCPU(milliseconds: 350)
        let after = try selfCPU()
        let providerDelta = after.provider - before.provider
        let rusageDelta = after.rusage - before.rusage
        XCTAssertGreaterThan(providerDelta, 30_000_000, "CPU time did not grow under the busy loop")
        XCTAssertGreaterThan(rusageDelta, 30_000_000)
        let ratio = Double(providerDelta) / Double(rusageDelta)
        XCTAssertEqual(
            ratio,
            1,
            accuracy: 0.4,
            "provider Δ \(providerDelta) ns vs getrusage Δ \(rusageDelta) ns (ratio \(ratio)); host timebase 125/3, ns = ticks * 125 / 3"
        )
    }

    func testLiveGroupMemoryStaysWithinSystemUsed() async throws {
        let provider = LiveProcessListProvider()
        let first = try provider.currentProcessList()
        // Same provider the store keeps: the first publication waits out the walk, then one later scan is the slack.
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var snapshot = try await provider.initialMemorySnapshot(first, deadline: deadline)
        var groups = grouped(snapshot)
        var budget = try await systemFootprintBudget()
        if attributedMemory(groups) > budget.limit {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            snapshot = try provider.currentProcessList()
            groups = grouped(snapshot)
            budget = try await systemFootprintBudget()
        }
        let attributed = attributedMemory(groups)
        let raw = snapshot.processes.reduce(0) { $0 + Double($1.memoryFootprintBytes) }
        let sharedProcesses = snapshot.processes.filter { !$0.sharedMemoryBytesByObject.isEmpty }.count
        print(String(
            format: "MEMORY_OBS attributed=%.0f raw=%.0f used=%.0f savings=%.0f budget=%.0f groups=%d sharedProcesses=%d",
            attributed, raw, Double(budget.used), Double(budget.savings), budget.adjusted, groups.count, sharedProcesses
        ))
        XCTAssertLessThanOrEqual(
            attributed,
            budget.limit,
            "attributed \(attributed) bytes vs used \(budget.used) + savings \(budget.savings) across \(groups.count) groups; raw footprints \(raw); processes with shared maps \(sharedProcesses)"
        )
    }

    func testSaturatedLoadAttributesNodeCPULoadScript() throws {
        let groups = try attributedGroups()
        guard let top = groups.max(by: { $0.cpuPercent < $1.cpuPercent }),
              top.displayName.hasPrefix("node"),
              top.processCount >= 24,
              top.cpuPercent >= 40
        else {
            throw XCTSkip("cpu-load.ts workers are not dominating this Mac")
        }
        XCTAssertEqual(top.kind, .commandLineTool)
        XCTAssertGreaterThanOrEqual(top.cpuPercent, 50, "node is using \(top.cpuPercent)% across \(top.processCount) processes")
        XCTAssertGreaterThanOrEqual(top.processCount, 24)
        XCTAssertEqual(top.displayName, "node (cpu-load.ts)")
        XCTAssertTrue(top.id.contains("|cpu-load.ts"), top.id)
    }

    private func attributedGroups() throws -> [ConsumerGroup] {
        let provider = LiveProcessListProvider()
        let first = try provider.currentProcessList()
        Thread.sleep(forTimeInterval: 0.4)
        let second = try provider.currentProcessList()
        return grouped(second, previous: first)
    }

    private func grouped(_ current: ProcessListSnapshot, previous: ProcessListSnapshot? = nil) -> [ConsumerGroup] {
        let cpu: [Int32: Double]
        if let previous {
            cpu = UsageAnalyzer.cpuPercentByPID(
                from: previous,
                to: current,
                logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount
            )
        } else {
            cpu = [:]
        }
        return UsageAnalyzer.groupConsumers(
            processes: current.processes,
            cpuPercentByPID: cpu,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private func systemFootprintBudget() async throws -> FootprintBudget {
        try await MainActor.run {
            let metrics = MetricsStore(provider: LiveSystemMetricsProvider(), refreshInterval: 60, historyWindow: 60)
            metrics.refresh()
            let memory = try XCTUnwrap(metrics.latest).memory
            let (sum, overflow) = memory.usedBytes.addingReportingOverflow(memory.compressedSavingsBytes)
            let adjusted = overflow ? Double.greatestFiniteMagnitude : Double(sum)
            return FootprintBudget(used: memory.usedBytes, savings: memory.compressedSavingsBytes, adjusted: adjusted)
        }
    }

    private func attributedMemory(_ groups: [ConsumerGroup]) -> Double {
        groups.filter { $0.kind != .otherSystem }.reduce(0) { $0 + Double($1.memoryBytes) }
    }

    private func selfCPU() throws -> (provider: UInt64, rusage: UInt64) {
        let snapshot = try LiveProcessListProvider().currentProcessList()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let me = try XCTUnwrap(snapshot.processes.first { $0.pid == getpid() })
        return (me.cpuTimeNanoseconds, nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime))
    }
}

private struct FootprintBudget {
    var used: UInt64
    var savings: UInt64
    var adjusted: Double
    var limit: Double { adjusted * 1.10 }
}

private func currentExecutablePath() -> String {
    let raw = CommandLine.arguments[0]
    let absolute = raw.hasPrefix("/") ? raw : FileManager.default.currentDirectoryPath + "/" + raw
    return URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
}

private func nanoseconds(_ time: timeval) -> UInt64 {
    UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1_000
}

private func burnCPU(milliseconds: UInt64) {
    let start = DispatchTime.now().uptimeNanoseconds
    let budget = milliseconds * 1_000_000
    var acc: UInt64 = 0x1234_5678
    while DispatchTime.now().uptimeNanoseconds &- start < budget {
        acc = acc &* 1_664_525 &+ 1_013_904_223
    }
    withExtendedLifetime(acc) {}
}
