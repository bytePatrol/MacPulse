import Foundation
import Darwin

/// Reads all processes the current user may inspect (proc_listallpids / proc_pidinfo /
/// proc_pid_rusage / proc_pidpath, responsible PID via the system responsibility API).
public final class LiveProcessListProvider: ProcessListProviding, @unchecked Sendable {
    private struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let executablePath: String?
    }

    private struct SharedMemoryEntry {
        let identity: ProcessIdentity
        var lastAttempt: UInt64
        var objects: [UInt32: UInt64]
        var hasMeasurement: Bool
    }

    private let cacheLock = NSLock()
    private let regionQueue = DispatchQueue(label: "MacPulse.shared-memory-regions", qos: .utility)
    private var sharedMemoryCache: [pid_t: SharedMemoryEntry] = [:]
    private var pendingRegions: [pid_t: ProcessIdentity] = [:]
    private let regionRefreshNanoseconds: UInt64 = 10_000_000_000

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibility: ResponsibilityFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    public init() {}

    public func currentProcessList() throws -> ProcessListSnapshot {
        let timestamp = Date()
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var timebase = mach_timebase_info_data_t()
        let result = mach_timebase_info(&timebase)
        guard result == KERN_SUCCESS, timebase.denom > 0 else {
            throw MetricsError.kernelCallFailed(call: "mach_timebase_info", code: result)
        }
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else {
            throw MetricsError.kernelCallFailed(call: "proc_listallpids", code: errno)
        }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        var count: Int32 = 0
        // Leave room for processes born between sizing and enumeration. If the
        // buffer still fills, grow it instead of silently dropping its tail.
        repeat {
            count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            guard count >= 0 else {
                throw MetricsError.kernelCallFailed(call: "proc_listallpids", code: errno)
            }
            if Int(count) < pids.count { break }
            pids = [pid_t](repeating: 0, count: pids.count * 2)
        } while true

        var processes: [ProcessSample] = []
        var identities: [pid_t: ProcessIdentity] = [:]
        processes.reserveCapacity(Int(count))
        var unreadable = 0
        for pid in Set(pids.prefix(Int(count))).sorted() where pid > 0 {
            var task = proc_taskinfo()
            var bsd = proc_bsdinfo()
            var usage = rusage_info_v4()
            let taskSize = MemoryLayout<proc_taskinfo>.stride
            let bsdSize = MemoryLayout<proc_bsdinfo>.stride
            let taskRead = withUnsafeMutablePointer(to: &task) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(taskSize))
            }
            let bsdRead = withUnsafeMutablePointer(to: &bsd) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(bsdSize))
            }
            let usageRead = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard taskRead == taskSize, bsdRead == bsdSize, usageRead == 0 else {
                // Exited processes are absent, not inaccessible. EPERM still
                // proves a process exists and belongs in the unreadable count.
                if kill(pid, 0) == 0 || errno != ESRCH { unreadable += 1 }
                continue
            }

            // PROC_PIDPATHINFO_MAXSIZE is a compound C macro unavailable to
            // Swift; its SDK definition is four times MAXPATHLEN.
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN) + 1)
            let pathRead = pathBuffer.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count - 1))
            }
            let path = pathRead > 0 ? String(cString: pathBuffer) : nil
            var nameBuffer = [CChar](repeating: 0, count: 1025)
            let nameRead = nameBuffer.withUnsafeMutableBytes {
                proc_name(pid, $0.baseAddress, UInt32($0.count - 1))
            }
            let name = nameRead > 0 ? String(cString: nameBuffer)
                : path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "PID \(pid)"
            let responsible = Self.responsibility?(pid) ?? pid
            let (ticks, overflow) = task.pti_total_user.addingReportingOverflow(task.pti_total_system)
            let cpuTime = Self.nanoseconds(ticks: overflow ? UInt64.max : ticks, timebase: timebase)
            let executableName = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
            identities[pid] = ProcessIdentity(pid: pid, startSeconds: bsd.pbi_start_tvsec,
                startMicroseconds: bsd.pbi_start_tvusec, executablePath: path)
            processes.append(ProcessSample(
                pid: pid, parentPID: Int32(bsd.pbi_ppid),
                responsiblePID: responsible > 0 ? responsible : pid,
                name: name, executablePath: path, cpuTimeNanoseconds: cpuTime,
                memoryFootprintBytes: usage.ri_phys_footprint,
                scriptName: ProcessArguments.scriptName(pid: pid, executableName: executableName)
            ))
        }
        applySharedMemoryCache(to: &processes, identities: identities)
        return ProcessListSnapshot(timestamp: timestamp, uptimeNanoseconds: uptime,
            processes: processes, unreadableProcessCount: unreadable)
    }

    /// Only the first InsightsStore analysis waits for this cache. Ordinary scans
    /// always return immediately, including while region walks are in progress.
    func initialMemorySnapshot(_ snapshot: ProcessListSnapshot, deadline: UInt64) async throws -> ProcessListSnapshot {
        while hasPendingRegions() {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            try await Task.sleep(nanoseconds: min(20_000_000, deadline - now))
        }
        try Task.checkCancellation()
        return snapshotWithCachedMemory(snapshot)
    }

    private func applySharedMemoryCache(to processes: inout [ProcessSample], identities: [pid_t: ProcessIdentity]) {
        let byExecutable = Dictionary(grouping: processes.filter { $0.executablePath != nil }, by: { $0.executablePath! })
        // Large repeated executables are the only candidates. Prioritising the
        // largest groups warms database shared buffers before smaller candidates.
        let candidates = byExecutable.values.compactMap { members -> (UInt64, [ProcessSample])? in
            let bytes = members.reduce(UInt64(0)) {
                let (sum, overflow) = $0.addingReportingOverflow($1.memoryFootprintBytes)
                return overflow ? UInt64.max : sum
            }
            return members.count >= 3 && bytes >= 1_073_741_824 ? (bytes, members) : nil
        }.sorted { $0.0 > $1.0 }
        let candidatePIDs = Set(candidates.flatMap { $0.1.map(\.pid) })
        let now = DispatchTime.now().uptimeNanoseconds
        var scheduled: [(ProcessIdentity, DispatchQoS)] = []
        cacheLock.lock()
        sharedMemoryCache = sharedMemoryCache.filter { identities[$0.key] == $0.value.identity }
        for index in processes.indices {
            if let cached = sharedMemoryCache[processes[index].pid] {
                processes[index].sharedMemoryBytesByObject = cached.objects
                processes[index].sharedMemoryPending = candidatePIDs.contains(processes[index].pid) && !cached.hasMeasurement
            } else {
                processes[index].sharedMemoryPending = candidatePIDs.contains(processes[index].pid)
            }
        }
        for (_, members) in candidates {
            for process in members.sorted(by: { $0.memoryFootprintBytes > $1.memoryFootprintBytes }) {
                guard let identity = identities[process.pid], pendingRegions[process.pid] == nil else { continue }
                let cached = sharedMemoryCache[process.pid]
                if let cached, now >= cached.lastAttempt, now - cached.lastAttempt < regionRefreshNanoseconds { continue }
                sharedMemoryCache[process.pid] = SharedMemoryEntry(identity: identity,
                    lastAttempt: now, objects: cached?.objects ?? [:], hasMeasurement: cached?.hasMeasurement ?? false)
                pendingRegions[process.pid] = identity
                // First measurements directly affect the launch headline. Give
                // them priority even when the CPU is saturated; refreshes can
                // retain their previous measured values at utility priority.
                let qos: DispatchQoS = cached?.hasMeasurement == true ? .utility : .userInitiated
                scheduled.append((identity, qos))
            }
        }
        cacheLock.unlock()
        for (identity, qos) in scheduled {
            regionQueue.async(qos: qos, flags: .enforceQoS) { [self] in
                let objects = Self.matchesCurrentProcess(identity) ? Self.sharedAnonymousMemory(pid: identity.pid) : nil
                let stillMatches = Self.matchesCurrentProcess(identity)
                cacheLock.lock()
                if let objects, stillMatches, sharedMemoryCache[identity.pid]?.identity == identity {
                    sharedMemoryCache[identity.pid]?.objects = objects
                    sharedMemoryCache[identity.pid]?.hasMeasurement = true
                }
                if pendingRegions[identity.pid] == identity { pendingRegions[identity.pid] = nil }
                cacheLock.unlock()
            }
        }
    }

    private func hasPendingRegions() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return !pendingRegions.isEmpty
    }

    private func snapshotWithCachedMemory(_ snapshot: ProcessListSnapshot) -> ProcessListSnapshot {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var updated = snapshot
        for index in updated.processes.indices {
            let process = updated.processes[index]
            guard let cached = sharedMemoryCache[process.pid], cached.identity.executablePath == process.executablePath else { continue }
            let started = Double(cached.identity.startSeconds) + Double(cached.identity.startMicroseconds) / 1_000_000
            // Do not attach a newly reused PID's memory to an older snapshot.
            guard started <= snapshot.timestamp.timeIntervalSince1970 else { continue }
            updated.processes[index].sharedMemoryBytesByObject = cached.objects
            if process.sharedMemoryPending {
                updated.processes[index].sharedMemoryPending = !cached.hasMeasurement
            }
        }
        return updated
    }

    private static func matchesCurrentProcess(_ identity: ProcessIdentity) -> Bool {
        var bsd = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &bsd) { proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, $0, Int32(size)) }
        guard result == size, bsd.pbi_start_tvsec == identity.startSeconds,
              bsd.pbi_start_tvusec == identity.startMicroseconds else { return false }
        guard let expectedPath = identity.executablePath else { return true }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN) + 1)
        let pathRead = buffer.withUnsafeMutableBytes { proc_pidpath(identity.pid, $0.baseAddress, UInt32($0.count - 1)) }
        return pathRead > 0 && String(cString: buffer) == expectedPath
    }

    private static func sharedAnonymousMemory(pid: pid_t) -> [UInt32: UInt64]? {
        var address: UInt64 = 0
        var objects: [UInt32: UInt64] = [:]
        var readAnyRegion = false
        var fileBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        while true {
            var region = proc_regioninfo()
            let size = MemoryLayout<proc_regioninfo>.stride
            let read = withUnsafeMutablePointer(to: &region) { proc_pidinfo(pid, PROC_PIDREGIONINFO, address, $0, Int32(size)) }
            guard read == size, region.pri_size > 0 else { return readAnyRegion ? objects : nil }
            readAnyRegion = true
            if [UInt32(SM_SHARED), UInt32(SM_TRUESHARED), UInt32(SM_SHARED_ALIASED)].contains(region.pri_share_mode),
               region.pri_obj_id != 0, region.pri_pages_resident > 0 {
                let fileRead = fileBuffer.withUnsafeMutableBytes {
                    proc_regionfilename(pid, region.pri_address, $0.baseAddress, UInt32($0.count))
                }
                if fileRead <= 0 {
                    let bytes = UInt64(region.pri_pages_resident) * UInt64(vm_kernel_page_size)
                    objects[region.pri_obj_id] = max(objects[region.pri_obj_id] ?? 0, bytes)
                }
            }
            let (next, overflow) = region.pri_address.addingReportingOverflow(region.pri_size)
            guard !overflow, next > address else { break }
            address = next
        }
        return objects
    }

    private static func nanoseconds(ticks: UInt64, timebase: mach_timebase_info_data_t) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        let divisor = UInt64(timebase.denom)
        guard product.high < divisor else { return UInt64.max }
        return divisor.dividingFullWidth(product).quotient
    }
}
