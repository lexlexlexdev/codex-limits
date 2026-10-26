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
        names.removeAll(); homes.removeAll(); signInButtons.removeAll()
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
        interval.stringValue = String(draft.refreshMinutes)
        interval.widthAnchor.constraint(equalToConstant: 45).isActive = true
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
