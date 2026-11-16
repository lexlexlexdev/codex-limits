import XCTest
@testable import LimitsCore

final class LimitsCoreTests: XCTestCase {
    // Contract fixtures use official camelCase fields. These are never linked into the app.
    private func usage(_ extra: String = "", primary: String = "{\"usedPercent\":26,\"windowDurationMins\":300,\"resetsAt\":1800000000}") throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data("""
        {"rateLimits":{"limitId":"codex","primary":\(primary),"secondary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1800400000}},"ordinaryUsageAllowed":true\(extra)}
        """.utf8))
    }
    func testOfficialSnapshotAndConversion() throws {
        let response = try usage()
        XCTAssertEqual(response.codex?.fiveHour?.remaining, 74)
        XCTAssertEqual(response.codex?.weekly?.remaining, 52)
        XCTAssertEqual(response.codex?.fiveHour?.resetDate, Date(timeIntervalSince1970: 1_800_000_000))
    }
    func testPercentClampingAndRounding() throws {
        XCTAssertEqual(try usage(primary: "{\"usedPercent\":-2}").rateLimits.primary?.remaining, 100)
        XCTAssertEqual(try usage(primary: "{\"usedPercent\":110}").rateLimits.primary?.remaining, 0)
        XCTAssertEqual(try usage(primary: "{\"usedPercent\":0.4}").rateLimits.primary?.remaining, 100)
    }
    func testBucketSelectionDoesNotSubstitutePremium() throws {
        let snapshot = try usage(",\"rateLimitsByLimitId\":{\"premium\":{\"limitId\":\"premium\",\"primary\":null,\"secondary\":null}}")
        XCTAssertNil(snapshot.codex)
        let selected = try usage(",\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":60,\"windowDurationMins\":300}}}")
        XCTAssertEqual(selected.codex?.fiveHour?.remaining, 40)
    }
    func testDurationRatherThanBucketOrder() throws {
        let response = try usage(primary: "{\"usedPercent\":2,\"windowDurationMins\":10080}")
        XCTAssertNil(response.codex?.fiveHour)
        XCTAssertEqual(response.codex?.weekly?.remaining, 98)
    }
    func testIncompleteDataDoesNotInventResets() throws {
        let response = try usage(primary: "{\"usedPercent\":0,\"windowDurationMins\":null,\"resetsAt\":null}")
        XCTAssertNil(response.codex?.fiveHour)
        XCTAssertNil(response.rateLimits.primary?.resetDate)
        XCTAssertNil(response.rateLimitResetCredits)
        let countOnly = try usage(",\"rateLimitResetCredits\":{\"availableCount\":3,\"credits\":null}")
        XCTAssertEqual(countOnly.rateLimitResetCredits?.availableCount, 3)
        XCTAssertNil(countOnly.rateLimitResetCredits?.sortedAvailable)
        let missingExpiration = try usage(",\"rateLimitResetCredits\":{\"availableCount\":1,\"credits\":[{\"id\":\"x\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":1}]}")
        XCTAssertEqual(missingExpiration.rateLimitResetCredits?.availableCount, 1)
        XCTAssertNil(missingExpiration.rateLimitResetCredits?.credits)
    }
    private func credit(id: String, expires: Int64?, status: String = "available", type: String = "codexRateLimits") -> BankedReset {
        BankedReset(id: id, resetType: type, status: status, grantedAt: 1, expiresAt: expires, title: nil, description: nil)
    }
    func testBankedResetSortingAndUnknownTypes() {
        let summary = ResetSummary(availableCount: 4, credits: [credit(id: "b", expires: 200), credit(id: "none", expires: nil), credit(id: "a", expires: 100), credit(id: "spent", expires: 50, status: "redeemed"), credit(id: "future", expires: 20, type: "unknown")])
        XCTAssertEqual(summary.sortedAvailable?.map(\.id), ["a", "b", "none"])
    }
    func testExpirationWarningThresholds() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(credit(id: "a", expires: 1000).warning(now: now), .expired)
        XCTAssertEqual(credit(id: "a", expires: 87_399).warning(now: now), .urgent)
        XCTAssertEqual(credit(id: "a", expires: 87_400).warning(now: now), .soon)
        XCTAssertEqual(credit(id: "a", expires: 260_200).warning(now: now), .soon)
        XCTAssertEqual(credit(id: "a", expires: 260_201).warning(now: now), .normal)
        XCTAssertEqual(credit(id: "a", expires: nil).warning(now: now), .normal)
    }
    func testCountdownAndTimezone() throws {
        let window = try usage().codex!.fiveHour!
        XCTAssertEqual(window.secondsUntilReset(now: Date(timeIntervalSince1970: 1_799_999_940)), 60)
        XCTAssertEqual(window.secondsUntilReset(now: Date(timeIntervalSince1970: 1_800_000_001)), 0)
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(DisplayTime.absolute(date, timeZone: TimeZone(secondsFromGMT: 0)!).hasSuffix("00:00"))
        XCTAssertTrue(DisplayTime.absolute(date, timeZone: TimeZone(secondsFromGMT: 32_400)!).hasSuffix("09:00"))
        XCTAssertEqual(DisplayTime.relative(until: date.addingTimeInterval(8040), now: date), "2h 14m")
        XCTAssertEqual(DisplayTime.relative(until: date, now: date), "expired")
    }
    func testDistinctUsersAndDuplicateWorkspaces() throws {
        let first = AccountSnapshot(email: "ONE@example.com", usage: try usage())
        let second = AccountSnapshot(email: "two@example.com", usage: try usage())
        XCTAssertNoThrow(try AccountIsolation.verify(first, second))
        XCTAssertThrowsError(try AccountIsolation.verify(first, AccountSnapshot(email: "one@example.com", usage: try usage())))
        let identified = try usage(",\"accountId\":\"workspace-1\"")
        XCTAssertThrowsError(try AccountIsolation.verify(AccountSnapshot(email: "one@example.com", usage: identified), AccountSnapshot(email: "two@example.com", usage: identified)))
    }
    func testTwoHomeIsolationAndLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try HomeLease(home: root.appendingPathComponent("a").path)
        let b = try HomeLease(home: root.appendingPathComponent("b").path)
        try withExtendedLifetime((a, b)) {
            XCTAssertThrowsError(try HomeLease(home: root.appendingPathComponent("a").path))
        }
    }
    func testSettingsPersistenceAndSymlinkIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(root: root)
        var settings = Settings(root: root, codexPath: "/usr/bin/true")
        settings.refreshMinutes = 7
        try store.save(settings)
        XCTAssertEqual(try store.load(defaultCodex: "").refreshMinutes, 7)
        XCTAssertEqual(try store.load(defaultCodex: "").accounts, settings.accounts)
        try FileManager.default.createDirectory(atPath: settings.accounts[0].home, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: settings.accounts[0].home)
        settings.accounts[1].home = link.path
        XCTAssertThrowsError(try settings.validate())
        settings.accounts[1].home = NSHomeDirectory() + "/.codex"
        XCTAssertThrowsError(try settings.validate())
        XCTAssertThrowsError(try CodexClient().read(account: settings.accounts[1], executable: "/usr/bin/true"))
    }
    func testAuthenticationAndNetworkFailures() {
        XCTAssertEqual(ClientFailure.fromRPC(code: -32600, message: "chatgpt authentication required"), .authentication("ChatGPT authentication failed. Sign in again in this account’s dedicated home."))
        XCTAssertEqual(ClientFailure.fromRPC(code: -32603, message: "failed to fetch codex rate limits: connection refused"), .network)
        XCTAssertFalse(ClientFailure.authentication("failure").isTransient)
    }
    func testBoundedExponentialRetriesAndAuthenticationStop() {
        var retry = RetryState()
        let now = Date(timeIntervalSince1970: 1000)
        for delay in [30.0, 60, 120, 300] {
            retry.failed(.network, now: now, interval: 300)
            XCTAssertEqual(retry.nextAttempt, now.addingTimeInterval(delay))
            XCTAssertFalse(retry.due(now: now))
        }
        retry.succeeded()
        XCTAssertEqual(retry.failures, 0)
        retry.failed(.authentication("expired"), now: now, interval: 300)
        XCTAssertEqual(retry.nextAttempt, .distantFuture)
    }
    func testMalformedSnapshotFailsInsteadOfShowingZero() {
        XCTAssertThrowsError(try JSONDecoder().decode(UsageResponse.self, from: Data("{\"rateLimits\":{\"primary\":{}}}".utf8)))
    }
    func testMockAccountsRemainSeparate() throws {
        struct MockReader: AccountReading {
            let fixtures: [String: AccountSnapshot]
            func read(account: AccountConfiguration, executable: String) throws -> AccountSnapshot {
                guard let fixture = fixtures[account.canonicalHome] else { throw ClientFailure.authentication("Not signed in") }
                return fixture
            }
        }
        let a = AccountConfiguration(slot: "A", name: "A", home: "/isolated/a")
        let b = AccountConfiguration(slot: "B", name: "B", home: "/isolated/b")
        let reader = MockReader(fixtures: [a.canonicalHome: AccountSnapshot(email: "a@example.com", usage: try usage()), b.canonicalHome: AccountSnapshot(email: "b@example.com", usage: try usage(primary: "{\"usedPercent\":70,\"windowDurationMins\":300}"))])
        XCTAssertEqual(try reader.read(account: a, executable: "").usage.codex?.fiveHour?.remaining, 74)
        XCTAssertEqual(try reader.read(account: b, executable: "").usage.codex?.fiveHour?.remaining, 30)
    }
}
