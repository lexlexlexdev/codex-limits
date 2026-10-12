import Foundation

public enum ResetOutcome: String, Codable, Sendable {
    case reset, nothingToReset, noCredit, alreadyRedeemed
    public var message: String {
        switch self {
        case .reset: return "Banked reset applied. Eligible usage windows were refreshed."
        case .nothingToReset: return "Nothing eligible to reset. Your banked reset was not used."
        case .noCredit: return "This reset is no longer available."
        case .alreadyRedeemed: return "This request already applied a reset. No additional reset was consumed."
        }
    }
}

public enum ResetFailure: Error, LocalizedError {
    case notSubmitted(String), uncertain
    public var errorDescription: String? {
        switch self {
        case .notSubmitted(let message): return "Reset not submitted. " + message
        case .uncertain: return "Reset result unknown; it may have been applied. Refresh or check Open Usage. No automatic retry will occur. Confirming this same reset again reuses its saved request key."
        }
    }
}

public struct ResetSelection: Sendable {
    public let account: AccountConfiguration
    public let email: String
    public let accountId: String
    public let credit: BankedReset
    public init(account: AccountConfiguration, snapshot: AccountSnapshot, creditId: String, now: Date = Date()) throws {
        guard !snapshot.email.isEmpty, let accountId = snapshot.usage.accountId, !accountId.isEmpty else {
            throw ResetFailure.notSubmitted("Verified account/workspace identity is unavailable. Use the official usage interface.")
        }
        guard let credit = snapshot.usage.rateLimitResetCredits?.sortedAvailable?.first(where: { $0.id == creditId }),
              !credit.id.isEmpty, (snapshot.usage.rateLimitResetCredits?.availableCount ?? 0) > 0,
              credit.expiration.map({ $0 > now }) ?? true else {
            throw ResetFailure.notSubmitted("This specific reset is unavailable or expired. Refresh usage.")
        }
        self.account = account; email = snapshot.email; self.accountId = accountId; self.credit = credit
    }
}

public struct ResetIntent: Codable, Equatable, Sendable {
    public let slot: String
    public let home: String
    public let email: String
    public let accountId: String
    public let creditId: String
    public let idempotencyKey: String
    init(selection: ResetSelection) {
        slot = selection.account.slot; home = selection.account.canonicalHome
        email = selection.email; accountId = selection.accountId; creditId = selection.credit.id
        idempotencyKey = UUID().uuidString
    }
    public var parameters: [String: String] { ["creditId": creditId, "idempotencyKey": idempotencyKey] }
    func matches(_ selection: ResetSelection) -> Bool {
        slot == selection.account.slot && home == selection.account.canonicalHome && email == selection.email
            && accountId == selection.accountId && creditId == selection.credit.id
    }
}

// Small per-reset request records, no tokens. Never replayed automatically at startup.
public final class ResetAttemptStore {
    private struct Record: Codable { let intent: ResetIntent; var outcome: ResetOutcome? }
    private let file: URL
    public init(root: URL) { file = root.appendingPathComponent("reset-attempts.json") }
    private func load() throws -> [String: Record] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: file))
    }
    private func save(_ records: [String: Record]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func begin(_ selection: ResetSelection) throws -> ResetIntent {
        var records = try load()
        let previous = records.values.first { $0.intent.matches(selection) }
        let reuse = previous.map { $0.intent.matches(selection) && $0.outcome != .nothingToReset && $0.outcome != .noCredit } ?? false
        let intent = reuse ? previous!.intent : ResetIntent(selection: selection)
        if let previous, !reuse { records.removeValue(forKey: previous.intent.idempotencyKey) }
        // Persist BEFORE any request; uncertain attempts reuse the key across restarts.
        records[intent.idempotencyKey] = Record(intent: intent, outcome: nil)
        try save(records)
        return intent
    }
    func finish(_ intent: ResetIntent, outcome: ResetOutcome) throws {
        var records = try load()
        guard records[intent.idempotencyKey]?.intent == intent else { throw ClientFailure.configuration("Reset journal changed.") }
        records[intent.idempotencyKey]?.outcome = outcome
        try save(records)
    }
}

public protocol ResetTransport: AnyObject {
    func readAccount() throws -> AccountResponse
    func readUsage() throws -> UsageResponse
    func consumeReset(_ intent: ResetIntent) throws -> ResetOutcome
    func close()
}

public struct ResetResult: Sendable {
    public let outcome: ResetOutcome
    public let snapshot: AccountSnapshot?
    public let warning: String?
}

public enum ResetRedemption {
    public static let method = "account/rateLimitResetCredit/consume"
    private static func verify(_ identity: AccountResponse, intent: ResetIntent) throws {
        guard identity.account?.type == "chatgpt", identity.account?.email == intent.email else {
            throw ClientFailure.authentication("The signed-in user changed. Refresh and confirm the correct account.")
        }
    }
    private static func verify(_ usage: UsageResponse, intent: ResetIntent) throws {
        guard usage.accountId == intent.accountId else {
            throw ClientFailure.authentication("The ChatGPT workspace changed or could not be verified. Refresh before applying a reset.")
        }
    }
    // Cancellation never touches the journal, creates a helper, or sends any request.
    // Tests inject an in-memory transport; the production factory uses the official CLI.
    public static func run(selection: ResetSelection, confirmed: Bool, store: ResetAttemptStore,
                           now: () -> Date = Date.init, connect: () throws -> ResetTransport) throws -> ResetResult? {
        guard confirmed else { return nil }
        let intent: ResetIntent
        let transport: ResetTransport
        do { intent = try store.begin(selection); transport = try connect() }
        catch { throw ResetFailure.notSubmitted("Could not prepare the dedicated account session or save its request key.") }
        defer { transport.close() }
        do {
            try verify(transport.readAccount(), intent: intent)
            let usage = try transport.readUsage()
            try verify(usage, intent: intent)
            try verify(transport.readAccount(), intent: intent)
            _ = try ResetSelection(account: selection.account, snapshot: AccountSnapshot(email: intent.email, usage: usage), creditId: intent.creditId, now: now())
        } catch {
            throw ResetFailure.notSubmitted(error.localizedDescription)
        }
        let outcome: ResetOutcome
        do { outcome = try transport.consumeReset(intent) }
        catch { throw ResetFailure.uncertain } // Do not retry a possibly applied mutation.
        var warnings: [String] = []
        do { try store.finish(intent, outcome: outcome) }
        catch { warnings.append("The confirmed result could not be saved locally. Check Open Usage before retrying.") }
        var snapshot: AccountSnapshot?
        do {
            let usage = try transport.readUsage()
            try verify(usage, intent: intent)
            try verify(transport.readAccount(), intent: intent)
            snapshot = AccountSnapshot(email: intent.email, usage: usage)
        } catch {
            warnings.append("Updated usage is unavailable. Refresh or check Open Usage; the reset response above is confirmed.")
        }
        return ResetResult(outcome: outcome, snapshot: snapshot, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }
}
