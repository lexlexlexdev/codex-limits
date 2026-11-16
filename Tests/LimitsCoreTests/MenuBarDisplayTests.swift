import XCTest
@testable import LimitsCore

final class MenuBarDisplayTests: XCTestCase {
    private func codex(_ slot: String, fiveHour: Int?, weekly: Int?, failed: Bool = false) -> CodexMenuBarState {
        CodexMenuBarState(slot: slot, state: ProviderMenuBarState(fiveHour: fiveHour, weekly: weekly, failed: failed))
    }

    func testLabelsAndErrorMarker() {
        let preferences = MenuBarPreferences(codexMetric: .fiveHour)
        let entries = MenuBarText.entries(codex: [codex("A", fiveHour: 74, weekly: 52), codex("B", fiveHour: nil, weekly: nil, failed: true)],
                                          commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ A: 74% · B: —!")
    }

    func testLabelsCanBeHidden() {
        var preferences = MenuBarPreferences()
        preferences.showLabels = false
        let entries = MenuBarText.entries(codex: [codex("A", fiveHour: 74, weekly: 52)], commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ 74%")
    }

    func testIconCanBeHiddenAndErrorMarkerSuppressed() {
        var preferences = MenuBarPreferences()
        preferences.showIcon = false
        preferences.showErrorMarker = false
        let entries = MenuBarText.entries(codex: [codex("A", fiveHour: 12, weekly: nil, failed: true)], commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "A: 12%")
    }

    func testBothWindowMetricFormatsTwoPercentages() {
        let preferences = MenuBarPreferences(codexMetric: .both)
        let entries = MenuBarText.entries(codex: [codex("A", fiveHour: 74, weekly: 52)], commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ A: 74%/52%")
    }

    func testWeeklyMetricFallsBackToFiveHourWhenWeeklyIsMissing() {
        let preferences = MenuBarPreferences(codexMetric: .weekly)
        let entries = MenuBarText.entries(codex: [codex("A", fiveHour: 63, weekly: nil)], commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ A: 63%")
    }

    func testMissingWindowsShowDashNotZero() {
        let preferences = MenuBarPreferences(codexMetric: .both)
        let entries = MenuBarText.entries(codex: [codex("A", fiveHour: nil, weekly: nil)], commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ A: —/—")
    }

    func testExtraAccountsCollapseIntoOverflowSegment() {
        let preferences = MenuBarPreferences(maxCodexAccounts: 2)
        let accounts = ["A", "B", "C", "D"].map { codex($0, fiveHour: 40, weekly: 40) }
        let entries = MenuBarText.entries(codex: accounts, commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ A: 40% · B: 40% · +2")
    }

    func testOverflowCanBeSuppressed() {
        var preferences = MenuBarPreferences(maxCodexAccounts: 1)
        preferences.showOverflow = false
        let accounts = ["A", "B"].map { codex($0, fiveHour: 40, weekly: 40) }
        let entries = MenuBarText.entries(codex: accounts, commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ A: 40%")
    }

    func testHiddenAccountsAreOmittedAndDoNotCountAsOverflow() {
        var preferences = MenuBarPreferences(maxCodexAccounts: 2)
        preferences.hiddenCodexSlots = ["B"]
        let accounts = ["A", "B", "C"].map { codex($0, fiveHour: 40, weekly: 40) }
        let entries = MenuBarText.entries(codex: accounts, commandCode: nil, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ A: 40% · C: 40%")
    }

    func testProvidersAreIncludedOnlyWhenEnabledAndRequested() {
        var preferences = MenuBarPreferences(showCommandCode: false, showClaudeCode: true)
        let state = ProviderMenuBarState(fiveHour: 88, weekly: 60)
        let entries = MenuBarText.entries(codex: [], commandCode: state, claude: state, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ Claude: 88%")

        preferences.showClaudeCode = false
        XCTAssertEqual(MenuBarText.entries(codex: [], commandCode: state, claude: state, preferences: preferences).count, 0)
    }

    func testCommandCodeFallsBackToMonthlyWhenNoWindowCaps() {
        let preferences = MenuBarPreferences(commandCodeMetric: .both)
        let state = ProviderMenuBarState(fiveHour: nil, weekly: nil, fallback: 42)
        let entries = MenuBarText.entries(codex: [], commandCode: state, claude: nil, preferences: preferences)
        XCTAssertEqual(MenuBarText.compose(entries, preferences: preferences).title, "◈ CC: 42%")
    }

    func testEmptySelectionShowsAppNameInsteadOfBlankTitle() {
        let preferences = MenuBarPreferences()
        XCTAssertEqual(MenuBarText.compose([], preferences: preferences).title, "◈ Codex Limits")
        var plain = preferences
        plain.showIcon = false
        XCTAssertEqual(MenuBarText.compose([], preferences: plain).title, "Codex Limits")
    }

    func testTooltipAndAccessibilityCarryEveryProvider() {
        let preferences = MenuBarPreferences()
        let entries = MenuBarText.entries(codex: [codex("A", fiveHour: 74, weekly: 52)], commandCode: ProviderMenuBarState(fiveHour: 10, weekly: 20),
                                          claude: ProviderMenuBarState(fiveHour: 30, weekly: 40), preferences: preferences)
        let title = MenuBarText.compose(entries, preferences: preferences)
        XCTAssertTrue(title.toolTip.contains("A 74%"))
        XCTAssertTrue(title.toolTip.contains("CC 10%"))
        XCTAssertTrue(title.toolTip.contains("Claude 30%"))
        XCTAssertTrue(title.accessibilityLabel.contains("A: 74%"))
    }

    func testPreferencesDecodeFillsMissingFieldsWithDefaults() throws {
        let decoded = try JSONDecoder().decode(MenuBarPreferences.self, from: Data("{\"showIcon\":false}".utf8))
        XCTAssertFalse(decoded.showIcon)
        XCTAssertTrue(decoded.showLabels)
        XCTAssertEqual(decoded.codexMetric, .fiveHour)
        XCTAssertEqual(decoded.maxCodexAccounts, 3)
        XCTAssertEqual(decoded.hiddenCodexSlots, [])
    }

    func testPreferencesDecodeClampsAccountCount() throws {
        let decoded = try JSONDecoder().decode(MenuBarPreferences.self, from: Data("{\"maxCodexAccounts\":99}".utf8))
        XCTAssertEqual(decoded.clamped().maxCodexAccounts, 8)
        var zero = MenuBarPreferences()
        zero.maxCodexAccounts = 0
        XCTAssertEqual(zero.clamped().maxCodexAccounts, 1)
    }

    func testOldSettingsFileMigratesToDefaultMenuBar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MenuBarMigration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let homeA = root.appendingPathComponent("A").path, homeB = root.appendingPathComponent("B").path
        let legacy = """
        {"accounts":[{"slot":"A","name":"One","home":"\(homeA)"},{"slot":"B","name":"Two","home":"\(homeB)"}],
         "codexPath":"/usr/bin/true","refreshMinutes":5}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.menuBar, MenuBarPreferences())
        XCTAssertNoThrow(try settings.validate())
    }
}
