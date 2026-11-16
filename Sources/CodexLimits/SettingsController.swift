import AppKit
import ServiceManagement
import LimitsCore

@MainActor
final class SettingsController: NSWindowController, NSTextFieldDelegate {
    let monitor: UsageMonitor

    // Editing state
    private var draft: Settings
    private var names: [NSTextField] = []
    private var homes: [NSTextField] = []
    private var labelFields: [String: NSTextField] = [:]
    private var slotToggles: [String: NSButton] = [:]
    private var signInButtons: [NSButton] = []

    // Rows
    private let executable = NSTextField()
    private let interval = NSTextField()
    private let launch = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let message = UI.label("", size: 11, color: .systemOrange)
    private let commandCodeEnabled = NSButton(checkboxWithTitle: "Monitor Command Code", target: nil, action: nil)
    private let commandCodePath = NSTextField()
    private let commandCodeStatus = UI.label("", size: 10, color: .secondaryLabelColor)
    private let commandCodeLabel = NSTextField()
    private let claudeEnabled = NSButton(checkboxWithTitle: "Monitor Claude Code", target: nil, action: nil)
    private let claudeKeychain = NSButton(checkboxWithTitle: "Read credentials from the login keychain", target: nil, action: nil)
    private let claudeKeychainService = NSTextField()
    private let claudePath = NSTextField()
    private let claudeLabel = NSTextField()
    private let claudeStatus = UI.label("", size: 10, color: .secondaryLabelColor)
    private let menuIcon = NSButton(checkboxWithTitle: "Show ◈ icon", target: nil, action: nil)
    private let menuLabels = NSButton(checkboxWithTitle: "Show provider labels", target: nil, action: nil)
    private let menuErrorMarker = NSButton(checkboxWithTitle: "Mark stale or failed providers with !", target: nil, action: nil)
    private let menuOverflow = NSButton(checkboxWithTitle: "Collapse extra accounts into +N", target: nil, action: nil)
    private let menuShowCommandCode = NSButton(checkboxWithTitle: "Include Command Code", target: nil, action: nil)
    private let menuShowClaude = NSButton(checkboxWithTitle: "Include Claude Code", target: nil, action: nil)
    private let codexMetric = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commandCodeMetric = NSPopUpButton(frame: .zero, pullsDown: false)
    private let claudeMetric = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codexAccountCount = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previewHolder = UI.stack([], spacing: 6)

    private var body: NSStackView?
    private var scroll: NSScrollView?

    static let windowWidth: CGFloat = 660
    private let contentWidth: CGFloat = 608

