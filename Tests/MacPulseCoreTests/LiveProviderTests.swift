// Acceptance tests for the live CPU, memory, and disk providers.
import XCTest
import os
@testable import MacPulseCore

final class LiveProviderTests: XCTestCase {
    func testCPUUsageIsWithinRangeAndFirstCallBaselines() throws {
        let provider = LiveCPUUsageProvider()
        let started = Date()
        let first = try provider.currentCPUUsage().percent
        let firstDuration = Date().timeIntervalSince(started)
        assertPercent(first)
        XCTAssertGreaterThanOrEqual(firstDuration, 0.09, "first CPU sample should measure a short baseline")
        XCTAssertLessThan(firstDuration, 0.5, "baseline was \(firstDuration)s, expected about 150ms")

        let again = Date()
        let second = try provider.currentCPUUsage().percent
        let secondDuration = Date().timeIntervalSince(again)
        assertPercent(second)
        XCTAssertLessThan(secondDuration, 0.1, "later CPU samples should not sleep, took \(secondDuration)s")
    }

    /// Regression: a second sample a few milliseconds later used to be a 0/0 tick delta (reported as 0%)
    /// or a noisy partial delta. Readings are cached for 250 ms and that window does not move on a hit.
    func testRapidCPUCallsReuseCachedReadingUntil250ms() throws {
        let provider = LiveCPUUsageProvider()
        let beforeSpinner = try provider.currentCPUUsage().percent
        assertPercent(beforeSpinner)
        Thread.sleep(forTimeInterval: 0.30)
        let spinner = CPUSpinner()
        defer { spinner.stopAndJoin() }
        spinner.start()
        // Move the tick baseline to "spinner already running" so `loaded` is not the idle gap above.
        _ = try provider.currentCPUUsage()
        Thread.sleep(forTimeInterval: 0.30)

        let loaded = try provider.currentCPUUsage().percent
        assertPercent(loaded)
        XCTAssertGreaterThan(loaded, 15, "busy loop should make the baseline reading non-zero, got \(loaded)")

        let cachedAt = Date()
        let immediate = try provider.currentCPUUsage().percent
        XCTAssertEqual(immediate, loaded, "back-to-back CPU reads must return the cached reading, not a 0/0 delta")
        XCTAssertGreaterThan(immediate, 0, "an empty interval must not be reported as 0%")
        XCTAssertLessThan(Date().timeIntervalSince(cachedAt), 0.05, "a cache hit should return without another baseline")
        spinner.requestStop()

        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(
            try provider.currentCPUUsage().percent,
            loaded,
            "80 ms is inside the 250 ms cache window"
        )
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertLessThan(Date().timeIntervalSince(cachedAt), cpuCacheWindow)
        XCTAssertEqual(
            try provider.currentCPUUsage().percent,
            loaded,
            "cache hits must not push the 250 ms window forward"
        )

        // The spinner itself pegs the machine. Skip the cooldown only when other
        // work had already saturated the CPU before this test started.
        if beforeSpinner >= 90 {
            throw XCTSkip("CPU already saturated by other processes (baseline \(String(format: "%.1f", beforeSpinner))%)")
        }

        let remaining = (cpuCacheWindow + 0.08) - Date().timeIntervalSince(cachedAt)
        if remaining > 0 {
            Thread.sleep(forTimeInterval: remaining)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(cachedAt), cpuCacheWindow)
        let fresh = try provider.currentCPUUsage().percent
        assertPercent(fresh)
        XCTAssertLessThan(
            fresh,
            loaded - 8,
            "at >= 250 ms the provider must take a new sample against the last baseline (cached \(loaded), fresh \(fresh))"
        )
    }

