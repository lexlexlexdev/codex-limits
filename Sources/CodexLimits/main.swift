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
                loaded.claudeCode = ClaudeCodeConfiguration(enabled: true, useKeychain: false,
                    credentialsFile: root.appendingPathComponent("no-claude-credentials.json").path)
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
        if settings.codexPath.isEmpty && !settings.commandCode.enabled && !settings.claudeCode.enabled { showSettings() }
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover() }
        }
    }
    private func update() {
        let text = monitor.menuBarTitle()
        statusItem.button?.title = text.title
        statusItem.button?.toolTip = text.toolTip
        statusItem.button?.setAccessibilityLabel(text.accessibilityLabel)
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
                guard let claudeView = findViews(in: controller.view).compactMap({ $0 as? ClaudeCodeView }).first,
                      claudeView.frame.height > 40 else {
                    fputs("UI smoke: Claude Code card is missing or has collapsed layout\n", stderr); exit(1)
                }
                guard findViews(in: controller.view).compactMap({ $0 as? MenuBarPreviewView }).isEmpty else {
                    fputs("UI smoke: the popover must not show the menu bar preview\n", stderr); exit(1)
                }
                writeSnapshot(claudeView, flag: "--ui-claude-snapshot")
                writeSnapshot(controller.view, flag: "--ui-snapshot")
                writeSnapshot(commandCodeView, flag: "--ui-command-code-snapshot")
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
                        writeSnapshot(content, flag: "--ui-settings-snapshot")
                        guard let settingsDocument = findViews(in: content).compactMap({ $0 as? NSScrollView }).first?.documentView else {
                            fputs("UI smoke: Settings document is missing\n", stderr); exit(1)
                        }
                        writeSnapshot(settingsDocument, flag: "--ui-settings-document-snapshot")
                        let documentViews = findViews(in: settingsDocument)
                        guard let settingsPreview = documentViews.compactMap({ $0 as? MenuBarPreviewView }).first else {
                            fputs("UI smoke: Settings menu bar preview is missing\n", stderr); exit(1)
                        }
                        let buttons = documentViews.compactMap { $0 as? NSButton }
                        let checkboxes = Set(buttons.map(\.title))
                        guard buttons.contains(where: { $0.title == "Monitor Claude Code" }) else {
                            fputs("UI smoke: Claude Code settings section is missing\n", stderr); exit(1)
                        }
                        guard checkboxes.contains("Show ◈ icon"), checkboxes.contains("Show provider labels"),
                              checkboxes.contains("Include Claude Code"), checkboxes.contains("Include Command Code") else {
                            fputs("UI smoke: menu bar visibility checkboxes are missing\n", stderr); exit(1)
                        }
                        guard documentViews.compactMap({ $0 as? NSPopUpButton }).count >= 4 else {
                            fputs("UI smoke: menu bar window/account pickers are missing\n", stderr); exit(1)
                        }
                        let beforeLabels = settingsPreview.title
                        print("UI smoke menu bar preview: \(beforeLabels)")
                        if let labels = buttons.first(where: { $0.title == "Show provider labels" }) {
                            // performClick flips a switch button's state and sends its action.
                            labels.performClick(nil)
                        }
                        guard let updatedPreview = findViews(in: settingsDocument).compactMap({ $0 as? MenuBarPreviewView }).first,
                              updatedPreview.title != beforeLabels else {
                            fputs("UI smoke: menu bar preview did not update when labels were toggled\n", stderr); exit(1)
                        }
                        guard let commandLabelField = documentViews.compactMap({ $0 as? NSTextField })
                                  .first(where: { $0.identifier?.rawValue == "menu-bar-label-command-code" }) else {
                            fputs("UI smoke: Command Code menu bar label field is missing\n", stderr); exit(1)
                        }
                        // Turn labels back on so the renamed provider is actually visible.
                        buttons.first(where: { $0.title == "Show provider labels" })?.performClick(nil)
                        commandLabelField.stringValue = "renamed"
                        commandLabelField.sendAction(commandLabelField.action, to: commandLabelField.target)
                        guard let renamedPreview = findViews(in: settingsDocument).compactMap({ $0 as? MenuBarPreviewView }).first,
                              renamedPreview.title.contains("renamed:") else {
                            fputs("UI smoke: renaming a provider did not update the preview: \(findViews(in: settingsDocument).compactMap({ $0 as? MenuBarPreviewView }).first?.title ?? "none")\n", stderr); exit(1)
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
    // cacheDisplay skips NSTextField text for offscreen views, so snapshots are rendered
    // as PDF (which includes text) and written next to a raster copy for inspection.
    private func writeSnapshot(_ view: NSView, flag: String) {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > index + 1,
              view.bounds.width > 1, view.bounds.height > 1 else { return }
        let path = CommandLine.arguments[index + 1]
        try? view.dataWithPDF(inside: view.bounds).write(to: URL(fileURLWithPath: path))
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
if CommandLine.arguments.contains("--claude-probe") {
    let service = CommandLine.arguments.firstIndex(of: "--keychain").flatMap { index in
        CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
    } ?? ClaudeCodeClient.defaultKeychainService
    let file = CommandLine.arguments.firstIndex(of: "--credentials").flatMap { index in
        CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
    } ?? ClaudeCodeConfiguration.defaultCredentialsFile
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { semaphore.signal() }
        do {
            let configuration = ClaudeCodeConfiguration(enabled: true, useKeychain: true, keychainService: service, credentialsFile: file)
            let snapshot = try await ClaudeCodeClient.shared.read(configuration: configuration)
            print("Claude Code account connected; usage response decoded. Identity not printed.")
            print("Plan: \(snapshot.planName ?? "unknown")")
            print("5-hour remaining: \(snapshot.fiveHour?.remaining.map(String.init) ?? "unavailable")")
            print("Weekly remaining: \(snapshot.weekly?.remaining.map(String.init) ?? "unavailable")")
            exit(0)
        } catch let failure as ClaudeCodeFailure {
            fputs("\(failure.localizedDescription)\n", stderr)
            exit(failure.isTransient ? 2 : 1)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    semaphore.wait()
} else if CommandLine.arguments.contains("--command-code-probe"),
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
