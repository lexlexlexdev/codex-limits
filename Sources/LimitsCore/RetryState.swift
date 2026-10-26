import Foundation

public struct RetryState: Sendable {
    public private(set) var failures = 0
    public private(set) var nextAttempt: Date?
    public init() {}
    public mutating func succeeded() { failures = 0; nextAttempt = nil }
    public mutating func failed(_ error: ClientFailure, now: Date, interval: TimeInterval) {
        failed(isTransient: error.isTransient, now: now, interval: interval)
    }
    public mutating func failed(isTransient: Bool, now: Date, interval: TimeInterval) {
        failures += 1
        if !isTransient { nextAttempt = .distantFuture; return }
        // Three bounded recovery attempts, then return to ordinary polling. No retry loop.
        let delay = failures <= 3 ? min(interval, 30 * pow(2, Double(failures - 1))) : interval
        nextAttempt = now.addingTimeInterval(delay)
    }
    public func due(now: Date) -> Bool { nextAttempt.map { now >= $0 } ?? true }
}
