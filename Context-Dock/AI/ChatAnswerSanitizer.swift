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
        // The capability id written as the key: {"globalcmd.empty-trash": {}}. Every
        // pattern above matches `<something>_call`, so this form — the one a model reaches
        // for after being handed an id — matched none of them and was printed at the user.
        "(?m)^\\s*```(?:json)?\\s*\\{\\s*\"[A-Za-z][A-Za-z0-9_]*\\.[A-Za-z0-9_.-]+\"[\\s\\S]*?```\\s*$",
        "(?m)^\\s*\\{\\s*\"[A-Za-z][A-Za-z0-9_]*\\.[A-Za-z0-9_.-]+\"\\s*:[\\s\\S]*?\\}\\s*$",
    ]

    /// Whether this text is protocol rather than an answer.
    ///
    /// The patterns above chase known shapes, and each new provider invents another. This
    /// asks the structural question instead: an assistant message that is nothing but one
    /// JSON object is never a reply to a person. Whatever key it uses, whatever we have or
    /// have not taught, it is a call that failed to execute — and the one thing it must
    /// never do is appear in the conversation as if it were an answer.
    static func isProtocolOnly(_ text: String) -> Bool {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unwrap a single fenced block so ```json {…} ``` is judged on its contents.
        if body.hasPrefix("```") {
            body = body
                .replacingOccurrences(
                    of: "^```(?:json)?\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "```$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.hasPrefix("{"), body.hasSuffix("}"),
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            !object.isEmpty
        else { return false }
        // Not every bare JSON object is protocol — "give me the config as JSON" is a real
        // request with a real answer. What marks an invocation is the shape of its keys:
        // a `*_call` envelope, or a dotted capability id. Both are structural, so a shape
        // nobody has invented yet is still caught, while {"name":"x","port":8080} is left
        // alone.
        if object.keys.allSatisfy({ key in
            key.hasSuffix("_call") || (key.contains(".") && !key.contains(" "))
        }) {
            return true
        }
        // A third shape, learned the hard way. Asked to empty the trash the model replied
        // with exactly `{"trash_bin_action": {"action": "empty"}}` — one key, no `_call`
        // suffix, no dot — so the two tests above both passed it through and the user was
        // shown the JSON as the answer.
        //
        // Widening to "any lone JSON object" would catch a real reply to "show me that as
        // JSON". So the extra test is the naming: one key, an object underneath it, and a
        // word in the key that describes doing something rather than being something.
        // {"server": {"port": 8080}} stays an answer; {"trash_bin_action": {…}} does not.
        guard object.count == 1, let key = object.keys.first,
            object[key] is [String: Any], !key.contains(" ")
        else { return false }
        let doingWords: Set<String> = [
            "call", "action", "command", "tool", "invoke", "execute", "run",
            "function", "request", "perform", "operation",
        ]
        // Split on case boundaries as well as separators. Models write both `run_tool` and
        // `runTool`, and a tokeniser that only knows underscores reads the second as one
        // word and lets it through.
        return key
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { doingWords.contains(String($0)) }
    }

    /// What the user should see instead of a call that never ran.
    ///
    /// Deliberately not an apology and not a retry prompt: the request was understood and
    /// the route was chosen, so the honest report is that carrying it out failed here.
    static let protocolFallback =
        "I worked out what to run but couldn't carry it out on this surface. "
        + "Try asking again, or ask in General Chat."

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

    /// A call the model wrote as text instead of calling: {"mcp_call":…},
    /// {"capability_call":…}, {"menu_call":…}, {"adapter_call":…}.
    ///
    /// The prompt teaches this protocol — the built-in tools section literally says to
    /// reply with one line of JSON — so a model that follows the instruction is not
    /// misbehaving. A surface that then only strips it swallows the user's request.
    static func knownCall(in text: String) -> (kind: String, arguments: [String: Any])? {
        let pattern = #"\{\s*"(mcp_call|capability_call|menu_call|adapter_call)"\s*:\s*(\{[\s\S]*?\})\s*\}"#
        guard let range = text.range(of: pattern, options: .regularExpression),
            let data = String(text[range]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object.keys.first,
            let arguments = object[kind] as? [String: Any]
        else { return nil }
        return (kind, arguments)
    }

    /// A capability call written with the id as the key: `{"globalcmd.empty-trash": {}}`.
    ///
    /// Matched separately because every other recovery here keys off `<name>_call`, so this
    /// form reached none of them, was stripped as scaffolding, and left an empty bubble
    /// under "No tools ran" — the request silently dropped rather than run.
    static func capabilityIDCall(in text: String) -> (id: String, arguments: [String: Any])? {
        let pattern = #"\{\s*"([A-Za-z][A-Za-z0-9_]*\.[A-Za-z0-9_.-]+)"\s*:\s*(\{[\s\S]*?\})\s*\}"#
        guard let range = text.range(of: pattern, options: .regularExpression),
            let data = String(text[range]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object.count == 1,
            let id = object.keys.first,
            let arguments = object[id] as? [String: Any]
        else { return nil }
        return (id, arguments)
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
