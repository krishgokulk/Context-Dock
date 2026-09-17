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

        do {
            try process.run()
        } catch {
            return .failure(PluginRunFailure(message: error.localizedDescription, kind: .launch))
        }

        // Read both pipes BEFORE waiting. A pipe buffer is 64 KB; a script that prints more
        // than that blocks on write while we block on wait, and neither side ever moves — a
        // few hundred list rows is enough to reach it.
        async let stdoutData = Self.read(out)
        async let stderrData = Self.read(err)

        let timedOut = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await Self.wait(for: process)
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard process.isRunning else { return false }
                process.terminate()
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrData, encoding: .utf8) ?? ""

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

    private static func read(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
    }

    private static func wait(for process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
