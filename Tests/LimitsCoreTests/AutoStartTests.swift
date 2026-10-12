import XCTest
@testable import LimitsCore

final class AutoStartTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func snapshot(used: Double = 0, weeklyUsed: Int = 20, permission: String = "true", credits: String = "{\"hasCredits\":false,\"unlimited\":false,\"balance\":\"0\"}", reset: Int = 2_000_000_000) throws -> AccountSnapshot {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data("""
        {"accountId":"workspace-a","ordinaryUsageAllowed":\(permission),"rateLimits":{"limitId":"codex","credits":\(credits),"primary":{"usedPercent":\(used),"windowDurationMins":300,"resetsAt":\(reset)},"secondary":{"usedPercent":\(weeklyUsed),"windowDurationMins":10080,"resetsAt":2000400000}}}
        """.utf8))
        return AccountSnapshot(email: "a@example.com", usage: usage, fetchedAt: now)
    }
    private func account(_ slot: String = "A") -> AccountConfiguration {
        var account = AccountConfiguration(slot: slot, name: "Test", home: "/isolated/\(slot)")
        account.autoStart = true; return account
    }
    private func withStore(_ body: (AutoStartStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AutoStartStore(root: root), root)
    }
    func testFirst100ClaimsBeforeDispatchAndSurvivesRestart() throws {
        try withStore { store, root in
            let a = account(), full = try snapshot()
            XCTAssertTrue(try store.observe(account: a, snapshot: full, now: now))
            XCTAssertFalse(try store.record(account: a, snapshot: full)!.armed)
            XCTAssertEqual(try store.record(account: a, snapshot: full)?.attemptedAt, now)
            let restarted = AutoStartStore(root: root)
            XCTAssertFalse(try restarted.observe(account: a, snapshot: full, now: now.addingTimeInterval(600)))
            XCTAssertFalse(try restarted.observe(account: a, snapshot: full, now: now.addingTimeInterval(3600)))
        }
    }
    func test99Then100RearmsEvenWhenResetArrivesEarly() throws {
        try withStore { store, _ in
            let a = account()
            XCTAssertTrue(try store.observe(account: a, snapshot: snapshot(), now: now))
            XCTAssertFalse(try store.observe(account: a, snapshot: snapshot(used: 1), now: now.addingTimeInterval(600)))
            XCTAssertTrue(try store.record(account: a, snapshot: snapshot())!.armed)
            XCTAssertTrue(try store.observe(account: a, snapshot: snapshot(reset: 2_001_000_000), now: now.addingTimeInterval(1200)))
        }
    }
    func testUnchanged100OrChangedTimestampAloneNeverRearms() throws {
        try withStore { store, _ in
            let a = account()
            XCTAssertTrue(try store.observe(account: a, snapshot: snapshot(), now: now))
            XCTAssertFalse(try store.observe(account: a, snapshot: snapshot(reset: 2_001_000_000), now: now.addingTimeInterval(600)))
        }
    }
    func testTenMinuteCadenceDoesNotObserveImmediatePostRequestDrop() throws {
        try withStore { store, _ in
            let a = account()
            XCTAssertTrue(try store.observe(account: a, snapshot: snapshot(), now: now))
            XCTAssertFalse(try store.observe(account: a, snapshot: snapshot(used: 1), now: now.addingTimeInterval(60)))
            XCTAssertFalse(try store.record(account: a, snapshot: snapshot())!.armed)
            XCTAssertFalse(try store.observe(account: a, snapshot: snapshot(), now: now.addingTimeInterval(600)))
        }
    }
    func testFailureAndToggleOffOnDoNotResend100Streak() throws {
        try withStore { store, _ in
            var a = account(); let full = try snapshot()
            XCTAssertTrue(try store.observe(account: a, snapshot: full, now: now))
            try store.finish(account: a, snapshot: full, message: "failed/unknown")
            a.autoStart = false
            XCTAssertFalse(try store.observe(account: a, snapshot: full, now: now.addingTimeInterval(600)))
            a.autoStart = true
            XCTAssertFalse(try store.observe(account: a, snapshot: full, now: now.addingTimeInterval(1200)))
        }
    }
    func testSafetyGatesSkipWeeklyExhaustionExistingOrUnknownCredits() throws {
        for usage in [try snapshot(weeklyUsed: 100), try snapshot(permission: "false"), try snapshot(permission: "null"),
                      try snapshot(credits: "null"), try snapshot(credits: "{\"hasCredits\":true,\"unlimited\":false,\"balance\":\"10\"}"),
                      try snapshot(credits: "{\"hasCredits\":false,\"unlimited\":true,\"balance\":null}"),
                      try snapshot(credits: "{\"hasCredits\":false,\"unlimited\":false,\"balance\":\"unknown\"}"),
                      try snapshot(used: 1), try snapshot(used: 0.4), try snapshot(used: -1)] {
            XCTAssertFalse(WindowInitializer.mayExecute(usage: usage.usage, enabled: true))
        }
        XCTAssertTrue(WindowInitializer.mayExecute(usage: try snapshot().usage, enabled: true))
        XCTAssertFalse(WindowInitializer.mayExecute(usage: try snapshot().usage, enabled: false))
    }
    func testAccountIsolationAndPersistedFilePermissions() throws {
        try withStore { store, root in
            let full = try snapshot()
            XCTAssertTrue(try store.observe(account: account("A"), snapshot: full, now: now))
            XCTAssertTrue(try store.observe(account: account("B"), snapshot: full, now: now))
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("auto-start.json").path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testCorruptLedgerFailsClosedAndOldSettingsDefaultOff() throws {
        try withStore { store, root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("invalid".utf8).write(to: root.appendingPathComponent("auto-start.json"))
            XCTAssertThrowsError(try store.observe(account: account(), snapshot: snapshot(), now: now))
        }
        let old = try JSONDecoder().decode(AccountConfiguration.self, from: Data("{\"slot\":\"A\",\"name\":\"Test\",\"home\":\"/isolated/A\"}".utf8))
        XCTAssertFalse(old.autoStart)
    }
    func testSuccessfulTurnRequiresCompletionAndZeroExit() throws {
        var events = ExecutionEvents()
        try events.consume(Data("{\"type\":\"turn.started\"}".utf8))
        XCTAssertFalse(events.succeeded(exitCode: 0))
        try events.consume(Data("{\"type\":\"item.completed\",\"item\":{\"id\":\"1\",\"type\":\"agent_message\",\"text\":\"ok\"}}".utf8))
        try events.consume(Data("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":1}}".utf8))
        XCTAssertTrue(events.succeeded(exitCode: 0))
        XCTAssertFalse(events.succeeded(exitCode: 1))
        try events.consume(Data("{\"type\":\"turn.failed\",\"error\":{\"message\":\"auth failed\"}}".utf8))
        XCTAssertFalse(events.succeeded(exitCode: 0))
    }
    func testUnexpectedToolActivityAndMalformedEventsAreRejected() throws {
        for kind in ["command_execution", "file_change", "mcp_tool_call", "collab_tool_call", "web_search"] {
            var events = ExecutionEvents()
            XCTAssertThrowsError(try events.consume(Data("{\"type\":\"item.started\",\"item\":{\"type\":\"\(kind)\"}}".utf8)))
        }
        var events = ExecutionEvents()
        XCTAssertThrowsError(try events.consume(Data("broken".utf8)))
    }
    func testExecutionArgumentsHaveIsolatedReadOnlyContextAndDisabledShell() {
        let args = AutoStartExecution.arguments(scratch: "/private/scratch")
        for flag in ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--strict-config"] { XCTAssertTrue(args.contains(flag)) }
        XCTAssertTrue(args.contains("read-only")); XCTAssertTrue(args.contains("approval_policy=\"never\""))
        XCTAssertTrue(args.contains("shell_tool")); XCTAssertTrue(args.contains("hooks")); XCTAssertTrue(args.contains("code_mode"))
        XCTAssertEqual(args.last, "ok")
        let profile = AutoStartExecution.sandboxProfile(binary: "/native/codex", home: "/dedicated/home", scratch: "/private/scratch")
        XCTAssertTrue(profile.contains("(deny process-exec)")); XCTAssertTrue(profile.contains("(deny file-write*)"))
        XCTAssertFalse(profile.contains("/bin/sh"))
    }
    func testKernelSandboxAllowsOnlyNativeCodexExecutableWithoutSendingPrompt() throws {
        let binary = CodexExecutable.discover()
        guard !binary.isEmpty else { throw XCTSkip("Official native Codex not installed") }
        try withStore { _, root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let profile = AutoStartExecution.sandboxProfile(binary: binary, home: root.path, scratch: root.path)
            func run(_ executable: String, args: [String]) throws -> Int32 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                process.arguments = ["-p", profile, executable] + args
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                return process.terminationStatus
            }
            // --version never authenticates, sends a prompt, or consumes usage.
            XCTAssertEqual(try run(binary, args: ["--version"]), 0)
            XCTAssertNotEqual(try run("/bin/sh", args: ["-c", "exit 0"]), 0)
        }
    }
}
