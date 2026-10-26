import AppKit
import LimitsCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var controller: PopoverController!
    private var settingsController: SettingsController?
    private var monitor: UsageMonitor!
    private var appLease: HomeLease?
    private var smokeRoot: URL?
    private var presentationPending = false
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let uiSmokeTest = CommandLine.arguments.contains("--ui-smoke-test") || CommandLine.arguments.contains("--ui-mouse-test")
        if uiSmokeTest { unsetenv("COMMAND_CODE_API_KEY") }
        let root: URL
        if uiSmokeTest {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexLimits-UI-" + UUID().uuidString)
            smokeRoot = root
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Limits")
        }
        do { appLease = try HomeLease(home: root.path) } catch { NSApp.terminate(nil); return }
        let store = SettingsStore(root: root)
        let settings: Settings
        do {
            var loaded = try store.load(defaultCodex: CodexExecutable.discover())
            if uiSmokeTest {
                for _ in 0..<3 { loaded.addAccount(root: root) }
                loaded.commandCode = CommandCodeConfiguration(enabled: true, authFile: root.appendingPathComponent("no-command-code-auth.json").path)
            }
            settings = loaded
        }
        catch {
            let alert = NSAlert(); alert.messageText = "Settings could not be read"
            alert.informativeText = "Fix or move \(root.appendingPathComponent("settings.json").path), then restart. Existing settings were not overwritten."
            alert.runModal(); NSApp.terminate(nil); return
        }
        // A damaged settings file must not cause out-of-bounds UI access.
        do { try settings.validateAccountSlots() } catch {
            let alert = NSAlert(); alert.messageText = "Invalid account settings"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return
        }
        monitor = UsageMonitor(settings: settings, store: store, backgroundEvents: !uiSmokeTest)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Codex Limits")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Codex Limits", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu; menu.addItem(appItem)
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self; button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        monitor.onChange = { [weak self] in self?.update() }
        update()
        if uiSmokeTest { runPopoverSmokeTest(); return }
        monitor.start()
        if settings.codexPath.isEmpty && !settings.commandCode.enabled { showSettings() }
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover() }
        }
    }
    private func update() {
        let codexParts = monitor.settings.accounts.map { account -> String in
            let state = monitor.states[account.slot]!
            let number = state.snapshot?.usage.codex?.fiveHour.map { "\($0.remaining)%" } ?? "—"
            return "\(account.slot): \(number)\(state.error == nil ? "" : "!")"
        }
        var parts = Array(codexParts.prefix(3))
        let overflow = codexParts.count > 3 ? " · +\(codexParts.count - 3)" : ""
        if monitor.settings.commandCode.enabled {
            let state = monitor.commandCode
            let number = state.snapshot?.menuBarRemaining.map { "\($0)%" } ?? "—"
            parts.append("CC: \(number)\(state.error == nil ? "" : "!")")
        }
        let title = parts.isEmpty ? "◈ Codex Limits" : "◈ " + parts.joined(separator: " · ") + overflow
        statusItem.button?.title = title
        statusItem.button?.toolTip = "Codex Limits · remaining 5-hour allowance; CC is Command Code. ! means stale/error. Click for details."
        statusItem.button?.setAccessibilityLabel("Codex Limits, " + parts.joined(separator: ", "))
        if popover?.isShown == true { controller.render() }
        settingsController?.updateStatus()
    }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.type == .rightMouseUp { showSettings(); return }
        guard !presentationPending else { return }
        if popover == nil {
            controller = PopoverController(monitor: monitor)
            controller.refreshOnOpen = smokeRoot == nil
            controller.openSettings = { [weak self] in self?.showSettings() }
            controller.onSizeChange = { [weak self] size in self?.popover?.contentSize = size }
            popover = NSPopover(); popover.behavior = .applicationDefined; popover.animates = false
            popover.delegate = self; popover.contentViewController = controller
            _ = controller.view
            popover.contentSize = controller.preferredContentSize
        }
        if popover.isShown { popover.close() }
        else {
            // Finish the status-button mouse event before presenting the popover.
            // Avoid activation during the triggering click's focus handling.
            presentationPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentationPending = false
                guard let button = self.statusItem.button else { return }
                self.popover.contentSize = self.controller.preferredContentSize
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.popover.contentSize = self.controller.preferredContentSize
                self.popover.contentViewController?.view.window?.makeKey()
                self.installDismissalMonitors()
            }
        }
    }
    private func installDismissalMonitors() {
        removeDismissalMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isInsidePopoverOrStatusItem(NSEvent.mouseLocation) else { return }
                self.popover?.close()
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            var consume = false
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.popover?.close(); consume = true }
                } else if !self.isInsidePopoverOrStatusItem(NSEvent.mouseLocation) {
                    self.popover.close()
                }
            }
            return consume ? nil : event
        }
    }
    private func isInsidePopoverOrStatusItem(_ point: NSPoint) -> Bool {
        if let button = statusItem.button, let window = button.window {
            let bounds = window.convertToScreen(button.convert(button.bounds, to: nil))
            if bounds.contains(point) { return true }
        }
        return popover.contentViewController?.view.window?.frame.contains(point) == true
    }
    private func removeDismissalMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        outsideClickMonitor = nil; localEventMonitor = nil
    }
    func popoverDidClose(_ notification: Notification) { removeDismissalMonitors() }
    @objc private func showSettings() {
        popover?.close()
        if settingsController == nil { settingsController = SettingsController(monitor: monitor) }
        settingsController?.present()
    }
    private func runPopoverSmokeTest() {
        let realMouse = CommandLine.arguments.contains("--ui-mouse-test")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            guard let button = statusItem.button, let action = button.action else {
                fputs("UI smoke: status button action is not connected\n", stderr); exit(1)
            }
            @MainActor func click() {
                if realMouse {
                    guard CGPreflightPostEventAccess(), let window = button.window else {
                        fputs("UI mouse test requires event-posting permission\n", stderr); exit(2)
                    }
                    let local = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    let screen = window.convertPoint(toScreen: local)
                    let point = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
                    // Let the target display's menu bar settle after pointer movement.
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let settled = window.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
                        let point = CGPoint(x: settled.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - settled.y)
                        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        }
                    }
                } else if !NSApp.sendAction(action, to: button.target, from: button) {
                    fputs("UI smoke: status button action is not connected\n", stderr); exit(1)
                }
            }
            click()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                guard popover?.isShown == true, controller.view.window?.isVisible == true else {
                    fputs("UI smoke: left-click action did not show a visible popover; created=\(popover != nil), shown=\(popover?.isShown == true), buttonWindow=\(String(describing: button.window?.frame)), mouse=\(NSEvent.mouseLocation)\n", stderr); exit(1)
                }
                let accountViews = findViews(in: controller.view).compactMap { $0 as? AccountView }
                guard controller.view.bounds.width >= 344, popover.contentSize.width >= 344,
                      controller.view.window!.frame.width >= 344 else {
                    fputs("UI smoke: popover width collapsed: view=\(controller.view.bounds), content=\(popover.contentSize), window=\(controller.view.window!.frame)\n", stderr); exit(1)
                }
                guard accountViews.count == monitor.settings.accounts.count, accountViews.allSatisfy({ $0.frame.height > 100 }) else {
                    fputs("UI smoke: account content is missing or has collapsed layout\n", stderr); exit(1)
                }
                guard let commandCodeView = findViews(in: controller.view).compactMap({ $0 as? CommandCodeView }).first,
                      commandCodeView.frame.height > 40 else {
                    fputs("UI smoke: Command Code card is missing or has collapsed layout\n", stderr); exit(1)
                }
                if let index = CommandLine.arguments.firstIndex(of: "--ui-snapshot"), CommandLine.arguments.count > index + 1,
                   let image = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                    controller.view.cacheDisplay(in: controller.view.bounds, to: image)
                    try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
                if let index = CommandLine.arguments.firstIndex(of: "--ui-command-code-snapshot"), CommandLine.arguments.count > index + 1,
                   let image = commandCodeView.bitmapImageRepForCachingDisplay(in: commandCodeView.bounds) {
                    commandCodeView.cacheDisplay(in: commandCodeView.bounds, to: image)
                    try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
                controller.render() // Exercise the normal refresh/render path while visible.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    guard popover.isShown else { fputs("UI smoke: popover closed during refresh\n", stderr); exit(1) }
                    click()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                        guard !popover.isShown else { fputs("UI smoke: second click did not close popover\n", stderr); exit(1) }
                        showSettings()
                        guard let window = settingsController?.window, window.isVisible,
                              let content = window.contentView,
                              let add = findViews(in: content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "+ Add Account" }) else {
                            fputs("UI smoke: Settings/Add Account is not visible\n", stderr); exit(1)
                        }
                        if let index = CommandLine.arguments.firstIndex(of: "--ui-settings-snapshot"), CommandLine.arguments.count > index + 1,
                           let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                            content.cacheDisplay(in: content.bounds, to: image)
                            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                        }
                        add.performClick(nil)
                        let loginButtons = findViews(in: content).compactMap { $0 as? NSButton }.filter { $0.title == "Sign in…" }
                        guard loginButtons.count == monitor.settings.accounts.count + 1, loginButtons.last?.isEnabled == false else {
                            fputs("UI smoke: added account draft is missing or can sign in before save\n", stderr); exit(1)
                        }
                        print("UI \(realMouse ? "mouse-event" : "action") test: show, account content, refresh, click-to-close, Settings, and Add Account passed; no account requests sent")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
    private func findViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { findViews(in: $0) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        removeDismissalMonitors()
        monitor?.stop()
        if let smokeRoot { appLease = nil; try? FileManager.default.removeItem(at: smokeRoot) }
    }
}

