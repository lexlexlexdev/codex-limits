import Foundation

// Which server-reported window a provider contributes. Percentages are remaining, not used.
public enum UsageMetric: String, Codable, Equatable, Sendable, CaseIterable {
    case fiveHour
    case weekly
    case both

    public var title: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .weekly: return "Weekly"
        case .both: return "5-hour + Weekly"
        }
    }

    // Single-value form: the 5-hour window when it exists, otherwise the weekly window.
    public func percent(fiveHour: Int?, weekly: Int?) -> Int? {
        switch self {
        case .fiveHour: return fiveHour ?? weekly
        case .weekly: return weekly ?? fiveHour
        case .both: return fiveHour ?? weekly
        }
    }
}

public struct MenuBarEntry: Equatable, Sendable {
    public let label: String?
    public let value: String
    public let failed: Bool

    public init(label: String?, value: String, failed: Bool = false) {
        self.label = label; self.value = value; self.failed = failed
    }

    public init(label: String?, fiveHour: Int?, weekly: Int?, metric: UsageMetric, failed: Bool = false, fallback: Int? = nil) {
        let text: String
        switch metric {
        case .fiveHour, .weekly:
            let single = metric.percent(fiveHour: fiveHour, weekly: weekly) ?? fallback
            text = Self.percentText(single)
        case .both:
            if fiveHour == nil && weekly == nil, let fallback {
                text = Self.percentText(fallback)
            } else {
                text = Self.percentText(fiveHour) + "/" + Self.percentText(weekly)
            }
        }
        self.init(label: label, value: text, failed: failed)
    }

    public static func percentText(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "—"
    }
}

public struct MenuBarPreferences: Codable, Equatable, Sendable {
    public var showIcon: Bool
    public var showLabels: Bool
    public var codexMetric: UsageMetric
    public var commandCodeMetric: UsageMetric
    public var claudeMetric: UsageMetric
    public var showCommandCode: Bool
    public var showClaudeCode: Bool
    public var maxCodexAccounts: Int
    public var showOverflow: Bool
    public var showErrorMarker: Bool
    public var hiddenCodexSlots: [String]
    public var accountLabels: [String: String]
    public var commandCodeLabel: String
    public var claudeCodeLabel: String

    public static let accountRange = 1...8
    public static let defaultCommandCodeLabel = "cmd"
    public static let defaultClaudeCodeLabel = "Claude"

    public init(
        showIcon: Bool = true,
        showLabels: Bool = true,
        codexMetric: UsageMetric = .fiveHour,
        commandCodeMetric: UsageMetric = .fiveHour,
        claudeMetric: UsageMetric = .fiveHour,
        showCommandCode: Bool = true,
        showClaudeCode: Bool = true,
        maxCodexAccounts: Int = 3,
        showOverflow: Bool = true,
        showErrorMarker: Bool = true,
        hiddenCodexSlots: [String] = [],
        accountLabels: [String: String] = [:],
        commandCodeLabel: String = MenuBarPreferences.defaultCommandCodeLabel,
        claudeCodeLabel: String = MenuBarPreferences.defaultClaudeCodeLabel
    ) {
        self.showIcon = showIcon; self.showLabels = showLabels
        self.codexMetric = codexMetric; self.commandCodeMetric = commandCodeMetric; self.claudeMetric = claudeMetric
        self.showCommandCode = showCommandCode; self.showClaudeCode = showClaudeCode
        self.maxCodexAccounts = maxCodexAccounts; self.showOverflow = showOverflow
        self.showErrorMarker = showErrorMarker; self.hiddenCodexSlots = hiddenCodexSlots
        self.accountLabels = accountLabels; self.commandCodeLabel = commandCodeLabel
        self.claudeCodeLabel = claudeCodeLabel
    }

    enum CodingKeys: String, CodingKey {
        case showIcon, showLabels, codexMetric, commandCodeMetric, claudeMetric
        case showCommandCode, showClaudeCode, maxCodexAccounts, showOverflow, showErrorMarker, hiddenCodexSlots
        case accountLabels, commandCodeLabel, claudeCodeLabel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showIcon = try values.decodeIfPresent(Bool.self, forKey: .showIcon) ?? true
        showLabels = try values.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        codexMetric = try values.decodeIfPresent(UsageMetric.self, forKey: .codexMetric) ?? .fiveHour
        commandCodeMetric = try values.decodeIfPresent(UsageMetric.self, forKey: .commandCodeMetric) ?? .fiveHour
        claudeMetric = try values.decodeIfPresent(UsageMetric.self, forKey: .claudeMetric) ?? .fiveHour
        showCommandCode = try values.decodeIfPresent(Bool.self, forKey: .showCommandCode) ?? true
        showClaudeCode = try values.decodeIfPresent(Bool.self, forKey: .showClaudeCode) ?? true
        maxCodexAccounts = try values.decodeIfPresent(Int.self, forKey: .maxCodexAccounts) ?? 3
        showOverflow = try values.decodeIfPresent(Bool.self, forKey: .showOverflow) ?? true
        showErrorMarker = try values.decodeIfPresent(Bool.self, forKey: .showErrorMarker) ?? true
        hiddenCodexSlots = try values.decodeIfPresent([String].self, forKey: .hiddenCodexSlots) ?? []
        accountLabels = try values.decodeIfPresent([String: String].self, forKey: .accountLabels) ?? [:]
        commandCodeLabel = try values.decodeIfPresent(String.self, forKey: .commandCodeLabel) ?? MenuBarPreferences.defaultCommandCodeLabel
        claudeCodeLabel = try values.decodeIfPresent(String.self, forKey: .claudeCodeLabel) ?? MenuBarPreferences.defaultClaudeCodeLabel
    }

