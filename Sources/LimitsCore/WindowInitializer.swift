import Foundation

public enum WindowInitializer {
    public static let supported = true
    public static let interval: TimeInterval = 600
    public static let limitation = "Best effort: checks every 10 minutes. Sends ok once at 100%; re-arms after an observed drop below 100%. No purchases or automatic reset redemption. Rounded percentages are not proof of a new window."
    public static func mayExecute(usage: UsageResponse, enabled: Bool) -> Bool {
        guard enabled, let limits = usage.codex, let five = limits.fiveHour,
              five.usedPercent == 0, let weekly = limits.weekly, weekly.remaining > 0,
              usage.ordinaryUsageAllowed == true, let credits = limits.credits,
              !credits.hasCredits, !credits.unlimited else { return false }
        if let balance = credits.balance, Decimal(string: balance) != 0 { return false }
        return true
    }
}

public struct AutoStartRecord: Codable, Sendable {
    public let home: String
    public let email: String
    public let accountId: String
    public var armed = true
    public var checkedAt: Date?
    public var attemptedAt: Date?
    public var message: String?
}

public final class AutoStartStore {
    private let file: URL
    public init(root: URL) { file = root.appendingPathComponent("auto-start.json") }
    private func load() throws -> [String: AutoStartRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: AutoStartRecord].self, from: Data(contentsOf: file))
    }
    private func key(account: AccountConfiguration, snapshot: AccountSnapshot) throws -> String {
        guard !snapshot.email.isEmpty, let id = snapshot.usage.accountId, !id.isEmpty else {
            throw ClientFailure.authentication("Auto-start requires a verified user/workspace identity.")
        }
        return String(data: try JSONEncoder().encode([account.canonicalHome, snapshot.email, id]), encoding: .utf8)!
    }
    private func save(_ records: [String: AutoStartRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func record(account: AccountConfiguration, snapshot: AccountSnapshot) throws -> AutoStartRecord? {
        try load()[key(account: account, snapshot: snapshot)]
    }
    // Claim before dispatch; failures/uncertain completion remain latched, including after restart.
    public func observe(account: AccountConfiguration, snapshot: AccountSnapshot, now: Date) throws -> Bool {
        guard account.autoStart else { return false }
        let id = try key(account: account, snapshot: snapshot)
        var records = try load()
        var record = records[id] ?? AutoStartRecord(home: account.canonicalHome, email: snapshot.email, accountId: snapshot.usage.accountId!)
        if let checked = record.checkedAt, now.timeIntervalSince(checked) < WindowInitializer.interval { return false }
        record.checkedAt = now
        if let remaining = snapshot.usage.codex?.fiveHour?.remaining, remaining < 100 {
            record.armed = true
            record.message = "Armed · waiting for 100%"
        }
        let fire = record.armed && WindowInitializer.mayExecute(usage: snapshot.usage, enabled: true)
        if fire {
            record.armed = false; record.attemptedAt = now
            record.message = "Attempt saved · result pending/unknown"
        } else if record.armed && snapshot.usage.codex?.fiveHour?.remaining == 100 {
            record.message = "Skipped · verify weekly allowance, ordinary usage permission, and no paid credits"
        }
        records[id] = record
        try save(records)
        return fire
    }
    public func finish(account: AccountConfiguration, snapshot: AccountSnapshot, message: String) throws {
        let id = try key(account: account, snapshot: snapshot)
        var records = try load()
        guard records[id] != nil else { throw ClientFailure.configuration("Auto-start record is missing.") }
        records[id]?.message = message
        try save(records)
    }
}

public struct RetryState: Sendable {
    public private(set) var failures = 0
    public private(set) var nextAttempt: Date?
    public init() {}
    public mutating func succeeded() { failures = 0; nextAttempt = nil }
    public mutating func failed(_ error: ClientFailure, now: Date, interval: TimeInterval) {
        failures += 1
        if !error.isTransient { nextAttempt = .distantFuture; return }
        // Three bounded recovery attempts, then return to ordinary polling. No retry loop.
        let delay = failures <= 3 ? min(interval, 30 * pow(2, Double(failures - 1))) : interval
        nextAttempt = now.addingTimeInterval(delay)
    }
    public func due(now: Date) -> Bool { nextAttempt.map { now >= $0 } ?? true }
}
