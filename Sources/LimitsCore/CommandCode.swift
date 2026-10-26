import Foundation

public enum CommandCodeFailure: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case authentication
    case configuration(String)
    case network
    case timeout
    case protocolError
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Command Code is not signed in. Run `cmd login`, then refresh."
        case .authentication:
            return "Command Code rejected the saved login. Run `cmd login` again."
        case .configuration(let text):
            return text
        case .network:
            return "Command Code usage could not be fetched. Check your network, then refresh."
        case .timeout:
            return "Command Code usage timed out. A bounded retry is scheduled."
        case .protocolError:
            return "Unsupported or incomplete Command Code usage response. Update Command Code or this app."
        case .server(let code):
            return "Command Code rejected the usage request (\(code)). Check the account or try again later."
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
        self == .authentication || self == .notConnected
    }
}

public struct CommandCodeWindow: Equatable, Sendable {
    public let used: Double?
    public let cap: Double?
    public let resetAt: Date?

    public init(used: Double?, cap: Double?, resetAt: Date?) {
        self.used = used; self.cap = cap; self.resetAt = resetAt
    }

    public var remaining: Int? {
        guard let used, let cap, cap > 0 else { return nil }
        return Int(((1 - min(1, max(0, used / cap))) * 100).rounded())
    }
}

public struct CommandCodeWindowLimits: Equatable, Sendable {
    public let limited: Bool
    public let fiveHour: CommandCodeWindow?
    public let weekly: CommandCodeWindow?

    public init(limited: Bool, fiveHour: CommandCodeWindow?, weekly: CommandCodeWindow?) {
        self.limited = limited; self.fiveHour = fiveHour; self.weekly = weekly
    }
}

public struct CommandCodeCredits: Equatable, Sendable {
    public let monthlyRemaining: Double?
    public let purchasedRemaining: Double
    public let freeRemaining: Double

    public init(monthlyRemaining: Double?, purchasedRemaining: Double, freeRemaining: Double) {
        self.monthlyRemaining = monthlyRemaining.map { max(0, $0) }
        self.purchasedRemaining = max(0, purchasedRemaining)
        self.freeRemaining = max(0, freeRemaining)
    }

    public var totalRemaining: Double? {
        monthlyRemaining.map { $0 + purchasedRemaining + freeRemaining }
    }
    public var extraRemaining: Double { purchasedRemaining + freeRemaining }
}

public struct CommandCodeSnapshot: Equatable, Sendable {
    public let userName: String
    public let orgLogin: String?
    public let planName: String?
    public let planMonthlyCredits: Double?
    public let subscriptionStatus: String?
    public let currentPeriodEnd: Date?
    public let credits: CommandCodeCredits?
    public let windowLimits: CommandCodeWindowLimits?
    public let totalCost: Double?
    public let totalCount: Int?
    public let warnings: [String]
    public let fetchedAt: Date

    public var monthlyRemainingPercent: Int? {
        guard let credits, let remaining = credits.totalRemaining else { return nil }
        let pool: Double?
        if subscriptionStatus == "active", let planMonthlyCredits {
            pool = planMonthlyCredits + credits.purchasedRemaining + credits.freeRemaining
        } else if let totalCost {
            pool = totalCost + remaining
        } else {
            pool = nil
        }
        guard let pool, pool > 0 else { return nil }
        return Int(((remaining / pool) * 100).rounded())
    }

    public var menuBarRemaining: Int? {
        if let window = windowLimits?.fiveHour, let remaining = window.remaining { return remaining }
        if windowLimits?.limited == true, let weekly = windowLimits?.weekly, let remaining = weekly.remaining { return remaining }
        return monthlyRemainingPercent
    }

    public func daysUntilRenewal(now: Date = Date()) -> Int? {
        currentPeriodEnd.map { max(0, Int(ceil($0.timeIntervalSince(now) / 86_400))) }
    }
}

