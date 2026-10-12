import Foundation
import Darwin

public struct AutoStartResult: Sendable {
    public let message: String
    public let snapshot: AccountSnapshot?
}

public struct ExecutionEvents {
    public private(set) var completed = false
    public private(set) var failed = false
    public init() {}
    public mutating func consume(_ data: Data) throws {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { throw ClientFailure.protocolError }
        switch type {
        case "turn.completed": completed = true
        case "turn.failed", "error": failed = true
        case "item.started", "item.updated", "item.completed":
            guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String else { throw ClientFailure.protocolError }
            // Unexpected tool activity is a failure, never a successful warm-up.
            if !["agent_message", "reasoning"].contains(kind) {
                throw ClientFailure.configuration("Auto-start stopped: an unexpected tool action was requested.")
            }
        case "thread.started", "turn.started": break
        default: throw ClientFailure.protocolError
        }
    }
    public func succeeded(exitCode: Int32) -> Bool { exitCode == 0 && completed && !failed }
}

enum ChildProcesses {
    private static let lock = NSLock()
    private static var processes: [Int32: Process] = [:]
    static func add(_ process: Process) { lock.lock(); defer { lock.unlock() }; processes[process.processIdentifier] = process }
    static func remove(_ process: Process) { lock.lock(); defer { lock.unlock() }; processes.removeValue(forKey: process.processIdentifier) }
    static func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        for (pid, process) in processes where process.isRunning { Darwin.kill(pid, SIGKILL) }
    }
}

public enum AutoStartExecution {
    // CLI options and flags verified against installed 0.154.0 and official source.
    public static func arguments(scratch: String) -> [String] {
        var arguments = ["exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--strict-config", "--sandbox", "read-only", "--cd", scratch, "--color", "never"]
        for override in ["approval_policy=\"never\"", "model_provider=\"openai\"", "service_tier=\"default\"", "web_search=\"disabled\"", "project_doc_max_bytes=0", "developer_instructions=\"Reply exactly ok. Do not use tools, execute commands, access files, or perform any other task.\"", "analytics.enabled=false", "feedback.enabled=false", "otel.exporter=\"none\"", "otel.trace_exporter=\"none\"", "chatgpt_base_url=\"https://chatgpt.com/backend-api/\""] {
            arguments += ["-c", override]
        }
        for feature in ["shell_tool", "hooks", "plugins", "apps", "multi_agent", "multi_agent_v2", "code_mode", "code_mode_only", "code_mode_host", "computer_use", "browser_use", "browser_use_external", "image_generation", "memories", "request_permissions", "request_permissions_tool", "shell_snapshot"] {
            arguments += ["--disable", feature]
        }
        return arguments + ["ok"]
    }
    public static func sandboxProfile(binary: String, home: String, scratch: String) -> String {
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        // Kernel backstop: no shell/interpreter executables, writes confined to auth/state
        // and disposable scratch. Codex's additional read-only tool sandbox protects both.
        return """
        (version 1)
        (allow default)
        (deny process-exec)
        (allow process-exec (literal \(quoted(binary))))
        (deny file-write*)
        (allow file-write* (subpath \(quoted(home))) (subpath \(quoted(scratch))) (literal "/dev/null"))
        """
    }
    static func run(binary: String, home: String) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CodexLimits-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", sandboxProfile(binary: binary, home: home, scratch: scratch.path), binary] + arguments(scratch: scratch.path)
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_REFRESH_TOKEN", "CODEX_HOME", "CODEX_PROFILE"] { environment.removeValue(forKey: key) }
        environment["CODEX_HOME"] = home; environment["TMPDIR"] = scratch.path
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        ChildProcesses.add(process)
        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { Darwin.kill(process!.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90, execute: watchdog)
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); watchdog.cancel(); ChildProcesses.remove(process)
            try? output.fileHandleForReading.close()
        }
        var events = ExecutionEvents(), buffer = Data(), bytes = 0
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            bytes += chunk.count
            guard bytes <= 1_048_576 else { throw ClientFailure.protocolError }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
                if !line.isEmpty { try events.consume(line) }
            }
        }
        process.waitUntilExit()
        guard buffer.isEmpty, events.succeeded(exitCode: process.terminationStatus) else {
            throw ClientFailure.configuration("Auto-start did not complete successfully (authentication, quota, execution restriction, or timeout). No automatic retry for this 100% streak.")
        }
    }
}
