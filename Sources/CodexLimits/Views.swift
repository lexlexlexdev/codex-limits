import AppKit
import LimitsCore

@MainActor
enum UI {
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    static func stack(_ views: [NSView] = [], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }
    static func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }
    static func divider() -> NSView {
        let box = NSBox(); box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 12)
        return button
    }
}

@MainActor
final class AllowanceBar: NSView {
    let remaining: Int?
    init(remaining: Int?) {
        self.remaining = remaining
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 6).isActive = true
        widthAnchor.constraint(equalToConstant: 156).isActive = true
        setAccessibilityElement(true)
        setAccessibilityLabel(remaining.map { "\($0) percent remaining" } ?? "Allowance unavailable")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        guard let remaining, remaining > 0 else { return }
        (remaining < 10 ? NSColor.systemRed : remaining < 25 ? .systemOrange : .controlAccentColor).setFill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(remaining) / 100, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}

@MainActor
final class ResetButton: NSButton {
    let slot: String
    let creditId: String
    init(slot: String, creditId: String, title: String, target: AnyObject, action: Selector) {
        self.slot = slot; self.creditId = creditId
        super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        bezelStyle = .inline; font = .systemFont(ofSize: 11)
        setAccessibilityLabel("Apply banked reset, \(title). Confirmation required.")
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class AccountView: NSStackView {
    init(configuration: AccountConfiguration, state: UsageMonitor.State, expanded: Bool, canRedeem: Bool, toggleTarget: AnyObject, toggleAction: Selector, redeemAction: Selector, autoAction: Selector) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        widthAnchor.constraint(equalToConstant: 312).isActive = true
        let stale = state.error != nil
        let status = state.resetInProgress ? "Reset pending…" : state.loginInProgress ? "Signing in…" : stale ? "Needs attention" : state.snapshot != nil ? "Connected" : "Not connected"
        addArrangedSubview(UI.stack([
            UI.label(configuration.slot, size: 13, weight: .bold, color: .controlAccentColor),
            UI.label(configuration.name, size: 13, weight: .semibold), UI.spacer(),
            UI.label(status, size: 10, color: stale ? .systemOrange : .secondaryLabelColor)
        ], vertical: false))
        let usage = state.snapshot?.usage
        if let snapshot = state.snapshot {
            addArrangedSubview(UI.label(snapshot.email, size: 10, color: .secondaryLabelColor))
        }
        for (title, window) in [("5-hour", usage?.codex?.fiveHour), ("Weekly", usage?.codex?.weekly)] {
            let titleView = UI.label(title, size: 11)
            titleView.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let number = UI.label(window.map { "\($0.remaining)%" } ?? "—", size: 12, weight: .medium)
            number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let row = UI.stack([titleView, AllowanceBar(remaining: window?.remaining), UI.spacer(), number], vertical: false)
            row.widthAnchor.constraint(equalToConstant: 312).isActive = true
            addArrangedSubview(row)
            if let date = window?.resetDate {
                let text: String
                if date <= Date() { text = "\(title) window ended · awaiting server update" }
                else if title == "5-hour" { text = "5h resets in \(DisplayTime.relative(until: date))" }
                else { text = "Weekly resets \(DisplayTime.absolute(date))" }
                let label = UI.label(text, size: 10, color: .secondaryLabelColor)
                label.toolTip = "Server reset: \(DisplayTime.absolute(date)) (\(TimeZone.current.abbreviation() ?? "local time"))"
                addArrangedSubview(label)
            } else {
                addArrangedSubview(UI.label("\(title) window / reset time unavailable", size: 10, color: .secondaryLabelColor))
            }
        }
        if let error = state.error {
            let label = UI.label(error + (state.snapshot == nil ? "" : " Last successful data shown."), size: 10, color: .systemOrange)
            label.preferredMaxLayoutWidth = 312
            addArrangedSubview(label)
        }
        if let message = state.resetMessage {
            let label = UI.label(message, size: 10, color: .secondaryLabelColor)
            label.preferredMaxLayoutWidth = 312
            addArrangedSubview(label)
        }
        let resets = usage?.rateLimitResetCredits
        if let resets, resets.availableCount == 0 {
            addArrangedSubview(UI.label("Available resets · 0", size: 11, color: .secondaryLabelColor))
        } else if let resets {
            let toggle = UI.button("\(expanded ? "▾" : "▸") Available resets · \(resets.availableCount)", target: toggleTarget, action: toggleAction)
            toggle.identifier = NSUserInterfaceItemIdentifier(configuration.slot)
            toggle.setAccessibilityLabel("Available banked resets, \(resets.availableCount), \(expanded ? "expanded" : "collapsed")")
            addArrangedSubview(toggle)
            if expanded {
                if let rows = resets.sortedAvailable {
                    for reset in rows {
                        let color: NSColor
                        switch reset.warning(now: Date()) {
                        case .urgent, .expired: color = .systemRed
                        case .soon: color = .systemOrange
                        case .normal: color = .secondaryLabelColor
                        }
                        let expiration = reset.expiration.map { DisplayTime.absolute($0) } ?? "No expiration"
                        let lifetime = reset.expiration.map { DisplayTime.relative(until: $0) + ($0 > Date() ? " left" : "") } ?? ""
                        let apply = ResetButton(slot: configuration.slot, creditId: reset.id, title: "↺ " + expiration, target: toggleTarget, action: redeemAction)
                        apply.attributedTitle = NSAttributedString(string: apply.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
                        apply.isEnabled = canRedeem && !stale && !reset.id.isEmpty && state.snapshot?.usage.accountId?.isEmpty == false && reset.warning(now: Date()) != .expired
                        apply.toolTip = apply.isEnabled ? "Apply this specific banked reset after confirmation. Weekly reset date may change." : "Refresh and verify account identity before applying a non-expired reset, or use Open Usage."
                        let row = UI.stack([apply, UI.spacer(), UI.label(lifetime, size: 10, color: color)], vertical: false, spacing: 6)
                        row.widthAnchor.constraint(equalToConstant: 312).isActive = true
                        row.toolTip = reset.title ?? "Banked Codex reset (not a quota-window reset)"
                        addArrangedSubview(row)
                    }
                    if rows.count < resets.availableCount {
                        addArrangedSubview(UI.label("\(resets.availableCount - rows.count) reset expiration details unavailable", size: 10, color: .secondaryLabelColor))
                    }
                } else {
                    addArrangedSubview(UI.label("Individual expiration details unavailable", size: 10, color: .secondaryLabelColor))
                }
            }
        } else {
            addArrangedSubview(UI.label("Available resets · unavailable", size: 11, color: .secondaryLabelColor))
        }
        let toggle = NSSwitch(); toggle.state = configuration.autoStart ? .on : .off; toggle.isEnabled = canRedeem
        toggle.target = toggleTarget; toggle.action = autoAction
        toggle.identifier = NSUserInterfaceItemIdentifier(configuration.slot)
        toggle.toolTip = WindowInitializer.limitation
        toggle.setAccessibilityLabel("Auto-start window, account " + configuration.slot)
        let auto = UI.stack([UI.label("Auto-start window", size: 11), UI.spacer(), UI.label("Every 10 min", size: 10, color: .secondaryLabelColor), toggle], vertical: false)
        auto.widthAnchor.constraint(equalToConstant: 312).isActive = true
        auto.toolTip = WindowInitializer.limitation
        addArrangedSubview(auto)
        if configuration.autoStart, let message = state.autoMessage {
            let label = UI.label(message, size: 10, color: .secondaryLabelColor)
            label.preferredMaxLayoutWidth = 312
            addArrangedSubview(label)
        }
        for child in arrangedSubviews { child.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
}
