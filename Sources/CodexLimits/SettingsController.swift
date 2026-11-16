import AppKit
import ServiceManagement
import LimitsCore

@MainActor
final class SettingsController: NSWindowController {
    let monitor: UsageMonitor
    private var names: [NSTextField] = []
    private var homes: [NSTextField] = []
    private let executable = NSTextField()
    private let interval = NSTextField()
    private let launch = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let message = UI.label("", size: 11, color: .systemOrange)
    private let commandCodeEnabled = NSButton(checkboxWithTitle: "Monitor Command Code", target: nil, action: nil)
    private let commandCodePath = NSTextField()
    private let commandCodeStatus = UI.label("", size: 10, color: .secondaryLabelColor)
    private let claudeEnabled = NSButton(checkboxWithTitle: "Monitor Claude Code", target: nil, action: nil)
    private let claudeKeychain = NSButton(checkboxWithTitle: "Read credentials from the login keychain", target: nil, action: nil)
    private let claudeKeychainService = NSTextField()
    private let claudePath = NSTextField()
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
    private var slotToggles: [String: NSButton] = [:]
    private var signInButtons: [NSButton] = []
    private var layout: NSStackView?
    private var draft: Settings
    private var scroll: NSScrollView?
    init(monitor: UsageMonitor) {
        self.monitor = monitor
        draft = monitor.settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Limits · Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func build() {
        guard let window, let container = window.contentView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        names.removeAll(); homes.removeAll(); signInButtons.removeAll(); slotToggles.removeAll()
        let title = UI.label("Accounts · one dedicated home each", size: 17, weight: .semibold)
        let help = UI.label("Each directory must belong exclusively to this utility. Do not select a home used by Codex CLI, VS Code, or the Codex app: concurrent OAuth refresh can invalidate credentials. No credentials are copied. Save before signing in.", size: 11, color: .secondaryLabelColor)
        help.preferredMaxLayoutWidth = 558
        let add = UI.button("+ Add Account", target: self, action: #selector(addAccount))
        add.setAccessibilityLabel("Add Account")
        let content = UI.stack([title, help, add, UI.divider()], spacing: 12)
        layout = content
        for (index, account) in draft.accounts.enumerated() {
            let name = NSTextField(string: account.name)
            let home = NSTextField(string: account.home)
            names.append(name); homes.append(home)
            name.widthAnchor.constraint(equalToConstant: 200).isActive = true
            home.widthAnchor.constraint(equalToConstant: 436).isActive = true
            home.font = .systemFont(ofSize: 11)
            let choose = UI.button("Choose…", target: self, action: #selector(chooseHome(_:))); choose.tag = index
            let login = UI.button("Sign in…", target: self, action: #selector(signIn(_:))); login.tag = index
            signInButtons.append(login)
            let remove = UI.button("Remove", target: self, action: #selector(removeAccount(_:))); remove.tag = index
            content.addArrangedSubview(UI.stack([UI.label("Account \(account.slot)", weight: .semibold), name, UI.spacer(), login, remove], vertical: false))
            content.addArrangedSubview(UI.stack([home, choose], vertical: false))
            let show = NSButton(checkboxWithTitle: "Show account \(account.slot) in the menu bar", target: self, action: #selector(updatePreview))
            show.state = draft.menuBar.hiddenCodexSlots.contains(account.slot) ? .off : .on
            show.tag = index
            slotToggles[account.slot] = show
            content.addArrangedSubview(show)
        }
        content.addArrangedSubview(UI.divider())
        executable.stringValue = draft.codexPath
        executable.font = .systemFont(ofSize: 11)
        executable.widthAnchor.constraint(equalToConstant: 436).isActive = true
        content.addArrangedSubview(UI.label("Native Codex CLI executable", weight: .medium))
        content.addArrangedSubview(UI.stack([executable, UI.button("Choose…", target: self, action: #selector(chooseExecutable))], vertical: false))
        content.addArrangedSubview(UI.divider())
        content.addArrangedSubview(UI.label("Command Code (optional)", size: 13, weight: .semibold))
        commandCodeEnabled.target = self; commandCodeEnabled.action = #selector(toggleCommandCode)
        commandCodeEnabled.state = draft.commandCode.enabled ? .on : .off
        commandCodeEnabled.toolTip = "Reads Command Code usage with the login already stored by the Command Code CLI."
        content.addArrangedSubview(commandCodeEnabled)
        commandCodePath.stringValue = draft.commandCode.authFile
        commandCodePath.font = .systemFont(ofSize: 11)
        commandCodePath.widthAnchor.constraint(equalToConstant: 436).isActive = true
        commandCodePath.isEnabled = draft.commandCode.enabled
        content.addArrangedSubview(UI.stack([commandCodePath, UI.button("Choose…", target: self, action: #selector(chooseCommandCodeAuth))], vertical: false))
        let commandCodeHelp = UI.label("Read-only: the app loads the API key from auth.json into memory for usage requests. It never writes, copies, or logs the key. Run `cmd login` to connect; COMMAND_CODE_API_KEY in the app’s environment takes precedence.", size: 10, color: .secondaryLabelColor)
        commandCodeHelp.preferredMaxLayoutWidth = 558
        content.addArrangedSubview(commandCodeHelp)
        commandCodeStatus.preferredMaxLayoutWidth = 558
        content.addArrangedSubview(commandCodeStatus)
        updateCommandCodeStatus()
        content.addArrangedSubview(UI.divider())
        content.addArrangedSubview(UI.label("Claude Code (optional)", size: 13, weight: .semibold))
        claudeEnabled.target = self; claudeEnabled.action = #selector(toggleClaudeCode)
        claudeEnabled.state = draft.claudeCode.enabled ? .on : .off
        claudeEnabled.toolTip = "Reads Claude Code usage with the sign-in Claude Code already stored."
        content.addArrangedSubview(claudeEnabled)
        claudeKeychain.target = self; claudeKeychain.action = #selector(toggleClaudeCode)
        claudeKeychain.state = draft.claudeCode.useKeychain ? .on : .off
        claudeKeychain.toolTip = "Claude Code stores its OAuth credential in the login keychain. The app reads it; it never writes or refreshes it."
        claudeKeychainService.stringValue = draft.claudeCode.keychainService
        claudeKeychainService.font = .systemFont(ofSize: 11)
        claudeKeychainService.widthAnchor.constraint(equalToConstant: 220).isActive = true
        claudeKeychainService.toolTip = "Keychain service name. Claude Code uses “Claude Code-credentials”."
        content.addArrangedSubview(UI.stack([claudeKeychain, claudeKeychainService], vertical: false))
        claudePath.stringValue = draft.claudeCode.credentialsFile
        claudePath.font = .systemFont(ofSize: 11)
        claudePath.widthAnchor.constraint(equalToConstant: 436).isActive = true
        content.addArrangedSubview(UI.stack([claudePath, UI.button("Choose…", target: self, action: #selector(chooseClaudeCredentials))], vertical: false))
        let claudeHelp = UI.label("Read-only: the app reads Claude Code’s saved OAuth token to call the usage endpoint that Claude Code itself uses. It never refreshes, rewrites, copies, or logs the token. Token expiry is reported, not repaired: open Claude Code once so it refreshes. CLAUDE_CODE_OAUTH_TOKEN in the app’s environment takes precedence.", size: 10, color: .secondaryLabelColor)
        claudeHelp.preferredMaxLayoutWidth = 558
        content.addArrangedSubview(claudeHelp)
        claudeStatus.preferredMaxLayoutWidth = 558
        content.addArrangedSubview(claudeStatus)
        claudePath.isEnabled = draft.claudeCode.enabled
        claudeKeychain.isEnabled = draft.claudeCode.enabled
        claudeKeychainService.isEnabled = draft.claudeCode.enabled && draft.claudeCode.useKeychain
        updateClaudeStatus()
        content.addArrangedSubview(UI.divider())
        content.addArrangedSubview(UI.label("Menu bar", size: 13, weight: .semibold))
        let menuHelp = UI.label("Choose what the status item shows. The preview updates as you change these options and matches what will appear after Save & Refresh.", size: 10, color: .secondaryLabelColor)
        menuHelp.preferredMaxLayoutWidth = 558
        content.addArrangedSubview(menuHelp)
        content.addArrangedSubview(previewHolder)
        for button in [menuIcon, menuLabels, menuErrorMarker, menuOverflow, menuShowCommandCode, menuShowClaude] {
            button.target = self; button.action = #selector(updatePreview)
            content.addArrangedSubview(button)
        }
        menuIcon.state = draft.menuBar.showIcon ? .on : .off
        menuLabels.state = draft.menuBar.showLabels ? .on : .off
        menuErrorMarker.state = draft.menuBar.showErrorMarker ? .on : .off
        menuOverflow.state = draft.menuBar.showOverflow ? .on : .off
        menuShowCommandCode.state = draft.menuBar.showCommandCode ? .on : .off
        menuShowClaude.state = draft.menuBar.showClaudeCode ? .on : .off
        menuShowCommandCode.isEnabled = draft.commandCode.enabled
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
        }
        content.addArrangedSubview(UI.stack([UI.label("Codex windows"), codexMetric, UI.label("accounts"), codexAccountCount], vertical: false))
        content.addArrangedSubview(UI.stack([UI.label("Command Code windows"), commandCodeMetric], vertical: false))
        content.addArrangedSubview(UI.stack([UI.label("Claude Code windows"), claudeMetric], vertical: false))
        interval.stringValue = String(draft.refreshMinutes)
        interval.widthAnchor.constraint(equalToConstant: 45).isActive = true
        updatePreview()
        content.addArrangedSubview(UI.stack([UI.label("Refresh every"), interval, UI.label("minutes (1–60)")], vertical: false))
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launch.target = self; launch.action = #selector(changeLaunch)
        content.addArrangedSubview(launch)
        message.preferredMaxLayoutWidth = 558
        content.addArrangedSubview(message)
        content.addArrangedSubview(UI.stack([UI.button("Quit Codex Limits", target: self, action: #selector(quit)), UI.spacer(), UI.button("Save & Refresh", target: self, action: #selector(save))], vertical: false))
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 610, height: 600))
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            content.widthAnchor.constraint(equalToConstant: 558)
        ])
        let scroll = NSScrollView(frame: container.bounds)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document; scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll); self.scroll = scroll
        resizeContent(scrollToTop: true)
        updateStatus()
    }
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil); updateStatus()
    }
    func updateStatus() {
        for (index, button) in signInButtons.enumerated() {
            let slot = draft.accounts[index].slot
            button.title = monitor.states[slot]?.loginInProgress == true ? "Signing in…" : "Sign in…"
            let saved = monitor.settings.accounts.first { $0.slot == slot }
            button.isEnabled = !monitor.isBusy && saved != nil
        }
        let errors = monitor.settings.accounts.compactMap { account in monitor.states[account.slot]?.error.map { "\(account.slot): \($0)" } }
        message.stringValue = errors.joined(separator: "\n")
        if monitor.settings.commandCode.enabled, let error = monitor.commandCode.error {
            message.stringValue = (message.stringValue.isEmpty ? "" : message.stringValue + "\n") + "Command Code: " + error
        }
        if monitor.settings.claudeCode.enabled, let error = monitor.claudeCode.error {
            message.stringValue = (message.stringValue.isEmpty ? "" : message.stringValue + "\n") + "Claude Code: " + error
        }
        resizeContent()
    }
    private func resizeContent(scrollToTop: Bool = false) {
        guard let layout, let scroll, let document = scroll.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let height = max(300, layout.fittingSize.height + 48)
        document.setFrameSize(NSSize(width: 610, height: height))
        let visibleHeight = min(height, ((window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 80, 740)
        window?.setContentSize(NSSize(width: 610, height: visibleHeight))
        let offset = scrollToTop ? max(0, height - visibleHeight) : min(scroll.contentView.bounds.origin.y, max(0, height - visibleHeight))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, offset)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func captureDraft() -> Settings {
        var updated = draft
        for index in updated.accounts.indices {
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
        return updated
    }
    @objc private func addAccount() {
        guard !monitor.isBusy else { message.stringValue = "Wait for the current operation to finish."; return }
        draft = captureDraft(); draft.addAccount(root: monitor.store.root)
        build(); message.stringValue = "New account added. Save & Refresh, then Sign in."
    }
    @objc private func removeAccount(_ sender: NSButton) {
        guard !monitor.isBusy else { message.stringValue = "Wait for the current operation to finish."; return }
        let account = draft.accounts[sender.tag]
        let alert = NSAlert(); alert.messageText = "Remove account \(account.slot)?"
        alert.informativeText = "This removes the slot from monitoring after Save & Refresh. Its credential directory and stored credentials will not be deleted or logged out."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        draft = captureDraft(); draft.accounts.remove(at: sender.tag)
        build(); message.stringValue = "Account removed from this draft. Save & Refresh to apply."
    }
    @objc private func chooseHome(_ sender: NSButton) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Select an existing dedicated CODEX_HOME. It must not be used by another Codex client."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Use this home exclusively with Codex Limits?"
        alert.informativeText = "Stop using this directory in other Codex clients before continuing. Codex Limits lets the official CLI manage authentication here; it never duplicates tokens or edits auth.json."
        alert.addButton(withTitle: "Use Dedicated Home"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { homes[sender.tag].stringValue = url.path }
    }
    @objc private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "Choose the native Codex binary (official npm launchers are resolved to their native binary)."
        if panel.runModal() == .OK, let url = panel.url {
            if let native = CodexExecutable.nativePath(url.path) { executable.stringValue = native }
            else { message.stringValue = "No native Codex executable found at this location." }
        }
    }
    @objc private func toggleCommandCode() {
        commandCodePath.isEnabled = commandCodeEnabled.state == .on
        draft = captureDraft()
        updateCommandCodeStatus()
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
    @objc private func save() {
        let settings = captureDraft()
        do { try monitor.apply(settings); draft = settings; message.stringValue = "Settings saved."; updateStatus() }
        catch { message.stringValue = error.localizedDescription }
    }
    private func configure(metric popup: NSPopUpButton, select metric: UsageMetric) {
        popup.removeAllItems()
        for value in UsageMetric.allCases { popup.addItem(withTitle: value.title) }
        popup.selectItem(at: UsageMetric.allCases.firstIndex(of: metric) ?? 0)
    }
    private func selectedMetric(_ popup: NSPopUpButton) -> UsageMetric {
        let index = max(0, popup.indexOfSelectedItem)
        return UsageMetric.allCases[min(index, UsageMetric.allCases.count - 1)]
    }
    // Builds the same title the status item would show for the edited draft, using
    // the current live values so the preview reflects real numbers.
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
        for view in previewHolder.arrangedSubviews { previewHolder.removeArrangedSubview(view); view.removeFromSuperview() }
        previewHolder.addArrangedSubview(MenuBarPreviewView(title: draftPreviewTitle()))
        previewHolder.addArrangedSubview(UI.label("Preview · macOS menu bar", size: 10, color: .secondaryLabelColor))
        resizeContent()
    }
    @objc private func toggleClaudeCode() {
        claudePath.isEnabled = claudeEnabled.state == .on
        claudeKeychainService.isEnabled = claudeEnabled.state == .on && claudeKeychain.state == .on
        claudeKeychain.isEnabled = claudeEnabled.state == .on
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
        let keychain = claudeKeychain.state == .on
        if keychain {
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
    @objc private func signIn(_ sender: NSButton) {
        let account = draft.accounts[sender.tag]
        guard let saved = monitor.settings.accounts.first(where: { $0.slot == account.slot }),
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
        } catch { launch.state = SMAppService.mainApp.status == .enabled ? .on : .off; message.stringValue = "Launch at login: \(error.localizedDescription)" }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
