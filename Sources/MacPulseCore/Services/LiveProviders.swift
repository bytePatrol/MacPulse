import Foundation
import Darwin

public final class LiveCPUUsageProvider: CPUUsageProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var previousReading: (ticks: host_cpu_load_info_data_t, uptime: TimeInterval, usage: CPUUsage)?
    private let minimumSampleInterval: TimeInterval = 0.25

    public init() {}

    public func currentCPUUsage() throws -> CPUUsage {
        lock.lock()
        defer { lock.unlock() }

        // Rapid manual refreshes reuse the last measured value. Keep the tick
        // baseline and its monotonic time intact so repeated calls cannot starve
        // the next measurement or turn a few scheduler ticks into a noisy spike.
        if let previousReading,
           ProcessInfo.processInfo.systemUptime - previousReading.uptime < minimumSampleInterval {
            return previousReading.usage
        }

        let baseline: host_cpu_load_info_data_t
        if let previousReading {
            baseline = previousReading.ticks
        } else {
            baseline = try readTicks()
            // Cumulative boot-time counters need a short measured interval before
            // they can describe current utilisation on the first call.
            Thread.sleep(forTimeInterval: 0.15)
        }

        var current = try readTicks()
        if previousReading == nil && current.cpu_ticks == baseline.cpu_ticks {
            // A first sample has no cached result to reuse. Allow one additional
            // measured interval before reporting unavailable tick data.
            Thread.sleep(forTimeInterval: 0.15)
            current = try readTicks()
        }
        let sampleUptime = ProcessInfo.processInfo.systemUptime
        // Mach counters wrap at UInt32.max; subtract each counter before widening.
        let user = UInt64(current.cpu_ticks.0 &- baseline.cpu_ticks.0)
        let system = UInt64(current.cpu_ticks.1 &- baseline.cpu_ticks.1)
        let idle = UInt64(current.cpu_ticks.2 &- baseline.cpu_ticks.2)
        let nice = UInt64(current.cpu_ticks.3 &- baseline.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else {
            if let previousReading { return previousReading.usage }
            // No measured interval is available yet; report an unavailable
            // reading rather than manufacture a zero-percent first sample.
            throw MetricsError.kernelCallFailed(call: "CPU tick sampling (no ticks elapsed)", code: KERN_FAILURE)
        }
        let percent = Double(busy) / Double(total) * 100
        let usage = CPUUsage(percent: min(100, max(0, percent)))
        previousReading = (ticks: current, uptime: sampleUptime, usage: usage)
        return usage
    }

    private func readTicks() throws -> host_cpu_load_info_data_t {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        // Unlike host_statistics, this path supplies live counters without the
        // kernel's rate-limited statistics cache. Sum all cores for system usage.
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS else {
            throw MetricsError.kernelCallFailed(call: "host_processor_info(PROCESSOR_CPU_LOAD_INFO)", code: result)
        }
        guard let info else {
            throw MetricsError.kernelCallFailed(call: "host_processor_info (missing CPU data)", code: KERN_FAILURE)
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        guard cpuCount > 0, Int(infoCount) >= Int(cpuCount) * Int(CPU_STATE_MAX) else {
            throw MetricsError.kernelCallFailed(call: "host_processor_info (incomplete CPU data)", code: KERN_FAILURE)
        }

        var ticks = host_cpu_load_info_data_t()
        for cpu in 0..<Int(cpuCount) {
            let offset = cpu * Int(CPU_STATE_MAX)
            // Sum modulo UInt32 so the delta remains correct when an individual
            // counter or the aggregate wraps between accepted readings.
            ticks.cpu_ticks.0 &+= UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)])
            ticks.cpu_ticks.1 &+= UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)])
            ticks.cpu_ticks.2 &+= UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)])
            ticks.cpu_ticks.3 &+= UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)])
        }
        return ticks
    }
}

public final class LiveMemoryUsageProvider: MemoryUsageProviding, @unchecked Sendable {
    public init() {}

    public func currentMemoryUsage() throws -> MemoryUsage {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MetricsError.kernelCallFailed(call: "host_statistics64(HOST_VM_INFO64)", code: result)
        }

        let total = ProcessInfo.processInfo.physicalMemory
        let usedPages = max(0, Int64(info.internal_page_count) - Int64(info.purgeable_count)
            + Int64(info.wire_count) + Int64(info.compressor_page_count))
        let used = UInt64(usedPages) * UInt64(vm_kernel_page_size)
        let uncompressedPages = UInt64(info.total_uncompressed_pages_in_compressor)
        let compressedPages = UInt64(info.compressor_page_count)
        let savedPages = uncompressedPages > compressedPages ? uncompressedPages - compressedPages : 0
        let (savings, overflow) = savedPages.multipliedReportingOverflow(by: UInt64(vm_kernel_page_size))
        return MemoryUsage(totalBytes: total, usedBytes: min(total, used),
            compressedSavingsBytes: overflow ? UInt64.max : savings)
    }
}

public final class LiveDiskUsageProvider: DiskUsageProviding, @unchecked Sendable {
    public let volumeURL: URL

    public init(volumeURL: URL = URL(fileURLWithPath: "/")) {
        self.volumeURL = volumeURL
    }

    public func currentDiskUsage() throws -> DiskUsage {
        do {
            let values = try volumeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            guard let total = values.volumeTotalCapacity, total > 0 else {
                throw MetricsError.volumeInfoUnavailable(path: volumeURL.path)
            }
            let available: Int64
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                available = important
            } else if let fallback = values.volumeAvailableCapacity, fallback >= 0 {
                available = Int64(fallback)
            } else {
                throw MetricsError.volumeInfoUnavailable(path: volumeURL.path)
            }
            return DiskUsage(totalBytes: UInt64(total), availableBytes: min(UInt64(total), UInt64(available)))
        } catch {
            throw MetricsError.volumeInfoUnavailable(path: volumeURL.path)
        }
    }
}

public final class LiveSystemMetricsProvider: SystemMetricsProviding, @unchecked Sendable {
    private let cpu: any CPUUsageProviding
    private let memory: any MemoryUsageProviding
    private let disk: any DiskUsageProviding

    public init(
        cpu: any CPUUsageProviding = LiveCPUUsageProvider(),
        memory: any MemoryUsageProviding = LiveMemoryUsageProvider(),
        disk: any DiskUsageProviding = LiveDiskUsageProvider()
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
    }

    public func currentSnapshot() throws -> SystemSnapshot {
        let cpuUsage = try cpu.currentCPUUsage()
        let memoryUsage = try memory.currentMemoryUsage()
        let diskUsage = try disk.currentDiskUsage()
        return SystemSnapshot(timestamp: Date(), cpu: cpuUsage, memory: memoryUsage, disk: diskUsage)
    }
}