    public func clamped() -> MenuBarPreferences {
        var copy = self
        copy.maxCodexAccounts = min(max(Self.accountRange.lowerBound, maxCodexAccounts), Self.accountRange.upperBound)
        // A blank label would render as ": 74%"; fall back to the account slot.
        copy.accountLabels = accountLabels.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
        copy.commandCodeLabel = Self.label(commandCodeLabel, fallback: Self.defaultCommandCodeLabel)
        copy.claudeCodeLabel = Self.label(claudeCodeLabel, fallback: Self.defaultClaudeCodeLabel)
        return copy
    }

    public func accountLabel(_ slot: String) -> String {
        Self.label(accountLabels[slot] ?? "", fallback: slot)
    }

    static func label(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        // Keep the status item readable; a label is a name, not a sentence.
        return String(trimmed.prefix(12))
    }
}

public struct MenuBarTitle: Equatable, Sendable {
    public let title: String
    public let toolTip: String
    public let accessibilityLabel: String
    public init(title: String, toolTip: String, accessibilityLabel: String) {
        self.title = title; self.toolTip = toolTip; self.accessibilityLabel = accessibilityLabel
    }
}

// Provider state reduced to what the menu bar can display. fallback is a monthly
// percentage for plans without 5-hour or weekly caps.
public struct ProviderMenuBarState: Equatable, Sendable {
    public let fiveHour: Int?
    public let weekly: Int?
    public let fallback: Int?
    public let failed: Bool
    public init(fiveHour: Int? = nil, weekly: Int? = nil, fallback: Int? = nil, failed: Bool = false) {
        self.fiveHour = fiveHour; self.weekly = weekly; self.fallback = fallback; self.failed = failed
    }
}

public struct CodexMenuBarState: Equatable, Sendable {
    public let slot: String
    public let state: ProviderMenuBarState
    public init(slot: String, state: ProviderMenuBarState) {
        self.slot = slot; self.state = state
    }
}

public enum MenuBarText {
    public static let icon = "◈"
    public static let fallbackTitle = "Codex Limits"

    // Accounts beyond the configured limit collapse into one +N segment.
    public static func truncate(_ entries: [MenuBarEntry], maximum: Int, showOverflow: Bool) -> [MenuBarEntry] {
        let limit = min(Swift.max(1, maximum), entries.count)
        guard entries.count > limit else { return entries }
        let visible = Array(entries.prefix(limit))
        guard showOverflow else { return visible }
        return visible + [MenuBarEntry(label: nil, value: "+\(entries.count - limit)")]
    }

    public static func compose(_ entries: [MenuBarEntry], preferences: MenuBarPreferences) -> MenuBarTitle {
        let preferences = preferences.clamped()
        guard !entries.isEmpty else {
            let iconPrefix = preferences.showIcon ? icon + " " : ""
            return MenuBarTitle(
                title: iconPrefix + fallbackTitle,
                toolTip: "Codex Limits · no usage providers are shown in the menu bar. Change this in Settings → Menu bar.",
                accessibilityLabel: fallbackTitle
            )
        }
        let segments = entries.map { entry -> String in
            let marker = entry.failed && preferences.showErrorMarker ? "!" : ""
            guard preferences.showLabels, let label = entry.label else { return entry.value + marker }
            return "\(label): \(entry.value)\(marker)"
        }
        let title = (preferences.showIcon ? icon + " " : "") + segments.joined(separator: " · ")
        let details = entries.map { entry -> String in
            let name = entry.label ?? "Total"
            let marker = entry.failed ? " (stale or error)" : ""
            return "\(name) \(entry.value)\(marker)"
        }
        let toolTip = "Codex Limits · remaining allowance: " + details.joined(separator: " · ")
            + ". ! means stale or failed data. Click for details."
        let accessibilityLabel = "Codex Limits, " + segments.joined(separator: ", ")
        return MenuBarTitle(title: title, toolTip: toolTip, accessibilityLabel: accessibilityLabel)
    }

    public static func entries(
        codex: [CodexMenuBarState],
        commandCode: ProviderMenuBarState?,
        claude: ProviderMenuBarState?,
        preferences: MenuBarPreferences
    ) -> [MenuBarEntry] {
        let preferences = preferences.clamped()
        let hidden = Set(preferences.hiddenCodexSlots)
        let codexEntries = codex
            .filter { !hidden.contains($0.slot) }
            .map {
                MenuBarEntry(
                    label: preferences.accountLabel($0.slot),
                    fiveHour: $0.state.fiveHour,
                    weekly: $0.state.weekly,
                    metric: preferences.codexMetric,
                    failed: $0.state.failed,
                    fallback: $0.state.fallback
                )
            }
        var entries = truncate(codexEntries, maximum: preferences.maxCodexAccounts, showOverflow: preferences.showOverflow)
        if preferences.showCommandCode, let commandCode {
            entries.append(MenuBarEntry(label: preferences.commandCodeLabel, fiveHour: commandCode.fiveHour, weekly: commandCode.weekly, metric: preferences.commandCodeMetric, failed: commandCode.failed, fallback: commandCode.fallback))
        }
        if preferences.showClaudeCode, let claude {
            entries.append(MenuBarEntry(label: preferences.claudeCodeLabel, fiveHour: claude.fiveHour, weekly: claude.weekly, metric: preferences.claudeMetric, failed: claude.failed, fallback: claude.fallback))
        }
        return entries
    }
}
