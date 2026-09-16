// ScopedToolStep.swift
// Context-Dock
//
// What a tool call is called, in the user's language.
//
// The transcript showed a spinner while a turn read a page, checked a file and ran a command,
// then produced an answer with no account of how it got there. The work was real and entirely
// invisible, which leaves the user deciding whether to trust a conclusion whose derivation
// they never saw. Tool names are the wrong thing to show them — `run_capability` and
// `read_url` are our vocabulary, not theirs.

import Foundation

enum ScopedToolStep {

    /// A short present-tense line for a tool that has just started.
    static func label(for toolName: String) -> String {
        switch toolName {
        case "read_page": return "Reading the page…"
        case "read_url": return "Fetching the link…"
        case "read_file": return "Reading the file…"
        case "read_selection": return "Reading your selection…"
        case "read_attachment": return "Reading the attachment…"
        case "find_capability", "find_route": return "Looking for a way to do this…"
        case "run_capability", "run_route": return "Running it…"
        case "run_command": return "Running a command…"
        case "run_menu_command": return "Using the app's menu…"
        case "run_adapter_action": return "Running an app action…"
        case "run_mcp_tool": return "Reading the app's data…"
        case "window_control": return "Adjusting the window…"
        case "send_keys": return "Typing into the app…"
        case "spawn_worker": return "Starting a background task…"
        case "verify_outcome": return "Checking it worked…"
        case "get_messages_conversations", "search_messages": return "Searching Messages…"
        case "compose_message": return "Composing a message…"
        default:
            // An extension's own tool, whose name the user chose. Shown as written rather
            // than hidden: they named it, so it means more to them than to us.
            let spaced = toolName.replacingOccurrences(of: "_", with: " ")
            return "\(spaced.prefix(1).uppercased())\(spaced.dropFirst())…"
        }
    }

    static func completedLabel(for toolName: String) -> String {
        "\(plainName(for: toolName)) complete"
    }

    static func failedLabel(for toolName: String) -> String {
        "\(plainName(for: toolName)) did not complete"
    }

    private static func plainName(for toolName: String) -> String {
        label(for: toolName).trimmingCharacters(in: CharacterSet(charactersIn: "…"))
    }
}
