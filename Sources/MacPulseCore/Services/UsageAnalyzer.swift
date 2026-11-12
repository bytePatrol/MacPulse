import Foundation

/// Pure functions that turn raw process readings into per-app consumers and a plain-English summary.
/// No I/O except `defaultBundleDisplayName`, so everything else is unit-testable with fixtures.
public enum UsageAnalyzer {
    public static let maxTopGroups = 5
    public static let maxInsights = 4
    public static let maxProcessesPerGroup = 8
    public static let otherSystemGroupID = "system:other"
    public static let otherSystemDisplayName = "macOS & background services"

    /// Per-PID share of the whole machine's CPU between two snapshots, 0...100.
    /// PIDs absent from `previous`, or whose CPU time went backwards (PID reuse), are omitted.
    public static func cpuPercentByPID(
        from previous: ProcessListSnapshot,
        to current: ProcessListSnapshot,
        logicalCPUCount: Int
    ) -> [Int32: Double] {
        guard current.uptimeNanoseconds > previous.uptimeNanoseconds, logicalCPUCount > 0 else { return [:] }
        let elapsed = Double(current.uptimeNanoseconds - previous.uptimeNanoseconds)
        let old = Dictionary(previous.processes.map { ($0.pid, $0.cpuTimeNanoseconds) }, uniquingKeysWith: { _, last in last })
        var result: [Int32: Double] = [:]
        for process in current.processes {
            guard let baseline = old[process.pid], process.cpuTimeNanoseconds >= baseline else { continue }
            let percent = Double(process.cpuTimeNanoseconds - baseline) / elapsed / Double(logicalCPUCount) * 100
            result[process.pid] = min(100, max(0, percent))
        }
        return result
    }

    /// Groups processes into consumers (helpers merged into their responsible app).
    /// Returns every group, unsorted. `bundleDisplayName` maps an .app path to its name.
    public static func groupConsumers(
        processes: [ProcessSample],
        cpuPercentByPID: [Int32: Double],
        physicalMemoryBytes: UInt64,
        bundleDisplayName: (String) -> String = UsageAnalyzer.defaultBundleDisplayName
    ) -> [ConsumerGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        var groups: [String: ConsumerGroup] = [:]
        var sharedObjectsByGroup: [String: [UInt32: UInt64]] = [:]
        for process in processes {
            let owner = byPID[process.responsiblePID] ?? process
            let ownerBundle = outermostApp(owner.executablePath)
            let ownBundle = outermostApp(process.executablePath)
            // Terminal/editor hosts launch independent tools, including tools
            // installed inside a different app (such as Xcode's toolchains).
            let terminalHosted = ownBundle != ownerBundle && ownerBundle.map(isTerminalHost) == true
            let bundle = terminalHosted ? nil : ownerBundle ?? ownBundle
            var id: String
            var name: String
            let kind: ConsumerKind
            if terminalHosted {
                id = process.executablePath.map { "exe:\($0)" } ?? "name:\(process.name)"
                name = process.name
                kind = .commandLineTool
            } else if let bundle {
                id = bundle
                name = groups[bundle]?.displayName ?? bundleDisplayName(bundle)
                kind = .app
            } else if let service = friendlyService(ProcessArguments.executableName(owner), isSelfOwned: owner.pid == process.pid)
                ?? friendlyService(owner.name, isSelfOwned: owner.pid == process.pid) {
                id = "svc:\(service.slug)"
                name = service.name
                kind = .systemService
            } else {
                id = owner.executablePath.map { "exe:\($0)" } ?? "name:\(owner.name)"
                name = owner.name
                kind = isSystemPath(owner.executablePath) ? .systemService : .commandLineTool
            }
            if kind == .commandLineTool {
                // Independent interpreter entry points keep their own script.
                // Other tools (such as postgres) still follow responsible node.
                let interpreter = ProcessArguments.isInterpreter(ProcessArguments.executableName(process)) ? process : owner
                if ProcessArguments.isInterpreter(ProcessArguments.executableName(interpreter)),
                   let script = inheritedScript(for: interpreter, byPID: byPID) {
                    id = (interpreter.executablePath.map { "exe:\($0)" } ?? "name:\(interpreter.name)") + "|\(script)"
                    name = "\(interpreter.name) (\(script))"
                }
            }
            var group = groups[id] ?? ConsumerGroup(id: id, displayName: name, kind: kind,
                bundlePath: bundle, processCount: 0, cpuPercent: 0, memoryBytes: 0, memoryPercent: 0, processes: [])
            group.sharedMemoryPending = group.sharedMemoryPending || process.sharedMemoryPending
            let cpu = cpuPercentByPID[process.pid] ?? 0
            let ownShared = process.sharedMemoryBytesByObject.values.reduce(UInt64(0), addingMemory)
            let privateBytes = process.memoryFootprintBytes > ownShared ? process.memoryFootprintBytes - ownShared : 0
            for (object, bytes) in process.sharedMemoryBytesByObject {
                let previousBytes = sharedObjectsByGroup[id]?[object] ?? 0
                sharedObjectsByGroup[id, default: [:]][object] = max(previousBytes, bytes)
            }
            group.processCount += 1
            group.cpuPercent += cpu.isFinite ? max(0, cpu) : 0
            group.memoryBytes = addingMemory(group.memoryBytes, privateBytes)
            group.processes.append(ProcessUsage(pid: process.pid, name: process.name,
                cpuPercent: cpu.isFinite ? max(0, cpu) : 0, memoryBytes: privateBytes))
            groups[id] = group
        }
        return groups.values.map { value in
            var group = value
            if let sharedObjects = sharedObjectsByGroup[group.id] {
                for bytes in sharedObjects.values { group.memoryBytes = addingMemory(group.memoryBytes, bytes) }
            }
            group.memoryPercent = physicalMemoryBytes == 0 ? 0 : Double(group.memoryBytes) / Double(physicalMemoryBytes) * 100
            group.processes.sort {
                if $0.memoryBytes != $1.memoryBytes { return $0.memoryBytes > $1.memoryBytes }
                if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
                return $0.pid < $1.pid
            }
            group.processes = Array(group.processes.prefix(maxProcessesPerGroup))
            return group
        }.sorted { $0.id < $1.id }
    }

