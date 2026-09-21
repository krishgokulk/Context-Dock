// AppAgentProfile.swift
// Context-Dock
//
// What an app is, as an agent — written as a file rather than compiled in.
//
// DoraX already holds everything an app can do: adapter actions, skills, CLI tools, MCP servers,
// Shortcuts, context readers, capabilities. What it has never held is how that app *behaves*:
// which of those to reach for, in what order, what it must never do, and how it checks its own
// work. That knowledge lives today in `ScopedAppPromptBuilder`, `FrontmostAppTaskPlan`, the
// capability catalogue and a run of `if bundleId ==` branches — so teaching DoraX a new app means
// editing DoraX.
//
// A profile is one Markdown file in the app's own folder: front matter the app reads as data, a
// body the model reads as instructions.
//
//     ---
//     app: Safari
//     bundle_id: com.apple.Safari
//     summary: Browsing, tabs, page content, and the open page's links.
//     tools:
//       capabilities: [browser.tabs, browser.currentPage]
//       mcp: [safari-mcp]
//       scripts: [tabs-to-md.sh]
//     never:
//       - Close or quit the browser without being asked to
//     verify:
//       tabs: browser.tabs
//     ---
//
//     Prefer the extension's live page read over AppleScript…
//
// The parser is deliberately small and forgiving: a profile is written by a person, and the
// failure mode for a typo must be "that line is ignored", never "the app loses its tools".
// Anything it cannot read is reported through `problems` so the authoring UI can say so, rather
// than being swallowed.

import Foundation

struct AppAgentProfile: Equatable {

    /// What the app may reach, by kind. Absent means "not declared", which is not the same as
    /// an empty list: an undeclared app keeps the behaviour DoraX infers today, while an app
    /// declaring `capabilities: []` is saying it has none.
    struct Tools: Equatable {
        var capabilities: [String]?
        var mcp: [String]?
        var cli: [String]?
        var actions: [String]?
        var scripts: [String]?

        var isEmpty: Bool {
            capabilities == nil && mcp == nil && cli == nil && actions == nil && scripts == nil
        }

        /// Everything declared, flattened, for a quick "does this profile mention X".
        var allNames: [String] {
            (capabilities ?? []) + (mcp ?? []) + (cli ?? []) + (actions ?? []) + (scripts ?? [])
        }
    }

    var appName: String
    var bundleID: String
    var summary: String
    /// Lines the app must never do, in the user's terms. Carried into the prompt verbatim and
    /// kept separate from the body so a future gate can enforce rather than ask.
    var never: [String]
    /// Capability id per outcome word — "tabs: browser.tabs" — so a claim can be checked with
    /// the reader the author nominated rather than one guessed at.
    var verify: [String: String]
    var tools: Tools
    /// The prompt body, verbatim.
    var instructions: String
    /// Lines the parser could not use, for the authoring UI. Never fatal.
    var problems: [String]

