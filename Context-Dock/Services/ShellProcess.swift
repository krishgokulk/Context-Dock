import Foundation

/// Safe child-process runner. Every call sets null stdin, drains pipes on dedicated threads
/// before `waitUntilExit` can deadlock on a full buffer, and SIGTERM → SIGKILLs on timeout.
///
/// Addresses issue #43: `grep -rln "waitUntilExit()" Context-Dock` returned 54 files; all
/// had at least one of (a) no `standardInput = FileHandle.nullDevice` — the child inherits
/// the host's terminal and stops on SIGTTIN — or (b) `readDataToEndOfFile` after
/// `waitUntilExit` — the child blocks writing into a full 64 KB pipe while the host blocks
/// waiting, and neither side ever moves.
///
/// Usage:
/// ```swift
/// // async context
/// if let r = await ShellProcess.run("/usr/bin/git", arguments: ["status"]) { … }
/// // sync context
/// let ok = ShellProcess.check("/usr/bin/which", arguments: ["jq"])
/// let r  = ShellProcess.runSync("/usr/bin/git", arguments: ["log", "--oneline"])
/// ```
enum ShellProcess {

    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
        var succeeded: Bool { status == 0 }
    }

    // MARK: - Async

    /// Runs the executable and waits. Null stdin; both pipes drained on dedicated threads;
    /// SIGTERM then SIGKILL if `timeout` expires. Returns nil if the executable cannot be
    /// launched.
    static func run(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async -> Result? {
        guard let (process, outPipe, errPipe) = launch(
            executable, arguments: arguments,
            workingDirectory: workingDirectory, environment: environment)
        else { return nil }

        let drainer = Drainer()
        drainer.start(process: process, stdout: outPipe, stderr: errPipe)

        let deadline = ContinuousClock.now + .seconds(timeout)
        var timedOut = false
        if await drainer.settled(before: deadline) == false {
            if process.isRunning {
                timedOut = true
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            _ = await drainer.settled(before: .now + .seconds(1))
        }

        if timedOut { return nil }
        return Result(
            stdout: String(data: drainer.stdout, encoding: .utf8) ?? "",
            stderr: String(data: drainer.stderr, encoding: .utf8) ?? "",
            status: process.terminationStatus)
    }

    // MARK: - Synchronous shim

    /// Synchronous variant. Drains stdout, stderr, and the wait concurrently on detached
    /// threads — never blocks on a full pipe. Avoid on the cooperative thread pool; prefer
    /// `run` in async contexts.
    static func runSync(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) -> Result? {
        guard let (process, outPipe, errPipe) = launch(
            executable, arguments: arguments,
            workingDirectory: workingDirectory, environment: environment)
        else { return nil }

        let group = DispatchGroup()
        let lock = NSLock()
        var outData = Data()
        var errData = Data()

        group.enter()
        Thread.detachNewThread {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = d; lock.unlock()
            group.leave()
        }
        group.enter()
        Thread.detachNewThread {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = d; lock.unlock()
            group.leave()
        }
        group.enter()
        Thread.detachNewThread {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            // Give pipes a moment to drain after the kill, then return nil — consistent
            // with the async `run` variant.
            _ = group.wait(timeout: .now() + 1)
            return nil
        }

        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()
        return Result(stdout: out, stderr: err, status: process.terminationStatus)
    }

    // MARK: - Exit-code check

    /// True if the process exits 0. Discards all output; null stdin. The common
    /// "is this tool installed?" pattern — no pipe to deadlock, no terminal to inherit.
    static func check(_ executable: String, arguments: [String] = []) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Private helpers

    private static func launch(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) -> (Process, Pipe, Pipe)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return nil }
        return (process, outPipe, errPipe)
    }

    /// Collects stdout, stderr, and the process exit on three dedicated threads. Mirrors
    /// `PluginScriptRunner.ProcessOutcome` — the upstream reference for this pattern.
    private final class Drainer: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var pending = 3
        private var waiter: CheckedContinuation<Bool, Never>?
        private var clock: Task<Void, Never>?

        var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
        var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }

        func start(process: Process, stdout: Pipe, stderr: Pipe) {
            drain(stdout.fileHandleForReading) { self.out.append($0) }
            drain(stderr.fileHandleForReading) { self.err.append($0) }
            Thread.detachNewThread {
                process.waitUntilExit()
                self.finishOne()
            }
        }

        private func drain(_ handle: FileHandle, into append: @escaping (Data) -> Void) {
            Thread.detachNewThread {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    self.lock.lock(); append(chunk); self.lock.unlock()
                }
                self.finishOne()
            }
        }

        private func finishOne() {
            lock.lock()
            pending -= 1
            let done = pending == 0 ? takeWaiter() : nil
            lock.unlock()
            done?.resume(returning: true)
        }

        private func takeWaiter() -> CheckedContinuation<Bool, Never>? {
            let w = waiter; waiter = nil; clock?.cancel(); clock = nil; return w
        }

        func settled(before deadline: ContinuousClock.Instant) async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if pending == 0 {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                waiter = continuation
                clock = Task {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard !Task.isCancelled else { return }
                    self.lock.lock()
                    let w = self.takeWaiter()
                    self.lock.unlock()
                    w?.resume(returning: false)
                }
                lock.unlock()
            }
        }
    }
}