    /// Reads CFBundleDisplayName / CFBundleName from the bundle, else the file name without ".app".
    public static func defaultBundleDisplayName(_ bundlePath: String) -> String {
        let plist = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = values[key] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return name
                }
            }
        }
        return URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
    }

    /// Ranks groups, adds the "macOS & background services" remainder from `system` totals
    /// when available, and writes the headline and insights.
    public static func summarize(
        groups: [ConsumerGroup],
        system: SystemSnapshot?,
        measuredProcessCount: Int,
        unmeasuredProcessCount: Int,
        cpuAveragedOverSeconds: Double,
        timestamp: Date
    ) -> UsageSummary {
        var rankedGroups = groups.filter { $0.id != otherSystemGroupID }
        if let system {
            let cpu = max(0, system.cpu.percent - rankedGroups.reduce(0) { $0 + $1.cpuPercent })
            let measuredMemory = rankedGroups.reduce(UInt64(0)) { addingMemory($0, $1.memoryBytes) }
            // Footprints charge compressed pages at their full size. Match that
            // basis before subtracting them from the resident system total.
            let footprintBudget = addingMemory(system.memory.usedBytes, system.memory.compressedSavingsBytes)
            let memory = footprintBudget > measuredMemory ? footprintBudget - measuredMemory : 0
            if cpu > 0 || memory > 0 {
                rankedGroups.append(ConsumerGroup(id: otherSystemGroupID, displayName: otherSystemDisplayName,
                    kind: .otherSystem, bundlePath: nil, processCount: unmeasuredProcessCount,
                    cpuPercent: cpu, memoryBytes: memory,
                    memoryPercent: system.memory.totalBytes == 0 ? 0 : Double(memory) / Double(system.memory.totalBytes) * 100,
                    processes: []))
            }
        }
        let cpuRanked = rankedGroups.sorted(by: cpuOrder)
        let memoryRanked = rankedGroups.filter { !$0.sharedMemoryPending }.sorted(by: memoryOrder)
        let topCPU = Array(cpuRanked.filter { $0.cpuPercent >= 0.5 }.prefix(maxTopGroups))
        let topMemory = Array(memoryRanked.filter { $0.kind != .otherSystem || $0.memoryBytes > 0 }.prefix(maxTopGroups))
        let cpuLeader = headlineLeader(cpuRanked, value: { $0.cpuPercent })
        let memoryLeader = headlineLeader(memoryRanked, value: { Double($0.memoryBytes) })
        let realMemoryLeader = memoryRanked.first { $0.kind != .otherSystem && $0.memoryBytes > 0 }
        var headline = "Collecting app usage…"
        if realMemoryLeader != nil, let memory = memoryLeader {
            let memoryText = memoryDescription(memory.memoryBytes)
            let processText = processDescription(memory.processCount)
            if let cpu = cpuLeader, cpu.cpuPercent >= 5 {
                if cpu.id == memory.id {
                    let noun = memory.kind == .app ? "app" : "program"
                    headline = "\(memory.displayName) is the heaviest \(noun) right now: \(memoryText) of memory and \(percent(cpu.cpuPercent)) CPU across \(processText)."
                } else {
                    headline = "\(memory.displayName) is using the most memory (\(memoryText) across \(processText)), and \(cpu.displayName) is using the most CPU (\(percent(cpu.cpuPercent)))."
                }
            } else {
                headline = "Your Mac is mostly idle. \(memory.displayName) is using the most memory (\(memoryText) across \(processText))."
            }
        }

        var insights: [UsageInsight] = []
        if let system, system.memory.usedPercent >= 85 {
            let subject = realMemoryLeader
            let recommendation = subject.map { " Quitting \($0.displayName) would free about \(memoryDescription($0.memoryBytes))." } ?? ""
            insights.append(UsageInsight(id: "memory-pressure:\(subject?.id ?? otherSystemGroupID)",
                severity: .warning, symbol: "memorychip",
                text: "Memory is nearly full (\(percent(system.memory.usedPercent))).\(recommendation)"))
        }
        if rankedGroups.contains(where: { $0.kind != .otherSystem && $0.memoryBytes > 0 }) {
            for group in cpuRanked where group.kind != .otherSystem && group.cpuPercent >= 50 {
                insights.append(UsageInsight(id: "cpu-busy:\(group.id)", severity: .warning, symbol: "flame",
                    text: "\(group.displayName) is keeping your CPU busy (\(percent(group.cpuPercent)))."))
            }
            let backgroundIDs: Set<String> = ["svc:spotlight", "svc:time-machine", "svc:photos", "svc:icloud", "svc:software-update"]
            for group in cpuRanked where group.cpuPercent >= 5 && backgroundIDs.contains(group.id) {
                insights.append(UsageInsight(id: "background-task:\(group.id)", severity: .info,
                    symbol: "clock.arrow.circlepath",
                    text: "\(group.displayName) is running in the background. This is usually temporary."))
            }
            if let app = topMemory.first(where: { $0.kind == .app }), app.processCount >= 3 {
                insights.append(UsageInsight(id: "multiprocess:\(app.id)", severity: .info, symbol: "square.stack.3d.up",
                    text: "\(app.displayName) runs \(app.processCount) separate processes (tabs, extensions and helpers). MacPulse combines them: \(memoryDescription(app.memoryBytes)) in total."))
            }
            for group in topCPU where group.kind == .app && group.cpuPercent >= 10 {
                let ownName = group.bundlePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                let helper = group.processes.filter {
                    $0.name.caseInsensitiveCompare(group.displayName) != .orderedSame
                        && (ownName == nil || $0.name.caseInsensitiveCompare(ownName!) != .orderedSame)
                }.sorted { $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : $0.cpuPercent > $1.cpuPercent }.first
                if let helper, helper.cpuPercent >= group.cpuPercent * 0.6 {
                    insights.append(UsageInsight(id: "dominant-helper:\(group.id)", severity: .notice,
                        symbol: "arrow.down.right.circle", text: "Most of \(group.displayName)'s CPU is from \(helper.name)."))
                }
            }
            if unmeasuredProcessCount > 0,
               topCPU.contains(where: { $0.id == otherSystemGroupID }) || topMemory.contains(where: { $0.id == otherSystemGroupID }) {
                insights.append(UsageInsight(id: "unmeasured:\(otherSystemGroupID)", severity: .info, symbol: "lock",
                    text: "\(unmeasuredProcessCount) system processes can't be inspected without admin rights; they're counted under \(otherSystemDisplayName)."))
            }
        }
        return UsageSummary(
            timestamp: timestamp,
            headline: headline,
            insights: Array(insights.prefix(maxInsights)),
            topCPU: topCPU,
            topMemory: topMemory,
            measuredProcessCount: measuredProcessCount,
            unmeasuredProcessCount: unmeasuredProcessCount,
            cpuAveragedOverSeconds: cpuAveragedOverSeconds
        )
    }

    private static func outermostApp(_ path: String?) -> String? {
        guard let path else { return nil }
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components.prefix(index + 1)))
    }

    private static func inheritedScript(for process: ProcessSample, byPID: [Int32: ProcessSample]) -> String? {
        var current = process
        var visited: Set<Int32> = []
        while visited.insert(current.pid).inserted {
            if let script = current.scriptName, !script.isEmpty { return script }
            guard let parent = byPID[current.parentPID],
                  ProcessArguments.isInterpreter(ProcessArguments.executableName(parent)),
                  ProcessArguments.executableName(current) == ProcessArguments.executableName(parent) else { return nil }
            if let currentPath = current.executablePath, let parentPath = parent.executablePath, currentPath != parentPath { return nil }
            current = parent
        }
        return nil
    }

    private static func isSystemPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    private static let terminalHosts: Set<String> = [
        "terminal", "iterm", "iterm2", "warp", "ghostty", "alacritty", "kitty", "wezterm",
        "hyper", "tabby", "visual studio code", "code", "cursor", "zed",
    ]

    private static func isTerminalHost(_ bundlePath: String) -> Bool {
        terminalHosts.contains(URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent.lowercased())
    }

    private static func friendlyService(_ name: String, isSelfOwned: Bool) -> (slug: String, name: String)? {
        switch name {
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd": return ("spotlight", "Spotlight indexing")
        case "backupd", "backupd-helper": return ("time-machine", "Time Machine backup")
        case "photoanalysisd", "mediaanalysisd", "photolibraryd": return ("photos", "Photos analysis")
        case "cloudd", "bird", "fileproviderd": return ("icloud", "iCloud sync")
        case "softwareupdated": return ("software-update", "Software Update")
        case "WindowServer": return ("windowserver", "WindowServer (display)")
        case "kernel_task": return ("kernel", "macOS kernel")
        case let executable where isSelfOwned && executable.hasPrefix("com.apple.WebKit.WebContent"):
            return ("webkit", "Web content (WebKit)")
        default: return nil
        }
    }

    private static func addingMemory(_ first: UInt64, _ second: UInt64) -> UInt64 {
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? UInt64.max : sum
    }

    private static func cpuOrder(_ first: ConsumerGroup, _ second: ConsumerGroup) -> Bool {
        if first.cpuPercent != second.cpuPercent { return first.cpuPercent > second.cpuPercent }
        if first.memoryBytes != second.memoryBytes { return first.memoryBytes > second.memoryBytes }
        return first.id < second.id
    }

    private static func memoryOrder(_ first: ConsumerGroup, _ second: ConsumerGroup) -> Bool {
        if first.memoryBytes != second.memoryBytes { return first.memoryBytes > second.memoryBytes }
        return first.id < second.id
    }

    private static func headlineLeader(_ ranked: [ConsumerGroup], value: (ConsumerGroup) -> Double) -> ConsumerGroup? {
        guard let first = ranked.first else { return nil }
        guard first.kind == .otherSystem, let real = ranked.first(where: { $0.kind != .otherSystem }) else { return first }
        return value(first) >= 2 * value(real) ? first : real
    }

    private static func memoryDescription(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private static func processDescription(_ count: Int) -> String { "\(count) \(count == 1 ? "process" : "processes")" }
}
