import Foundation
import Darwin

public enum ClaudeCodeFailure: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case authentication(String)
    case configuration(String)
    case network
    case timeout
    case protocolError
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not signed in. Run `claude` and sign in with a Claude subscription, then refresh."
        case .authentication(let text):
            return text
        case .configuration(let text):
            return text
        case .network:
            return "Claude Code usage could not be fetched. Check your network, then refresh."
        case .timeout:
            return "Claude Code usage timed out. A bounded retry is scheduled."
        case .protocolError:
            return "Unsupported or incomplete Claude Code response."
        case .server(let code):
            return code == 429
                ? "Claude Code rate-limited this request (429). A bounded retry is scheduled."
                : "Claude Code rejected the request (\(code))."
        }
    }

    public var isTransient: Bool {
        switch self {
        case .network, .timeout: return true
        case .server(let code): return code == 429 || (500...599).contains(code)
        default: return false
        }
    }

    public var isAuthentication: Bool {
        switch self {
        case .authentication, .notConnected: return true
        default: return false
        }
    }
}

// One server-reported quota window. utilization is the percent already consumed.
public struct ClaudeWindow: Equatable, Sendable {
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(usedPercent: Double?, resetsAt: Date?) {
        self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }

    public var remaining: Int? {
        usedPercent.map { Int((100 - min(100, max(0, $0))).rounded()) }
    }
}

public struct ClaudeExtraUsage: Equatable, Sendable {
    public let isEnabled: Bool?
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?

    public init(isEnabled: Bool?, monthlyLimit: Double?, usedCredits: Double?, utilization: Double?) {
        self.isEnabled = isEnabled; self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits; self.utilization = utilization
    }

    public var configured: Bool { isEnabled == true && (monthlyLimit ?? 0) > 0 }
}

public struct ClaudeCodeSnapshot: Equatable, Sendable {
    public let subscriptionType: String?
    public let rateLimitTier: String?
    public let fiveHour: ClaudeWindow?
    public let weekly: ClaudeWindow?
    public let weeklyOpus: ClaudeWindow?
    public let weeklySonnet: ClaudeWindow?
    public let extraUsage: ClaudeExtraUsage?
    public let fetchedAt: Date

    public init(
        subscriptionType: String?,
        rateLimitTier: String?,
        fiveHour: ClaudeWindow?,
        weekly: ClaudeWindow?,
        weeklyOpus: ClaudeWindow?,
        weeklySonnet: ClaudeWindow?,
        extraUsage: ClaudeExtraUsage?,
        fetchedAt: Date
    ) {
        self.subscriptionType = subscriptionType; self.rateLimitTier = rateLimitTier
        self.fiveHour = fiveHour; self.weekly = weekly
        self.weeklyOpus = weeklyOpus; self.weeklySonnet = weeklySonnet
        self.extraUsage = extraUsage; self.fetchedAt = fetchedAt
    }

    public var planName: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        switch subscriptionType.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return subscriptionType.capitalized
        }
    }

    // The single number the menu bar uses when a provider-wide metric is requested.
    public func remaining(for metric: UsageMetric) -> Int? {
        switch metric {
        case .fiveHour: return fiveHour?.remaining ?? weekly?.remaining
        case .weekly: return weekly?.remaining ?? fiveHour?.remaining
        case .both: return fiveHour?.remaining ?? weekly?.remaining
        }
    }
}

public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken; self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType; self.rateLimitTier = rateLimitTier
    }

    public func expired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

// Read-only Claude Code usage. The OAuth credential is read from the keychain item
// Claude Code itself wrote, or its file copy. This client never refreshes, rewrites,
// copies, or logs the credential: an expired token is reported, not rotated, because
// Claude Code owns that lifecycle.
public final class ClaudeCodeClient: @unchecked Sendable {
    public static let defaultKeychainService = "Claude Code-credentials"
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public static let shared = ClaudeCodeClient()

