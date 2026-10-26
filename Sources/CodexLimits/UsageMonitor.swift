import AppKit
import Network
import LimitsCore

@MainActor
final class UsageMonitor {
    struct State {
        var snapshot: AccountSnapshot?
        var error: String?
        var retry = RetryState()
        var loginInProgress = false
        var resetInProgress = false
        var resetMessage: String?
    }
    struct CommandCodeState {
        var snapshot: CommandCodeSnapshot?
        var error: String?
        var notConnected = false
        var retry = RetryState()
    }
    var settings: Settings
    let store: SettingsStore
    var states: [String: State]
    var commandCode = CommandCodeState()
    var onChange: (() -> Void)?
    private let worker = DispatchQueue(label: "CodexLimits.rpc", qos: .utility)
    private let network = NWPathMonitor()
    private var timer: Timer?
    private var inFlight = false
    private var sleeping = false
    private var online = true
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var resetSlot: String?

    init(settings: Settings, store: SettingsStore, backgroundEvents: Bool = true) {
        self.settings = settings; self.store = store
        states = Dictionary(uniqueKeysWithValues: settings.accounts.map { ($0.slot, State()) })
        guard backgroundEvents else { return }
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.online
                self.online = path.status == .satisfied
                if self.online && !wasOnline { self.refreshIfStale() }
                self.schedule()
                self.onChange?()
            }
        }
        network.start(queue: DispatchQueue(label: "CodexLimits.network", qos: .utility))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.timer?.invalidate(); CodexClient.cancelAll(); CommandCodeClient.cancelAll() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.refreshIfStale(); self?.schedule() }
        })
    }
    var interval: TimeInterval { Double(settings.refreshMinutes) * 60 }
    var isRefreshing: Bool { inFlight }
    var isBusy: Bool { inFlight || resetSlot != nil || states.values.contains(where: \.loginInProgress) }
    var isOffline: Bool { !online }
    var connectedCount: Int {
        states.values.filter { $0.snapshot != nil && $0.error == nil }.count
    }
    var commandCodeConnected: Bool { commandCode.snapshot != nil && commandCode.error == nil }
    private func commandCodeDue(now: Date = Date()) -> Bool {
        guard settings.commandCode.enabled else { return false }
        if commandCode.error != nil { return commandCode.retry.due(now: now) }
        if commandCode.notConnected { return true }
        return commandCode.snapshot.map { now.timeIntervalSince($0.fetchedAt) >= interval } ?? true
    }
    func start() { refresh(manual: true) }
    func apply(_ newSettings: Settings) throws {
        guard !isBusy else {
            throw ClientFailure.configuration("Wait for the current refresh, sign-in, or reset confirmation to finish before saving.")
        }
        try store.save(newSettings)
        settings = newSettings; generation += 1
        states = Dictionary(uniqueKeysWithValues: settings.accounts.map { ($0.slot, State()) })
        commandCode = CommandCodeState()
        refresh(manual: true)
    }
    func refreshIfStale() {
        let now = Date()
        if states.values.contains(where: { $0.snapshot.map { now.timeIntervalSince($0.fetchedAt) >= interval } ?? true })
            || commandCodeDue(now: now) {
            refresh(manual: false)
        }
    }
    func refresh(manual: Bool) {
        guard !isBusy, !sleeping, online else { schedule(); return }
        do { try settings.validate() } catch {
            for account in settings.accounts { states[account.slot]?.error = error.localizedDescription }
            if settings.commandCode.enabled { commandCode.error = error.localizedDescription }
            timer?.invalidate(); onChange?(); return
        }
        let now = Date()
        let accounts = settings.accounts.filter { account in
            let state = states[account.slot]!
            guard !state.loginInProgress else { return false }
            if manual { return true }
            if state.error != nil { return state.retry.due(now: now) }
            return state.snapshot.map { now.timeIntervalSince($0.fetchedAt) >= interval } ?? true
        }
        let shouldRefreshCommandCode = settings.commandCode.enabled && (manual || commandCodeDue(now: now))
        guard !accounts.isEmpty || shouldRefreshCommandCode else { schedule(); return }
        inFlight = true; timer?.invalidate(); onChange?()
        let executable = settings.codexPath, version = generation
        Task {
            for account in accounts {
                let result: Result<AccountSnapshot, ClientFailure> = await withCheckedContinuation { continuation in
                    worker.async {
                        autoreleasepool {
                            do { continuation.resume(returning: .success(try CodexClient().read(account: account, executable: executable))) }
                            catch { continuation.resume(returning: .failure(error as? ClientFailure ?? .protocolError)) }
                        }
                    }
                }
                guard version == generation else { continue }
                switch result {
                case .success(let snapshot):
                    states[account.slot]?.snapshot = snapshot
                    states[account.slot]?.error = nil
                    states[account.slot]?.retry.succeeded()
                case .failure(let error):
                    states[account.slot]?.error = error.localizedDescription
                    states[account.slot]?.retry.failed(error, now: Date(), interval: interval)
                }
                verifyIsolation()
                onChange?()
            }
            if shouldRefreshCommandCode, version == generation { await refreshCommandCode(version: version) }
            inFlight = false; schedule(); onChange?()
        }
    }
    private func refreshCommandCode(version: Int) async {
        let configuration = settings.commandCode
        guard configuration.enabled else { return }
        do {
            let snapshot = try await CommandCodeClient.shared.read(authFile: configuration.authFile)
            guard version == generation, settings.commandCode == configuration else { return }
            commandCode.snapshot = snapshot
            commandCode.error = nil
            commandCode.notConnected = false
            commandCode.retry.succeeded()
        } catch let failure as CommandCodeFailure {
            guard version == generation, settings.commandCode == configuration else { return }
            if case .notConnected = failure {
                commandCode.snapshot = nil
                commandCode.error = nil
                commandCode.notConnected = true
                commandCode.retry.succeeded()
            } else {
                commandCode.error = failure.localizedDescription
                commandCode.notConnected = false
                commandCode.retry.failed(isTransient: failure.isTransient, now: Date(), interval: interval)
            }
        } catch {
            guard version == generation, settings.commandCode == configuration else { return }
            commandCode.error = error.localizedDescription
            commandCode.notConnected = false
            commandCode.retry.failed(isTransient: false, now: Date(), interval: interval)
        }
        onChange?()
    }
    private func verifyIsolation() {
        let snapshots = settings.accounts.compactMap { account in
            states[account.slot]?.snapshot.map { (slot: account.slot, snapshot: $0) }
        }
        for (slot, message) in AccountIsolation.duplicateSlots(snapshots) {
            states[slot]?.snapshot = nil
            states[slot]?.error = message
            states[slot]?.retry.failed(.authentication(message), now: Date(), interval: interval)
        }
    }
    func login(slot: String) {
        guard !isBusy,
              let account = settings.accounts.first(where: { $0.slot == slot }) else { return }
        do { try settings.validate() } catch { states[slot]?.error = error.localizedDescription; onChange?(); return }
        states[slot]?.loginInProgress = true; onChange?()
        timer?.invalidate()
        let executable = settings.codexPath
        worker.async { [weak self] in
            let result: Result<Void, ClientFailure>
            do {
                try CodexClient().login(account: account, executable: executable) { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                result = .success(())
            } catch { result = .failure(error as? ClientFailure ?? .protocolError) }
            Task { @MainActor in
                guard let self else { return }
                self.states[slot]?.loginInProgress = false
                switch result {
                case .success:
                    self.states[slot] = State()
                    self.refresh(manual: true)
                case .failure(let error):
                    self.states[slot]?.error = error.localizedDescription
                    self.states[slot]?.retry.failed(error, now: Date(), interval: self.interval)
                }
                self.schedule(); self.onChange?()
            }
        }
    }
    func beginResetConfirmation(slot: String, creditId: String) throws -> ResetSelection {
        guard !isBusy, !sleeping, online else {
            throw ResetFailure.notSubmitted("Wait for the current operation to finish and check your connection.")
        }
        try settings.validate()
        guard let account = settings.accounts.first(where: { $0.slot == slot }),
              let state = states[slot], state.error == nil, let snapshot = state.snapshot else {
            throw ResetFailure.notSubmitted("Refresh and verify this account first.")
        }
        let selection = try ResetSelection(account: account, snapshot: snapshot, creditId: creditId)
        resetSlot = slot
        states[slot]?.resetInProgress = true
        states[slot]?.resetMessage = nil
        timer?.invalidate(); onChange?()
        return selection
    }
    func finishResetConfirmation(_ selection: ResetSelection, confirmed: Bool, completion: ((String) -> Void)? = nil) {
        guard resetSlot == selection.account.slot else { return }
        let slot = selection.account.slot
        guard confirmed, !sleeping, online else {
            states[slot]?.resetInProgress = false
            resetSlot = nil; schedule(); onChange?()
            return
        }
        let executable = settings.codexPath
        let attempts = ResetAttemptStore(root: store.root)
        worker.async { [weak self] in
            let result: Result<ResetResult, Error> = autoreleasepool {
                do {
                    guard let response = try CodexClient().redeem(selection: selection, confirmed: true, store: attempts, executable: executable) else {
                        return .failure(ResetFailure.notSubmitted("Confirmation was cancelled."))
                    }
                    return .success(response)
                } catch { return .failure(error) }
            }
            Task { @MainActor in
                guard let self else { return }
                self.states[slot]?.resetInProgress = false
                self.resetSlot = nil
                switch result {
                case .success(let response):
                    self.states[slot]?.resetMessage = response.outcome.message + (response.warning.map { " " + $0 } ?? "")
                    if let snapshot = response.snapshot {
                        self.states[slot]?.snapshot = snapshot
                        self.states[slot]?.error = nil
                        self.states[slot]?.retry.succeeded()
                        self.verifyIsolation()
                        self.schedule(); self.onChange?()
                    } else {
                        self.states[slot]?.snapshot = nil
                        self.refresh(manual: true)
                    }
                case .failure(let error):
                    self.states[slot]?.resetMessage = error.localizedDescription
                    // Recovery refreshes are read-only. Never resend the mutation here.
                    self.states[slot]?.snapshot = nil
                    self.refresh(manual: true)
                }
                self.onChange?()
                completion?(self.states[slot]?.resetMessage ?? "Check Open Usage to verify the reset result.")
            }
        }
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard online, !sleeping, !isBusy else { return }
        var allDates = settings.accounts.map { account -> Date in
            let state = states[account.slot]!
            if state.error != nil { return state.retry.nextAttempt ?? .distantFuture }
            return state.snapshot?.fetchedAt.addingTimeInterval(interval) ?? Date().addingTimeInterval(interval)
        }
        if settings.commandCode.enabled {
            if commandCode.error != nil {
                allDates.append(commandCode.retry.nextAttempt ?? .distantFuture)
            } else if commandCode.notConnected {
                allDates.append(Date().addingTimeInterval(interval))
            } else {
                allDates.append(commandCode.snapshot?.fetchedAt.addingTimeInterval(interval) ?? Date())
            }
        }
        guard let date = allDates.min(), date != .distantFuture else { return }
        let timer = Timer(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh(manual: false) }
        }
        timer.tolerance = 5
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        timer?.invalidate(); network.cancel()
        CodexClient.cancelAll()
        CommandCodeClient.cancelAll()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
