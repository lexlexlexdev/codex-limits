import AppKit
import LimitsCore

@MainActor
final class PopoverController: NSViewController {
    let monitor: UsageMonitor
    var openSettings: (() -> Void)?
    var onSizeChange: ((NSSize) -> Void)?
    private var expanded: Set<String>
    private var countdownTimer: Timer?
    var refreshOnOpen = true
    init(monitor: UsageMonitor) {
        self.monitor = monitor; expanded = Set(monitor.settings.accounts.map(\.slot))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let root = UI.stack([], spacing: 0)
        root.frame = NSRect(x: 0, y: 0, width: 344, height: 620)
        view = root
        render()
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        if refreshOnOpen { monitor.refreshIfStale() }
        render()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        countdownTimer?.tolerance = 5
    }
    override func viewDidDisappear() { super.viewDidDisappear(); countdownTimer?.invalidate(); countdownTimer = nil }
    func render() {
        guard isViewLoaded else { return }
        guard let root = view as? NSStackView else { return }
        for child in root.arrangedSubviews { root.removeArrangedSubview(child); child.removeFromSuperview() }
        let refresh = UI.button("↻", target: self, action: #selector(refreshNow))
        refresh.toolTip = "Refresh all accounts"; refresh.isEnabled = !monitor.isBusy
        refresh.setAccessibilityLabel("Refresh usage")
        let settings = UI.button("Settings…", target: self, action: #selector(settingsNow))
        settings.toolTip = "Open Settings (⌘,)"
        settings.setAccessibilityLabel("Settings")
        let header = UI.stack([UI.label("◈ Codex Limits", size: 15, weight: .semibold), UI.spacer(), refresh, settings], vertical: false)
        header.widthAnchor.constraint(equalToConstant: 312).isActive = true
        var summary = monitor.settings.accounts.isEmpty ? "No Codex accounts" : "\(monitor.connectedCount) of \(monitor.settings.accounts.count) Codex accounts connected"
        if monitor.settings.commandCode.enabled {
            if monitor.commandCodeConnected {
                summary += " · Command Code connected"
            } else if monitor.commandCode.notConnected || !monitor.settings.commandCode.hasCredential {
                summary += " · Command Code not connected"
            } else if monitor.commandCode.error != nil {
                summary += " · Command Code needs attention"
            } else {
                summary += " · Command Code checking"
            }
        }
        let content = UI.stack([UI.label(summary, size: 11, color: .secondaryLabelColor), UI.divider()], spacing: 10)
        if monitor.settings.accounts.isEmpty {
            content.addArrangedSubview(UI.label("No Codex accounts configured. Use Settings → Add Account.", color: .secondaryLabelColor))
        }
        for configuration in monitor.settings.accounts {
            content.addArrangedSubview(AccountView(configuration: configuration, state: monitor.states[configuration.slot]!, expanded: expanded.contains(configuration.slot), canRedeem: !monitor.isBusy && !monitor.isOffline, toggleTarget: self, toggleAction: #selector(toggleResets(_:)), redeemAction: #selector(applyReset(_:))))
            content.addArrangedSubview(UI.divider())
        }
        if monitor.settings.commandCode.enabled {
            content.addArrangedSubview(CommandCodeView(configuration: monitor.settings.commandCode, state: monitor.commandCode, target: self, openAction: #selector(openCommandCode)))
        }
        let last = (monitor.states.values.compactMap { $0.snapshot?.fetchedAt } + [monitor.commandCode.snapshot?.fetchedAt].compactMap { $0 }).min()
        let footer: String
        if monitor.isOffline { footer = "● Offline · last successful data shown" }
        else if monitor.isRefreshing { footer = "● Updating…" }
        else if let last {
            let minutes = max(0, Int(Date().timeIntervalSince(last) / 60))
            footer = minutes == 0 ? "● Updated just now" : "● Updated \(minutes)m ago"
        } else { footer = "● Configure accounts in Settings" }
        content.addArrangedSubview(UI.label(footer, size: 10, color: .secondaryLabelColor))
        let bottom = UI.stack([UI.label("Refresh every \(monitor.settings.refreshMinutes) min", size: 10, color: .secondaryLabelColor), UI.spacer(), UI.button("Codex usage ↗", target: self, action: #selector(openUsage))], vertical: false)
        bottom.widthAnchor.constraint(equalToConstant: 312).isActive = true
        content.addArrangedSubview(bottom)
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: 312).isActive = true
        // Long banks scroll instead of producing oversized cards or offscreen popovers.
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = NSView()
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14)
        ])
        document.layoutSubtreeIfNeeded()
        let height = max(400, content.fittingSize.height + 28)
        document.frame = NSRect(x: 0, y: 0, width: 344, height: height)
        scroll.documentView = document
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let headerHeight: CGFloat = 48
        let visibleHeight = min(height + headerHeight, screenHeight - 80, 760)
        preferredContentSize = NSSize(width: 344, height: visibleHeight)
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.widthAnchor.constraint(equalToConstant: 344),
            toolbar.heightAnchor.constraint(equalToConstant: headerHeight),
            scroll.widthAnchor.constraint(equalToConstant: 344),
            scroll.heightAnchor.constraint(equalToConstant: visibleHeight - headerHeight)
        ])
        header.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            header.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
        let separator = UI.divider()
        separator.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            separator.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        ])
        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(scroll)
        root.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - (visibleHeight - headerHeight))))
        scroll.reflectScrolledClipView(scroll.contentView)
        onSizeChange?(NSSize(width: 344, height: visibleHeight))
    }
    @objc private func refreshNow() { monitor.refresh(manual: true) }
    @objc private func settingsNow() { openSettings?() }
    @objc private func toggleResets(_ sender: NSButton) {
        guard let slot = sender.identifier?.rawValue else { return }
        if expanded.contains(slot) { expanded.remove(slot) } else { expanded.insert(slot) }
        render()
    }
    @objc private func applyReset(_ sender: ResetButton) {
        let selection: ResetSelection
        do { selection = try monitor.beginResetConfirmation(slot: sender.slot, creditId: sender.creditId) }
        catch {
            let alert = NSAlert(); alert.messageText = "Cannot apply reset"; alert.informativeText = error.localizedDescription
            alert.runModal(); return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apply this banked reset?"
        let expiration = selection.credit.expiration.map { "Expires \(DisplayTime.absolute($0)) (\(TimeZone.current.abbreviation() ?? "local time"))" } ?? "No expiration"
        alert.informativeText = "Account \(selection.account.slot) · \(selection.account.name)\n\(selection.email)\n\(expiration)\n\nThis uses one saved reset to refresh eligible 5-hour and weekly limits. Your weekly reset date may change. It cannot be undone. No credits or resets will be purchased.\n\nThe account and this reset will be checked again before applying. There are no automatic retries; an uncertain retry of this same reset reuses its saved request key."
        alert.addButton(withTitle: "Cancel")
        let apply = alert.addButton(withTitle: "Apply Reset")
        apply.keyEquivalent = "" // Return defaults to Cancel, never an irreversible action.
        let confirmed = alert.runModal() == .alertSecondButtonReturn
        monitor.finishResetConfirmation(selection, confirmed: confirmed) { message in
            let result = NSAlert()
            result.messageText = "Account \(selection.account.slot) · Banked reset result"
            result.informativeText = message
            result.runModal()
        }
    }
    @objc private func openUsage() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!) }
    @objc private func openCommandCode() { NSWorkspace.shared.open(URL(string: "https://commandcode.ai/usage")!) }
}