    public static func cancelAll() {
        shared.session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    public func read(configuration: ClaudeCodeConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ClaudeCodeSnapshot {
        let credentials = try Self.resolveCredentials(configuration: configuration, environment: environment)
        if credentials.expired() {
            throw ClaudeCodeFailure.authentication("Claude Code’s saved token has expired. Open Claude Code once so it refreshes, then refresh here.")
        }
        let response = try await fetchUsage(token: credentials.accessToken)
        return Self.decode(response, credentials: credentials, now: Date())
    }

    static func decode(_ response: AnthropicUsageResponse, credentials: ClaudeCredentials, now: Date) -> ClaudeCodeSnapshot {
        ClaudeCodeSnapshot(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            fiveHour: response.fiveHour.map(Self.window),
            weekly: response.sevenDay.map(Self.window),
            weeklyOpus: response.sevenDayOpus.map(Self.window),
            weeklySonnet: response.sevenDaySonnet.map(Self.window),
            extraUsage: response.extra.map {
                ClaudeExtraUsage(isEnabled: $0.isEnabled, monthlyLimit: $0.monthlyLimit,
                                 usedCredits: $0.usedCredits, utilization: $0.utilization)
            },
            fetchedAt: now
        )
    }

    private static func window(_ raw: AnthropicWindow) -> ClaudeWindow {
        ClaudeWindow(usedPercent: raw.utilization, resetsAt: raw.resetsAt.flatMap(parseDate))
    }

    public static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func resolveCredentials(configuration: ClaudeCodeConfiguration, environment: [String: String]) throws -> ClaudeCredentials {
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return ClaudeCredentials(accessToken: token, expiresAt: nil, subscriptionType: nil, rateLimitTier: nil)
        }
        var data: Data?
        var foundSource = false
        if configuration.useKeychain {
            data = KeychainCredential.read(service: configuration.keychainService)
            foundSource = data != nil
        }
        if data == nil, configuration.hasCredentialsFile {
            data = try? Data(contentsOf: URL(fileURLWithPath: configuration.expandedCredentialsFile))
            foundSource = foundSource || data != nil
        }
        guard foundSource, let data else { throw ClaudeCodeFailure.notConnected }
        guard let payload = try? JSONDecoder().decode(CredentialFile.self, from: data) else {
            throw ClaudeCodeFailure.configuration("Claude Code credentials could not be read. Open Claude Code and sign in again.")
        }
        guard let block = payload.claudeAiOauth else { throw ClaudeCodeFailure.notConnected }
        // An empty token means Claude Code is not actually signed in. That is a
        // not-connected state, not a failure worth an error marker in the menu bar.
        let token = block.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ClaudeCodeFailure.notConnected }
        let expiresAt = block.expiresAt.flatMap(Self.date(milliseconds:))
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: block.subscriptionType,
            rateLimitTier: block.rateLimitTier
        )
    }

    // Claude Code writes epoch milliseconds. Older builds wrote seconds; detect the unit.
    static func date(milliseconds raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw >= 1e11 ? raw / 1000 : raw)
    }

    private func fetchUsage(token: String) async throws -> AnthropicUsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexLimits/1.5", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? ClaudeCodeFailure.timeout : ClaudeCodeFailure.network
        } catch {
            throw ClaudeCodeFailure.network
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeCodeFailure.protocolError }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403:
            throw ClaudeCodeFailure.authentication("Claude Code rejected the saved token. Open Claude Code to sign in again, then refresh here.")
        case 429: throw ClaudeCodeFailure.server(429)
        default: throw ClaudeCodeFailure.server(http.statusCode)
        }
        guard data.count <= 4_194_304 else { throw ClaudeCodeFailure.protocolError }
        do {
            return try JSONDecoder().decode(AnthropicUsageResponse.self, from: data)
        } catch {
            throw ClaudeCodeFailure.protocolError
        }
    }
}

// /usr/bin/security already has access to the item Claude Code created, so reading it
// costs no keychain prompt for a differently signed app. Read-only; no writes, no copy.
enum KeychainCredential {
    // Attribute-only lookup; never reads or prints the secret.
    static func exists(service: String) -> Bool {
        let trimmed = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", trimmed]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func read(service: String) -> Data? {
        let trimmed = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", trimmed, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let pid = process.processIdentifier
        let deadline = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { Darwin.kill(pid, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}

struct CredentialFile: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
        let subscriptionType: String?
        let rateLimitTier: String?
    }
    let claudeAiOauth: OAuth?
}

struct AnthropicWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
}

struct AnthropicExtraUsageField: Decodable {
    let is_enabled: Bool?
    let monthly_limit: Double?
    let used_credits: Double?
    let utilization: Double?
}

struct AnthropicUsageResponse: Decodable {
    let five_hour: AnthropicWindow?
    let seven_day: AnthropicWindow?
    let seven_day_opus: AnthropicWindow?
    let seven_day_sonnet: AnthropicWindow?
    let extra_usage: AnthropicExtraUsageField?
}

extension AnthropicUsageResponse {
    var fiveHour: AnthropicWindow? { five_hour }
    var sevenDay: AnthropicWindow? { seven_day }
    var sevenDayOpus: AnthropicWindow? { seven_day_opus }
    var sevenDaySonnet: AnthropicWindow? { seven_day_sonnet }
    var extra: AnthropicExtraUsageField? { extra_usage }
}

extension AnthropicWindow {
    var resetsAt: String? { resets_at }
}

extension AnthropicExtraUsageField {
    var isEnabled: Bool? { is_enabled }
    var monthlyLimit: Double? { monthly_limit }
    var usedCredits: Double? { used_credits }
}
