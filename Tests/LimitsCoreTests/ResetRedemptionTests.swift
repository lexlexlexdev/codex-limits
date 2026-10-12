import XCTest
@testable import LimitsCore

final class ResetRedemptionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func usage(accountId: String? = "workspace-a", credits: String = "[{\"id\":\"reset-a\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":1800000000,\"expiresAt\":2100000000}]", count: Int = 1, used: Int = 60) throws -> UsageResponse {
        let identity = accountId.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(UsageResponse.self, from: Data("""
        {"accountId":\(identity),"rateLimits":{"limitId":"codex","primary":{"usedPercent":\(used),"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000400000}},"rateLimitResetCredits":{"availableCount":\(count),"credits":\(credits)}}
        """.utf8))
    }
    private func identity(email: String = "a@example.com", type: String = "chatgpt") throws -> AccountResponse {
        try JSONDecoder().decode(AccountResponse.self, from: Data("""
        {"account":{"type":"\(type)","email":"\(email)","planType":"plus"},"requiresOpenaiAuth":true}
        """.utf8))
    }
    private func selection(slot: String = "A", accountId: String? = "workspace-a", credits: String? = nil) throws -> ResetSelection {
        let snapshot = try credits.map { try usage(accountId: accountId, credits: $0) } ?? usage(accountId: accountId)
        return try ResetSelection(account: AccountConfiguration(slot: slot, name: "Test", home: "/isolated/\(slot)"), snapshot: AccountSnapshot(email: "a@example.com", usage: snapshot), creditId: "reset-a", now: now)
    }
    private func withStore(_ body: (ResetAttemptStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ResetAttemptStore(root: root), root)
    }
    private final class MockTransport: ResetTransport {
        var identities: [AccountResponse]
        var usages: [UsageResponse]
        var outcome = ResetOutcome.reset
        var consumeError: ClientFailure?
        var usageErrorAfterConsume: ClientFailure?
        var calls: [String] = []
        var intents: [ResetIntent] = []
        var closed = false
        init(identity: AccountResponse, usage: UsageResponse) {
            identities = [identity]; usages = [usage]
        }
        func readAccount() throws -> AccountResponse {
            calls.append("account/read")
            return identities.count > 1 ? identities.removeFirst() : identities[0]
        }
        func readUsage() throws -> UsageResponse {
            calls.append("account/rateLimits/read")
            if !intents.isEmpty, let error = usageErrorAfterConsume { throw error }
            return usages.count > 1 ? usages.removeFirst() : usages[0]
        }
        func consumeReset(_ intent: ResetIntent) throws -> ResetOutcome {
            calls.append(ResetRedemption.method); intents.append(intent)
            if let consumeError { throw consumeError }
            return outcome
        }
        func close() { closed = true }
    }
    func testCancelMakesNoConnectionAndWritesNoJournal() throws {
        try withStore { store, root in
            let selected = try selection()
            let result = try ResetRedemption.run(selection: selected, confirmed: false, store: store) {
                XCTFail("Cancellation must never open a server")
                throw ClientFailure.network
            }
            XCTAssertNil(result)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("reset-attempts.json").path))
        }
    }
    func testConfirmedExactCreditUsesOfficialMethodOnceAndRefreshes() throws {
        try withStore { store, root in
            let mock = try MockTransport(identity: identity(), usage: usage())
            mock.usages.append(try usage(credits: "[]", count: 0, used: 0))
            let result = try ResetRedemption.run(selection: selection(), confirmed: true, store: store, now: { self.now }) { mock }
            XCTAssertEqual(result?.outcome, .reset)
            XCTAssertEqual(result?.snapshot?.usage.codex?.fiveHour?.remaining, 100)
            XCTAssertEqual(result?.snapshot?.usage.rateLimitResetCredits?.availableCount, 0)
            XCTAssertEqual(mock.calls, ["account/read", "account/rateLimits/read", "account/read", "account/rateLimitResetCredit/consume", "account/rateLimits/read", "account/read"])
            XCTAssertEqual(mock.intents.count, 1)
            XCTAssertEqual(mock.intents[0].parameters["creditId"], "reset-a")
            XCTAssertEqual(mock.intents[0].parameters.count, 2)
            XCTAssertNotNil(UUID(uuidString: mock.intents[0].parameters["idempotencyKey"]!))
            XCTAssertTrue(mock.closed)
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("reset-attempts.json").path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testChangedUserPreventsConsume() throws {
        try withStore { store, _ in
            let mock = try MockTransport(identity: identity(email: "b@example.com"), usage: usage())
            XCTAssertThrowsError(try ResetRedemption.run(selection: selection(), confirmed: true, store: store) { mock })
            XCTAssertTrue(mock.intents.isEmpty); XCTAssertTrue(mock.closed)
        }
    }
    func testUserChangingDuringPreflightPreventsConsume() throws {
        try withStore { store, _ in
            let mock = try MockTransport(identity: identity(), usage: usage())
            mock.identities.append(try identity(email: "b@example.com"))
            XCTAssertThrowsError(try ResetRedemption.run(selection: selection(), confirmed: true, store: store) { mock })
            XCTAssertTrue(mock.intents.isEmpty)
        }
    }
    func testChangedWorkspacePreventsConsume() throws {
        try withStore { store, _ in
            let mock = try MockTransport(identity: identity(), usage: usage(accountId: "workspace-b"))
            XCTAssertThrowsError(try ResetRedemption.run(selection: selection(), confirmed: true, store: store) { mock })
            XCTAssertTrue(mock.intents.isEmpty)
        }
    }
    func testRemovedResetAndCountOnlyDetailsPreventConsume() throws {
        for credits in ["[]", "null"] {
            try withStore { store, _ in
                let mock = try MockTransport(identity: identity(), usage: usage(credits: credits))
                XCTAssertThrowsError(try ResetRedemption.run(selection: selection(), confirmed: true, store: store) { mock })
                XCTAssertTrue(mock.intents.isEmpty)
            }
        }
    }
    func testExpiredUnknownAndIncompleteResetsCannotBeSelected() throws {
        for fields in ["\"resetType\":\"unknown\",\"status\":\"available\",\"expiresAt\":2100000000",
                       "\"resetType\":\"codexRateLimits\",\"status\":\"redeeming\",\"expiresAt\":2100000000",
                       "\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"expiresAt\":1900000000",
                       "\"resetType\":\"codexRateLimits\",\"status\":\"available\""] {
            XCTAssertThrowsError(try selection(credits: "[{\"id\":\"reset-a\",\"grantedAt\":1800000000,\(fields)}]"))
        }
        XCTAssertThrowsError(try selection(accountId: nil))
    }
    func testExpirationDuringConfirmationIsRechecked() throws {
        try withStore { store, _ in
            let mock = try MockTransport(identity: identity(), usage: usage())
            XCTAssertThrowsError(try ResetRedemption.run(selection: selection(), confirmed: true, store: store, now: { Date(timeIntervalSince1970: 2_100_000_000) }) { mock })
            XCTAssertTrue(mock.intents.isEmpty)
        }
    }
    func testUnknownResultIsNotRetriedAndKeySurvivesRestart() throws {
        try withStore { store, root in
            let selected = try selection()
            let first = try MockTransport(identity: identity(), usage: usage())
            first.consumeError = .timeout
            XCTAssertThrowsError(try ResetRedemption.run(selection: selected, confirmed: true, store: store) { first }) { error in
                guard case ResetFailure.uncertain = error else { return XCTFail("Expected uncertain outcome") }
            }
            XCTAssertEqual(first.intents.count, 1)
            XCTAssertTrue(first.closed)
            let second = try MockTransport(identity: identity(), usage: usage())
            second.outcome = .alreadyRedeemed
            let result = try ResetRedemption.run(selection: selected, confirmed: true, store: ResetAttemptStore(root: root)) { second }
            XCTAssertEqual(result?.outcome, .alreadyRedeemed)
            XCTAssertEqual(first.intents[0].idempotencyKey, second.intents[0].idempotencyKey)
        }
    }
    func testNothingToResetAndNoCreditAllowNewExplicitAttempt() throws {
        for outcome in [ResetOutcome.nothingToReset, .noCredit] {
            try withStore { store, _ in
                let mock = try MockTransport(identity: identity(), usage: usage())
                mock.outcome = outcome
                let selected = try selection()
                XCTAssertEqual(try ResetRedemption.run(selection: selected, confirmed: true, store: store) { mock }?.outcome, outcome)
                _ = try ResetRedemption.run(selection: selected, confirmed: true, store: store) { mock }
                XCTAssertNotEqual(mock.intents[0].idempotencyKey, mock.intents[1].idempotencyKey)
            }
        }
    }
    func testConfirmedSuccessNotReportedAsFailureWhenRefreshFails() throws {
        try withStore { store, _ in
            let mock = try MockTransport(identity: identity(), usage: usage())
            mock.usageErrorAfterConsume = .network
            let result = try ResetRedemption.run(selection: selection(), confirmed: true, store: store) { mock }
            XCTAssertEqual(result?.outcome, .reset)
            XCTAssertNil(result?.snapshot)
            XCTAssertNotNil(result?.warning)
            XCTAssertEqual(mock.intents.count, 1)
        }
    }
    func testJournalKeepsAccountKeysSeparate() throws {
        try withStore { store, _ in
            let a = try store.begin(selection(slot: "A"))
            let b = try store.begin(selection(slot: "B", accountId: "workspace-b"))
            XCTAssertNotEqual(a.idempotencyKey, b.idempotencyKey)
            XCTAssertNotEqual(a.home, b.home)
            XCTAssertEqual(try store.begin(selection(slot: "A")).idempotencyKey, a.idempotencyKey)
            let otherGrant = try ResetSelection(account: AccountConfiguration(slot: "A", name: "Test", home: "/isolated/A"), snapshot: AccountSnapshot(email: "a@example.com", usage: usage(credits: "[{\"id\":\"reset-other\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":1800000000,\"expiresAt\":2100000000}]")), creditId: "reset-other", now: now)
            XCTAssertNotEqual(try store.begin(otherGrant).idempotencyKey, a.idempotencyKey)
            // Selecting another grant must not discard an earlier uncertain request key.
            XCTAssertEqual(try store.begin(selection(slot: "A")).idempotencyKey, a.idempotencyKey)
        }
    }
    func testCorruptJournalBlocksMutationBeforeConnecting() throws {
        try withStore { store, root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("broken".utf8).write(to: root.appendingPathComponent("reset-attempts.json"))
            XCTAssertThrowsError(try ResetRedemption.run(selection: selection(), confirmed: true, store: store) {
                XCTFail("Cannot connect when the journal is unreadable")
                throw ClientFailure.network
            })
        }
    }
    func testOfficialOutcomeParsingRejectsUnknownSuccess() throws {
        for value in ["reset", "nothingToReset", "noCredit", "alreadyRedeemed"] {
            XCTAssertNoThrow(try JSONDecoder().decode(ResetOutcome.self, from: Data("\"\(value)\"".utf8)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ResetOutcome.self, from: Data("\"newOutcome\"".utf8)))
    }
}
