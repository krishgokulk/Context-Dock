// AgentToolNarration.swift
// Context-Dock
//
// Saying what the harness is doing, while it does it.
//
// A turn that read Safari's tabs, wrote a note and verified the result showed "4 steps" and a
// paragraph. Everything needed for a live account already existed — the tool name, its
// arguments, its result — and none of it was published, so the user's report was fair: it does
// not show where it is searching, how it is finding, or what it is running.
//
// These are one-line renderings of those three facts. Written here rather than at each of the
// three provider loops because a line that appears for OpenAI and not for Anthropic is worse
// than none: it teaches the user the app is doing less on one provider than on another.

import Foundation

enum AgentToolNarration {

    /// "Searching Notes for “project ideas”…", "Reading /tmp/report.pdf…", or the tool's own
    /// name when nothing better can be said about it.
    ///
    /// The argument that matters is the one a person would have typed: a query, a path, a
    /// menu item, a target. Everything else is plumbing and stays out.
    static func start(tool: String, arguments: [String: Any]) -> String {
        let subject = subject(in: arguments)
        let verb = verb(for: tool)
        guard let subject, !subject.isEmpty else { return "\(verb)…" }
        return "\(verb) \(subject)…"
    }

    /// What came back, in one line: the first line of output, capped, or a plain statement
    /// that it produced nothing — never "done", which is a claim rather than evidence.
    static func finish(displayCommand: String, success: Bool, output: String) -> String {
        let first = output
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = first.count > 120 ? String(first.prefix(120)) + "…" : first
        let verb = success ? "Ran" : "Failed"
        return detail.isEmpty
            ? "\(verb) \(displayCommand) — no output"
            : "\(verb) \(displayCommand) — \(detail)"
    }

    private static func verb(for tool: String) -> String {
        switch tool {
        case "find_capability", "find_route": return "Looking for a route"
        case "search_messages", "get_messages_conversations": return "Searching Messages"
        case "read_page": return "Reading the open page"
        case "read_url": return "Fetching"
        case "read_file", "read_attachment": return "Reading"
        case "read_selection": return "Reading the selection"
        case "run_command": return "Running"
        case "run_menu_command": return "Pressing"
        case "operate_app": return "Looking in the live menu bar for"
        case "run_adapter_action": return "Running app action"
        case "run_capability", "run_mcp_tool", "run_route": return "Running"
        case "send_keys": return "Typing"
        case "window_control": return "Moving the window"
        case "compose_message": return "Drafting a message"
        case "verify_outcome": return "Checking the result"
        case "spawn_worker": return "Handing this to a worker"
        default: return "Running \(tool)"
        }
    }

    /// The argument a person would recognise. Ordered by how much it says about the call, so
    /// a tool carrying both a path and a limit is described by the path.
    private static func subject(in arguments: [String: Any]) -> String? {
        let keys = [
            "query", "target", "path", "url", "command", "capability_id", "action_id",
            "tool", "text", "name", "bundle_id", "file",
        ]
        for key in keys {
            guard let raw = arguments[key] else { continue }
            let value = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let shortened = value.count > 80 ? String(value.prefix(80)) + "…" : value
            return key == "query" || key == "text" ? "“\(shortened)”" : shortened
        }
        return nil
    }
}
