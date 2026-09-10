// CLIScopeRunner.swift
// Context-Dock
//
// Running one command-line tool from a scope the user has stepped into.
//
// The corner could find `tailscale` and then had nowhere to go with it: entering the scope
// posted a notification to the dock, which did nothing visible while the corner was up. This
// runs it where the user is.
//
// **It runs one tool, never a shell.** The executable is fixed by the scope — the tool the
// user stepped into — and everything typed becomes arguments in an array. There is no
// `sh -c`, so a semicolon, a backtick or a `$(…)` in the field is an argument to that tool
// and not a second command. A field that searches apps must never become a way to run
// anything on the machine by typing it.

import Foundation

enum CLIScopeRunner {

    struct Output: Equatable {
        let command: String
        let text: String
        let failed: Bool
    }

    /// How long a command may take before it is killed. Long enough for a status call,
    /// short enough that a tool waiting on input does not hold the surface open forever.
    static let timeout: TimeInterval = 12

    /// Split what the user typed into arguments, respecting quotes.
    ///
    /// Quoted so a path with a space is one argument. Nothing else is interpreted: this is
    /// argument splitting, not shell parsing, and the difference is the whole safety story.
    static func arguments(from line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?

        for character in line {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    /// Where a tool lives, if it is installed. Looked up rather than assumed, because the
    /// path differs between Homebrew, /usr/bin and a user's own bin directory.
    static func executablePath(for command: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            NSHomeDirectory() + "/.local/bin",
        ]
        for directory in candidates {
            let path = directory + "/" + command
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Run `command` with the arguments typed after it.
    static func run(command: String, line: String) async -> Output {
        let args = arguments(from: line)
        let display = ([command] + args).joined(separator: " ")

        guard let executable = executablePath(for: command) else {
            return Output(
                command: display,
                text: "\(command) is not installed, or is not on the usual paths.",
                failed: true)
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Nothing to type into: a tool that waits on stdin would otherwise hang until
            // the timeout, with the surface showing nothing.
            process.standardInput = FileHandle.nullDevice

            var finished = false
            let lock = NSLock()

            func finish(_ output: Output) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: output)
            }

            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                finish(
                    Output(
                        command: display,
                        text: text.isEmpty ? "(no output)" : text,
                        failed: proc.terminationStatus != 0))
            }

            do {
                try process.run()
            } catch {
                finish(
                    Output(
                        command: display, text: "Could not run \(command): \(error)",
                        failed: true))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                finish(
                    Output(
                        command: display,
                        text: "Timed out after \(Int(timeout))s — no output.",
                        failed: true))
            }
        }
    }
}
