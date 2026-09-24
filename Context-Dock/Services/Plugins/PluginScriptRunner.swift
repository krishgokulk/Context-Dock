// Context-Dock
//
// The one place a plugin starts a process or opens a socket. Everything else in the runtime is
// a pure function, which is what keeps the rest of it testable offline.
//
// It replaces `UserExtensionScriptRunner` (UserGlobalExtensionStore.swift) and the runner
// inside CustomListProviderService, and deliberately keeps their behaviour: /bin/zsh -lc,
// /usr/bin/osascript (with -l JavaScript for jxa), the plugin's variables merged OVER the real
// environment, output trimmed. A migrated script has to behave identically. What those lacked
// and this adds: a timeout, scriptFile, http behind a permission gate, and a typed failure.

import Foundation

struct PluginRunResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct PluginRunFailure: Error, Equatable {
    enum Kind: Equatable { case launch, timeout, exit, blocked }
    let message: String
    let kind: Kind
}

actor PluginScriptRunner {

    func run(type: PluginScriptType, script: String, env: [String: String],
             timeout: TimeInterval, workingDirectory: String?) async
        -> Result<PluginRunResult, PluginRunFailure>
    {
        switch type {
        case .http:
            return .failure(PluginRunFailure(
                message: "an http source is fetched through run(http:manifest:timeout:), "
                    + "which is where the host is checked",
                kind: .blocked))
        case .shortcut:
            // The app already runs Shortcuts, and a second path to the same thing is how two
            // behaviours appear. Hand it to the service that owns them.
            do {
                let output = try await ShortcutRunner.shared.runShortcut(named: script)
                return .success(PluginRunResult(
                    stdout: output.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: "", exitCode: 0))
            } catch {
                return .failure(PluginRunFailure(
                    message: error.localizedDescription, kind: .exit))
            }
        case .bash, .applescript, .jxa, .scriptFile:
            return await spawn(
                type: type, script: script, env: env, timeout: timeout,
                workingDirectory: workingDirectory)
        }
    }

    /// An http data source. Separate from `run` because it is gated: an undeclared host never
    /// leaves the process.
    func run(http urlString: String, manifest: PluginManifest, timeout: TimeInterval) async
        -> Result<PluginRunResult, PluginRunFailure>
    {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
            let host = url.host
        else {
            return .failure(PluginRunFailure(message: "not a URL: \(urlString)", kind: .launch))
        }
        guard PluginPermissions.allowsHost(host, manifest: manifest) else {
            return .failure(PluginRunFailure(
                message: "\(manifest.name) did not declare network:\(host)", kind: .blocked))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return .failure(PluginRunFailure(
                    message: "\(url.absoluteString) answered \(code)", kind: .exit))
            }
            return .success(PluginRunResult(
                stdout: String(data: data, encoding: .utf8) ?? "", stderr: "", exitCode: 0))
        } catch {
            return .failure(PluginRunFailure(message: error.localizedDescription, kind: .launch))
        }
    }

    // MARK: The process

    private func spawn(type: PluginScriptType, script: String, env: [String: String],
                       timeout: TimeInterval, workingDirectory: String?) async
        -> Result<PluginRunResult, PluginRunFailure>
    {
        let process = Process()
        switch type {
        case .applescript:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
        case .jxa:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
        case .scriptFile:
            let path = workingDirectory.map { "\($0)/\(script)" } ?? script
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "\"\(path)\""]
        default:
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
        }

        // Merged OVER the real environment, never replacing it: a script calls git, jq, lsof,
        // and an empty PATH stops every one of them resolving.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        process.environment = environment
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Never the host's stdin. A script has no terminal: left unset, the shell inherits
        // whatever launched the app — a real tty when the test host is started from one —
        // and a login zsh with a tty can settle at an interactive prompt that reads
        // forever and ignores SIGTERM. Three did, and the suite waited on them for half an
        // hour.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(PluginRunFailure(message: error.localizedDescription, kind: .launch))
        }

        // Read both pipes BEFORE waiting. A pipe buffer is 64 KB; a script that prints more
        // than that blocks on write while we block on wait, and neither side ever moves — a
        // few hundred list rows is enough to reach it.
        //
        // The two reads and the wait each block a thread, and they get threads of their own —
        // never DispatchQueue.global. The global pool has a thread cap, and the app parks
        // blocking work on it from dozens of places (waitUntilExit on osascript, AX calls).
        // In the test host on CI those wait on an Automation prompt nobody answers, the pool
        // runs dry, and blocks queued here never start: `echo ok` with a 30 s timeout sat for
        // the suite's full 120 s limit, because the timeout could only fire the kill — the
        // group still waited on a wait that had never begun.
        let outcome = ProcessOutcome()
        outcome.start(process: process, stdout: out, stderr: err)

        // Whether the clock ran out is decided by the clock, not by which side reports first:
        // a process killed by the timeout exits, and its wait can win the race.
        let deadline = ContinuousClock.now + .seconds(timeout)
        var timedOut = false
        if await outcome.settled(before: deadline) == false {
            if process.isRunning {
                timedOut = true
                // SIGTERM first, SIGKILL if it is still there a moment later — an
                // interactive shell ignores the first.
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            // A moment to drain what the pipes still hold. A process that has exited but
            // left a child holding its stdout never sends EOF; that is not worth waiting on.
            _ = await outcome.settled(before: .now + .seconds(1))
        }

        let stdout = String(data: outcome.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: outcome.stderr, encoding: .utf8) ?? ""

        if timedOut {
            return .failure(PluginRunFailure(
                message: "took longer than \(Int(timeout))s and was stopped", kind: .timeout))
        }
        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(PluginRunFailure(
                message: message.isEmpty
                    ? "exited with code \(process.terminationStatus)" : message,
                kind: .exit))
        }
        return .success(PluginRunResult(
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus))
    }

    /// The process's output and exit, collected on three threads of its own. `settled` is
    /// true once both pipes reached EOF and the process exited.
    private final class ProcessOutcome: @unchecked Sendable {
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

        /// Chunk by chunk rather than readDataToEndOfFile, so what arrived before a drain was
        /// abandoned is still there to report.
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

        /// Called with the lock held.
        private func takeWaiter() -> CheckedContinuation<Bool, Never>? {
            let w = waiter
            waiter = nil
            clock?.cancel()
            clock = nil
            return w
        }

        /// Waits until everything is in or `deadline` passes; true if everything is in.
        /// The clock is a Swift task, not a GCD timer — the global pool may be the thing that
        /// is stuck.
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
                    self.lock.withLock { self.takeWaiter() }?.resume(returning: false)
                }
                lock.unlock()
            }
        }
    }
}
