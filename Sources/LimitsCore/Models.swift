import Foundation

public struct UsageWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Int64?
    public var remaining: Int { Int((100 - min(100, max(0, usedPercent))).rounded()) }
    public var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: Double($0)) } }
    public func secondsUntilReset(now: Date) -> TimeInterval? {
        resetDate.map { max(0, $0.timeIntervalSince(now)) }
    }
}

public struct RateLimits: Codable, Equatable, Sendable {
    public let limitId: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public struct Credits: Codable, Equatable, Sendable {
        public let hasCredits: Bool
        public let unlimited: Bool
        public let balance: String?
    }
    public let credits: Credits?
    // Match durations, not primary/secondary ordering: plans can differ.
    public var fiveHour: UsageWindow? { [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == 300 } }
    public var weekly: UsageWindow? { [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == 10_080 } }
}

public enum ExpirationWarning: Equatable { case normal, soon, urgent, expired }

public struct BankedReset: Codable, Equatable, Sendable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Int64
    public let expiresAt: Int64?
    public let title: String?
    public let description: String?
    enum CodingKeys: String, CodingKey { case id, resetType, status, grantedAt, expiresAt, title, description }
    public init(id: String, resetType: String, status: String, grantedAt: Int64, expiresAt: Int64?, title: String?, description: String?) {
        self.id = id; self.resetType = resetType; self.status = status; self.grantedAt = grantedAt
        self.expiresAt = expiresAt; self.title = title; self.description = description
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Explicit null means non-expiring. An absent field means unavailable, not forever.
        guard values.contains(.expiresAt) else {
            throw DecodingError.keyNotFound(CodingKeys.expiresAt, .init(codingPath: decoder.codingPath, debugDescription: "Expiration field unavailable"))
        }
        id = try values.decode(String.self, forKey: .id)
        resetType = try values.decode(String.self, forKey: .resetType)
        status = try values.decode(String.self, forKey: .status)
        grantedAt = try values.decode(Int64.self, forKey: .grantedAt)
        expiresAt = try values.decodeIfPresent(Int64.self, forKey: .expiresAt)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        description = try values.decodeIfPresent(String.self, forKey: .description)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(resetType, forKey: .resetType)
        try values.encode(status, forKey: .status); try values.encode(grantedAt, forKey: .grantedAt)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encodeIfPresent(title, forKey: .title); try values.encodeIfPresent(description, forKey: .description)
    }
    public var expiration: Date? { expiresAt.map { Date(timeIntervalSince1970: Double($0)) } }
    public func warning(now: Date) -> ExpirationWarning {
        guard let expiration else { return .normal }
        let seconds = expiration.timeIntervalSince(now)
        if seconds <= 0 { return .expired }
        if seconds < 86_400 { return .urgent }
        if seconds <= 259_200 { return .soon }
        return .normal
    }
}

public struct ResetSummary: Codable, Equatable, Sendable {
    public let availableCount: Int
    public let credits: [BankedReset]?
    enum CodingKeys: String, CodingKey { case availableCount, credits }
    public init(availableCount: Int, credits: [BankedReset]?) { self.availableCount = availableCount; self.credits = credits }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try values.decode(Int.self, forKey: .availableCount)
        // Keep a trustworthy count when details are incomplete or from a newer schema.
        credits = try? values.decode([BankedReset].self, forKey: .credits)
    }
    public var sortedAvailable: [BankedReset]? {
        credits.map { rows in
            rows.filter { $0.status == "available" && $0.resetType == "codexRateLimits" }
                .sorted {
                    let a = $0.expiresAt ?? Int64.max, b = $1.expiresAt ?? Int64.max
                    return a == b ? $0.id < $1.id : a < b
                }
        }
    }
}

public struct UsageResponse: Codable, Equatable, Sendable {
    public let rateLimits: RateLimits
    public let rateLimitsByLimitId: [String: RateLimits]?
    public let rateLimitResetCredits: ResetSummary?
    public let ordinaryUsageAllowed: Bool?
    public let accountId: String?
    public var codex: RateLimits? {
        if let buckets = rateLimitsByLimitId, !buckets.isEmpty { return buckets["codex"] }
        // Do not mislabel a premium/model-specific bucket as the ordinary Codex pool.
        return rateLimits.limitId == nil || rateLimits.limitId == "codex" ? rateLimits : nil
    }
}

public struct AccountResponse: Decodable, Sendable {
    public struct Account: Decodable, Sendable {
        public let type: String
        public let email: String?
        public let planType: String?
    }
    public let account: Account?
    public let requiresOpenaiAuth: Bool
}

public struct AccountSnapshot: Sendable {
    public let email: String
    public let usage: UsageResponse
    public let fetchedAt: Date
    public init(email: String, usage: UsageResponse, fetchedAt: Date = Date()) {
        self.email = email; self.usage = usage; self.fetchedAt = fetchedAt
    }
}

public enum DisplayTime {
    public static func relative(until: Date, now: Date = Date()) -> String {
        let seconds = until.timeIntervalSince(now)
        guard seconds > 0 else { return "expired" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
    public static func absolute(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}
