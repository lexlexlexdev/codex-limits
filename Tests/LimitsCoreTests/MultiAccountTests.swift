import XCTest
@testable import LimitsCore

final class MultiAccountTests: XCTestCase {
    func testAddAccountsBeyondZAndPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = Settings(root: root, codexPath: "/usr/bin/true")
        for _ in 0..<30 { settings.addAccount(root: root) }
        XCTAssertEqual(settings.accounts.count, 32)
        XCTAssertEqual(settings.accounts[2].slot, "C")
        XCTAssertEqual(settings.accounts[26].slot, "AA")
        XCTAssertEqual(Set(settings.accounts.map(\.canonicalHome)).count, 32)
        try settings.validate()
        let store = SettingsStore(root: root)
        try store.save(settings)
        XCTAssertEqual(try store.load(defaultCodex: "").accounts, settings.accounts)
    }
    func testZeroOrOneAccountIsValid() throws {
        var settings = Settings(root: URL(fileURLWithPath: "/isolated"), codexPath: "/usr/bin/true")
        settings.accounts.removeLast()
        XCTAssertNoThrow(try settings.validate())
        settings.accounts.removeAll()
        XCTAssertNoThrow(try settings.validate())
    }
    func testRemovalDoesNotDeleteCredentialsAndReusedLabelGetsFreshHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = Settings(root: root, codexPath: "/usr/bin/true")
        let removed = settings.accounts.removeFirst()
        try FileManager.default.createDirectory(atPath: removed.home, withIntermediateDirectories: true)
        let marker = URL(fileURLWithPath: removed.home).appendingPathComponent("test-marker")
        try Data("not credentials".utf8).write(to: marker)
        try SettingsStore(root: root).save(settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        settings.addAccount(root: root)
        XCTAssertEqual(settings.accounts.last?.slot, "A")
        XCTAssertNotEqual(settings.accounts.last?.home, removed.home)
    }
    func testDuplicateSlotsAndNonAdjacentHomesAreRejected() throws {
        var settings = Settings(root: URL(fileURLWithPath: "/isolated"), codexPath: "/usr/bin/true")
        settings.addAccount(root: URL(fileURLWithPath: "/isolated"))
        settings.accounts[2].home = settings.accounts[0].home
        XCTAssertThrowsError(try settings.validate())
        settings.accounts[2].home = "/isolated/c"
        settings.accounts[2].slot = "A"
        XCTAssertThrowsError(try settings.validateAccountSlots())
    }
    func testOldTwoAccountSettingsMigrateWithoutCredentialChanges() throws {
        let old = Data("""
        {"accounts":[{"slot":"A","name":"Personal","home":"/dedicated/one"},{"slot":"B","name":"Secondary","home":"/dedicated/two","autoStart":true}],"codexPath":"/usr/bin/true","refreshMinutes":5}
        """.utf8)
        var migrated = try JSONDecoder().decode(Settings.self, from: old)
        let existing = migrated.accounts
        migrated.addAccount(root: URL(fileURLWithPath: "/isolated"))
        XCTAssertEqual(Array(migrated.accounts.prefix(2)), existing)
        XCTAssertNoThrow(try migrated.validate())
        let encoded = try JSONEncoder().encode(migrated)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("autoStart"))
    }
    func testUserAndWorkspaceDuplicatesAreCheckedAcrossEverySlot() throws {
        func snapshot(_ email: String, _ id: String) throws -> AccountSnapshot {
            let response = try JSONDecoder().decode(UsageResponse.self, from: Data("{\"rateLimits\":{},\"accountId\":\"\(id)\"}".utf8))
            return AccountSnapshot(email: email, usage: response)
        }
        let snapshots = [(slot: "A", snapshot: try snapshot("a@example.com", "one")),
                         (slot: "B", snapshot: try snapshot("b@example.com", "two")),
                         (slot: "C", snapshot: try snapshot("A@example.com", "three")),
                         (slot: "D", snapshot: try snapshot("d@example.com", "two")),
                         (slot: "E", snapshot: try snapshot("e@example.com", "five"))]
        let rejected = AccountIsolation.duplicateSlots(snapshots)
        XCTAssertEqual(Set(rejected.keys), ["C", "D"])
        XCTAssertTrue(rejected["C"]!.contains("A"))
        XCTAssertTrue(rejected["D"]!.contains("B"))
    }
}