    var isEmpty: Bool {
        summary.isEmpty && never.isEmpty && verify.isEmpty && tools.isEmpty
            && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Reading

    static func parse(_ text: String, bundleID: String = "", appName: String = "")
        -> AppAgentProfile
    {
        var profile = AppAgentProfile(
            appName: appName, bundleID: bundleID, summary: "", never: [], verify: [:],
            tools: Tools(), instructions: "", problems: [])

        let (frontMatter, body) = split(text)
        profile.instructions = stripComments(body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !frontMatter.isEmpty else { return profile }

        // One indent level, which is all a profile needs: `tools:` and `verify:` take a block,
        // everything else is a scalar or an inline list. A full YAML parser would accept shapes
        // this format has no meaning for, and then fail on the ones it does.
        var section: String?
        for rawLine in frontMatter.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indented = line.hasPrefix("  ")

            // A list item belongs to whichever key opened the block.
            if trimmed.hasPrefix("- ") {
                let value = unquoted(String(trimmed.dropFirst(2)))
                switch section {
                case "never": profile.never.append(value)
                case "capabilities": profile.tools.capabilities = (profile.tools.capabilities ?? []) + [value]
                case "mcp": profile.tools.mcp = (profile.tools.mcp ?? []) + [value]
                case "cli": profile.tools.cli = (profile.tools.cli ?? []) + [value]
                case "actions": profile.tools.actions = (profile.tools.actions ?? []) + [value]
                case "scripts": profile.tools.scripts = (profile.tools.scripts ?? []) + [value]
                default: profile.problems.append("A list item with no key above it: \(trimmed)")
                }
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else {
                profile.problems.append("Not a key: \(trimmed)")
                continue
            }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquoted(
                String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces))

            if indented {
                // Inside `tools:` or `verify:`.
                if section == "tools" || toolKeys.contains(key) {
                    if value.isEmpty {
                        section = key  // a block list follows
                    } else {
                        assign(list(from: value), to: key, in: &profile)
                    }
                    continue
                }
                if section == "verify" {
                    guard !value.isEmpty else {
                        profile.problems.append("verify.\(key) names no capability")
                        continue
                    }
                    profile.verify[key] = value
                    continue
                }
                profile.problems.append("Indented under nothing: \(trimmed)")
                continue
            }

            switch key {
            case "app": profile.appName = value
            case "bundle_id", "bundleId": profile.bundleID = value
            case "summary": profile.summary = value
            case "never":
                section = "never"
                if !value.isEmpty { profile.never = list(from: value) }
            case "verify":
                section = "verify"
            case "tools":
                section = "tools"
            default:
                profile.problems.append("Unknown key: \(key)")
                section = nil
            }
        }
        return profile
    }

    private static let toolKeys: Set<String> = ["capabilities", "mcp", "cli", "actions", "scripts"]

    private static func assign(_ values: [String], to key: String, in profile: inout AppAgentProfile) {
        switch key {
        case "capabilities": profile.tools.capabilities = values
        case "mcp": profile.tools.mcp = values
        case "cli": profile.tools.cli = values
        case "actions": profile.tools.actions = values
        case "scripts": profile.tools.scripts = values
        default: profile.problems.append("Unknown tool kind: \(key)")
        }
    }

    /// `[a, b]` or `a, b` → ["a", "b"]. An empty list stays empty rather than becoming nil:
    /// declaring nothing and declaring none are different statements.
    private static func list(from value: String) -> [String] {
        var inner = value
        if inner.hasPrefix("["), inner.hasSuffix("]") {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner
            .split(separator: ",")
            .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// `<!-- … -->` is a note to whoever edits the file, not a line for the model.
    ///
    /// The generated draft used to put its own guidance — "Write how DoraX should work with
    /// Safari…" — in the body as plain prose, so a profile saved before the user replaced it
    /// sent the model an instruction addressed to the user. A comment is the right shape for
    /// something a person reads and a turn never sees.
    static func stripComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "<!--") {
            result += rest[rest.startIndex..<start.lowerBound]
            guard let end = rest.range(of: "-->", range: start.upperBound..<rest.endIndex) else {
                // An unclosed comment swallows the rest of the file rather than leaking half
                // a note into the prompt.
                return result
            }
            rest = rest[end.upperBound...]
        }
        result += rest
        return result
    }

    private static func unquoted(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where text.hasPrefix(quote) && text.hasSuffix(quote) && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// Front matter between the first two `---` lines, and everything after.
    private static func split(_ text: String) -> (frontMatter: String, body: String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ("", text) }
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            // An unterminated block is a mistake worth being loud about, but the body is still
            // usable as instructions — better than an app losing its profile to a missing line.
            return (lines.dropFirst().joined(separator: "\n"), "")
        }
        return (
            lines[1..<end].joined(separator: "\n"),
            lines[(end + 1)...].joined(separator: "\n")
        )
    }

    // MARK: - Writing

    /// Back to a file, in the order a person reads: who, then policy, then tools, then prose.
    func markdown() -> String {
        var lines = ["---"]
        if !appName.isEmpty { lines.append("app: \(appName)") }
        if !bundleID.isEmpty { lines.append("bundle_id: \(bundleID)") }
        if !summary.isEmpty { lines.append("summary: \(summary)") }
        if !tools.isEmpty {
            lines.append("tools:")
            appendList(tools.capabilities, key: "capabilities", to: &lines)
            appendList(tools.mcp, key: "mcp", to: &lines)
            appendList(tools.cli, key: "cli", to: &lines)
            appendList(tools.actions, key: "actions", to: &lines)
            appendList(tools.scripts, key: "scripts", to: &lines)
        }
        if !never.isEmpty {
            lines.append("never:")
            lines += never.map { "  - \($0)" }
        }
        if !verify.isEmpty {
            lines.append("verify:")
            lines += verify.keys.sorted().map { "  \($0): \(verify[$0] ?? "")" }
        }
        lines.append("---")
        lines.append("")
        lines.append(instructions)
        return lines.joined(separator: "\n")
    }

    private func appendList(_ values: [String]?, key: String, to lines: inout [String]) {
        guard let values else { return }
        let inline = "  \(key): [\(values.joined(separator: ", "))]"
        // Short lists read best on one line; a long one becomes a wall nobody can edit — and
        // "every capability this app can reach" is sixty of them. Both shapes parse.
        if values.count <= 6, inline.count <= 96 {
            lines.append(inline)
            return
        }
        lines.append("  \(key):")
        lines += values.map { "    - \($0)" }
    }
}
