import Foundation
import Darwin

public enum ClientFailure: Error, LocalizedError, Equatable, Sendable {
    case authentication(String), configuration(String), network, timeout, protocolError, server(Int)
    public var errorDescription: String? {
        switch self {
        case .authentication(let text), .configuration(let text): return text
        case .network: return "Codex could not fetch usage. Check your network, then refresh."
        case .timeout: return "Codex timed out. A bounded retry is scheduled."
        case .protocolError: return "Unsupported or incomplete Codex response. Update the CLI."
        case .server(let code): return "Codex rejected the request (\(code)). Check the account or CLI configuration."
        }
    }
    public var isTransient: Bool { self == .network || self == .timeout }
    public static func fromRPC(code: Int, message: String) -> ClientFailure {
        let text = message.lowercased()
        if ["authentication", "unauthorized", "401", "refresh token", "refresh_token", "sign in", "login"].contains(where: text.contains) {
            return .authentication("ChatGPT authentication failed. Sign in again in this account’s dedicated home.")
        }
        if ["failed to fetch", "network", "connect", "timed out", "429", "503", "502"].contains(where: text.contains) { return .network }
        return .server(code)
    }
}

public protocol AccountReading {
    func read(account: AccountConfiguration, executable: String) throws -> AccountSnapshot
}

public enum CodexExecutable {
    public static func nativePath(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let magic = (try? handle.read(upToCount: 4)) ?? Data()
            let signatures: [[UInt8]] = [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca], [0xca, 0xfe, 0xba, 0xbf]]
            if signatures.contains(Array(magic)) { return url.path }
        }
        // Resolve the official npm launcher to its native executable; never run Node.
        let package = url.deletingLastPathComponent().deletingLastPathComponent()
        for relative in ["vendor/aarch64-apple-darwin/bin/codex", "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex", "../codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"] {
            let candidate = package.appendingPathComponent(relative).standardizedFileURL.path
            if candidate != path, FileManager.default.isExecutableFile(atPath: candidate) { return nativePath(candidate) }
        }
        return nil
    }
    public static func discover() -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        for directory in paths {
            if let binary = nativePath(directory + "/codex") { return binary }
        }
        return ""
    }
}

// One blocking worker per refresh; no persistent Codex server or timers in the client.
// Never expose raw stderr/RPC payloads: they may contain sensitive diagnostics.
public final class CodexClient: AccountReading {
    public init() {}
    public static func cancelAll() { ChildProcesses.cancelAll() }
    public func initializeWindow(account: AccountConfiguration, expected: AccountSnapshot, executable: String) throws -> AutoStartResult {
        try account.validateDedicatedHome()
        guard let binary = CodexExecutable.nativePath(executable) else { throw ClientFailure.configuration("Native Codex binary unavailable.") }
        let lease = try HomeLease(home: account.canonicalHome)
        return try withExtendedLifetime(lease) {
            let rpc = try RPCSession(executable: binary, home: account.canonicalHome, timeout: 40)
            do {
                try rpc.initialize()
                let identity = try rpc.readAccount()
                let usage = try rpc.readUsage()
                let after = try rpc.readAccount()
                guard identity.account?.email == expected.email, after.account?.email == expected.email,
                      identity.account?.type == "chatgpt", after.account?.type == "chatgpt",
                      expected.usage.accountId != nil, usage.accountId == expected.usage.accountId else {
                    throw ClientFailure.authentication("Auto-start skipped: account/workspace changed.")
                }
                guard WindowInitializer.mayExecute(usage: usage, enabled: account.autoStart) else {
                    throw ClientFailure.configuration("Auto-start skipped: allowance or credit state changed before execution.")
                }
                rpc.close()
                try AutoStartExecution.run(binary: binary, home: account.canonicalHome)
            } catch { rpc.close(); throw error }
            // Same home lease retained until inference ends; then the ordinary reader may acquire it.
            return AutoStartResult(message: "ok completed · " + DisplayTime.absolute(Date()), snapshot: nil)
        }
    }
    public func redeem(selection: ResetSelection, confirmed: Bool, store: ResetAttemptStore, executable: String) throws -> ResetResult? {
        guard confirmed else { return nil }
        try selection.account.validateDedicatedHome()
        let lease = try HomeLease(home: selection.account.canonicalHome)
        return try withExtendedLifetime(lease) {
            try ResetRedemption.run(selection: selection, confirmed: confirmed, store: store) {
                let rpc = try RPCSession(executable: executable, home: selection.account.canonicalHome, timeout: 40)
                do { try rpc.initialize(); return rpc }
                catch { rpc.close(); throw error }
            }
        }
    }
    public func read(account: AccountConfiguration, executable: String) throws -> AccountSnapshot {
        try account.validateDedicatedHome()
        let lease = try HomeLease(home: account.canonicalHome)
        return try withExtendedLifetime(lease) {
            let rpc = try RPCSession(executable: executable, home: account.canonicalHome, timeout: 40)
            defer { rpc.close() }
            try rpc.initialize()
            let identity: AccountResponse = try rpc.request("account/read", params: ["refreshToken": false])
            guard let user = identity.account, user.type == "chatgpt" else {
                throw ClientFailure.authentication("Not signed into ChatGPT. Use Sign in in Settings; API keys are not supported.")
            }
            guard let email = user.email, !email.isEmpty else {
                throw ClientFailure.authentication("Codex did not return an account identity. Independence cannot be verified.")
            }
            let usage: UsageResponse = try rpc.request("account/rateLimits/read", params: [:])
            // Ensure the local auth owner did not change during the network read.
            let after: AccountResponse = try rpc.request("account/read", params: ["refreshToken": false])
            guard after.account?.type == "chatgpt", after.account?.email == email else {
                throw ClientFailure.authentication("Account changed while reading usage. Refresh again.")
            }
            return AccountSnapshot(email: email, usage: usage)
        }
    }

