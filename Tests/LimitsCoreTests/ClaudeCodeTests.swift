import XCTest
@testable import LimitsCore

final class ClaudeCodeTests: XCTestCase {
    private func decode(_ json: String, subscription: String? = "max") throws -> ClaudeCodeSnapshot {
        let response = try JSONDecoder().decode(AnthropicUsageResponse.self, from: Data(json.utf8))
        let credentials = ClaudeCredentials(accessToken: "token", expiresAt: nil, subscriptionType: subscription, rateLimitTier: nil)
        return ClaudeCodeClient.decode(response, credentials: credentials, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testUsageResponseDecodesWindowsAsRemaining() throws {
        let snapshot = try decode("""
        {"five_hour":{"utilization":6.0,"resets_at":"2026-04-08T18:59:59Z"},
         "seven_day":{"utilization":35.0,"resets_at":"2026-04-14T16:59:59.000Z"},
         "seven_day_opus":{"utilization":12.0,"resets_at":"2026-04-14T17:59:59Z"},
         "seven_day_sonnet":null,
         "extra_usage":{"is_enabled":true,"monthly_limit":100.0,"used_credits":12.5,"utilization":12.5}}
        """)
        XCTAssertEqual(snapshot.fiveHour?.remaining, 94)
        XCTAssertEqual(snapshot.weekly?.remaining, 65)
        XCTAssertEqual(snapshot.weeklyOpus?.remaining, 88)
        XCTAssertNil(snapshot.weeklySonnet)
        XCTAssertEqual(snapshot.extraUsage?.usedCredits, 12.5)
        XCTAssertEqual(snapshot.planName, "Max")
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, ISO8601DateFormatter().date(from: "2026-04-08T18:59:59Z"))
        XCTAssertNotNil(snapshot.weekly?.resetsAt, "Fractional-second timestamps must parse.")
    }

    func testMissingAndNullBucketsStayUnavailable() throws {
        let snapshot = try decode("""
        {"five_hour":null,"seven_day":null,"seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":null}
        """)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertNil(snapshot.remaining(for: .fiveHour))
        XCTAssertNil(snapshot.remaining(for: .weekly))
    }

    func testUtilizationClampsToValidPercent() throws {
        let oversized = try decode("""
        {"five_hour":{"utilization":140.0,"resets_at":null}}
        """)
        XCTAssertEqual(oversized.fiveHour?.remaining, 0)
        let negative = try decode("""
        {"five_hour":{"utilization":-5.0,"resets_at":null}}
        """)
        XCTAssertEqual(negative.fiveHour?.remaining, 100, "Clamped to the full allowance.")
    }

    func testMetricFallbacksUseWhicheverWindowExists() throws {
        let snapshot = try decode("""
        {"five_hour":null,"seven_day":{"utilization":20.0,"resets_at":null}}
        """)
        XCTAssertEqual(snapshot.remaining(for: .fiveHour), 80)
        XCTAssertEqual(snapshot.remaining(for: .weekly), 80)
        XCTAssertEqual(snapshot.remaining(for: .both), 80)
    }

    func testPlanNameMapping() throws {
        XCTAssertEqual(try decode("{}", subscription: "max").planName, "Max")
        XCTAssertEqual(try decode("{}", subscription: "pro").planName, "Pro")
        XCTAssertEqual(try decode("{}", subscription: "team").planName, "Team")
        XCTAssertEqual(try decode("{}", subscription: "weird-plan").planName, "Weird-Plan")
        XCTAssertNil(try decode("{}", subscription: nil).planName)
    }

    func testExpiryUnitDetection() {
        XCTAssertEqual(ClaudeCodeClient.date(milliseconds: 1_800_000_000_000), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(ClaudeCodeClient.date(milliseconds: 1_800_000_000), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(ClaudeCodeClient.date(milliseconds: 0))
    }

    func testExpiredCredentialsAreReportedNotRotated() {
        let credentials = ClaudeCredentials(accessToken: "token", expiresAt: Date(timeIntervalSince1970: 100), subscriptionType: nil, rateLimitTier: nil)
        XCTAssertTrue(credentials.expired(now: Date(timeIntervalSince1970: 200)))
        XCTAssertFalse(credentials.expired(now: Date(timeIntervalSince1970: 50)))
        XCTAssertFalse(ClaudeCredentials(accessToken: "token", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil).expired())
    }

    func testEnvironmentTokenTakesPrecedenceWithoutTouchingDisk() throws {
        let configuration = ClaudeCodeConfiguration(enabled: true, useKeychain: false, credentialsFile: "/nonexistent/credentials.json")
        let credentials = try ClaudeCodeClient.resolveCredentials(
            configuration: configuration,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "  sk-ant-oat01-test  "]
        )
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-test")
        XCTAssertNil(credentials.expiresAt)
    }

    func testMissingCredentialReportsNotConnected() {
        let configuration = ClaudeCodeConfiguration(enabled: true, useKeychain: false, credentialsFile: "/nonexistent/credentials.json")
        XCTAssertThrowsError(try ClaudeCodeClient.resolveCredentials(configuration: configuration, environment: [:])) { error in
            XCTAssertEqual(error as? ClaudeCodeFailure, .notConnected)
        }
    }

    func testCredentialsFileWithoutOAuthBlockReportsNotConnected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCreds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.json")
        try Data(#"{"claudeAiOauth":null}"#.utf8).write(to: file)
        let configuration = ClaudeCodeConfiguration(enabled: true, useKeychain: false, credentialsFile: file.path)
        XCTAssertThrowsError(try ClaudeCodeClient.resolveCredentials(configuration: configuration, environment: [:])) { error in
            XCTAssertEqual(error as? ClaudeCodeFailure, .notConnected)
        }
    }

    func testEmptySavedTokenIsReportedAsNotConnected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCreds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"  ","expiresAt":0,"subscriptionType":"team"}}"#.utf8).write(to: file)
        let configuration = ClaudeCodeConfiguration(enabled: true, useKeychain: false, credentialsFile: file.path)
        XCTAssertThrowsError(try ClaudeCodeClient.resolveCredentials(configuration: configuration, environment: [:])) { error in
            XCTAssertEqual(error as? ClaudeCodeFailure, .notConnected)
        }
    }

    func testCredentialsFileTokenAndMillisExpiryAreRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCreds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.json")
        try Data("""
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-file","refreshToken":"sk-ant-ort01-secret","expiresAt":1800000000000,
         "subscriptionType":"pro","rateLimitTier":"default","scopes":["user:inference"]}}
        """.utf8).write(to: file)
        let configuration = ClaudeCodeConfiguration(enabled: true, useKeychain: false, credentialsFile: file.path)
        let credentials = try ClaudeCodeClient.resolveCredentials(configuration: configuration, environment: [:])
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-file")
        XCTAssertEqual(credentials.subscriptionType, "pro")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).contains("refreshToken"), true, "The file must never be rewritten.")
    }

    func testConfigurationValidationRequiresSomeSource() {
        var configuration = ClaudeCodeConfiguration(enabled: true, useKeychain: false, credentialsFile: "")
        XCTAssertThrowsError(try configuration.validate())
        configuration.credentialsFile = "relative/path.json"
        XCTAssertThrowsError(try configuration.validate())
        configuration.credentialsFile = "~/.claude/.credentials.json"
        XCTAssertNoThrow(try configuration.validate())
        configuration.useKeychain = true
        configuration.credentialsFile = ""
        XCTAssertNoThrow(try configuration.validate())
    }

    func testTransientClassification() {
        XCTAssertTrue(ClaudeCodeFailure.network.isTransient)
        XCTAssertTrue(ClaudeCodeFailure.timeout.isTransient)
        XCTAssertTrue(ClaudeCodeFailure.server(429).isTransient)
        XCTAssertTrue(ClaudeCodeFailure.server(503).isTransient)
        XCTAssertFalse(ClaudeCodeFailure.server(400).isTransient)
        XCTAssertFalse(ClaudeCodeFailure.notConnected.isTransient)
        XCTAssertTrue(ClaudeCodeFailure.notConnected.isAuthentication)
        XCTAssertTrue(ClaudeCodeFailure.authentication("x").isAuthentication)
    }
}
