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
    func refresh(_ command: SystemCommand, query: String, completion: @escaping () -> Void) {
        if cache[command.id]?.refreshing == true { return }
        var entry = cache[command.id] ?? Entry(rows: [], at: .distantPast, refreshing: false)
        entry.refreshing = true
        cache[command.id] = entry

        let script = command.script
        let interpreter = command.actionType
        let env = environment(query: query, row: nil)

        queue.async { [weak self] in
            let output = Self.runCapturing(
                script: script, interpreter: interpreter, env: env)
            let rows = Self.parseRows(output)
            DispatchQueue.main.async {
                self?.cache[command.id] = Entry(rows: rows, at: Date(), refreshing: false)
                self?.lastQuery[command.id] = query
                completion()
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
    /// scopes (type + Enter to save, live search, …).
    static func isLiveQuery(_ command: SystemCommand) -> Bool {
        command.keywords.contains { $0.lowercased() == "query:live" }
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
