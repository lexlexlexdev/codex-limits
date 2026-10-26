import Foundation
import Darwin

enum ChildProcesses {
    private static let lock = NSLock()
    private static var processes: [Int32: Process] = [:]
    static func add(_ process: Process) { lock.lock(); defer { lock.unlock() }; processes[process.processIdentifier] = process }
    static func remove(_ process: Process) { lock.lock(); defer { lock.unlock() }; processes.removeValue(forKey: process.processIdentifier) }
    static func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        for (pid, process) in processes where process.isRunning { Darwin.kill(pid, SIGKILL) }
    }
}