    func testCPUUsageRisesUnderLoad() throws {
        let provider = LiveCPUUsageProvider()
        _ = try provider.currentCPUUsage()
        Thread.sleep(forTimeInterval: 0.25)
        let idle = try provider.currentCPUUsage().percent
        assertPercent(idle)
        XCTAssertGreaterThan(idle, 0, "baseline CPU should be non-zero, got \(idle)")
        if idle >= 90 {
            throw XCTSkip("CPU already saturated by other processes (baseline \(String(format: "%.1f", idle))%)")
        }

        let stop = OSAllocatedUnfairLock(initialState: false)
        let sink = OSAllocatedUnfairLock(initialState: UInt64(0))
        let workers = (0..<max(2, ProcessInfo.processInfo.activeProcessorCount)).map { _ in
            Thread {
                var local: UInt64 = 0x1234_5678_9abc_def
                while !stop.withLock({ $0 }) {
                    for _ in 0..<80_000 {
                        local = local &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                        local ^= local >> 27
                    }
                }
                let finished = local
                sink.withLock { $0 ^= finished }
            }
        }
        workers.forEach {
            $0.qualityOfService = .userInitiated
            $0.start()
        }
        defer {
            stop.withLock { $0 = true }
            for worker in workers where !worker.isFinished {
                while !worker.isFinished {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            _ = sink.withLock { $0 }
        }

        Thread.sleep(forTimeInterval: 0.05)
        _ = try provider.currentCPUUsage()
        Thread.sleep(forTimeInterval: 0.45)
        let loaded = try provider.currentCPUUsage().percent
        assertPercent(loaded)
        XCTAssertGreaterThan(
            loaded,
            idle + 8,
            "CPU should rise while \(workers.count) threads spin (idle \(idle), loaded \(loaded))"
        )
        XCTAssertGreaterThan(loaded, 15, "busy loop was barely visible in system CPU: \(loaded)")
    }

    func testCPUProviderIsSafeAcrossThreads() throws {
        let provider = LiveCPUUsageProvider()
        let values = LockedArray<Double>()
        let errors = LockedArray<String>()
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    values.append(try provider.currentCPUUsage().percent)
                } catch {
                    errors.append(String(describing: error))
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success, "CPU calls did not finish")
        XCTAssertEqual(errors.snapshot(), [])
        let percents = values.snapshot()
        XCTAssertEqual(percents.count, 8)
        for percent in percents {
            assertPercent(percent)
        }
    }

    func testMemoryMatchesPhysicalMemoryAndVMStat() throws {
        let memory = try LiveMemoryUsageProvider().currentMemoryUsage()
        XCTAssertEqual(memory.totalBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(memory.totalBytes, 0)
        XCTAssertGreaterThan(memory.usedBytes, 0)
        XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
        XCTAssertEqual(
            memory.availableBytes,
            memory.totalBytes > memory.usedBytes ? memory.totalBytes - memory.usedBytes : 0
        )
        XCTAssertGreaterThanOrEqual(memory.usedPercent, 0)
        XCTAssertLessThanOrEqual(memory.usedPercent, 100)

        let expected = try vmStatUsedBytes()
        assertBytesClose(
            memory.usedBytes,
            expected,
            relative: 0.12,
            absolute: 2 * 1024 * 1024 * 1024,
            "used bytes should track vm_stat anonymous − purgeable + wired + compressor"
        )
    }

    func testDiskMatchesFileManagerAndDF() throws {
        let provider = LiveDiskUsageProvider()
        XCTAssertEqual(provider.volumeURL.standardizedFileURL.path, "/")
        let usage = try provider.currentDiskUsage()
        XCTAssertGreaterThan(usage.totalBytes, 0)
        XCTAssertGreaterThan(usage.availableBytes, 0)
        XCTAssertGreaterThanOrEqual(usage.usedPercent, 0)
        XCTAssertLessThanOrEqual(usage.usedPercent, 100)

        let volume = try fileManagerVolume(at: "/")
        assertBytesClose(usage.totalBytes, volume.total, relative: 0.005, absolute: 64 * 1024 * 1024, "total vs FileManager")
        assertBytesClose(
            usage.availableBytes,
            volume.available,
            relative: 0.015,
            absolute: 4 * 1024 * 1024 * 1024,
            "available vs FileManager important-usage"
        )

        let df = try dfRootKilobytes()
        assertBytesClose(usage.totalBytes, df.totalBlocks * 1024, relative: 0.01, absolute: 256 * 1024 * 1024, "total vs df -k /")
        assertBytesClose(
            usage.availableBytes,
            df.availableBlocks * 1024,
            relative: 0.08,
            absolute: 32 * 1024 * 1024 * 1024,
            "available vs df -k / (purgeable space can widen this gap)"
        )
    }

    func testDiskProviderKeepsVolumeURL() {
        let custom = URL(fileURLWithPath: "/Volumes/MacPulseQA")
        XCTAssertEqual(LiveDiskUsageProvider().volumeURL.standardizedFileURL, URL(fileURLWithPath: "/").standardizedFileURL)
        XCTAssertEqual(LiveDiskUsageProvider(volumeURL: custom).volumeURL, custom)
    }

    func testDiskMissingVolumeThrows() {
        let missing = URL(fileURLWithPath: "/tmp/macpulse-missing-\(UUID().uuidString)")
        let provider = LiveDiskUsageProvider(volumeURL: missing)
        XCTAssertThrowsError(try provider.currentDiskUsage()) { error in
            guard case let MetricsError.volumeInfoUnavailable(path) = error else {
                return XCTFail("expected volumeInfoUnavailable, got \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    func testLiveSnapshotCombinesCurrentMetrics() throws {
        let snapshot = try LiveSystemMetricsProvider().currentSnapshot()
        assertPercent(snapshot.cpu.percent)
        XCTAssertEqual(snapshot.memory.totalBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(snapshot.memory.usedBytes, snapshot.memory.totalBytes)
        XCTAssertGreaterThan(snapshot.disk.totalBytes, 0)
        XCTAssertGreaterThan(snapshot.disk.availableBytes, 0)
        XCTAssertLessThan(abs(snapshot.timestamp.timeIntervalSinceNow), 2)
    }
}

private struct VolumeBytes {
    var total: UInt64
    var available: UInt64
}

private func fileManagerVolume(at path: String) throws -> VolumeBytes {
    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
    ])
    guard let total = values.volumeTotalCapacity, total > 0 else {
        throw ParseFailure("FileManager returned no total capacity for \(path)")
    }
    let important = values.volumeAvailableCapacityForImportantUsage ?? 0
    let fallback = Int64(values.volumeAvailableCapacity ?? 0)
    let available = important > 0 ? important : fallback
    guard available >= 0 else {
        throw ParseFailure("FileManager returned negative available capacity")
    }
    return VolumeBytes(total: UInt64(total), available: UInt64(available))
}

private struct DFKilobytes {
    var totalBlocks: UInt64
    var availableBlocks: UInt64
}

private func dfRootKilobytes() throws -> DFKilobytes {
    let output = try runTool("/bin/df", arguments: ["-k", "/"])
    let lines = output.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    guard let data = lines.last else {
        throw ParseFailure("df -k / returned no data: \(output)")
    }
    let columns = data.split(whereSeparator: \.isWhitespace).map(String.init)
    guard columns.count >= 4, let total = UInt64(columns[1]), let available = UInt64(columns[3]) else {
        throw ParseFailure("could not parse df -k / line: \(data)")
    }
    return DFKilobytes(totalBlocks: total, availableBlocks: available)
}

/// Activity Monitor's "Memory Used": (anonymous − purgeable + wired + compressor) × page size.
private func vmStatUsedBytes() throws -> UInt64 {
    let output = try runTool("/usr/bin/vm_stat", arguments: [])
    guard let pageSize = firstMatch(#"page size of (\d+) bytes"#, in: output).flatMap(UInt64.init) else {
        throw ParseFailure("vm_stat page size missing: \(output.prefix(200))")
    }
    let anonymous = try vmStatField("Anonymous pages", in: output)
    let purgeable = try vmStatField("Pages purgeable", in: output)
    let wired = try vmStatField("Pages wired down", in: output)
    let compressor = try vmStatField("Pages occupied by compressor", in: output)
    let appPages = anonymous > purgeable ? anonymous - purgeable : 0
    return (appPages + wired + compressor) * pageSize
}

private func vmStatField(_ name: String, in output: String) throws -> UInt64 {
    for raw in output.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(name + ":") else { continue }
        let digits = line.drop { $0 != ":" }.dropFirst().filter(\.isNumber)
        guard let value = UInt64(digits), !digits.isEmpty else { continue }
        return value
    }
    throw ParseFailure("vm_stat is missing \(name)")
}

private func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
          let hit = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[hit])
}

private func runTool(_ path: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw ParseFailure("\(path) exited \(process.terminationStatus): \(output)")
    }
    return output
}

