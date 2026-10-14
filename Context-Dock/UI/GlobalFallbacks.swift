// GlobalFallbacks.swift
// Context-Dock
//
// The last section of Global Context's list (owner 2026-10-14, #258 G3), as Raycast's and
// Tinycast's end theirs: what to do with the words themselves when the matches above are not
// it — ask AI, search the web, and, when the words read as a shell command, run them in
// Terminal.

import AppKit

enum GlobalFallbacks {
    static let section = "Fallbacks"
    static let askKind = "fallbackAsk"
    static let webKind = "fallbackWeb"
    static let terminalKind = "fallbackTerminal"

    /// The fallback rows for what is typed, in order: Ask AI, search the web, run in Terminal.
    static func rows(for typed: String, ask: @escaping (String) -> Void) -> [DockPill] {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var rows = [
            pill("ask", "Ask AI: \(text)", "sparkles", askKind) { ask(text) },
            // `openWebSearch` asks Google, in the default browser: the row names the engine.
            pill("web", "Search Google for “\(text)”", "globe", webKind) {
                L2AppActionRouter.openWebSearch(text)
            },
        ]
        if looksLikeShellCommand(text) {
            rows.append(pill("terminal", "Run in Terminal: \(text)", "terminal", terminalKind) {
                runInTerminal(text)
            })
        }
        return rows
    }

    private static func pill(
        _ id: String, _ name: String, _ symbol: String, _ kind: String,
        execute: @escaping () -> Void
    ) -> DockPill {
        var pill = DockPill(id: "fallback-\(id)", name: name, icon: symbol, badge: nil, execute: execute)
        pill.rankingKind = kind
        pill.resultSection = section
        return pill
    }

    /// Words that read as a shell command: the first word is a program on the usual paths
    /// ("git status", "npm -v", "ls"), or the line uses the shell's own marks. An app's name
    /// is not a program, so "safari" does not offer Terminal.
    static func looksLikeShellCommand(
        _ text: String,
        isProgram: (String) -> Bool = { name in
            ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
                .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
        }
    ) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = line.split(separator: " ").first.map(String.init), !first.isEmpty
        else { return false }
        if first.hasPrefix("./") || first.hasPrefix("~/") || first.hasPrefix("/") { return true }
        // A program name is one lowercase word; "Terms of Service" is not a command.
        guard first == first.lowercased(), first.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) })
        else { return false }
        return isProgram(first)
    }

    /// The line as an AppleScript string literal's contents.
    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Opens Terminal on a new window running the line — the user typed it and chose this
    /// row, so it runs where they can see and stop it.
    static func runInTerminal(_ text: String) {
        let source = """
            tell application "Terminal"
                activate
                do script "\(appleScriptEscaped(text))"
            end tell
            """
        AppleScriptQueue.shared.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeSerialized(error: &error)
        }
    }
}