    init(monitor: UsageMonitor) {
        self.monitor = monitor
        draft = monitor.settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Codex Limits · Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func build() {
        guard let window, let container = window.contentView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        names.removeAll(); homes.removeAll(); labelFields.removeAll()
        slotToggles.removeAll(); signInButtons.removeAll()

        let stack = UI.stack([accountsCard(), providersCard(), menuBarCard(), generalCard()], spacing: 16)
        body = stack
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.scroll = scroll

        let footer = footerBar()
        container.addSubview(scroll)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 56)
        ])

        document.layoutSubtreeIfNeeded()
        let height = max(320, stack.fittingSize.height + 24)
        document.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: height)
        resizeWindow()
        updateCommandCodeStatus()
        updateClaudeStatus()
        updatePreview()
        updateStatus()
    }

    private func footerBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let line = UI.divider()
        line.translatesAutoresizingMaskIntoConstraints = false
        message.preferredMaxLayoutWidth = 300
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = UI.stack([
            UI.button("Quit Codex Limits", target: self, action: #selector(quit)),
            UI.spacer(),
            UI.button("Save & Refresh", target: self, action: #selector(save))
        ], vertical: false)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        bar.addSubview(message)
        bar.addSubview(buttons)
        message.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.topAnchor.constraint(equalTo: bar.topAnchor),
            message.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 24),
            message.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 4),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -24),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 4)
        ])
        return bar
    }

    // A rounded card with a section title and optional one-line explanation.
    private func card(_ title: String, _ subtitle: String? = nil) -> (box: NSBox, stack: NSStackView) {
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .textBackgroundColor
        box.borderWidth = 0
        box.cornerRadius = 10
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let heading = UI.stack([UI.label(title, size: 13, weight: .semibold)], vertical: true, spacing: 2)
        if let subtitle {
            let detail = UI.label(subtitle, size: 10, color: .secondaryLabelColor)
            detail.preferredMaxLayoutWidth = contentWidth - 32
            heading.addArrangedSubview(detail)
        }
        let stack = UI.stack([heading], spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14)
        ])
        return (box, stack)
    }

    // Aligned form row: fixed caption column, control column, optional trailing control.
    private func row(_ caption: String, _ control: NSView, trailing: NSView? = nil, captionWidth: CGFloat = 132) -> NSView {
        let name = UI.label(caption, size: 11, color: .secondaryLabelColor)
        name.alignment = .right
        name.widthAnchor.constraint(equalToConstant: captionWidth).isActive = true
        var views: [NSView] = [name, control]
        if let trailing { views.append(trailing) }
        let stack = UI.stack(views, vertical: false, spacing: 8)
        stack.widthAnchor.constraint(equalToConstant: contentWidth - 32).isActive = true
        return stack
    }

    private func field(_ value: String, width: CGFloat, mono: Bool = false) -> NSTextField {
        let field = NSTextField(string: value)
        field.font = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    private func accountsCard() -> NSView {
        let (box, card) = card("Codex accounts", "One dedicated home per account. Never share a home with another Codex client.")
        let add = UI.button("+ Add Account", target: self, action: #selector(addAccount))
        add.setAccessibilityLabel("Add Account")
        card.addArrangedSubview(UI.stack([add, UI.spacer()], vertical: false))

        for (index, account) in draft.accounts.enumerated() {
            let name = field(account.name, width: 180)
            name.placeholderString = "Account name"
            let home = field(account.home, width: contentWidth - 32 - 132 - 8 - 78, mono: true)
            home.toolTip = account.home
            let label = field(draft.menuBar.accountLabels[account.slot] ?? "", width: 84)
            label.placeholderString = account.slot
            label.toolTip = "Menu bar label. Blank shows the slot letter \(account.slot)."
            label.identifier = NSUserInterfaceItemIdentifier("menu-bar-label-\(account.slot)")
            label.target = self
            label.action = #selector(updatePreview)
            label.delegate = self
            names.append(name); homes.append(home); labelFields[account.slot] = label

            let choose = UI.button("Choose…", target: self, action: #selector(chooseHome(_:)))
            choose.tag = index
            let login = UI.button("Sign in…", target: self, action: #selector(signIn(_:)))
            login.tag = index
            signInButtons.append(login)
            let remove = UI.button("Remove", target: self, action: #selector(removeAccount(_:)))
            remove.tag = index

            let badge = UI.label(account.slot, size: 11, weight: .bold, color: .controlAccentColor)
            badge.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let show = NSButton(checkboxWithTitle: "Show in menu bar", target: self, action: #selector(updatePreview))
            show.state = draft.menuBar.hiddenCodexSlots.contains(account.slot) ? .off : .on
            show.tag = index
            slotToggles[account.slot] = show

            card.addArrangedSubview(UI.stack([badge, name, UI.spacer(), login, remove], vertical: false, spacing: 8))
            card.addArrangedSubview(row("Home", home, trailing: choose))
            card.addArrangedSubview(row("Menu bar", UI.stack([label, show, UI.spacer()], vertical: false, spacing: 10)))
            if index < draft.accounts.count - 1 { card.addArrangedSubview(UI.divider()) }
        }
        return box
    }

    private func providersCard() -> NSView {
        let (box, card) = card("Providers", "Both use the sign-in their own CLI already stored. Credentials are read-only.")

        commandCodeEnabled.target = self; commandCodeEnabled.action = #selector(toggleCommandCode)
        commandCodeEnabled.state = draft.commandCode.enabled ? .on : .off
        commandCodeEnabled.toolTip = "Reads Command Code usage with the login already stored by the Command Code CLI."
        card.addArrangedSubview(commandCodeEnabled)
        commandCodePath.stringValue = draft.commandCode.authFile
        commandCodePath.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandCodePath.widthAnchor.constraint(equalToConstant: contentWidth - 32 - 132 - 8 - 78).isActive = true
        commandCodePath.lineBreakMode = .byTruncatingMiddle
        commandCodePath.isEnabled = draft.commandCode.enabled
        commandCodeLabel.stringValue = draft.menuBar.commandCodeLabel
        commandCodeLabel.font = .systemFont(ofSize: 12)
        commandCodeLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
        commandCodeLabel.placeholderString = MenuBarPreferences.defaultCommandCodeLabel
        commandCodeLabel.toolTip = "Label used for Command Code in the menu bar."
        commandCodeLabel.identifier = NSUserInterfaceItemIdentifier("menu-bar-label-command-code")
        commandCodeLabel.target = self
        commandCodeLabel.action = #selector(updatePreview)
        card.addArrangedSubview(row("auth.json", commandCodePath, trailing: UI.button("Choose…", target: self, action: #selector(chooseCommandCodeAuth))))
        card.addArrangedSubview(row("Menu bar label", commandCodeLabel))
        commandCodeStatus.preferredMaxLayoutWidth = contentWidth - 32
        card.addArrangedSubview(commandCodeStatus)
        card.addArrangedSubview(UI.divider())

        claudeEnabled.target = self; claudeEnabled.action = #selector(toggleClaudeCode)
        claudeEnabled.state = draft.claudeCode.enabled ? .on : .off
        claudeEnabled.toolTip = "Reads Claude Code usage with the sign-in Claude Code already stored."
        card.addArrangedSubview(claudeEnabled)
        claudeKeychain.target = self; claudeKeychain.action = #selector(toggleClaudeCode)
        claudeKeychain.state = draft.claudeCode.useKeychain ? .on : .off
        claudeKeychain.toolTip = "Claude Code stores its OAuth credential in the login keychain. The app reads it; it never writes or refreshes it."
        claudeKeychainService.stringValue = draft.claudeCode.keychainService
        claudeKeychainService.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        claudeKeychainService.widthAnchor.constraint(equalToConstant: 200).isActive = true
        claudeKeychainService.toolTip = "Keychain service name. Claude Code uses “Claude Code-credentials”."
        card.addArrangedSubview(row("Keychain", UI.stack([claudeKeychain, UI.spacer()], vertical: false)))
        card.addArrangedSubview(row("Service", claudeKeychainService))
        claudePath.stringValue = draft.claudeCode.credentialsFile
        claudePath.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        claudePath.widthAnchor.constraint(equalToConstant: contentWidth - 32 - 132 - 8 - 78).isActive = true
        claudePath.lineBreakMode = .byTruncatingMiddle
        card.addArrangedSubview(row("Credentials", claudePath, trailing: UI.button("Choose…", target: self, action: #selector(chooseClaudeCredentials))))
        claudeLabel.stringValue = draft.menuBar.claudeCodeLabel
        claudeLabel.font = .systemFont(ofSize: 12)
        claudeLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
        claudeLabel.placeholderString = MenuBarPreferences.defaultClaudeCodeLabel
        claudeLabel.toolTip = "Label used for Claude Code in the menu bar."
        claudeLabel.identifier = NSUserInterfaceItemIdentifier("menu-bar-label-claude")
        claudeLabel.target = self
        claudeLabel.action = #selector(updatePreview)
        card.addArrangedSubview(row("Menu bar label", claudeLabel))
        claudeStatus.preferredMaxLayoutWidth = contentWidth - 32
        card.addArrangedSubview(claudeStatus)

        claudePath.isEnabled = draft.claudeCode.enabled
        claudeKeychain.isEnabled = draft.claudeCode.enabled
        claudeKeychainService.isEnabled = draft.claudeCode.enabled && draft.claudeCode.useKeychain
        claudeLabel.isEnabled = draft.claudeCode.enabled
        return box
    }

    private func menuBarCard() -> NSView {
        let (box, card) = card("Menu bar", "The preview is the exact status item title and updates as you edit.")
        for view in previewHolder.arrangedSubviews { previewHolder.removeArrangedSubview(view); view.removeFromSuperview() }
        card.addArrangedSubview(previewHolder)
        setPreview(UI.stack([UI.label("Preview · macOS menu bar", size: 10, color: .secondaryLabelColor),
                             MenuBarPreviewView(title: draftPreviewTitle(), width: contentWidth - 32)], spacing: 4))

        for button in [menuIcon, menuLabels, menuErrorMarker, menuOverflow] {
            button.target = self; button.action = #selector(updatePreview)
            card.addArrangedSubview(button)
        }
        menuIcon.state = draft.menuBar.showIcon ? .on : .off
        menuLabels.state = draft.menuBar.showLabels ? .on : .off
        menuErrorMarker.state = draft.menuBar.showErrorMarker ? .on : .off
        menuOverflow.state = draft.menuBar.showOverflow ? .on : .off

        menuShowCommandCode.target = self; menuShowCommandCode.action = #selector(updatePreview)
        menuShowCommandCode.state = draft.menuBar.showCommandCode ? .on : .off
        menuShowCommandCode.isEnabled = draft.commandCode.enabled
        menuShowClaude.target = self; menuShowClaude.action = #selector(updatePreview)
        menuShowClaude.state = draft.menuBar.showClaudeCode ? .on : .off
        menuShowClaude.isEnabled = draft.claudeCode.enabled

        configure(metric: codexMetric, select: draft.menuBar.codexMetric)
        configure(metric: commandCodeMetric, select: draft.menuBar.commandCodeMetric)
        configure(metric: claudeMetric, select: draft.menuBar.claudeMetric)
        codexAccountCount.removeAllItems()
        for count in MenuBarPreferences.accountRange { codexAccountCount.addItem(withTitle: "\(count)") }
        codexAccountCount.selectItem(at: min(draft.menuBar.maxCodexAccounts, MenuBarPreferences.accountRange.count) - 1)
        for popup in [codexMetric, commandCodeMetric, claudeMetric, codexAccountCount] {
            popup.target = self; popup.action = #selector(updatePreview)
            popup.font = .systemFont(ofSize: 11)
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
        }

        card.addArrangedSubview(UI.divider())
        card.addArrangedSubview(row("Codex window", codexMetric, captionWidth: 132))
        card.addArrangedSubview(row("Codex accounts", codexAccountCount, trailing: menuOverflow, captionWidth: 132))
        card.addArrangedSubview(UI.stack([menuShowCommandCode, commandCodeMetric, UI.spacer()], vertical: false, spacing: 10))
        card.addArrangedSubview(UI.stack([menuShowClaude, claudeMetric, UI.spacer()], vertical: false, spacing: 10))
        return box
    }

    private func generalCard() -> NSView {
        let (box, card) = card("General")
        executable.stringValue = draft.codexPath
        executable.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        executable.widthAnchor.constraint(equalToConstant: contentWidth - 32 - 132 - 8 - 78).isActive = true
        executable.lineBreakMode = .byTruncatingMiddle
        executable.toolTip = draft.codexPath
        card.addArrangedSubview(row("Codex binary", executable, trailing: UI.button("Choose…", target: self, action: #selector(chooseExecutable))))

        interval.stringValue = String(draft.refreshMinutes)
        interval.widthAnchor.constraint(equalToConstant: 52).isActive = true
        interval.alignment = .right
        interval.target = self
        interval.action = #selector(validateInterval)
        card.addArrangedSubview(row("Refresh every", UI.stack([interval, UI.label("minutes (1–60)", size: 11, color: .secondaryLabelColor), UI.spacer()], vertical: false, spacing: 8)))

        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launch.target = self; launch.action = #selector(changeLaunch)
        card.addArrangedSubview(row("Startup", UI.stack([launch, UI.spacer()], vertical: false)))
        return box
    }

    // MARK: - Window sizing

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        updateStatus()
    }

    private func resizeWindow() {
        guard let scroll, let document = scroll.documentView, let window, let body else { return }
        document.layoutSubtreeIfNeeded()
        let contentHeight = body.fittingSize.height + 24
        if abs(document.frame.height - contentHeight) > 0.5 {
            document.setFrameSize(NSSize(width: Self.windowWidth, height: contentHeight))
        }
        let available = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 120
        let height = min(max(420, contentHeight), available, 820)
        if abs(window.contentView!.bounds.height - height) > 0.5 {
            window.setContentSize(NSSize(width: Self.windowWidth, height: height))
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Status

    func updateStatus() {
        for (index, button) in signInButtons.enumerated() {
            guard index < draft.accounts.count else { continue }
            let slot = draft.accounts[index].slot
            button.title = monitor.states[slot]?.loginInProgress == true ? "Signing in…" : "Sign in…"
            let saved = monitor.settings.accounts.first { $0.slot == slot }
            button.isEnabled = !monitor.isBusy && saved != nil
        }
        var lines = monitor.settings.accounts.compactMap { account in
            monitor.states[account.slot]?.error.map { "\(account.slot): \($0)" }
        }
        if monitor.settings.commandCode.enabled, let error = monitor.commandCode.error {
            lines.append("\(draft.menuBar.commandCodeLabel): " + error)
        }
        if monitor.settings.claudeCode.enabled, let error = monitor.claudeCode.error {
            lines.append("\(draft.menuBar.claudeCodeLabel): " + error)
        }
        message.stringValue = lines.joined(separator: "  ·  ")
    }

    // MARK: - Draft capture

    private func captureDraft() -> Settings {
        var updated = draft
        for index in updated.accounts.indices where index < names.count {
            updated.accounts[index].name = names[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.accounts[index].home = homes[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        updated.codexPath = CodexExecutable.nativePath(executable.stringValue) ?? executable.stringValue
        updated.refreshMinutes = Int(interval.stringValue) ?? 0
        updated.commandCode.enabled = commandCodeEnabled.state == .on
        updated.commandCode.authFile = commandCodePath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.claudeCode.enabled = claudeEnabled.state == .on
        updated.claudeCode.useKeychain = claudeKeychain.state == .on
        updated.claudeCode.keychainService = claudeKeychainService.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.claudeCode.credentialsFile = claudePath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.menuBar.showIcon = menuIcon.state == .on
        updated.menuBar.showLabels = menuLabels.state == .on
        updated.menuBar.showErrorMarker = menuErrorMarker.state == .on
        updated.menuBar.showOverflow = menuOverflow.state == .on
        updated.menuBar.showCommandCode = menuShowCommandCode.state == .on
        updated.menuBar.showClaudeCode = menuShowClaude.state == .on
        updated.menuBar.codexMetric = selectedMetric(codexMetric)
        updated.menuBar.commandCodeMetric = selectedMetric(commandCodeMetric)
        updated.menuBar.claudeMetric = selectedMetric(claudeMetric)
        updated.menuBar.maxCodexAccounts = codexAccountCount.numberOfItems == 0
            ? updated.menuBar.maxCodexAccounts
            : codexAccountCount.indexOfSelectedItem + 1
        updated.menuBar.hiddenCodexSlots = slotToggles
            .filter { $0.value.state == .off }
            .keys
            .filter { slot in updated.accounts.contains { $0.slot == slot } }
            .sorted()
        var labels: [String: String] = [:]
        for (slot, field) in labelFields {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, updated.accounts.contains(where: { $0.slot == slot }) else { continue }
            labels[slot] = value
        }
        updated.menuBar.accountLabels = labels
        updated.menuBar.commandCodeLabel = commandCodeLabel.stringValue
        updated.menuBar.claudeCodeLabel = claudeLabel.stringValue
        // Trim, cap at 12 characters, and drop labels for accounts that no longer exist.
        updated.menuBar = updated.menuBar.clamped()
        updated.menuBar.accountLabels = updated.menuBar.accountLabels.filter { slot, _ in
            updated.accounts.contains { $0.slot == slot }
        }
        return updated
    }

    // MARK: - Preview

    private func configure(metric popup: NSPopUpButton, select metric: UsageMetric) {
        popup.removeAllItems()
        for value in UsageMetric.allCases { popup.addItem(withTitle: value.title) }
        popup.selectItem(at: UsageMetric.allCases.firstIndex(of: metric) ?? 0)
    }

    private func selectedMetric(_ popup: NSPopUpButton) -> UsageMetric {
        let index = max(0, popup.indexOfSelectedItem)
        return UsageMetric.allCases[min(index, UsageMetric.allCases.count - 1)]
    }

    private func draftPreviewTitle() -> String {
        let draft = captureDraft()
        let codex = draft.accounts.map { account -> CodexMenuBarState in
            let state = monitor.states[account.slot]
            let usage = state?.snapshot?.usage.codex
            return CodexMenuBarState(slot: account.slot, state: ProviderMenuBarState(
                fiveHour: usage?.fiveHour?.remaining,
                weekly: usage?.weekly?.remaining,
                failed: state?.error != nil
            ))
        }
        var commandCode: ProviderMenuBarState?
        if draft.commandCode.enabled, draft.menuBar.showCommandCode {
            let state = monitor.commandCode
            commandCode = ProviderMenuBarState(
                fiveHour: state.snapshot?.windowLimits?.fiveHour?.remaining,
                weekly: state.snapshot?.windowLimits?.weekly?.remaining,
                fallback: state.snapshot?.monthlyRemainingPercent,
                failed: state.error != nil
            )
        }
        var claude: ProviderMenuBarState?
        if draft.claudeCode.enabled, draft.menuBar.showClaudeCode {
            let state = monitor.claudeCode
            claude = ProviderMenuBarState(
                fiveHour: state.snapshot?.fiveHour?.remaining,
                weekly: state.snapshot?.weekly?.remaining,
                failed: state.error != nil
            )
        }
        let entries = MenuBarText.entries(codex: codex, commandCode: commandCode, claude: claude, preferences: draft.menuBar)
        return MenuBarText.compose(entries, preferences: draft.menuBar).title
    }

    @objc private func updatePreview() {
        draft = captureDraft()
        setPreview(UI.stack([UI.label("Preview · macOS menu bar", size: 10, color: .secondaryLabelColor),
                             MenuBarPreviewView(title: draftPreviewTitle(), width: contentWidth - 32)], spacing: 4))
    }
    private func setPreview(_ view: NSView) {
        for child in previewHolder.arrangedSubviews { previewHolder.removeArrangedSubview(child); child.removeFromSuperview() }
        previewHolder.addArrangedSubview(view)
    }
    // Typing a label should move the preview immediately, before focus leaves the field.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        guard field === commandCodeLabel || field === claudeLabel || labelFields.values.contains(where: { $0 === field }) else { return }
        let preview = draftPreviewTitle()
        if let stack = previewHolder.arrangedSubviews.first as? NSStackView,
           let strip = stack.arrangedSubviews.last as? MenuBarPreviewView,
           strip.title != preview {
            setPreview(UI.stack([UI.label("Preview · macOS menu bar", size: 10, color: .secondaryLabelColor),
                                 MenuBarPreviewView(title: preview, width: contentWidth - 32)], spacing: 4))
        }
    }

    // MARK: - Actions

    @objc private func addAccount() {
        guard !monitor.isBusy else { message.stringValue = "Wait for the current operation to finish."; return }
        draft = captureDraft(); draft.addAccount(root: monitor.store.root)
        build(); message.stringValue = "New account added. Save & Refresh, then Sign in."
    }

    @objc private func removeAccount(_ sender: NSButton) {
        guard !monitor.isBusy else { message.stringValue = "Wait for the current operation to finish."; return }
        guard sender.tag < draft.accounts.count else { return }
        let account = draft.accounts[sender.tag]
        let alert = NSAlert(); alert.messageText = "Remove account \(account.slot)?"
        alert.informativeText = "This removes the slot from monitoring after Save & Refresh. Its credential directory and stored credentials will not be deleted or logged out."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        draft = captureDraft(); draft.accounts.remove(at: sender.tag)
        build(); message.stringValue = "Account removed from this draft. Save & Refresh to apply."
    }

    @objc private func chooseHome(_ sender: NSButton) {
        guard sender.tag < draft.accounts.count else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Select an existing dedicated CODEX_HOME. It must not be used by another Codex client."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Use this home exclusively with Codex Limits?"
        alert.informativeText = "Stop using this directory in other Codex clients before continuing. Codex Limits lets the official CLI manage authentication here; it never duplicates tokens or edits auth.json."
        alert.addButton(withTitle: "Use Dedicated Home"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard sender.tag < homes.count else { return }
        homes[sender.tag].stringValue = url.path
    }

    @objc private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "Choose the native Codex binary (official npm launchers are resolved to their native binary)."
        if panel.runModal() == .OK, let url = panel.url {
            if let native = CodexExecutable.nativePath(url.path) { executable.stringValue = native; executable.toolTip = native }
            else { message.stringValue = "No native Codex executable found at this location." }
        }
    }

    @objc private func toggleCommandCode() {
        commandCodePath.isEnabled = commandCodeEnabled.state == .on
        commandCodeLabel.isEnabled = commandCodeEnabled.state == .on
        menuShowCommandCode.isEnabled = commandCodeEnabled.state == .on
        draft = captureDraft()
        updateCommandCodeStatus()
        updatePreview()
    }

    @objc private func chooseCommandCodeAuth() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".commandcode")
        panel.message = "Choose Command Code’s auth.json. It is read only; the key is never copied."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commandCodePath.stringValue = url.path
        commandCodeEnabled.state = .on
        commandCodePath.isEnabled = true
        draft = captureDraft()
        updateCommandCodeStatus()
    }

    private func updateCommandCodeStatus() {
        let value = commandCodePath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            commandCodeStatus.stringValue = "Choose Command Code’s auth.json."
            commandCodeStatus.textColor = .systemOrange
            commandCodeStatus.isHidden = commandCodeEnabled.state != .on
            return
        }
        let path = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
        if FileManager.default.fileExists(atPath: path) {
            commandCodeStatus.stringValue = "Found auth.json · read-only"
            commandCodeStatus.textColor = .secondaryLabelColor
        } else {
            commandCodeStatus.stringValue = "Not found · run `cmd login` in Terminal, then Save & Refresh."
            commandCodeStatus.textColor = .systemOrange
        }
        commandCodeStatus.isHidden = commandCodeEnabled.state != .on
    }

    @objc private func toggleClaudeCode() {
        claudePath.isEnabled = claudeEnabled.state == .on
        claudeKeychain.isEnabled = claudeEnabled.state == .on
        claudeKeychainService.isEnabled = claudeEnabled.state == .on && claudeKeychain.state == .on
        claudeLabel.isEnabled = claudeEnabled.state == .on
        menuShowClaude.isEnabled = claudeEnabled.state == .on
        draft = captureDraft()
        updateClaudeStatus()
        updatePreview()
    }

    @objc private func chooseClaudeCredentials() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        panel.showsHiddenFiles = true
        panel.message = "Choose Claude Code’s credentials file. It is read only; the token is never copied or rewritten."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        claudePath.stringValue = url.path
        claudeEnabled.state = .on
        draft = captureDraft()
        updateClaudeStatus()
        updatePreview()
    }

    private func updateClaudeStatus() {
        let enabled = claudeEnabled.state == .on
        let value = claudePath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExists = !value.isEmpty && FileManager.default.fileExists(atPath: (value as NSString).expandingTildeInPath)
        if claudeKeychain.state == .on {
            let note = fileExists ? " Found a credentials file too." : ""
            claudeStatus.stringValue = "Keychain: \(claudeKeychainService.stringValue) · read-only." + note
            claudeStatus.textColor = .secondaryLabelColor
        } else if value.isEmpty {
            claudeStatus.stringValue = "Choose a credentials file or enable the keychain lookup."
            claudeStatus.textColor = .systemOrange
        } else if fileExists {
            claudeStatus.stringValue = "Found credentials file · read-only"
            claudeStatus.textColor = .secondaryLabelColor
        } else {
            claudeStatus.stringValue = "Not found · sign in with `claude` first."
            claudeStatus.textColor = .systemOrange
        }
        claudeStatus.isHidden = !enabled
    }

    @objc private func validateInterval() {
        guard let value = Int(interval.stringValue), (1...60).contains(value) else {
            message.stringValue = "Refresh interval must be 1–60 minutes."
            return
        }
        message.stringValue = ""
    }

    @objc private func save() {
        let settings = captureDraft()
        do {
            try monitor.apply(settings)
            draft = settings
            message.stringValue = "Saved. Refreshing…"
            message.textColor = .secondaryLabelColor
            updateStatus()
        } catch {
            message.stringValue = error.localizedDescription
            message.textColor = .systemOrange
        }
    }

    @objc private func signIn(_ sender: NSButton) {
        guard sender.tag < draft.accounts.count else { return }
        let account = draft.accounts[sender.tag]
        guard let saved = monitor.settings.accounts.first(where: { $0.slot == account.slot }),
              sender.tag < homes.count,
              homes[sender.tag].stringValue == saved.home, executable.stringValue == monitor.settings.codexPath else {
            message.stringValue = "Save the directory and executable before signing in."; return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to account \(account.slot)?"
        alert.informativeText = "The official Codex login will save credentials in \(account.canonicalHome). It may replace an existing login in that directory. This home must not be used by another app. Choose a different ChatGPT user for each slot in your browser."
        alert.addButton(withTitle: "Sign In"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { monitor.login(slot: account.slot) }
    }

    @objc private func changeLaunch() {
        do {
            if launch.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                message.stringValue = "Approve Codex Limits in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
            message.stringValue = "Launch at login: \(error.localizedDescription)"
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