private struct ParseFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private let cpuCacheWindow: TimeInterval = 0.250

final class CPUSpinner: @unchecked Sendable {
    private let stop = OSAllocatedUnfairLock(initialState: false)
    private let sink = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var workers: [Thread] = []

    func start() {
        let stop = self.stop
        let sink = self.sink
        workers = (0..<max(2, ProcessInfo.processInfo.activeProcessorCount)).map { _ in
            let thread = Thread {
                var local: UInt64 = 0x1234_5678_9abc_def
                while !stop.withLock({ $0 }) {
                    for _ in 0..<80_000 {
                        local = local &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                        local ^= local >> 27
                    }
                }
                let finished = local
                sink.withLock { $0 ^= finished }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
            return thread
        }
    }

    func requestStop() {
        stop.withLock { $0 = true }
    }

    func stopAndJoin() {
        requestStop()
        for worker in workers {
            while !worker.isFinished {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        _ = sink.withLock { $0 }
    }
}

private func assertPercent(_ percent: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(percent.isNaN, file: file, line: line)
    XCTAssertGreaterThanOrEqual(percent, 0, file: file, line: line)
    XCTAssertLessThanOrEqual(percent, 100, file: file, line: line)
}

private func assertBytesClose(
    _ actual: UInt64,
    _ expected: UInt64,
    relative: Double,
    absolute: UInt64,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let delta = actual > expected ? actual - expected : expected - actual
    let relativeLimit = UInt64((Double(expected) * relative).rounded(.up))
    let limit = max(absolute, relativeLimit)
    XCTAssertLessThanOrEqual(
        delta,
        limit,
        "\(message): actual=\(actual) expected=\(expected) delta=\(delta) limit=\(limit)",
        file: file,
        line: line
    )
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []

    func append(_ value: Element) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
