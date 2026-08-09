// ChatAnswerSanitizer.swift
// Context-Dock
//
// Strips tool-call scaffolding from an answer before it is shown.
//
// Models sometimes print their tool call as text instead of calling it: Anthropic-style
// `<function><invoke …>` XML, a bare `{"terminal_call": …}` line, or the
// `[TERMINAL_COMMAND: …]` directive the package-aware prompt teaches. None of that is an
// answer, and a surface that renders it is showing the user the plumbing.
//
// Shared so every chat surface hides the same things — the window used to print a raw
// `{"terminal_call":{"command":"rem list"}}` that the dock would have caught.

import Foundation

enum ChatAnswerSanitizer {

    /// Tool-call syntax the model may emit as prose. Kept in one place so a new call
    /// shape is hidden everywhere at once.
    private static let patterns = [
        "(?s)<function>.*?</function>",
        "(?s)<invoke\\b.*?</invoke>",
        "(?m)^\\s*</?(?:antml:)?(?:function|invoke|parameter)\\b[^>]*>\\s*$",
        "(?s)<parameter\\b.*?</parameter>",
        "(?s)\\[?TERMINAL_COMMAND\\].*?\\[/TERMINAL_COMMAND\\]",
        // The single-bracket directive form: [TERMINAL_COMMAND: rem --help] plus the
        // [COMMAND_PURPOSE: …] line that always follows it.
        "(?m)^\\s*\\[(?:TERMINAL_COMMAND|COMMAND_PURPOSE)\\s*:[^\\]]*\\]\\s*$",
        "\\[(?:TERMINAL_COMMAND|COMMAND_PURPOSE)\\s*:[^\\]]*\\]",
        // A lone JSON tool call, fenced or not.
        "(?m)^\\s*```(?:json)?\\s*\\{\\s*\"[a-z_]+_call\"[\\s\\S]*?```\\s*$",
        "(?m)^\\s*\\{\\s*\"[a-z_]+_call\"\\s*:[\\s\\S]*?\\}\\s*$",
    ]

    /// A call the model invented rather than one we defined — e.g. system_call. Returned
    /// so the surface can look for a real capability that does the same thing instead of
    /// showing the user a JSON blob or, worse, dropping their request in silence.
    static func inventedCall(in text: String) -> (name: String, body: String)? {
        let pattern = #"\{\s*"([a-z_]+_call)"\s*:\s*(\{[\s\S]*?\})\s*\}"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        let blob = String(text[match])
        guard let data = blob.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let key = object.keys.first
        else { return nil }
        let known = ["mcp_call", "menu_call", "adapter_call", "terminal_call", "capability_call"]
        guard !known.contains(key) else { return nil }
        let fields = object[key] as? [String: Any] ?? [:]
        let body = fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return (key, body)
    }

    static func clean(_ text: String) -> String {
        var out = text
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "", options: [.regularExpression])
        }
        // Collapse the blank gaps left behind.
        out = out.replacingOccurrences(of: "(?m)\\n{3,}", with: "\n\n", options: [.regularExpression])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The command from a `terminal_call` the model wrote as text rather than calling.
    /// Returned so the surface can run it and answer from the output instead of showing
    /// the user a JSON blob and stopping.
    static func terminalCall(in text: String) -> (command: String, purpose: String)? {
        let pattern = "\\{\\s*\"terminal_call\"\\s*:\\s*\\{[\\s\\S]*?\\}\\s*\\}"
        guard let range = text.range(of: pattern, options: .regularExpression),
            let data = String(text[range]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let call = object["terminal_call"] as? [String: Any],
            let command = call["command"] as? String,
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (command, call["purpose"] as? String ?? "Answer the user's question")
    }
}
