import Foundation

/// Shared transport for Codex worker runs and subscription discovery/chat. Prompts use stdin;
/// event stdout and diagnostic stderr stay separate. Cancellation waits for the process to exit.
enum CLIProcess {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    enum Failure: LocalizedError {
        case timedOut
        var errorDescription: String? { "Codex timed out. Try again or choose a faster model." }
    }

    static func run(
        binary: String, arguments: [String], directory: URL?,
        environment: [String: String], input: String? = nil,
        closeInput: Bool = true, timeout: TimeInterval,
        onLine: @escaping @Sendable (String) -> Bool = { _ in false }
    ) async throws -> Output {
        let control = Control()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let output = Pipe(), errors = Pipe(), stdin = Pipe()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = arguments
                    process.currentDirectoryURL = directory ?? FileManager.default.temporaryDirectory
                    process.environment = environment
                    process.standardOutput = output
                    process.standardError = errors
                    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
                    do {
                        // A cancelled CLI can close stdin while a large prompt is still
                        // being written. Turn EPIPE into a write error, never SIGPIPE in DoraX.
                        if input != nil,
                           fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        try control.launch(process)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let timer = DispatchWorkItem { control.stop(timedOut: true) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    let diagnostic = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        // Drain concurrently so a verbose stderr cannot fill the pipe and hang.
                        while true {
                            let data = errors.fileHandleForReading.availableData
                            if data.isEmpty { break }
                            diagnostic.append(data)
                        }
                        group.leave()
                    }
                    if let input {
                        DispatchQueue.global().async {
                            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                            if closeInput { try? stdin.fileHandleForWriting.close() }
                        }
                    }
                    var lines = CLIByteLines()
                    var transcript = Data()
                    while true {
                        let data = output.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        transcript.append(data)
                        for line in lines.append(data) where onLine(line) { control.stop() }
                    }
                    if let tail = lines.finish(), onLine(tail) { control.stop() }
                    process.waitUntilExit()
                    try? stdin.fileHandleForWriting.close()
                    group.wait()
                    timer.cancel()
                    do {
                        try control.checkResult()
                        continuation.resume(returning: Output(
                            stdout: String(decoding: transcript, as: UTF8.self),
                            stderr: diagnostic.text, status: process.terminationStatus))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.stop(cancelled: true) }
    }

    private final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var processGroup: pid_t?
        private var cancelled = false
        private var timedOut = false

        func launch(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            self.process = process
            try process.run()
            // Darwin's Process starts a separate process group. Only signal that group
            // after verifying ownership: never signal the app/host's own group.
            let pid = process.processIdentifier
            if getpgid(pid) == pid { processGroup = pid }
        }

        func stop(cancelled: Bool = false, timedOut: Bool = false) {
            lock.lock()
            self.cancelled = self.cancelled || cancelled
            self.timedOut = self.timedOut || timedOut
            let running = process
            let group = processGroup
            lock.unlock()
            if let group { kill(-group, SIGTERM) }
            else if let running, running.isRunning { running.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                // The leader may already be gone while an ignored SIGTERM in a child
                // keeps its stdout/stderr open. Escalate the group even in that case.
                if let group { kill(-group, SIGKILL) }
                else if let running, running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }

        func checkResult() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            if timedOut { throw Failure.timedOut }
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            data = data.suffix(4096)
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Keep bytes until a whole line exists; decoding individual pipe chunks loses split emoji.
struct CLIByteLines {
    private var pending = Data()
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[..<end], as: UTF8.self))
            pending.removeSubrange(...end)
        }
        return lines
    }
    mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
