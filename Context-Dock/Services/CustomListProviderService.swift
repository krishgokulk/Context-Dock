// CustomListProviderService.swift
// Context-Dock
//
// Engine for USER-AUTHORED list extensions — the generic version of the built-in
// Process Monitor. A Global Command becomes a live list scope by carrying the
// keyword `provider:custom`. Its existing fields are reused so the whole thing is
// authorable from the normal Global Commands editor with no extra UI:
//
//   • script      (scriptType)      → the ROWS script: prints one JSON object per
//                                     line: {"id","title","subtitle","badge","icon"}
//   • undoScript  (undoScriptType)  → the ROW ACTION script, run on Enter with the
//                                     row exposed as $CD_ROW_ID / $CD_ROW_TITLE.
//   • keyword `refresh:N`           → optional auto-refresh interval in seconds.
//
// Like ProcessMonitorService, scripts run on a BACKGROUND queue into a per-command
// cache; the SwiftUI pill-builder only ever reads the cache. Running a subprocess
// on the view-build path re-enters the view graph and aborts.

import AppKit

struct CustomListRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let badge: String?
    let icon: String?   // SF Symbol name, or an absolute file/app path
}

final class CustomListProviderService {
    static let shared = CustomListProviderService()
    private init() {}

    private struct Entry {
        var rows: [CustomListRow]
        var at: Date
        var refreshing: Bool
    }

    private var cache: [UUID: Entry] = [:]   // main-thread only
    private var lastQuery: [UUID: String] = [:]  // last query the rows script saw (live mode)
    private var pendingDebounce: [UUID: DispatchWorkItem] = [:]
    private var queuedQuery: [UUID: String] = [:]
    private var generation: [UUID: UInt64] = [:]

    /// Long enough that a burst of typing is one run, short enough to feel instant.
    private static let liveDebounce: TimeInterval = 0.12
    /// A rows script is on the interactive path; one that hangs must not wedge the
    /// panel forever behind `refreshing == true`.
    private static let scriptTimeout: TimeInterval = 5
    private let queue = DispatchQueue(
        label: "com.krishgokul.ContextDock.customListProvider", qos: .userInitiated)

    // MARK: Public (main thread)

    func rows(for command: SystemCommand) -> [CustomListRow] {
        cache[command.id]?.rows ?? []
    }

    func isStale(_ command: SystemCommand, query: String) -> Bool {
        guard let entry = cache[command.id] else { return true }
        // Live-query extensions re-run whenever the typed query changes, so the rows
        // script can react to $CD_QUERY (capture-style scopes like Quick Note).
        if Self.isLiveQuery(command), lastQuery[command.id] != query { return true }
        return Date().timeIntervalSince(entry.at) > refreshInterval(for: command)
    }

    /// Run the rows script off-view, cache the parsed rows, fire `completion` on the
    /// main thread. No-ops while a refresh for this command is already in flight.
    ///
    /// Live-query extensions are debounced: a keystroke-per-subprocess would spawn a
    /// shell for every character of "100 gbp" and let a slow one land after a newer
    /// keystroke, flickering stale results back onto the screen.
    func refresh(_ command: SystemCommand, query: String, completion: @escaping () -> Void) {
        guard Self.isLiveQuery(command) else {
            performRefresh(command, query: query, completion: completion)
            return
        }

        pendingDebounce[command.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingDebounce[command.id] = nil
            self?.performRefresh(command, query: query, completion: completion)
        }
        pendingDebounce[command.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveDebounce, execute: work)
    }

