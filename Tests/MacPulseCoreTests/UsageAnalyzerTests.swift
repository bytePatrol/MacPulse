// Fixture-driven acceptance tests for UsageAnalyzer.
import XCTest
@testable import MacPulseCore

final class UsageAnalyzerTests: XCTestCase {
    private let root = "/tmp/macpulse-fixtures"
    private let nodePath = "/usr/local/bin/node"
    private let postgresPath = "/usr/local/bin/postgres"

    func testConstantsMatchTheContract() {
        XCTAssertEqual(UsageAnalyzer.maxTopGroups, 5)
        XCTAssertEqual(UsageAnalyzer.maxInsights, 4)
        XCTAssertEqual(UsageAnalyzer.maxProcessesPerGroup, 8)
        XCTAssertEqual(UsageAnalyzer.otherSystemGroupID, "system:other")
        XCTAssertEqual(UsageAnalyzer.otherSystemDisplayName, "macOS & background services")
        XCTAssertEqual(UsageAnalyzer.defaultBundleDisplayName("\(root)/Firefox.app"), "Firefox")
        XCTAssertEqual(UsageAnalyzer.defaultBundleDisplayName("\(root)/Google Chrome.app"), "Google Chrome")
    }

    func testCPUPercentDividesByLogicalCPUCountAndClamps() {
        let previous = processSnapshot(uptimeNanoseconds: 1_000_000_000, processes: [
            processSample(pid: 1, name: "a"),
            processSample(pid: 2, name: "b", cpuTimeNanoseconds: 5_000_000_000),
        ])
        let current = processSnapshot(uptimeNanoseconds: 2_000_000_000, processes: [
            processSample(pid: 1, name: "a", cpuTimeNanoseconds: 1_000_000_000),
            processSample(pid: 2, name: "b", cpuTimeNanoseconds: 7_000_000_000),
        ])
        let four = UsageAnalyzer.cpuPercentByPID(from: previous, to: current, logicalCPUCount: 4)
        XCTAssertEqual(four[1] ?? -1, 25, accuracy: 0.0001)
        XCTAssertEqual(four[2] ?? -1, 50, accuracy: 0.0001)
        let one = UsageAnalyzer.cpuPercentByPID(from: previous, to: current, logicalCPUCount: 1)
        XCTAssertEqual(one[1] ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(one[2] ?? -1, 100, accuracy: 0.0001)
    }

    func testCPUOmitsNewPIDsAndReusedPIDs() {
        let previous = processSnapshot(uptimeNanoseconds: 1_000_000_000, processes: [
            processSample(pid: 1, name: "reused", cpuTimeNanoseconds: 5_000),
            processSample(pid: 2, name: "stable", cpuTimeNanoseconds: 1_000),
        ])
        let current = processSnapshot(uptimeNanoseconds: 2_000_000_000, processes: [
            processSample(pid: 1, name: "reused", cpuTimeNanoseconds: 4_000),
            processSample(pid: 2, name: "stable", cpuTimeNanoseconds: 1_000),
            processSample(pid: 3, name: "new", cpuTimeNanoseconds: 9_000),
        ])
        let result = UsageAnalyzer.cpuPercentByPID(from: previous, to: current, logicalCPUCount: 4)
        XCTAssertNil(result[1], "CPU time went backwards; the PID was reused")
        XCTAssertNil(result[3], "a PID missing from the previous snapshot is omitted")
        XCTAssertEqual(result[2] ?? -1, 0, accuracy: 0.0001)
    }

    func testCPUIsEmptyWhenUptimeDoesNotAdvance() {
        let base = processSnapshot(uptimeNanoseconds: 5_000, processes: [
            processSample(pid: 1, name: "a", cpuTimeNanoseconds: 10),
        ])
        let same = processSnapshot(uptimeNanoseconds: 5_000, processes: [
            processSample(pid: 1, name: "a", cpuTimeNanoseconds: 99),
        ])
        let backwards = processSnapshot(uptimeNanoseconds: 4_000, processes: [
            processSample(pid: 1, name: "a", cpuTimeNanoseconds: 99),
        ])
        XCTAssertTrue(UsageAnalyzer.cpuPercentByPID(from: base, to: same, logicalCPUCount: 8).isEmpty)
        XCTAssertTrue(UsageAnalyzer.cpuPercentByPID(from: base, to: backwards, logicalCPUCount: 8).isEmpty)
        let forward = processSnapshot(uptimeNanoseconds: 6_000, processes: [
            processSample(pid: 1, name: "a", cpuTimeNanoseconds: 110),
        ])
        XCTAssertEqual(
            UsageAnalyzer.cpuPercentByPID(from: base, to: forward, logicalCPUCount: 8)[1] ?? -1,
            1.25,
            accuracy: 0.0001
        )
    }

    func testFirefoxHelpersMergeIntoOneGroupCappedAndSorted() {
        let firefoxBin = "\(root)/Firefox.app/Contents/MacOS/firefox"
        let helperBin = "\(root)/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
        var processes = [
            processSample(pid: 100, name: "firefox", executablePath: firefoxBin, memoryFootprintBytes: 2_000),
        ]
        var cpu: [Int32: Double] = [100: 5]
        for offset in 0..<10 {
            let pid = Int32(210 + offset)
            processes.append(processSample(
                pid: pid,
                responsiblePID: 100,
                name: "plugin-container",
                executablePath: helperBin,
                memoryFootprintBytes: 100
            ))
            cpu[pid] = Double(10 - offset)
        }
        let grouped = groups(from: processes, cpu: cpu)
        XCTAssertEqual(grouped.count, 1)
        let firefox = grouped[0]
        XCTAssertEqual(firefox.id, "\(root)/Firefox.app")
        XCTAssertEqual(firefox.displayName, "Firefox")
        XCTAssertEqual(firefox.kind, .app)
        XCTAssertEqual(firefox.bundlePath, "\(root)/Firefox.app")
        XCTAssertEqual(firefox.processCount, 11)
        XCTAssertEqual(firefox.memoryBytes, 3_000)
        XCTAssertEqual(firefox.memoryPercent, 30, accuracy: 0.0001)
        XCTAssertEqual(firefox.cpuPercent, 60, accuracy: 0.0001)
        XCTAssertEqual(firefox.processes.count, 8)
        XCTAssertEqual(firefox.processes.map(\.pid), [100, 210, 211, 212, 213, 214, 215, 216])
        XCTAssertEqual(firefox.processes[1].cpuPercent, 10, accuracy: 0.0001)
        XCTAssertEqual(firefox.processes[2].cpuPercent, 9, accuracy: 0.0001)
    }

    func testNestedChromeHelperUsesTheOutermostApp() {
        let helper = "\(root)/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/120/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let grouped = groups(from: [
            processSample(pid: 7, name: "Google Chrome Helper (Renderer)", executablePath: helper, memoryFootprintBytes: 80),
        ])
        XCTAssertEqual(grouped.map(\.id), ["\(root)/Google Chrome.app"])
        XCTAssertEqual(grouped[0].displayName, "Google Chrome")
        XCTAssertEqual(grouped[0].kind, .app)
        XCTAssertEqual(grouped[0].bundlePath, "\(root)/Google Chrome.app")
        XCTAssertEqual(grouped[0].processCount, 1)
    }

    func testProcessOwnAppIsUsedWhenTheOwnerHasNone() throws {
        let node = processSample(pid: 1, name: "node", executablePath: nodePath, memoryFootprintBytes: 10)
        let helper = processSample(
            pid: 2,
            responsiblePID: 1,
            name: "helper",
            executablePath: "\(root)/HelperHost.app/Contents/MacOS/helper",
            memoryFootprintBytes: 40
        )
        let grouped = groups(from: [node, helper])
        let host = try XCTUnwrap(grouped.first { $0.id == "\(root)/HelperHost.app" })
        let tool = try XCTUnwrap(grouped.first { $0.id == "exe:\(nodePath)" })
        XCTAssertEqual(host.kind, .app)
        XCTAssertEqual(host.displayName, "HelperHost")
        XCTAssertEqual(host.processCount, 1)
        XCTAssertEqual(host.memoryBytes, 40)
        XCTAssertEqual(tool.kind, .commandLineTool)
        XCTAssertEqual(tool.displayName, "node")
        XCTAssertEqual(tool.processCount, 1)
        XCTAssertEqual(tool.memoryBytes, 10)
        XCTAssertNil(tool.bundlePath)
    }

    func testPostgresResponsibleToNodeMergesIntoNode() {
        var processes = [
            processSample(pid: 50, name: "node", executablePath: nodePath, memoryFootprintBytes: 100),
        ]
        for offset in 0..<5 {
            processes.append(processSample(
                pid: Int32(60 + offset),
                responsiblePID: 50,
                name: "postgres",
                executablePath: postgresPath,
                memoryFootprintBytes: 20
            ))
        }
        let grouped = groups(from: processes)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].id, "exe:\(nodePath)")
        XCTAssertEqual(grouped[0].displayName, "node")
        XCTAssertEqual(grouped[0].kind, .commandLineTool)
        XCTAssertEqual(grouped[0].processCount, 6)
        XCTAssertEqual(grouped[0].memoryBytes, 200)
        XCTAssertEqual(grouped[0].processes.first?.name, "node")
        XCTAssertEqual(Set(grouped[0].processes.map(\.name)), ["node", "postgres"])
    }

    func testMissingOwnerFallsBackToTheProcessAndIgnoresParentPID() {
        let helper = processSample(
            pid: 5,
            parentPID: 1,
            responsiblePID: 999,
            name: "plugin-container",
            executablePath: "\(root)/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container",
            memoryFootprintBytes: 15
        )
        let other = processSample(
            pid: 6,
            parentPID: 5,
            name: "Other",
            executablePath: "\(root)/Other.app/Contents/MacOS/Other",
            memoryFootprintBytes: 30
        )
        let grouped = groups(from: [helper, other])
        XCTAssertEqual(Set(grouped.map(\.id)), ["\(root)/Firefox.app", "\(root)/Other.app"])
        XCTAssertEqual(grouped.first { $0.id == "\(root)/Firefox.app" }?.memoryBytes, 15)
        XCTAssertEqual(grouped.first { $0.id == "\(root)/Other.app" }?.memoryBytes, 30)
    }

    func testSystemPathsBecomeSystemServicesAndUsrBinDoesNot() throws {
        let samples = [
            processSample(pid: 1, name: "trustd", executablePath: "/usr/libexec/trustd"),
            processSample(pid: 2, name: "distnoted", executablePath: "/usr/sbin/distnoted"),
            processSample(pid: 3, name: "launchd", executablePath: "/sbin/launchd"),
            processSample(pid: 4, name: "ReportCrash", executablePath: "/System/Library/CoreServices/ReportCrash"),
            processSample(pid: 5, name: "apple-service", executablePath: "/Library/Apple/System/Library/CoreServices/apple-service"),
            processSample(pid: 6, name: "python3", executablePath: "/usr/bin/python3"),
        ]
        let grouped = groups(from: samples)
        for sample in samples.dropLast() {
            let group = try XCTUnwrap(grouped.first { $0.id == "exe:\(sample.executablePath!)" })
            XCTAssertEqual(group.kind, .systemService, sample.name)
            XCTAssertEqual(group.displayName, sample.name)
        }
        let python = try XCTUnwrap(grouped.first { $0.id == "exe:/usr/bin/python3" })
        XCTAssertEqual(python.kind, .commandLineTool)
        XCTAssertEqual(python.displayName, "python3")
    }

    func testPathlessProcessUsesItsName() {
        let grouped = groups(from: [processSample(pid: 1, name: "mytool", memoryFootprintBytes: 5)])
        XCTAssertEqual(grouped.map(\.id), ["name:mytool"])
        XCTAssertEqual(grouped[0].kind, .commandLineTool)
        XCTAssertEqual(grouped[0].displayName, "mytool")
    }

    func testFriendlyNamesShareOneGroup() {
        let support = "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support"
        let names = ["mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd"]
        let processes = names.enumerated().map { index, name in
            processSample(pid: Int32(index + 1), name: name, executablePath: "\(support)/\(name)", memoryFootprintBytes: 10)
        }
        let grouped = groups(from: processes)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].id, "svc:spotlight")
        XCTAssertEqual(grouped[0].displayName, "Spotlight indexing")
        XCTAssertEqual(grouped[0].kind, .systemService)
        XCTAssertEqual(grouped[0].processCount, 5)
        XCTAssertEqual(grouped[0].memoryBytes, 50)
        XCTAssertNil(grouped[0].bundlePath)
    }

    func testEachFriendlyServiceSlug() throws {
        let cases: [(String, String?, String, String)] = [
            ("backupd", "/System/Library/CoreServices/backupd", "svc:time-machine", "Time Machine backup"),
            ("backupd-helper", "/usr/libexec/backupd-helper", "svc:time-machine", "Time Machine backup"),
            ("photoanalysisd", "/System/Library/Frameworks/PhotoAnalysis.framework/photoanalysisd", "svc:photos", "Photos analysis"),
            ("mediaanalysisd", "/System/Library/Frameworks/MediaAnalysis.framework/mediaanalysisd", "svc:photos", "Photos analysis"),
            ("photolibraryd", "/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/photolibraryd", "svc:photos", "Photos analysis"),
            ("cloudd", "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/cloudd", "svc:icloud", "iCloud sync"),
            ("bird", "/System/Library/PrivateFrameworks/CloudDocs.framework/bird", "svc:icloud", "iCloud sync"),
            ("fileproviderd", "/System/Library/Frameworks/FileProvider.framework/fileproviderd", "svc:icloud", "iCloud sync"),
            ("softwareupdated", "/System/Library/CoreServices/softwareupdated", "svc:software-update", "Software Update"),
            ("WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", "svc:windowserver", "WindowServer (display)"),
            ("kernel_task", nil, "svc:kernel", "macOS kernel"),
        ]
        let processes = cases.enumerated().map { index, item in
            processSample(pid: Int32(index + 1), name: item.0, executablePath: item.1, memoryFootprintBytes: 1)
        }
        let grouped = groups(from: processes)
        let ids = Set(grouped.map(\.id))
        XCTAssertEqual(ids, Set(cases.map(\.2)))
        for item in cases {
            let group = try XCTUnwrap(grouped.first { $0.id == item.2 })
            XCTAssertEqual(group.displayName, item.3)
            XCTAssertEqual(group.kind, .systemService)
        }
        XCTAssertEqual(grouped.first { $0.id == "svc:time-machine" }?.processCount, 2)
        XCTAssertEqual(grouped.first { $0.id == "svc:photos" }?.processCount, 3)
        XCTAssertEqual(grouped.first { $0.id == "svc:icloud" }?.processCount, 3)
    }

    func testSelfOwnedWebContentIsWebKitAndHostedWebContentStaysWithSafari() {
        let webPath = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let alone = groups(from: [
            processSample(pid: 9, name: "com.apple.WebKit.WebContent", executablePath: webPath, memoryFootprintBytes: 30),
        ])
        XCTAssertEqual(alone.map(\.id), ["svc:webkit"])
        XCTAssertEqual(alone[0].displayName, "Web content (WebKit)")
        XCTAssertEqual(alone[0].kind, .systemService)

        let safariBin = "\(root)/Safari.app/Contents/MacOS/Safari"
        let hosted = groups(from: [
            processSample(pid: 8, name: "Safari", executablePath: safariBin, memoryFootprintBytes: 100),
            processSample(pid: 9, responsiblePID: 8, name: "com.apple.WebKit.WebContent", executablePath: webPath, memoryFootprintBytes: 50),
        ])
        XCTAssertEqual(hosted.count, 1)
        XCTAssertEqual(hosted[0].id, "\(root)/Safari.app")
        XCTAssertEqual(hosted[0].processCount, 2)
        XCTAssertEqual(hosted[0].memoryBytes, 150)
        XCTAssertFalse(hosted.contains { $0.id == "svc:webkit" })
    }

    /// proc_name is truncated to MAXCOMLEN (`com.apple.WebKit`). The full executable basename still maps it.
    func testTruncatedWebContentProcNameUsesExecutableBasename() {
        let webPath = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let alone = groups(from: [
            processSample(pid: 9, name: "com.apple.WebKit", executablePath: webPath, memoryFootprintBytes: 30),
        ])
        XCTAssertEqual(alone.map(\.id), ["svc:webkit"])
        XCTAssertEqual(alone[0].displayName, "Web content (WebKit)")
        XCTAssertEqual(alone[0].kind, .systemService)

        let safariBin = "\(root)/Safari.app/Contents/MacOS/Safari"
        let hosted = groups(from: [
            processSample(pid: 8, name: "Safari", executablePath: safariBin, memoryFootprintBytes: 100),
            processSample(pid: 9, responsiblePID: 8, name: "com.apple.WebKit", executablePath: webPath, memoryFootprintBytes: 50),
        ])
        XCTAssertEqual(hosted.count, 1)
        XCTAssertEqual(hosted[0].id, "\(root)/Safari.app")
        XCTAssertEqual(hosted[0].displayName, "Safari")
        XCTAssertEqual(hosted[0].processCount, 2)
        XCTAssertFalse(hosted.contains { $0.id == "svc:webkit" })
    }

    func testBundleDisplayNameClosureIsUsed() {
        let path = "\(root)/Firefox.app/Contents/MacOS/firefox"
        let grouped = UsageAnalyzer.groupConsumers(
            processes: [processSample(pid: 1, name: "firefox", executablePath: path)],
            cpuPercentByPID: [:],
            physicalMemoryBytes: 1_000,
            bundleDisplayName: { _ in "Custom Firefox" }
        )
        XCTAssertEqual(grouped.first?.displayName, "Custom Firefox")
    }

    func testEmptyProcessListProducesNoGroups() {
        XCTAssertTrue(groups(from: []).isEmpty)
    }

    // MARK: Terminal hosts

    func testNodeWorkersResponsibleToTerminalStayOutOfTerminal() throws {
        let terminal = "\(root)/Terminal.app/Contents/MacOS/Terminal"
        var processes = [
            processSample(pid: 1, name: "Terminal", executablePath: terminal, memoryFootprintBytes: 200),
        ]
        for offset in 0..<24 {
            processes.append(processSample(
                pid: Int32(100 + offset),
                responsiblePID: 1,
                name: "node",
                executablePath: nodePath,
                memoryFootprintBytes: 10
            ))
        }
        let grouped = groups(from: processes)
        let terminalGroup = try XCTUnwrap(grouped.first { $0.id == "\(root)/Terminal.app" })
        let node = try XCTUnwrap(grouped.first { $0.id == "exe:\(nodePath)" })
        XCTAssertEqual(terminalGroup.processCount, 1)
        XCTAssertEqual(terminalGroup.memoryBytes, 200)
        XCTAssertEqual(terminalGroup.processes.map(\.name), ["Terminal"])
        XCTAssertEqual(node.displayName, "node")
        XCTAssertEqual(node.kind, .commandLineTool)
        XCTAssertEqual(node.processCount, 24)
        XCTAssertEqual(node.memoryBytes, 240)
    }

    func testSwiftFrontendResponsibleToTerminalIsItsOwnGroup() throws {
        let terminal = "\(root)/Terminal.app/Contents/MacOS/Terminal"
        let tool = "/usr/bin/swift-frontend"
        let grouped = groups(from: [
            processSample(pid: 1, name: "Terminal", executablePath: terminal, memoryFootprintBytes: 50),
            processSample(pid: 2, responsiblePID: 1, name: "swift-frontend", executablePath: tool, memoryFootprintBytes: 80),
        ])
        XCTAssertEqual(grouped.first { $0.id == "\(root)/Terminal.app" }?.processCount, 1)
        let compiler = try XCTUnwrap(grouped.first { $0.id == "exe:\(tool)" })
        XCTAssertEqual(compiler.displayName, "swift-frontend")
        XCTAssertEqual(compiler.kind, .commandLineTool)
        XCTAssertEqual(compiler.memoryBytes, 80)
    }

    func testToolchainSwiftFrontendResponsibleToTerminalIsNotXcodeOrTerminal() {
        let terminal = "\(root)/Terminal.app/Contents/MacOS/Terminal"
        let xcode = "\(root)/Xcode.app/Contents/MacOS/Xcode"
        let tool = "\(root)/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
        let fromTerminal = groups(from: [
            processSample(pid: 1, name: "Terminal", executablePath: terminal),
            processSample(pid: 2, responsiblePID: 1, name: "swift-frontend", executablePath: tool, memoryFootprintBytes: 90),
        ])
        XCTAssertEqual(fromTerminal.first { $0.displayName == "swift-frontend" }?.id, "exe:\(tool)")
        XCTAssertEqual(fromTerminal.first { $0.displayName == "swift-frontend" }?.kind, .commandLineTool)
        XCTAssertNil(fromTerminal.first { $0.id == "\(root)/Xcode.app" })
        XCTAssertEqual(fromTerminal.first { $0.id == "\(root)/Terminal.app" }?.processCount, 1)

        let fromXcode = groups(from: [
            processSample(pid: 1, name: "Xcode", executablePath: xcode, memoryFootprintBytes: 100),
            processSample(pid: 2, responsiblePID: 1, name: "swift-frontend", executablePath: tool, memoryFootprintBytes: 90),
        ])
        XCTAssertEqual(fromXcode.count, 1)
        XCTAssertEqual(fromXcode[0].id, "\(root)/Xcode.app")
        XCTAssertEqual(fromXcode[0].kind, .app)
        XCTAssertEqual(fromXcode[0].processCount, 2)
        XCTAssertEqual(fromXcode[0].memoryBytes, 190)
    }

    func testHelperInsideTheTerminalBundleStaysWithTerminal() {
        let terminal = "\(root)/Terminal.app/Contents/MacOS/Terminal"
        let helper = "\(root)/Terminal.app/Contents/PlugIns/Helper.app/Contents/MacOS/Helper"
        let grouped = groups(from: [
            processSample(pid: 1, name: "Terminal", executablePath: terminal, memoryFootprintBytes: 40),
            processSample(pid: 2, responsiblePID: 1, name: "Helper", executablePath: helper, memoryFootprintBytes: 15),
        ])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].id, "\(root)/Terminal.app")
        XCTAssertEqual(grouped[0].processCount, 2)
        XCTAssertEqual(grouped[0].memoryBytes, 55)
    }

    func testPythonResponsibleToHeadroomStaysWithHeadroom() {
        let headroom = "\(root)/Headroom.app/Contents/MacOS/Headroom"
        let grouped = groups(from: [
            processSample(pid: 1, name: "Headroom", executablePath: headroom, memoryFootprintBytes: 70),
            processSample(pid: 2, responsiblePID: 1, name: "python3", executablePath: "/usr/local/bin/python3", memoryFootprintBytes: 25),
        ])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].id, "\(root)/Headroom.app")
        XCTAssertEqual(grouped[0].kind, .app)
        XCTAssertEqual(grouped[0].processCount, 2)
        XCTAssertEqual(grouped[0].memoryBytes, 95)
    }

    // MARK: Shared memory and interpreters

    func testSharedAnonymousMemoryIsCountedOncePerGroup() throws {
        let shared: UInt64 = 500_000_000
        let footprint: UInt64 = 600_000_000
        var processes: [ProcessSample] = (0..<5).map { index in
            processSample(
                pid: Int32(60 + index),
                responsiblePID: 50,
                name: "postgres",
                executablePath: postgresPath,
                memoryFootprintBytes: footprint,
                sharedMemoryBytesByObject: [42: shared]
            )
        }
        processes.append(processSample(
            pid: 50,
            name: "postgres",
            executablePath: postgresPath,
            memoryFootprintBytes: 200_000_000
        ))
        processes.append(processSample(
            pid: 7,
            name: "firefox",
            executablePath: "\(root)/Firefox.app/Contents/MacOS/firefox",
            memoryFootprintBytes: 50_000_000
        ))
        let grouped = groups(from: processes, physical: 64 * 1024 * 1024 * 1024)
        let postgres = try XCTUnwrap(grouped.first { $0.displayName == "postgres" })
        // 5 × (600 − 500) MB private + 500 MB of object 42 once + the unshared member.
        XCTAssertEqual(postgres.memoryBytes, 1_200_000_000)
        XCTAssertEqual(postgres.processCount, 6)
        let sharedMembers = postgres.processes.filter { $0.pid >= 60 }
        XCTAssertEqual(sharedMembers.count, 5)
        XCTAssertTrue(sharedMembers.allSatisfy { $0.memoryBytes == 100_000_000 })
        XCTAssertEqual(postgres.processes.first { $0.pid == 50 }?.memoryBytes, 200_000_000)
        XCTAssertEqual(grouped.first { $0.displayName == "Firefox" }?.memoryBytes, 50_000_000)
    }

    func testSharedObjectUsesTheMaxResidentBytes() {
        let grouped = groups(from: [
            processSample(pid: 1, name: "postgres", executablePath: postgresPath, memoryFootprintBytes: 100, sharedMemoryBytesByObject: [7: 100]),
            processSample(pid: 2, name: "postgres", executablePath: postgresPath, memoryFootprintBytes: 40, sharedMemoryBytesByObject: [7: 40]),
        ])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].memoryBytes, 100)
        XCTAssertTrue(grouped[0].processes.allSatisfy { $0.memoryBytes == 0 })
    }

    func testInterpreterScriptsSplitWorkersHelpersAndParentChain() throws {
        let load = processSample(pid: 1, name: "node", executablePath: nodePath, memoryFootprintBytes: 100, scriptName: "cpu-load.ts")
        let loadWorker = processSample(pid: 2, parentPID: 1, responsiblePID: 1, name: "node", executablePath: nodePath, memoryFootprintBytes: 10)
        let grandchild = processSample(pid: 3, parentPID: 2, responsiblePID: 2, name: "node", executablePath: nodePath, memoryFootprintBytes: 10)
        let server = processSample(
            pid: 4,
            parentPID: 1,
            responsiblePID: 1,
            name: "node",
            executablePath: nodePath,
            memoryFootprintBytes: 80,
            scriptName: "server.js"
        )
        let serverWorker = processSample(pid: 5, parentPID: 4, responsiblePID: 4, name: "node", executablePath: nodePath, memoryFootprintBytes: 10)
        let database = processSample(
            pid: 6,
            parentPID: 4,
            responsiblePID: 4,
            name: "postgres",
            executablePath: postgresPath,
            memoryFootprintBytes: 30
        )
        let grouped = groups(from: [load, loadWorker, grandchild, server, serverWorker, database])
        let loadGroup = try XCTUnwrap(grouped.first { $0.id == "exe:\(nodePath)|cpu-load.ts" })
        let serverGroup = try XCTUnwrap(grouped.first { $0.id == "exe:\(nodePath)|server.js" })
        XCTAssertEqual(loadGroup.displayName, "node (cpu-load.ts)")
        XCTAssertEqual(loadGroup.kind, .commandLineTool)
        XCTAssertEqual(Set(loadGroup.processes.map(\.pid)), [1, 2, 3])
        XCTAssertEqual(serverGroup.displayName, "node (server.js)")
        XCTAssertEqual(Set(serverGroup.processes.map(\.pid)), [4, 5, 6])
        XCTAssertEqual(grouped.count, 2)
    }

    func testNilScriptNameKeepsExecutableGrouping() {
        let grouped = groups(from: [
            processSample(pid: 1, name: "node", executablePath: nodePath, memoryFootprintBytes: 10),
            processSample(pid: 2, responsiblePID: 1, name: "postgres", executablePath: postgresPath, memoryFootprintBytes: 20),
        ])
        XCTAssertEqual(grouped.map(\.id), ["exe:\(nodePath)"])
        XCTAssertEqual(grouped[0].displayName, "node")
        XCTAssertEqual(grouped[0].processCount, 2)
    }

    func testInterpreterParentCycleDoesNotHang() {
        let first = processSample(pid: 10, parentPID: 11, responsiblePID: 11, name: "node", executablePath: nodePath)
        let second = processSample(pid: 11, parentPID: 10, responsiblePID: 10, name: "node", executablePath: nodePath)
        let grouped = groups(from: [first, second])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].id, "exe:\(nodePath)")
        XCTAssertEqual(grouped[0].displayName, "node")
        XCTAssertEqual(grouped[0].processCount, 2)
    }

    func testInterpreterEmbeddedInAnAppStaysWithTheApp() {
        let app = "\(root)/MyApp.app/Contents/MacOS/MyApp"
        let embedded = "\(root)/MyApp.app/Contents/Resources/node"
        let grouped = groups(from: [
            processSample(pid: 1, name: "MyApp", executablePath: app, memoryFootprintBytes: 40),
            processSample(pid: 2, responsiblePID: 1, name: "node", executablePath: embedded, memoryFootprintBytes: 20, scriptName: "server.js"),
        ])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].id, "\(root)/MyApp.app")
        XCTAssertEqual(grouped[0].kind, .app)
        XCTAssertEqual(grouped[0].processCount, 2)
    }

    func testPython3PrefixIsAnInterpreter() {
        let path = "/usr/local/bin/python3.11"
        let grouped = groups(from: [
            processSample(pid: 1, name: "python3.11", executablePath: path, memoryFootprintBytes: 30, scriptName: "app.py"),
        ])
        XCTAssertEqual(grouped.map(\.id), ["exe:\(path)|app.py"])
        XCTAssertEqual(grouped[0].displayName, "python3.11 (app.py)")
        XCTAssertEqual(grouped[0].kind, .commandLineTool)
    }

    // MARK: Summary

    func testSummarizeWithNoGroupsDoesNotCrashAndSaysCollecting() {
        let date = Date(timeIntervalSince1970: 1_700_000_100)
        let summary = summarize([], measured: 0, unmeasured: 3, averaged: 0, at: date)
        XCTAssertEqual(summary.headline, "Collecting app usage…")
        XCTAssertTrue(summary.insights.isEmpty)
        XCTAssertTrue(summary.topCPU.isEmpty)
        XCTAssertTrue(summary.topMemory.isEmpty)
        XCTAssertEqual(summary.measuredProcessCount, 0)
        XCTAssertEqual(summary.unmeasuredProcessCount, 3)
        XCTAssertEqual(summary.cpuAveragedOverSeconds, 0)
        XCTAssertEqual(summary.timestamp, date)
        XCTAssertFalse(summary.headline.contains("*"))
    }

    func testZeroMemoryGroupsKeepRankingsAndOnlyMemoryPressure() {
        let hot = makeGroup(id: "exe:\(nodePath)", name: "node", kind: .commandLineTool, bundlePath: nil, cpu: 40, memory: 0)
        let quiet = summarize([hot], system: makeSystem(cpu: 40, used: 50, total: 100))
        XCTAssertEqual(quiet.headline, "Collecting app usage…")
        XCTAssertTrue(quiet.insights.isEmpty)
        XCTAssertEqual(quiet.topCPU.map(\.id), ["exe:\(nodePath)"])

        let pressured = summarize([hot], system: makeSystem(cpu: 40, used: 90, total: 100))
        XCTAssertEqual(pressured.headline, "Collecting app usage…")
        XCTAssertEqual(pressured.insights.map(\.id), ["memory-pressure:system:other"])
        XCTAssertEqual(pressured.insights[0].severity, .warning)
        XCTAssertEqual(pressured.insights[0].symbol, "memorychip")
        XCTAssertEqual(pressured.insights[0].text, "Memory is nearly full (90%).")
        XCTAssertFalse(pressured.insights[0].text.contains("Quitting"))
    }

    func testRemainderClampsAtZeroAndDropsEmptyMemoryFromTopMemory() throws {
        let app = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", cpu: 25, memory: 400)
        let clamped = summarize([app], system: makeSystem(cpu: 10, used: 100, total: 1_000), unmeasured: 9)
        XCTAssertFalse(clamped.topCPU.contains { $0.id == "system:other" })
        XCTAssertFalse(clamped.topMemory.contains { $0.id == "system:other" })

        let partial = summarize([app], system: makeSystem(cpu: 10, used: 1_000, total: 2_000), unmeasured: 9)
        XCTAssertFalse(partial.topCPU.contains { $0.id == "system:other" })
        let memoryRemainder = try XCTUnwrap(partial.topMemory.first { $0.id == "system:other" })
        XCTAssertEqual(memoryRemainder.memoryBytes, 600)
        XCTAssertEqual(memoryRemainder.cpuPercent, 0, accuracy: 0.0001)
        XCTAssertEqual(memoryRemainder.processCount, 9)
        XCTAssertTrue(memoryRemainder.processes.isEmpty)
        XCTAssertEqual(memoryRemainder.kind, .otherSystem)

        let both = summarize([app], system: makeSystem(cpu: 40, used: 1_000, total: 2_000), unmeasured: 9)
        let cpuRemainder = try XCTUnwrap(both.topCPU.first { $0.id == "system:other" })
        XCTAssertEqual(cpuRemainder.cpuPercent, 15, accuracy: 0.0001)
        XCTAssertEqual(cpuRemainder.memoryBytes, 600)
        XCTAssertEqual(both.topCPU.map(\.id), ["\(root)/Firefox.app", "system:other"])
        XCTAssertEqual(both.topMemory.map(\.id), ["system:other", "\(root)/Firefox.app"])
    }

    /// Footprints count compressed pages at full size. Remainder memory is
    /// max(0, used + compressedSavingsBytes − Σ groups). Pressure stays on physical usedPercent.
    func testRemainderMemoryAddsCompressedSavingsAndSaturates() throws {
        let app = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", cpu: 25, memory: 400)
        let saved = summarize([app], system: makeSystem(cpu: 10, used: 1_000, total: 10_000, savings: 300), unmeasured: 4)
        let remainder = try XCTUnwrap(saved.topMemory.first { $0.id == "system:other" })
        XCTAssertEqual(remainder.memoryBytes, 900)
        XCTAssertEqual(remainder.cpuPercent, 0, accuracy: 0.0001)
        XCTAssertEqual(remainder.processCount, 4)
        XCTAssertFalse(saved.topCPU.contains { $0.id == "system:other" })
        XCTAssertFalse(saved.insights.contains { $0.id.hasPrefix("memory-pressure") })

        // used + savings would read as 100% if pressure used the footprint budget. Physical used is 80%.
        let notPressured = summarize(
            [makeGroup(id: "\(root)/Firefox.app", name: "Firefox", cpu: 25, memory: 100)],
            system: makeSystem(cpu: 30, used: 800, total: 1_000, savings: 200)
        )
        XCTAssertEqual(notPressured.topMemory.first { $0.id == "system:other" }?.memoryBytes, 900)
        XCTAssertFalse(notPressured.insights.contains { $0.id.hasPrefix("memory-pressure") })

        let clamped = summarize([app], system: makeSystem(cpu: 40, used: 100, total: 10_000, savings: 50), unmeasured: 4)
        XCTAssertFalse(clamped.topMemory.contains { $0.id == "system:other" })
        let cpuOnly = try XCTUnwrap(clamped.topCPU.first { $0.id == "system:other" })
        XCTAssertEqual(cpuOnly.cpuPercent, 15, accuracy: 0.0001)
        XCTAssertEqual(cpuOnly.memoryBytes, 0)

        let saturated = summarize(
            [makeGroup(id: "\(root)/Firefox.app", name: "Firefox", cpu: 0, memory: 100)],
            system: makeSystem(cpu: 0, used: UInt64.max - 10, total: UInt64.max, savings: 50)
        )
        XCTAssertEqual(saturated.topMemory.first { $0.id == "system:other" }?.memoryBytes, UInt64.max - 100)
    }

    /// An unmeasured shared-memory group stays out of memory rankings, the memory headline,
    /// and memory advice. Its footprint still reduces the remainder, and CPU ranking stays.
    func testPendingGroupIsHiddenFromMemoryButStillShrinksTheRemainder() throws {
        let hugeID = "\(root)/Huge.app"
        let mailID = "\(root)/Mail.app"
        let system = makeSystem(cpu: 100, used: 10_000, total: 20_000)
        let measured = summarize(
            [
                makeGroup(id: hugeID, name: "Huge", processCount: 3, cpu: 55, memory: 8_000),
                makeGroup(id: mailID, name: "Mail", cpu: 60, memory: 200),
            ],
            system: system,
            measured: 4
        )
        XCTAssertEqual(measured.topMemory.map(\.id), [hugeID, "system:other", mailID])
        XCTAssertEqual(measured.topMemory.first { $0.id == "system:other" }?.memoryBytes, 1_800)
        XCTAssertTrue(measured.headline.contains("Huge"))
        XCTAssertTrue(measured.insights.contains { $0.id == "multiprocess:\(hugeID)" })
        XCTAssertTrue(measured.insights.contains { $0.id == "cpu-busy:\(hugeID)" })

        let pending = summarize(
            [
                makeGroup(id: hugeID, name: "Huge", processCount: 3, cpu: 55, memory: 8_000, sharedMemoryPending: true),
                makeGroup(id: mailID, name: "Mail", cpu: 60, memory: 200),
            ],
            system: system,
            measured: 4
        )
        XCTAssertFalse(pending.topMemory.contains { $0.id == hugeID })
        XCTAssertEqual(pending.topMemory.map(\.id), ["system:other", mailID])
        XCTAssertEqual(pending.topMemory.first { $0.id == "system:other" }?.memoryBytes, 1_800)
        XCTAssertEqual(pending.topCPU.map(\.id), [mailID, hugeID])
        XCTAssertEqual(pending.topCPU.first { $0.id == hugeID }?.sharedMemoryPending, true)
        XCTAssertFalse(pending.headline.contains("Huge"))
        XCTAssertTrue(pending.headline.contains("Mail"))
        XCTAssertEqual(pending.insights.map(\.id), ["cpu-busy:\(mailID)", "cpu-busy:\(hugeID)"])
        XCTAssertFalse(pending.insights.contains { $0.id.hasPrefix("multiprocess:") })

        let pressured = summarize(
            [
                makeGroup(id: hugeID, name: "Huge", processCount: 3, cpu: 20, memory: 500, sharedMemoryPending: true),
                makeGroup(id: mailID, name: "Mail", cpu: 30, memory: 200),
            ],
            system: makeSystem(cpu: 60, used: 900, total: 1_000)
        )
        XCTAssertFalse(pressured.topMemory.contains { $0.id == hugeID })
        XCTAssertEqual(pressured.topMemory.first { $0.id == "system:other" }?.memoryBytes, 200)
        XCTAssertFalse(pressured.headline.contains("Huge"))
        let pressure = try XCTUnwrap(pressured.insights.first { $0.id.hasPrefix("memory-pressure:") })
        XCTAssertEqual(pressure.id, "memory-pressure:\(mailID)")
        XCTAssertTrue(pressure.text.contains("Quitting Mail"))
        XCTAssertFalse(pressure.text.contains("Huge"))
    }

    /// The pending flag is the OR of every member, including one the 8-member display cap drops.
    func testPendingFlagOrsEveryMemberBeforeTheDisplayCap() {
        let path = "\(root)/Huge.app/Contents/MacOS/Huge"
        let shown = (1...8).map { pid in
            processSample(
                pid: Int32(pid),
                name: "Huge",
                executablePath: path,
                memoryFootprintBytes: UInt64(900 - pid * 10)
            )
        }
        let hidden = processSample(
            pid: 9,
            name: "Pending",
            executablePath: path,
            memoryFootprintBytes: 1,
            sharedMemoryPending: true
        )
        let grouped = groups(from: shown + [hidden])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].processCount, 9)
        XCTAssertEqual(grouped[0].processes.count, 8)
        XCTAssertFalse(grouped[0].processes.contains { $0.pid == 9 })
        XCTAssertEqual(grouped[0].memoryBytes, shown.reduce(0) { $0 + $1.memoryFootprintBytes } + 1)
        XCTAssertTrue(grouped[0].sharedMemoryPending)

        let clear = groups(from: shown)
        XCTAssertEqual(clear.count, 1)
        XCTAssertFalse(clear[0].sharedMemoryPending)
    }

    func testTopListsCapSortAndDropNegligibleCPU() {
        let rows: [(String, Double, UInt64)] = [
            ("cpu-hi", 40, 10),
            ("tie-b", 20, 5),
            ("tie-a", 20, 5),
            ("mid", 10, 1),
            ("low", 1, 1),
            ("sixth", 0.8, 1),
            ("dust", 0.49, 8_000),
            ("edge", 0.5, 4),
        ]
        let groups = rows.map { makeGroup(id: $0.0, name: $0.0, cpu: $0.1, memory: $0.2) }
        let summary = summarize(groups)
        XCTAssertEqual(summary.topCPU.map(\.id), ["cpu-hi", "tie-a", "tie-b", "mid", "low"])
        XCTAssertFalse(summary.topCPU.contains { $0.id == "dust" || $0.id == "sixth" || $0.id == "edge" })
        XCTAssertEqual(summary.topMemory.map(\.id), ["dust", "cpu-hi", "tie-a", "tie-b", "edge"])
        XCTAssertLessThanOrEqual(summary.topCPU.count, 5)
        XCTAssertLessThanOrEqual(summary.topMemory.count, 5)

        let boundary = summarize([
            makeGroup(id: "keep", name: "keep", cpu: 10, memory: 100),
            makeGroup(id: "edge", name: "edge", cpu: 0.5, memory: 50),
            makeGroup(id: "dust", name: "dust", cpu: 0.49, memory: 80),
        ])
        XCTAssertEqual(boundary.topCPU.map(\.id), ["keep", "edge"])
        XCTAssertEqual(boundary.topMemory.map(\.id), ["keep", "dust", "edge"])
    }

    func testAppHeadlineTemplatesIncludingSingularProcess() {
        let firefox = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 14, cpu: 18, memory: 6_100_000_000)
        let same = summarize([firefox])
        XCTAssertEqual(same.headline, heaviest("Firefox", kind: .app, memory: 6_100_000_000, cpu: 18, count: 14))
        XCTAssertEqual(same.cpuAveragedOverSeconds, 10)

        let one = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 1, cpu: 18.4, memory: 2_000)
        XCTAssertEqual(
            summarize([one]).headline,
            heaviest("Firefox", kind: .app, memory: 2_000, cpu: 18, count: 1)
        )

        let idle = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 14, cpu: 4.9, memory: 4_000)
        XCTAssertEqual(
            summarize([idle]).headline,
            "Your Mac is mostly idle. Firefox is using the most memory (\(analyzerMemoryText(4_000)) across 14 processes)."
        )

        let exactFive = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 2, cpu: 5, memory: 4_000)
        XCTAssertEqual(summarize([exactFive]).headline, heaviest("Firefox", kind: .app, memory: 4_000, cpu: 5, count: 2))

        let xcode = makeGroup(id: "\(root)/Xcode.app", name: "Xcode", processCount: 3, cpu: 23.6, memory: 1_000)
        let split = summarize([
            makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 4, cpu: 8, memory: 5_000),
            xcode,
        ])
        XCTAssertEqual(
            split.headline,
            "Firefox is using the most memory (\(analyzerMemoryText(5_000)) across 4 processes), and Xcode is using the most CPU (24%)."
        )
    }

    func testNonAppAndRemainderHeadlinesSayProgram() {
        let node = makeGroup(id: "exe:\(nodePath)", name: "node", kind: .commandLineTool, bundlePath: nil, processCount: 1, cpu: 18, memory: 9_000)
        XCTAssertEqual(summarize([node]).headline, heaviest("node", kind: .commandLineTool, memory: 9_000, cpu: 18, count: 1))

        let toolLeadsCPU = summarize([
            makeGroup(id: "exe:\(nodePath)", name: "node", kind: .commandLineTool, bundlePath: nil, cpu: 23, memory: 100),
            makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 4, cpu: 8, memory: 5_000),
        ])
        XCTAssertEqual(
            toolLeadsCPU.headline,
            "Firefox is using the most memory (\(analyzerMemoryText(5_000)) across 4 processes), and node is using the most CPU (23%)."
        )

        let app = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 1, cpu: 10, memory: 1_000)
        let named = summarize([app], system: makeSystem(cpu: 30, used: 3_000, total: 10_000), unmeasured: 4)
        XCTAssertEqual(
            named.headline,
            heaviest("macOS & background services", kind: .otherSystem, memory: 2_000, cpu: 20, count: 4)
        )

        let justUnder = summarize([app], system: makeSystem(cpu: 29, used: 2_000, total: 10_000), unmeasured: 4)
        XCTAssertEqual(justUnder.headline, heaviest("Firefox", kind: .app, memory: 1_000, cpu: 10, count: 1))
    }

    func testInsightThresholdsOnBothSides() {
        let firefox = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 2, cpu: 10, memory: 5_000)
        XCTAssertFalse(summarize([firefox], system: makeSystem(cpu: 10, used: 849, total: 1_000)).insights.contains { $0.id.hasPrefix("memory-pressure") })
        let pressured = summarize([firefox], system: makeSystem(cpu: 10, used: 850, total: 1_000))
        XCTAssertEqual(
            pressured.insights.first { $0.id == "memory-pressure:\(root)/Firefox.app" }?.text,
            "Memory is nearly full (85%). Quitting Firefox would free about \(analyzerMemoryText(5_000))."
        )

        XCTAssertFalse(summarize([makeGroup(id: "\(root)/Xcode.app", name: "Xcode", cpu: 49.9, memory: 100)]).insights.contains { $0.id.hasPrefix("cpu-busy") })
        let busy = summarize([makeGroup(id: "\(root)/Xcode.app", name: "Xcode", cpu: 50, memory: 100)])
        XCTAssertEqual(busy.insights.first { $0.id == "cpu-busy:\(root)/Xcode.app" }?.text, "Xcode is keeping your CPU busy (50%).")
        XCTAssertEqual(busy.insights[0].severity, .warning)
        XCTAssertEqual(busy.insights[0].symbol, "flame")

        let quietSpotlight = makeGroup(id: "svc:spotlight", name: "Spotlight indexing", kind: .systemService, bundlePath: nil, cpu: 4.9, memory: 100)
        XCTAssertFalse(summarize([quietSpotlight]).insights.contains { $0.id.hasPrefix("background-task") })
        let spotlight = summarize([
            makeGroup(id: "svc:spotlight", name: "Spotlight indexing", kind: .systemService, bundlePath: nil, cpu: 5, memory: 100),
        ])
        XCTAssertEqual(
            spotlight.insights.first { $0.id == "background-task:svc:spotlight" }?.text,
            "Spotlight indexing is running in the background. This is usually temporary."
        )
        let windowServer = summarize([
            makeGroup(id: "svc:windowserver", name: "WindowServer (display)", kind: .systemService, bundlePath: nil, cpu: 20, memory: 100),
        ])
        XCTAssertFalse(windowServer.insights.contains { $0.id.hasPrefix("background-task") })

        let two = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 2, cpu: 1, memory: 300)
        XCTAssertFalse(summarize([two]).insights.contains { $0.id.hasPrefix("multiprocess") })
        let three = summarize([makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 3, cpu: 1, memory: 300)])
        XCTAssertEqual(
            three.insights.first { $0.id == "multiprocess:\(root)/Firefox.app" }?.text,
            "Firefox runs 3 separate processes (tabs, extensions and helpers). MacPulse combines them: \(analyzerMemoryText(300)) in total."
        )
        let tool = summarize([
            makeGroup(id: "exe:\(nodePath)", name: "node", kind: .commandLineTool, bundlePath: nil, processCount: 8, cpu: 1, memory: 900),
            makeGroup(id: "\(root)/Firefox.app", name: "Firefox", processCount: 1, cpu: 1, memory: 100),
        ])
        XCTAssertFalse(tool.insights.contains { $0.id.hasPrefix("multiprocess") })
    }

    func testDominantHelperThresholdsAndAppOwnExecutable() throws {
        let terminal = "\(root)/Terminal.app"
        let present = summarize([
            dominantGroup(cpu: 20, own: 4, helper: 16, helperName: "swift-frontend"),
        ])
        let insight = try XCTUnwrap(present.insights.first { $0.id == "dominant-helper:\(terminal)" })
        XCTAssertEqual(insight.severity, .notice)
        XCTAssertEqual(insight.symbol, "arrow.down.right.circle")
        XCTAssertEqual(insight.text, "Most of Terminal's CPU is from swift-frontend.")

        XCTAssertFalse(summarize([dominantGroup(cpu: 20, own: 8.2, helper: 11.8, helperName: "swift-frontend")]).insights.contains { $0.id.hasPrefix("dominant-helper") })
        XCTAssertFalse(summarize([dominantGroup(cpu: 9.9, own: 1, helper: 8.9, helperName: "swift-frontend")]).insights.contains { $0.id.hasPrefix("dominant-helper") })
        XCTAssertTrue(summarize([dominantGroup(cpu: 10, own: 4, helper: 6, helperName: "swift-frontend")]).insights.contains { $0.id.hasPrefix("dominant-helper") })

        let own = dominantGroup(cpu: 20, own: 2, helper: 18, helperName: "terminal")
        XCTAssertFalse(summarize([own]).insights.contains { $0.id.hasPrefix("dominant-helper") })
        var display = dominantGroup(cpu: 20, own: 2, helper: 18, helperName: "Terminal Host")
        display = ConsumerGroup(
            id: display.id, displayName: "Terminal Host", kind: .app, bundlePath: display.bundlePath,
            processCount: 2, cpuPercent: 20, memoryBytes: 100, memoryPercent: 1, processes: display.processes
        )
        XCTAssertFalse(summarize([display]).insights.contains { $0.id.hasPrefix("dominant-helper") })

        let tool = makeGroup(
            id: "exe:\(nodePath)", name: "node", kind: .commandLineTool, bundlePath: nil, processCount: 2, cpu: 40, memory: 100,
            processes: [
                ProcessUsage(pid: 1, name: "node", cpuPercent: 4, memoryBytes: 10),
                ProcessUsage(pid: 2, name: "postgres", cpuPercent: 36, memoryBytes: 90),
            ]
        )
        XCTAssertFalse(summarize([tool]).insights.contains { $0.id.hasPrefix("dominant-helper") })

        var fillers: [ConsumerGroup] = (0..<5).map { index in
            makeGroup(id: "filler-\(index)", name: "Filler \(index)", cpu: Double(30 - index), memory: 100)
        }
        fillers.append(dominantGroup(cpu: 15, own: 3, helper: 12, helperName: "swift-frontend"))
        XCTAssertFalse(summarize(fillers).insights.contains { $0.id.hasPrefix("dominant-helper") })
    }

    func testUnmeasuredInsightRequiresRemainderInATopList() {
        let app = makeGroup(id: "\(root)/Firefox.app", name: "Firefox", cpu: 10, memory: 400)
        XCTAssertFalse(summarize([app], system: makeSystem(cpu: 40, used: 1_000, total: 2_000), unmeasured: 0).insights.contains { $0.id.hasPrefix("unmeasured") })
        XCTAssertFalse(summarize([app], system: makeSystem(cpu: 10, used: 100, total: 1_000), unmeasured: 4).insights.contains { $0.id.hasPrefix("unmeasured") })
        let shown = summarize([app], system: makeSystem(cpu: 40, used: 1_000, total: 2_000), unmeasured: 4)
        XCTAssertEqual(
            shown.insights.first { $0.id == "unmeasured:system:other" }?.text,
            "4 system processes can't be inspected without admin rights; they're counted under macOS & background services."
        )
        XCTAssertEqual(shown.insights.first { $0.id == "unmeasured:system:other" }?.symbol, "lock")
        XCTAssertEqual(shown.insights.first { $0.id == "unmeasured:system:other" }?.severity, .info)
    }

    func testInsightsKeepPriorityOrderAndCapAtFour() {
        let firefox = makeGroup(
            id: "\(root)/Firefox.app", name: "Firefox", processCount: 14, cpu: 62, memory: 5_000,
            processes: [
                ProcessUsage(pid: 1, name: "Firefox", cpuPercent: 10, memoryBytes: 4_000),
                ProcessUsage(pid: 2, name: "plugin-container", cpuPercent: 52, memoryBytes: 1_000),
            ]
        )
        let spotlight = makeGroup(id: "svc:spotlight", name: "Spotlight indexing", kind: .systemService, bundlePath: nil, cpu: 6, memory: 100)
        let summary = summarize(
            [firefox, spotlight],
            system: makeSystem(cpu: 80, used: 8_800, total: 10_000),
            unmeasured: 5
        )
        XCTAssertEqual(summary.insights.map(\.id), [
            "memory-pressure:\(root)/Firefox.app",
            "cpu-busy:\(root)/Firefox.app",
            "background-task:svc:spotlight",
            "multiprocess:\(root)/Firefox.app",
        ])
        XCTAssertEqual(summary.insights.map(\.severity), [.warning, .warning, .info, .info])
        XCTAssertEqual(summary.insights.map(\.symbol), ["memorychip", "flame", "clock.arrow.circlepath", "square.stack.3d.up"])
        XCTAssertFalse(summary.insights.contains { $0.id.hasPrefix("dominant-helper") || $0.id.hasPrefix("unmeasured") })
    }

    private func groups(from processes: [ProcessSample], physical: UInt64 = 10_000, cpu: [Int32: Double] = [:]) -> [ConsumerGroup] {
        UsageAnalyzer.groupConsumers(
            processes: processes,
            cpuPercentByPID: cpu,
            physicalMemoryBytes: physical,
            bundleDisplayName: { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        )
    }

    private func heaviest(_ name: String, kind: ConsumerKind, memory: UInt64, cpu: Double, count: Int) -> String {
        let noun = kind == .app ? "app" : "program"
        return "\(name) is the heaviest \(noun) right now: \(analyzerMemoryText(memory)) of memory and \(Int(cpu.rounded()))% CPU across \(analyzerProcessText(count))."
    }

    private func dominantGroup(cpu: Double, own: Double, helper: Double, helperName: String) -> ConsumerGroup {
        makeGroup(
            id: "\(root)/Terminal.app",
            name: "Terminal",
            processCount: 2,
            cpu: cpu,
            memory: 100,
            processes: [
                ProcessUsage(pid: 1, name: "Terminal", cpuPercent: own, memoryBytes: 80),
                ProcessUsage(pid: 2, name: helperName, cpuPercent: helper, memoryBytes: 20),
            ]
        )
    }
}
