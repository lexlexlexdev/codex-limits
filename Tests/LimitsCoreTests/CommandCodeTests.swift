import XCTest
@testable import LimitsCore

final class CommandCodeTests: XCTestCase {
    private func responses(
        whoami: String = """
        {"user":{"userName":"alex","email":"alex@example.com"},"org":{"id":"org_1","login":"alexco"},"orgLimits":[]}
        """,
        credits: String,
        subscription: String? = nil,
        summary: String? = nil
    ) throws -> (WhoamiResponse, CreditsResponse, SubscriptionResponse?, UsageSummaryResponse?) {
        let decoder = JSONDecoder()
        return (
            try decoder.decode(WhoamiResponse.self, from: Data(whoami.utf8)),
            try decoder.decode(CreditsResponse.self, from: Data(credits.utf8)),
            try subscription.map { try decoder.decode(SubscriptionResponse.self, from: Data($0.utf8)) },
            try summary.map { try decoder.decode(UsageSummaryResponse.self, from: Data($0.utf8)) }
        )
    }

    func testSubscriptionSnapshotDerivesWindowsAndMonthlyRemaining() throws {
        let (whoami, credits, subscription, summary) = try responses(
            credits: """
            {"credits":{"monthlyCredits":42.5,"purchasedCredits":3,"freeCredits":1,"planId":"individual-goat"},
             "windowLimits":{"limited":true,
               "fiveHour":{"used":4,"cap":14,"resetAt":1800000000000},
               "weekly":{"used":20,"cap":35,"resetAt":1800400000000}}}
            """,
            subscription: """
            {"data":{"planId":"individual-goat","status":"active","currentPeriodStart":"2026-10-01T00:00:00.000Z","currentPeriodEnd":"2026-11-01T00:00:00.000Z"}}
            """,
            summary: """
            {"totalCost":12.5,"totalCount":123}
            """
        )
        let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
        let snapshot = CommandCodeClient.decode(whoami: whoami, credits: credits, subscription: subscription, summary: summary, now: now)
        XCTAssertEqual(snapshot.userName, "alex")
        XCTAssertEqual(snapshot.orgLogin, "alexco")
        XCTAssertEqual(snapshot.planName, "GOAT")
        XCTAssertEqual(snapshot.planMonthlyCredits, 70)
        XCTAssertEqual(snapshot.subscriptionStatus, "active")
        XCTAssertEqual(snapshot.windowLimits?.fiveHour?.remaining, 71)
        XCTAssertEqual(snapshot.windowLimits?.weekly?.remaining, 43)
        XCTAssertEqual(snapshot.monthlyRemainingPercent, 63)
        XCTAssertEqual(snapshot.menuBarRemaining, 71)
        XCTAssertEqual(snapshot.credits?.extraRemaining, 4)
        XCTAssertEqual(snapshot.totalCost, 12.5)
        XCTAssertEqual(snapshot.totalCount, 123)
        XCTAssertEqual(snapshot.daysUntilRenewal(now: now), 12)
        XCTAssertEqual(snapshot.windowLimits?.fiveHour?.resetAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testMissingWindowsDoNotFabricateCapsAndUseMonthlyFallback() throws {
        let (whoami, credits, subscription, summary) = try responses(
            credits: """
            {"credits":{"monthlyCredits":5,"purchasedCredits":2,"freeCredits":0,"planId":"individual-provider"},
             "windowLimits":{"limited":false}}
            """,
            subscription: """
            {"data":{"planId":"individual-provider","status":"active","currentPeriodEnd":"2026-11-01T00:00:00Z"}}
            """,
            summary: """
            {"totalCost":5,"totalCount":4}
            """
        )
        let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
        let snapshot = CommandCodeClient.decode(whoami: whoami, credits: credits, subscription: subscription, summary: summary, now: now)
        XCTAssertEqual(snapshot.windowLimits?.limited, false)
        XCTAssertNil(snapshot.windowLimits?.fiveHour)
        XCTAssertNil(snapshot.windowLimits?.weekly)
        XCTAssertEqual(snapshot.planName, "Provider")
        XCTAssertEqual(snapshot.menuBarRemaining, 41)
        XCTAssertEqual(snapshot.currentPeriodEnd, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    }

    func testIncompleteCreditsStayUnavailable() throws {
        let (whoami, credits, subscription, summary) = try responses(
            credits: """
            {"credits":{"planId":"individual-ultra"},
             "windowLimits":{"limited":true,"fiveHour":{"used":3},"weekly":{}}}
            """
        )
        let snapshot = CommandCodeClient.decode(whoami: whoami, credits: credits, subscription: subscription, summary: summary, now: Date())
        XCTAssertEqual(snapshot.planName, "Ultra")
        XCTAssertNil(snapshot.monthlyRemainingPercent)
        XCTAssertNil(snapshot.credits?.monthlyRemaining)
        XCTAssertNil(snapshot.windowLimits?.fiveHour?.remaining)
        XCTAssertNil(snapshot.windowLimits?.fiveHour?.resetAt)
        XCTAssertNil(snapshot.windowLimits?.weekly?.remaining)
        XCTAssertNil(snapshot.menuBarRemaining)
        XCTAssertNil(snapshot.daysUntilRenewal())
    }

    func testNoPlanPoolAndNoSummaryLeavesMonthlyUnknown() throws {
        let (whoami, credits, subscription, summary) = try responses(
            credits: """
            {"credits":{"monthlyCredits":8,"purchasedCredits":0,"freeCredits":0,"planId":"custom-plan"}}
            """
        )
        let snapshot = CommandCodeClient.decode(whoami: whoami, credits: credits, subscription: subscription, summary: summary, now: Date())
        XCTAssertEqual(snapshot.planName, "custom-plan")
        XCTAssertNil(snapshot.monthlyRemainingPercent)
        XCTAssertEqual(snapshot.credits?.totalRemaining, 8)
    }

    func testFailureClassification() {
        XCTAssertTrue(CommandCodeFailure.network.isTransient)
        XCTAssertTrue(CommandCodeFailure.server(429).isTransient)
        XCTAssertTrue(CommandCodeFailure.server(503).isTransient)
        XCTAssertFalse(CommandCodeFailure.server(400).isTransient)
        XCTAssertFalse(CommandCodeFailure.authentication.isTransient)
        XCTAssertTrue(CommandCodeFailure.notConnected.isAuthentication)
        XCTAssertEqual(CommandCodeFailure.notConnected.localizedDescription, "Command Code is not signed in. Run `cmd login`, then refresh.")
    }

    func testSettingsMigratesWithoutCommandCodeAndValidatesPath() throws {
        let old = Data("""
        {"accounts":[{"slot":"A","name":"Personal","home":"/dedicated/one"}],"codexPath":"/usr/bin/true","refreshMinutes":5}
        """.utf8)
        var settings = try JSONDecoder().decode(Settings.self, from: old)
        XCTAssertEqual(settings.commandCode.authFile, CommandCodeConfiguration.defaultAuthFile)
        settings.commandCode = CommandCodeConfiguration(enabled: true, authFile: "~/.commandcode/auth.json")
        XCTAssertEqual(settings.commandCode.expandedAuthFile, NSHomeDirectory() + "/.commandcode/auth.json")
        XCTAssertNoThrow(try settings.commandCode.validate())
        settings.commandCode.authFile = "relative/auth.json"
        XCTAssertThrowsError(try settings.commandCode.validate())
        settings.commandCode.authFile = "   "
        XCTAssertThrowsError(try settings.commandCode.validate())
    }

    func testCommandCodeConfigurationRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(root: root)
        var settings = Settings(root: root, codexPath: "/usr/bin/true")
        settings.commandCode = CommandCodeConfiguration(enabled: true, authFile: "/tmp/auth.json")
        try store.save(settings)
        XCTAssertEqual(try store.load(defaultCodex: "").commandCode, settings.commandCode)
    }

    func testCommandCodeOnlySettingsDoNotRequireCodexExecutable() throws {
        var settings = Settings(root: URL(fileURLWithPath: "/isolated"), codexPath: "")
        settings.accounts.removeAll()
        settings.commandCode = CommandCodeConfiguration(enabled: true, authFile: "~/.commandcode/auth.json")
        XCTAssertNoThrow(try settings.validate())
    }

    func testV1PlanNamesAndCredits() throws {
        let (whoami, credits, subscription, summary) = try responses(
            credits: """
            {"credits":{"monthlyCredits":20,"purchasedCredits":0,"freeCredits":0,"planId":"individual-pro-v1"}}
            """
        )
        let snapshot = CommandCodeClient.decode(whoami: whoami, credits: credits, subscription: subscription, summary: summary, now: Date())
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.planMonthlyCredits, 80)
    }
}
