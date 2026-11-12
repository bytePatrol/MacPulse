// Interpreter identity uses argv only, never environment values.
import Foundation
import Darwin

enum ProcessArguments {
    static func isInterpreter(_ name: String) -> Bool {
        ["node", "bun", "deno", "python", "ruby", "perl", "java", "php"].contains(name)
            || name.hasPrefix("python3")
    }

    static func executableName(_ process: ProcessSample) -> String {
        process.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? process.name
    }

    private static let argumentCapacity: Int = {
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, u_int(mib.count), &limit, &size, nil, 0) == 0, limit > 0 else { return 0 }
        return Int(limit)
    }()

    static func scriptName(pid: pid_t, executableName: String) -> String? {
        guard isInterpreter(executableName), argumentCapacity > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: argumentCapacity)
        var size = bytes.count
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = bytes.withUnsafeMutableBytes {
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size)) }
        guard argc > 0, argc <= size else { return nil }
        var index = MemoryLayout<Int32>.size
        // Kernel format: argc, executable path, NUL padding, then argc argv
        // strings. Stop at argc so environment strings are never interpreted.
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < size else { return nil }
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size else { return nil }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return scriptName(in: arguments, executableName: executableName)
    }

    static func scriptName(in arguments: [String], executableName: String) -> String? {
        guard isInterpreter(executableName) else { return nil }
        let takesOperand: Set<String> = [
            "-r", "--require", "--import", "--loader", "--experimental-loader", "--conditions", "-C",
            "-W", "-X", "-I", "-E", "--encoding", "-cp", "-classpath", "--class-path",
            "--module-path", "--add-opens", "--add-exports", "--add-reads", "--patch-module",
        ]
        var index = 1 // argv[0] is the interpreter, not its script.
        var positional = false
        while index < arguments.count {
            let argument = arguments[index]
            if !positional && argument == "--" { positional = true; index += 1; continue }
            if !positional && argument == "-m" {
                return index + 1 < arguments.count ? nonempty(arguments[index + 1]) : nil
            }
            if !positional && ["-e", "--eval", "-c", "-p", "--print"].contains(argument) {
                // Inline source is not a script identity and may contain secrets.
                return nil
            }
            if !positional && argument.hasPrefix("--eval=") { return nil }
            if !positional && takesOperand.contains(argument) { index += 2; continue }
            if !positional && argument.hasPrefix("-") {
                if argument == "-" { return nil } // stdin
                index += 1
                continue
            }
            if (executableName == "bun" || executableName == "deno") && ["run", "task"].contains(argument) {
                index += 1
                continue
            }
            return nonempty(URL(fileURLWithPath: argument).lastPathComponent)
        }
        return nil
    }

    private static func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }
}
