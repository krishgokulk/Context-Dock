// BrowserActionGate.swift
// Context-Dock
//
// Which of Safari's MCP tools may run, and what the user is asked first.
//
// Apple's server hands over sixteen tools. Four of them read, and the rest act: they navigate,
// click, type, evaluate JavaScript, resize the viewport. "The model may drive the browser" is the
// sentence a prompt-injection attack wants to be true — a page DoraX reads can contain text
// telling the model to go somewhere and do something, and the model has no way to know that
// sentence came from a stranger rather than from the user.
//
// So the gate is not about trusting the model. It is about making every act the user's, one at a
// time:
//
//   * reads run freely — they are what a chat is for;
//   * every navigation is approved, showing the destination (the owner's call: per navigation,
//     not per host — a site can link anywhere, and "I allowed this site" is not "I allowed
//     wherever this site sends me");
//   * evaluate_javascript is approved every time, with the script shown — it is the widest tool
//     in the set and can do anything the other fifteen can;
//   * a sensitive destination is refused before any of that, by rule rather than by judgement.

import Foundation

enum BrowserActionGate {

    /// Tools that only look. Everything not named here is treated as acting, so a tool added to
    /// the server later is gated by default rather than let through by omission.
    static let readOnlyTools: Set<String> = [
        "get_page_content", "page_info", "list_tabs", "screenshot",
        "browser_console_messages", "list_network_requests", "get_network_request",
    ]

    /// Tools that move the browser somewhere new.
    static let navigationTools: Set<String> = [
        "navigate_to_url", "create_tab", "switch_tab", "wait_for_navigation",
    ]

    /// The widest one.
    static let scriptTools: Set<String> = ["evaluate_javascript"]

    enum Decision: Equatable {
        case allow
        case askFirst(what: String, detail: String)
        case refuse(String)
    }

    /// What to do about one call.
    static func decide(tool: String, arguments: [String: Any], userDenylist: [String] = [])
        -> Decision
    {
        let destination = url(in: arguments)

        // The refusal comes first: a sensitive destination is not something to ask about, and
        // an approval card naming a bank is an invitation to click through.
        if let destination,
            let reason = SensitivePageGuard.refusal(
                for: destination, userDenylist: userDenylist)
        {
            return .refuse(reason.message)
        }

        if readOnlyTools.contains(tool) { return .allow }

        if scriptTools.contains(tool) {
            let script = (arguments["script"] as? String)
                ?? (arguments["expression"] as? String)
                ?? (arguments["code"] as? String) ?? ""
            return .askFirst(
                what: "Run JavaScript on this page",
                detail: script.isEmpty ? "(no script given)" : String(script.prefix(600)))
        }

        if navigationTools.contains(tool) {
            return .askFirst(
                what: "Open a page in Safari",
                detail: destination ?? "(no address given)")
        }

        // Interaction: clicking and typing into whatever is on screen.
        return .askFirst(
            what: "Act on this page",
            detail: describe(tool: tool, arguments: arguments))
    }

    /// The address a call is aimed at, wherever the tool happens to put it.
    static func url(in arguments: [String: Any]) -> String? {
        for key in ["url", "URL", "href", "address", "destination"] {
            if let value = arguments[key] as? String,
                !value.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return value
            }
        }
        return nil
    }

    private static func describe(tool: String, arguments: [String: Any]) -> String {
        let parts = arguments
            .sorted { $0.key < $1.key }
            .prefix(4)
            .map { "\($0.key): \(String(describing: $0.value).prefix(80))" }
        return parts.isEmpty ? tool : "\(tool) — " + parts.joined(separator: ", ")
    }
}