    private func performRefresh(_ command: SystemCommand, query: String,
                                completion: @escaping () -> Void) {
        if cache[command.id]?.refreshing == true {
            // Something newer is wanted than what's running. Remember it so the
            // in-flight run's completion can immediately chase the current query.
            queuedQuery[command.id] = query
            return
        }
        var entry = cache[command.id] ?? Entry(rows: [], at: .distantPast, refreshing: false)
        entry.refreshing = true
        cache[command.id] = entry

        let script = command.script
        let interpreter = command.actionType
        let env = environment(query: query, row: nil)
        // Generation guards against an older, slower run overwriting a newer result.
        generation[command.id, default: 0] &+= 1
        let issued = generation[command.id] ?? 0

        queue.async { [weak self] in
            let output = Self.runCapturing(
                script: script, interpreter: interpreter, env: env)
            let rows = Self.parseRows(output)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation[command.id] == issued else { return }

                var updated = self.cache[command.id]
                    ?? Entry(rows: [], at: .distantPast, refreshing: false)
                // A rows script that returns nothing mid-typing ("100 g" before the
                // currency is complete) must not blank the panel — hold the last good
                // rows so the list stays steady the way Spotlight's does.
                updated.rows = rows.isEmpty && !updated.rows.isEmpty ? updated.rows : rows
                updated.at = Date()
                updated.refreshing = false
                self.cache[command.id] = updated
                self.lastQuery[command.id] = query
                completion()

                if let next = self.queuedQuery.removeValue(forKey: command.id), next != query {
                    self.performRefresh(command, query: next, completion: completion)
                }
            }
        }
    }

    /// Run the row-action script (the command's undo field) for the tapped row.
    func runAction(_ command: SystemCommand, row: CustomListRow, query: String) {
        let script = command.undoScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        let interpreter = command.undoActionType
        let env = environment(query: query, row: row)
        queue.async {
            _ = Self.runCapturing(script: command.undoScript, interpreter: interpreter, env: env)
        }
    }

    // MARK: Config

    /// Whether a command is a user-authored list extension.
    static func isListProvider(_ command: SystemCommand) -> Bool {
        command.keywords.contains { $0.lowercased() == "provider:custom" }
    }

    /// Live-query extensions re-run the rows script on every keystroke (passing
    /// $CD_QUERY) instead of client-filtering the cached rows — enables capture-style
    /// scopes (type + Enter to save, live search, converters, …).
    ///
    /// The `query:live` keyword is the explicit opt-in, but a script that reads
    /// $CD_QUERY has already declared the dependency: client-filtering its output is
    /// always wrong. A currency converter emitting one row for "20 gbp" got that row
    /// filtered away by the literal text "20" and showed an empty panel. Inferring the
    /// mode from the script removes a magic keyword the author had no way to guess.
    static func isLiveQuery(_ command: SystemCommand) -> Bool {
        if command.keywords.contains(where: { $0.lowercased() == "query:live" }) { return true }
        return scriptReadsQuery(command.script)
    }

    /// Does the rows script reference the query variable in any of its spellings?
    static func scriptReadsQuery(_ script: String) -> Bool {
        script.contains("CD_QUERY")
    }

    // MARK: Authoring-time test

    /// Run a rows script once and hand back raw stdout, for the settings tester.
    /// Bypasses the cache entirely — the author wants this exact script, right now.
    static func testRun(script: String, interpreter: SystemCommandActionType,
                        query: String) async -> String {
        let ctx = await MainActor.run { AXContextReader.shared.current }
        let env: [String: String] = [
            "CD_QUERY": query,
            "CD_URL": ctx.currentURL ?? "",
            "CD_TEXT": ctx.selectedText ?? "",
            "CD_APP": ctx.appName,
        ]
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning:
                    runCapturing(script: script, interpreter: interpreter, env: env))
            }
        }
    }

    static func testParse(_ output: String) -> [CustomListRow] {
        parseRows(output)
    }

    private func refreshInterval(for command: SystemCommand) -> TimeInterval {
        for kw in command.keywords {
            let lower = kw.lowercased()
            guard lower.hasPrefix("refresh:") else { continue }
            if let n = Double(lower.dropFirst("refresh:".count)) { return max(1, n) }
        }
        return 3
    }

    private func environment(query: String, row: CustomListRow?) -> [String: String] {
        let ctx = AXContextReader.shared.current
        var env: [String: String] = [
            "CD_QUERY": query,
            "CD_URL": ctx.currentURL ?? "",
            "CD_TEXT": ctx.selectedText ?? "",
            "CD_APP": ctx.appName,
        ]
        if let row {
            env["CD_ROW_ID"] = row.id
            env["CD_ROW_TITLE"] = row.title
        }
        return env
    }

    // MARK: Execution (background)

    private static func runCapturing(
        script: String,
        interpreter: SystemCommandActionType,
        env: [String: String]
    ) -> String {
        let process = Process()
        switch interpreter {
        case .bash:
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
        case .applescript:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
        case .jxa:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
        case .scriptFile:
            let path = (script as NSString).expandingTildeInPath
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "\(path.replacingOccurrences(of: "\"", with: "\\\""))"]
        case .url, .file, .aiPrompt:
            return ""  // not meaningful as a rows source
        }

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }

        // Kill a script that overruns rather than blocking this queue forever — a
        // `curl` with no network would otherwise leave the panel permanently busy.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + scriptTimeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Parse stdout into rows. Each non-empty line is a JSON object; a line that
    /// isn't valid JSON is treated as a plain title (id = the line text) so trivial
    /// scripts (`echo hello`) still produce rows.
    private static func parseRows(_ output: String) -> [CustomListRow] {
        struct Raw: Decodable {
            let id: String?
            let title: String?
            let subtitle: String?
            let badge: String?
            let icon: String?
        }
        var rows: [CustomListRow] = []
        var autoIndex = 0
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let data = line.data(using: .utf8),
                let raw = try? JSONDecoder().decode(Raw.self, from: data),
                (raw.title != nil || raw.id != nil)
            {
                autoIndex += 1
                let title = raw.title ?? raw.id ?? "Row \(autoIndex)"
                rows.append(
                    CustomListRow(
                        id: raw.id ?? "\(autoIndex)",
                        title: title,
                        subtitle: raw.subtitle,
                        badge: raw.badge,
                        icon: raw.icon))
            } else {
                autoIndex += 1
                rows.append(
                    CustomListRow(
                        id: "\(autoIndex)", title: line, subtitle: nil, badge: nil, icon: nil))
            }
            if rows.count >= 60 { break }
        }
        return rows
    }
}