    public func login(account: AccountConfiguration, executable: String, openURL: (URL) -> Void) throws {
        try account.validateDedicatedHome()
        let lease = try HomeLease(home: account.canonicalHome)
        try withExtendedLifetime(lease) {
            let rpc = try RPCSession(executable: executable, home: account.canonicalHome, timeout: 300)
            defer { rpc.close() }
            try rpc.initialize()
            struct Login: Decodable { let type: String; let loginId: String?; let authUrl: String? }
            let login: Login = try rpc.request("account/login/start", params: ["type": "chatgpt"])
            guard login.type == "chatgpt", let id = login.loginId, let raw = login.authUrl,
                  let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com" else {
                throw ClientFailure.protocolError
            }
            openURL(url)
            while true {
                let message = try rpc.nextMessage()
                guard message["method"] as? String == "account/login/completed",
                      let params = message["params"] as? [String: Any], params["loginId"] as? String == id else { continue }
                guard params["success"] as? Bool == true else {
                    throw ClientFailure.authentication("ChatGPT sign-in failed or was cancelled. Try again.")
                }
                return
            }
        }
    }
}

private final class RPCSession: ResetTransport {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var watchdog: DispatchWorkItem?
    private var closed = false
    private var totalBytes = 0

    init(executable: String, home: String, timeout: TimeInterval) throws {
        guard let binary = CodexExecutable.nativePath(executable) else {
            throw ClientFailure.configuration("A native Apple Silicon Codex executable is required. Select its binary in Settings.")
        }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false", "-c", "feedback.enabled=false", "-c", "otel.exporter=\"none\"", "-c", "otel.trace_exporter=\"none\"", "-c", "chatgpt_base_url=\"https://chatgpt.com/backend-api/\""]
        // Start outside any project; do not load project-specific configuration.
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_REFRESH_TOKEN", "CODEX_HOME", "CODEX_PROFILE"] { environment.removeValue(forKey: key) }
        environment["CODEX_HOME"] = home
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClientFailure.configuration("Could not launch the selected Codex binary.") }
        let pid = process.processIdentifier
        ChildProcesses.add(process)
        let task = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { Darwin.kill(pid, SIGKILL) }
        }
        watchdog = task
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: task)
    }
    func initialize() throws {
        struct Initialized: Decodable {}
        let _: Initialized = try request("initialize", params: [
            "clientInfo": ["name": "codex_limits", "title": "Codex Limits", "version": "1.3.0"],
            "capabilities": ["experimentalApi": false]
        ])
        try send(["method": "initialized", "params": [:]])
    }
    func readAccount() throws -> AccountResponse { try request("account/read", params: ["refreshToken": false]) }
    func readUsage() throws -> UsageResponse { try request("account/rateLimits/read", params: [:]) }
    func consumeReset(_ intent: ResetIntent) throws -> ResetOutcome {
        struct Response: Decodable { let outcome: ResetOutcome }
        let response: Response = try request(ResetRedemption.method, params: intent.parameters)
        return response.outcome
    }
    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw ClientFailure.protocolError }
    }
    func request<T: Decodable>(_ method: String, params: [String: Any]) throws -> T {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        while true {
            let message = try nextMessage()
            guard message["id"] as? Int == id, message["method"] == nil else { continue }
            if let error = message["error"] as? [String: Any] {
                throw ClientFailure.fromRPC(code: error["code"] as? Int ?? -1, message: error["message"] as? String ?? "")
            }
            guard let result = message["result"] else { throw ClientFailure.protocolError }
            do { return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result)) }
            catch { throw ClientFailure.protocolError }
        }
    }
    func nextMessage() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ClientFailure.protocolError }
                if let method = message["method"] as? String, let id = message["id"] {
                    // This monitor never grants approvals or executes server-requested tools.
                    try send(["id": id, "error": ["code": -32601, "message": "Read-only usage monitor rejects \(method)"]])
                    continue
                }
                return message
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                if !process.isRunning, process.terminationReason == .uncaughtSignal { throw ClientFailure.timeout }
                throw ClientFailure.protocolError
            }
            totalBytes += chunk.count
            guard totalBytes <= 8_388_608 else { throw ClientFailure.protocolError }
            buffer.append(chunk)
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        watchdog?.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier
        // Bounded forced shutdown; never retain an app-server after a completed poll.
        let killTask = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { Darwin.kill(pid, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: killTask)
        process.waitUntilExit()
        ChildProcesses.remove(process)
        killTask.cancel()
        try? output.fileHandleForReading.close()
    }
    deinit { close() }
}