// Read-only protocol smoke test; never performs login or inference.
if CommandLine.arguments.contains("--command-code-probe"),
   let index = CommandLine.arguments.firstIndex(of: "--auth"), CommandLine.arguments.count > index + 1 {
    let authFile = CommandLine.arguments[index + 1]
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { semaphore.signal() }
        do {
            let snapshot = try await CommandCodeClient.shared.read(authFile: authFile)
            print("Command Code account connected; usage response decoded. Identity not printed.")
            print("Plan: \(snapshot.planName ?? "unknown")")
            print("5-hour remaining: \(snapshot.windowLimits?.fiveHour?.remaining.map(String.init) ?? "unavailable")")
            print("Weekly remaining: \(snapshot.windowLimits?.weekly?.remaining.map(String.init) ?? "unavailable")")
            print("Monthly remaining: \(snapshot.monthlyRemainingPercent.map(String.init) ?? "unavailable")")
            exit(0)
        } catch let failure as CommandCodeFailure {
            fputs("\(failure.localizedDescription)\n", stderr)
            exit(failure.isTransient ? 2 : 1)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    semaphore.wait()
} else if CommandLine.arguments.contains("--probe"), let index = CommandLine.arguments.firstIndex(of: "--home"), CommandLine.arguments.count > index + 1 {
    let home = CommandLine.arguments[index + 1]
    do {
        let snapshot = try CodexClient().read(account: AccountConfiguration(slot: "A", name: "Probe", home: home), executable: CodexExecutable.discover())
        print("ChatGPT account connected; usage response decoded. Identity not printed.")
        print("5-hour remaining: \(snapshot.usage.codex?.fiveHour?.remaining.description ?? "unavailable")")
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(error is ClientFailure && (error as? ClientFailure)?.isTransient == true ? 2 : 1)
    }
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