public final class CommandCodeClient: @unchecked Sendable {
    public static let shared = CommandCodeClient()
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "https://api.commandcode.ai")!) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    public static func cancelAll() {
        shared.session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    public func read(authFile: String, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> CommandCodeSnapshot {
        let token = try Self.resolveToken(authFile: authFile, environment: environment)
        let whoami: WhoamiResponse = try await fetch("/alpha/whoami", query: [URLQueryItem(name: "limits", value: "1")], token: token)
        let orgId = whoami.org?.id
        let credits: CreditsResponse = try await fetch("/alpha/billing/credits", query: [URLQueryItem(name: "orgId", value: orgId)], token: token)

        var warnings: [String] = []
        var subscription: SubscriptionResponse?
        do {
            subscription = try await fetch("/alpha/billing/subscriptions", query: [URLQueryItem(name: "orgId", value: orgId)], token: token)
        } catch let failure as CommandCodeFailure {
            if failure.isAuthentication { throw failure }
            warnings.append("Billing period unavailable.")
        }

        var summary: UsageSummaryResponse?
        do {
            summary = try await fetch("/alpha/usage/summary", query: [
                URLQueryItem(name: "orgId", value: orgId),
                URLQueryItem(name: "since", value: subscription?.data?.currentPeriodStart)
            ], token: token)
        } catch let failure as CommandCodeFailure {
            if failure.isAuthentication { throw failure }
            warnings.append("Usage summary unavailable.")
        }

        return Self.decode(whoami: whoami, credits: credits, subscription: subscription, summary: summary, now: Date(), warnings: warnings)
    }

    static func decode(whoami: WhoamiResponse, credits: CreditsResponse, subscription: SubscriptionResponse?, summary: UsageSummaryResponse?, now: Date, warnings: [String] = []) -> CommandCodeSnapshot {
        let planId = subscription?.data?.planId ?? credits.credits?.planId
        let planName = planId.map(Self.planDisplayName)
        let planCredits = planId.flatMap(Self.planMonthlyCredits)
        let rawCredits = credits.credits
        let mappedCredits = rawCredits.map {
            CommandCodeCredits(monthlyRemaining: $0.monthlyCredits,
                               purchasedRemaining: $0.purchasedCredits ?? 0,
                               freeRemaining: $0.freeCredits ?? 0)
        }
        let windowLimits = credits.windowLimits.map { raw in
            CommandCodeWindowLimits(
                limited: raw.limited ?? (raw.fiveHour != nil || raw.weekly != nil),
                fiveHour: raw.fiveHour.map(Self.window),
                weekly: raw.weekly.map(Self.window)
            )
        }
        return CommandCodeSnapshot(
            userName: whoami.user?.userName ?? whoami.user?.email ?? whoami.org?.login ?? "Command Code",
            orgLogin: whoami.org?.login,
            planName: planName,
            planMonthlyCredits: planCredits,
            subscriptionStatus: subscription?.data?.status,
            currentPeriodEnd: Self.date(subscription?.data?.currentPeriodEnd),
            credits: mappedCredits,
            windowLimits: windowLimits,
            totalCost: summary?.totalCost,
            totalCount: summary?.totalCount,
            warnings: warnings,
            fetchedAt: now
        )
    }

    private static func window(_ raw: RawWindow) -> CommandCodeWindow {
        CommandCodeWindow(used: raw.used, cap: raw.cap, resetAt: raw.resetAt.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    private static func planDisplayName(_ planId: String) -> String {
        let id = planId.lowercased().replacingOccurrences(of: "_", with: "-")
        if id.hasPrefix("individual-goat") { return "GOAT" }
        if id.hasPrefix("individual-provider") { return "Provider" }
        if id.hasPrefix("individual-go") { return "Go" }
        if id.hasPrefix("individual-pro") { return "Pro" }
        if id.hasPrefix("individual-max") { return "Max" }
        if id.hasPrefix("individual-ultra") { return "Ultra" }
        if id.hasPrefix("teams-pro") { return "Teams Pro" }
        return planId
    }

    private static func planMonthlyCredits(_ planId: String) -> Double? {
        let id = planId.lowercased().replacingOccurrences(of: "_", with: "-")
        if id.hasPrefix("individual-goat") { return 70 }
        if id.hasPrefix("individual-provider") { return 15 }
        if id.hasPrefix("individual-go") { return 10 }
        if id.hasPrefix("individual-pro-v1") { return 80 }
        if id.hasPrefix("individual-pro") { return 30 }
        if id.hasPrefix("individual-max") { return 150 }
        if id.hasPrefix("individual-ultra") { return 300 }
        if id.hasPrefix("teams-pro") { return 40 }
        return nil
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func resolveToken(authFile: String, environment: [String: String]) throws -> String {
        if let token = environment["COMMAND_CODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        let trimmed = authFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CommandCodeFailure.configuration("Command Code auth.json path is empty.") }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else {
            throw CommandCodeFailure.configuration("Command Code auth.json must use an absolute or ~/ path.")
        }
        let path = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { throw CommandCodeFailure.notConnected }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let token = auth.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw CommandCodeFailure.configuration("Command Code auth.json could not be read. Run `cmd login` again.")
        }
        return token
    }

    private func fetch<T: Decodable>(_ path: String, query: [URLQueryItem], token: String) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw CommandCodeFailure.protocolError
        }
        let filtered = query.filter { $0.value?.isEmpty == false }
        components.queryItems = filtered.isEmpty ? nil : filtered
        guard let url = components.url else { throw CommandCodeFailure.protocolError }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexLimits/1.4", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw CommandCodeFailure.timeout
            case .cancelled: throw CommandCodeFailure.network
            default: throw CommandCodeFailure.network
            }
        } catch {
            throw CommandCodeFailure.network
        }
        guard let http = response as? HTTPURLResponse else { throw CommandCodeFailure.protocolError }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw CommandCodeFailure.authentication
        case 429: throw CommandCodeFailure.server(429)
        case 500...599: throw CommandCodeFailure.server(http.statusCode)
        default: throw CommandCodeFailure.server(http.statusCode)
        }
        guard data.count <= 4_194_304 else { throw CommandCodeFailure.protocolError }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CommandCodeFailure.protocolError
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private struct AuthFile: Decodable {
    let apiKey: String
}

struct WhoamiResponse: Decodable {
    struct User: Decodable {
        let userName: String?
        let email: String?
    }
    struct Org: Decodable {
        let id: String?
        let login: String?
    }
    let user: User?
    let org: Org?
}

struct CreditsResponse: Decodable {
    struct RawCredits: Decodable {
        let monthlyCredits: Double?
        let purchasedCredits: Double?
        let freeCredits: Double?
        let planId: String?
    }
    struct RawWindowLimits: Decodable {
        let limited: Bool?
        let fiveHour: RawWindow?
        let weekly: RawWindow?
    }
    let credits: RawCredits?
    let windowLimits: RawWindowLimits?
}

struct RawWindow: Decodable {
    let used: Double?
    let cap: Double?
    let resetAt: Double?
}

struct SubscriptionResponse: Decodable {
    struct Subscription: Decodable {
        let planId: String?
        let status: String?
        let currentPeriodStart: String?
        let currentPeriodEnd: String?
    }
    let data: Subscription?
}

struct UsageSummaryResponse: Decodable {
    let totalCost: Double?
    let totalCount: Int?
}
