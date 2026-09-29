// ShortcutsService.swift
// Context-Dock
//
// The rules behind `list_shortcuts` and `run_shortcut`: the user's Shortcuts, driven through the
// `shortcuts` command line tool that ships with macOS. That tool is the supported route to
// Siri-style reach — macOS has no public API for calling another app's App Intents.
//
// Pure apart from one injected seam, the process runner, so tests never need the real binary or
// a real shortcut. The real runner follows this repo's process rules: stdin is the null device,
// the pipes are drained before waiting on the process (a full pipe deadlocks it), and a timer
// terminates a run that hangs. Output is capped as it is read, so a chatty shortcut cannot fill
// memory.

import Foundation

enum ShortcutsService {

    static let executablePath = "/usr/bin/shortcuts"
    /// Names returned to the model. A few hundred shortcuts is already more than a prompt wants.
    static let maxListed = 200
    static let listTimeout: TimeInterval = 15
    static let runTimeout: TimeInterval = 60
    /// Bytes of stdout kept from one run.
    static let maxOutputBytes = 20_000
    /// Longest input text handed to a shortcut.
    static let maxInputCharacters = 4_000

    // MARK: - Injected seam

    struct ProcessOutcome: Equatable, Sendable {
        var status: Int32
        var stdout: String
        var stderr: String = ""
        var timedOut: Bool = false
        /// More output was produced than `maxBytes`; the excess was discarded.
        var truncated: Bool = false
        /// The binary could not be started at all.
        var launchFailed: Bool = false
    }

    typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval, _ maxBytes: Int)
        -> ProcessOutcome

    enum Refusal: Error, Equatable, LocalizedError {
        case emptyName
        case inputTooLong
        case unknownShortcut(String)
        case listFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "run_shortcut needs the exact name of a shortcut from list_shortcuts."
            case .inputTooLong:
                return "The input is too long for a shortcut (limit "
                    + "\(ShortcutsService.maxInputCharacters) characters)."
            case .unknownShortcut(let name):
                return "There is no shortcut named \"\(name)\". Nothing ran. Call list_shortcuts "
                    + "and use a name exactly as listed, or tell the user it does not exist."
            case .listFailed(let why):
                return "Could not read the user's shortcuts: \(why)"
            }
        }
    }

    // MARK: - Listing

    /// `shortcuts list` prints one name per line. Trimmed, empties dropped, repeats kept once.
    static func parseList(_ text: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// Every shortcut name (uncapped: the exact-name check must see all of them).
    static func allNames(runner: Runner = ShortcutsService.systemRunner) -> Result<[String], Refusal> {
        let outcome = runner(["list"], listTimeout, maxOutputBytes * 4)
        if outcome.launchFailed {
            return .failure(.listFailed("the `shortcuts` tool could not be started."))
        }
        if outcome.timedOut {
            return .failure(.listFailed("the Shortcuts app did not answer in time."))
        }
        guard outcome.status == 0 else {
            let why = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.listFailed(why.isEmpty ? "exit status \(outcome.status)." : why))
        }
        return .success(parseList(outcome.stdout))
    }

    /// The text the model reads for `list_shortcuts`.
    static func listReport(names: [String]) -> String {
        guard !names.isEmpty else {
            return "The user has no shortcuts in the Shortcuts app. Say so."
        }
        let shown = names.prefix(maxListed)
        var text = "\(names.count) shortcut\(names.count == 1 ? "" : "s"), one per line "
            + "(use a name exactly as written with run_shortcut):\n" + shown.joined(separator: "\n")
        if names.count > shown.count {
            text += "\n… and \(names.count - shown.count) more not shown."
        }
        return text
    }

    // MARK: - Running

    struct RunOutcome: Equatable {
        var success: Bool
        var text: String
        var status: Int32
    }

    /// Run `name` with optional `input`. The caller has already checked the name against the
    /// list and been approved. The input goes to a temp file passed with `-i`; the file is
    /// removed on every path out, including failure and timeout.
    static func run(
        name: String, input: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        runner: Runner = ShortcutsService.systemRunner
    ) -> RunOutcome {
        var arguments = ["run", name]
        var inputFile: URL?
        defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }

        if let input, !input.isEmpty {
            let file = tempDirectory.appendingPathComponent("dorax-shortcut-\(UUID().uuidString).txt")
            do {
                try Data(input.utf8).write(to: file, options: .atomic)
            } catch {
                return RunOutcome(
                    success: false,
                    text: "Could not prepare the input for the shortcut: \(error.localizedDescription)",
                    status: -1)
            }
            inputFile = file
            arguments += ["-i", file.path]
        }

        return interpret(runner(arguments, runTimeout, maxOutputBytes), name: name)
    }

    static func interpret(_ outcome: ProcessOutcome, name: String) -> RunOutcome {
        if outcome.launchFailed {
            return RunOutcome(
                success: false, text: "The `shortcuts` tool could not be started. Nothing ran.",
                status: -1)
        }
        if outcome.timedOut {
            return RunOutcome(
                success: false,
                text: "\"\(name)\" did not finish within \(Int(runTimeout)) seconds and was "
                    + "stopped. It may have done part of its work.",
                status: outcome.status)
        }
        let out = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard outcome.status == 0 else {
            var text = "\"\(name)\" failed (exit status \(outcome.status))."
            if !err.isEmpty { text += " " + err }
            if !out.isEmpty { text += "\nOutput:\n" + out }
            return RunOutcome(success: false, text: text, status: outcome.status)
        }
        var text = out.isEmpty
            ? "Ran \"\(name)\", no output. (exit status 0)"
            : "Ran \"\(name)\" (exit status 0). Output:\n" + out
        if outcome.truncated { text += "\n[output truncated]" }
        return RunOutcome(success: true, text: text, status: 0)
    }

    // MARK: - The real process

    /// Runs `/usr/bin/shortcuts`. Blocking: call it off the main actor.
    static let systemRunner: Runner = { arguments, timeout, maxBytes in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            return ProcessOutcome(status: -1, stdout: "", launchFailed: true)
        }

        let timedOut = LockedBox(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.set(true)
            process.terminate()
            // A shortcut that ignores SIGTERM must not hold the turn hostage.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        // Drain stderr on its own thread so neither pipe can fill while the other is read.
        let errBox = LockedBox(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.set(drain(errPipe.fileHandleForReading, maxBytes: 4_000).data)
            group.leave()
        }
        let out = drain(outPipe.fileHandleForReading, maxBytes: maxBytes)
        group.wait()
        process.waitUntilExit()
        return ProcessOutcome(
            status: process.terminationStatus,
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            timedOut: timedOut.get(),
            truncated: out.truncated)
    }

    /// Read to end of stream, keeping the first `maxBytes` and discarding the rest.
    static func drain(_ handle: FileHandle, maxBytes: Int) -> (data: Data, truncated: Bool) {
        var kept = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            let room = maxBytes - kept.count
            if chunk.count > room { truncated = true }
            if room > 0 { kept.append(chunk.prefix(room)) }
        }
        return (kept, truncated)
    }

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }
}
