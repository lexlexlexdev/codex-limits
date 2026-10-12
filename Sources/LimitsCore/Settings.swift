import Foundation
import Darwin

public struct AccountConfiguration: Codable, Equatable, Sendable {
    public var slot: String
    public var name: String
    public var home: String
    public var autoStart: Bool
    public init(slot: String, name: String, home: String) {
        self.slot = slot; self.name = name; self.home = home
        autoStart = false
    }
    enum CodingKeys: String, CodingKey { case slot, name, home, autoStart }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        slot = try values.decode(String.self, forKey: .slot)
        name = try values.decode(String.self, forKey: .name)
        home = try values.decode(String.self, forKey: .home)
        autoStart = try values.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
    public var canonicalHome: String {
        URL(fileURLWithPath: (home as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public func validateDedicatedHome() throws {
        guard home.hasPrefix("/") || home.hasPrefix("~/") else { throw ClientFailure.configuration("CODEX_HOME must be an absolute path.") }
        let shared = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").resolvingSymlinksInPath().path
        guard canonicalHome != shared else { throw ClientFailure.configuration("The shared ~/.codex home is not allowed. Use a dedicated home to avoid refresh-token races.") }
    }
}

public struct Settings: Codable, Sendable {
    public var accounts: [AccountConfiguration]
    public var codexPath: String
    public var refreshMinutes: Int
    public init(root: URL, codexPath: String) {
        accounts = [AccountConfiguration(slot: "A", name: "Personal", home: root.appendingPathComponent("Accounts/A").path),
                    AccountConfiguration(slot: "B", name: "Secondary", home: root.appendingPathComponent("Accounts/B").path)]
        self.codexPath = codexPath; refreshMinutes = 5
    }
    public func validate() throws {
        try validateAccountSlots()
        guard Set(accounts.map(\.canonicalHome)).count == accounts.count else { throw ClientFailure.configuration("Accounts must use different CODEX_HOME directories.") }
        for account in accounts {
            try account.validateDedicatedHome()
            guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure.configuration("Account names cannot be empty.") }
        }
        guard (1...60).contains(refreshMinutes) else { throw ClientFailure.configuration("Refresh interval must be 1–60 minutes.") }
        guard codexPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: codexPath) else {
            throw ClientFailure.configuration("Select an executable Codex CLI binary.")
        }
    }
    public func validateAccountSlots() throws {
        guard Set(accounts.map(\.slot)).count == accounts.count,
              accounts.allSatisfy({ !$0.slot.isEmpty && $0.slot.allSatisfy { $0 >= "A" && $0 <= "Z" } }) else {
            throw ClientFailure.configuration("Account slots must have unique letter identifiers.")
        }
    }
    public mutating func addAccount(root: URL) {
        var number = 1
        func label(_ index: Int) -> String {
            var n = index, result = ""
            while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
            return result
        }
        let taken = Set(accounts.map(\.slot))
        while taken.contains(label(number)) { number += 1 }
        let slot = label(number)
        let home = root.appendingPathComponent("Accounts/\(slot)-\(UUID().uuidString)").path
        accounts.append(AccountConfiguration(slot: slot, name: "Account \(slot)", home: home))
    }
}

public final class SettingsStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func load(defaultCodex: String) throws -> Settings {
        let file = root.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Settings(root: root, codexPath: defaultCodex) }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    }
    public func save(_ settings: Settings) throws {
        try settings.validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// Advisory lock protects this app's short-lived sessions and login across instances.
// It cannot lock other Codex clients; configured homes must be exclusively owned.
public final class HomeLease {
    private var descriptor: Int32 = -1
    public init(home: String) throws {
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(home + "/.codex-limits.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ClientFailure.configuration("Cannot lock this CODEX_HOME.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw ClientFailure.configuration("This home is busy in another Codex Limits session.")
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    deinit { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor) } }
}

public enum AccountIsolation {
    public static func duplicateSlots(_ snapshots: [(slot: String, snapshot: AccountSnapshot)]) -> [String: String] {
        var accepted: [(slot: String, snapshot: AccountSnapshot)] = []
        var rejected: [String: String] = [:]
        for item in snapshots {
            var duplicate: String?
            for other in accepted {
                do { try verify(other.snapshot, item.snapshot) }
                catch { duplicate = "Account \(item.slot) conflicts with \(other.slot): " + error.localizedDescription; break }
            }
            if let duplicate { rejected[item.slot] = duplicate } else { accepted.append(item) }
        }
        return rejected
    }
    public static func verify(_ first: AccountSnapshot, _ second: AccountSnapshot) throws {
        let a = first.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = second.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !a.isEmpty, !b.isEmpty else { throw ClientFailure.authentication("Account identity unavailable; independence cannot be verified.") }
        guard a != b else { throw ClientFailure.authentication("Both slots are signed into the same ChatGPT user. Sign in with a different account.") }
        if let aID = first.usage.accountId, let bID = second.usage.accountId, aID == bID {
            throw ClientFailure.authentication("Both slots use the same ChatGPT workspace/account.")
        }
    }
}
