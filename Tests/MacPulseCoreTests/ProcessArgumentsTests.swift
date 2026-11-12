// KERN_PROCARGS2 identity: argv only, never the environment.
import Foundation
import XCTest
@testable import MacPulseCore

final class ProcessArgumentsTests: XCTestCase {
    func testNonInterpretersAndInlineSourceHaveNoScriptName() {
        XCTAssertNil(ProcessArguments.scriptName(in: ["postgres", "-D", "/tmp/data"], executableName: "postgres"))
        XCTAssertNil(ProcessArguments.scriptName(in: ["node", "-e", "console.log(process.env.SECRET)", "cpu-load.ts"], executableName: "node"))
        XCTAssertNil(ProcessArguments.scriptName(in: ["python3", "-c", "import os"], executableName: "python3"))
        XCTAssertNil(ProcessArguments.scriptName(in: ["ruby", "-e", "puts ENV['SECRET']"], executableName: "ruby"))
        XCTAssertNil(ProcessArguments.scriptName(in: ["perl", "-e", "sleep 5"], executableName: "perl"))
        XCTAssertNil(ProcessArguments.scriptName(in: ["php", "-r", "sleep(5);"], executableName: "php"))
        XCTAssertNil(ProcessArguments.scriptName(in: ["node", "--eval=process.env.SECRET"], executableName: "node"))
        XCTAssertNil(ProcessArguments.scriptName(in: ["node", "-p", "1"], executableName: "node"))
        XCTAssertNil(ProcessArguments.scriptName(in: ["node", "-"], executableName: "node"))
        XCTAssertFalse(ProcessArguments.isInterpreter("postgres"))
        XCTAssertTrue(ProcessArguments.isInterpreter("python3.11"))
    }

    func testPositionalScriptIsTheLastPathComponentAfterFlags() {
        XCTAssertEqual(
            ProcessArguments.scriptName(in: ["node", "-r", "./preload.js", "--experimental-loader", "./loader.mjs", "--", "dir/cpu-load.ts"], executableName: "node"),
            "cpu-load.ts"
        )
        XCTAssertEqual(
            ProcessArguments.scriptName(in: ["node", "--max-old-space-size=4096", "/tmp/macpulse/cpu-load.ts"], executableName: "node"),
            "cpu-load.ts"
        )
        XCTAssertEqual(ProcessArguments.scriptName(in: ["python3.11", "-m", "http.server"], executableName: "python3.11"), "http.server")
        XCTAssertEqual(ProcessArguments.scriptName(in: ["bun", "run", "src/cpu-load.ts"], executableName: "bun"), "cpu-load.ts")
        XCTAssertEqual(ProcessArguments.scriptName(in: ["deno", "task", "start"], executableName: "deno"), "start")
        XCTAssertEqual(
            ProcessArguments.scriptName(in: ["java", "-cp", "/tmp/lib.jar", "com.example.Main"], executableName: "java"),
            "com.example.Main"
        )
        XCTAssertNil(ProcessArguments.scriptName(in: ["node", "--require", "/tmp/preload.js"], executableName: "node"))
    }

    func testLiveParserStopsAtArgcAndIgnoresTheEnvironment() throws {
        let node = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node.path), "node is not installed")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macpulse-qa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cpu-load.ts")
        let preload = directory.appendingPathComponent("preload.js")
        try "setInterval(() => {}, 1000)\n".write(to: script, atomically: true, encoding: .utf8)
        try "setInterval(() => {}, 1000)\n".write(to: preload, atomically: true, encoding: .utf8)

        let secret = "/tmp/should-not-be-the-script.js"
        let scripted = try launch(node, arguments: [script.path], secret: secret)
        defer { scripted.terminate() }
        let required = try launch(node, arguments: ["--require", preload.path], secret: secret)
        defer { required.terminate() }
        let inline = try launch(node, arguments: ["-e", "setInterval(() => {}, 1000)"], secret: secret)
        defer { inline.terminate() }

        let scriptName = ProcessArguments.scriptName(pid: scripted.processIdentifier, executableName: "node")
        let requiredName = ProcessArguments.scriptName(pid: required.processIdentifier, executableName: "node")
        let inlineName = ProcessArguments.scriptName(pid: inline.processIdentifier, executableName: "node")
        XCTAssertEqual(scriptName, "cpu-load.ts", "expected the script, got \(scriptName ?? "nil")")
        XCTAssertNil(requiredName, "a --require with no script must not adopt an environment value (got \(requiredName ?? "nil"))")
        XCTAssertNil(inlineName, "inline -e source must not become a script name (got \(inlineName ?? "nil"))")
        XCTAssertNotEqual(scriptName, "should-not-be-the-script.js")
    }

    private func launch(_ node: URL, arguments: [String], secret: String) throws -> Process {
        let process = Process()
        process.executableURL = node
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["MACPULSE_QA_SECRET"] = secret
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(process.isRunning, "node exited before its arguments could be read: \(arguments)")
        return process
    }
}
