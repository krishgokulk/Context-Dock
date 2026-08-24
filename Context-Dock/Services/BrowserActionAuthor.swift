//
//  BrowserActionAuthor.swift
//  Context-Dock
//
//  Writes a page userscript for a request no existing route can serve.
//
//  Context Dock resolves a request in order: trigger rules → system commands →
//  find intents → app menus → adapter actions → cross-app intents. Everything in
//  that chain matches against something that *already exists*. A page is different:
//  "dark mode for this page", "hide the sidebar", "expand every comment" have no
//  menu item and no adapter action anywhere, and never will — the capability lives
//  in the page, not the app. Below that chain a browser scope used to fall straight
//  into a general chat answer, so the dock explained how to do the thing instead of
//  doing it.
//
//  This is the last routing step for browser and Safari Web App scopes: ask the
//  provider for one self-contained snippet, hand it to the normal adapter approval
//  sheet, and — once it runs — keep it as a real Browser Extension action on that
//  app's adapter so the second time it is a plain trigger match, not an AI call.
//

import Foundation

@MainActor
final class BrowserActionAuthor {
    static let shared = BrowserActionAuthor()
    private init() {}

    struct Authored {
        let action: AdapterAction
        /// One line for the chat transcript: what the script will do.
        let summary: String
    }

    enum AuthorError: LocalizedError {
        case notFeasible(String)
        case unusableResponse

        var errorDescription: String? {
            switch self {
            case .notFeasible(let reason):
                return reason
            case .unusableResponse:
                return "The model didn't return a usable page script."
            }
        }
    }

    /// Requests that read like "do this to the page I'm looking at". Questions and
    /// content requests ("summarize this", "what does this say") stay with chat —
    /// they want an answer, not a script.
    static func looksLikePageAction(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 3, !q.hasSuffix("?") else { return false }

        // "Install this in my VS Code project" points *through* the page at another app
        // and the local filesystem. It is not a request to mutate the DOM. The old generic
        // `this` fallback captured it, asked the page-script author for JavaScript, and then
        // displayed the author's inevitable filesystem refusal as the assistant's answer.
        guard !isCrossAppProjectRequest(q) else { return false }

        // Browser chrome belongs to the app, not the rendered document. These requests must
        // continue into the shared app-capability resolver where cached/live menus, adapter
        // actions and shortcuts can compete. A page script can never reach this state.
        let browserChromeObjects = [
            "closed tab", "closed window", "recently closed", "last session", "history",
            "bookmark", "private window", "incognito", "new tab", "new window",
            "downloads window", "sidebar", "tab group",
        ]
        let browserChromeVerbs = [
            "reopen", "restore", "open", "close", "new", "show", "hide", "clear",
            "bookmark", "move tab", "pin tab", "duplicate tab",
        ]
        if browserChromeObjects.contains(where: q.contains),
            browserChromeVerbs.contains(where: q.contains)
        {
            return false
        }

        let questionOpeners = [
            "what", "why", "how ", "who", "when", "where", "explain", "summar",
            "describe", "translate", "tell me", "is ", "does ", "do ", "can you tell",
        ]
        if questionOpeners.contains(where: { q.hasPrefix($0) }) { return false }

        // Verbs that act on a rendered page.
        let actionVerbs = [
            "dark mode", "light mode", "night mode", "hide", "show", "remove", "block",
            "expand", "collapse", "zoom", "scroll", "highlight", "copy all", "extract",
            "count", "select all", "click", "toggle", "enable", "disable", "mute",
            "unmute", "pause", "play", "speed", "download all", "open all", "sort",
            "filter", "clean", "declutter", "focus mode", "reader", "font", "colour",
            "color", "background", "contrast", "invert", "fullscreen", "pip",
            "picture in picture", "auto scroll", "stop", "resize",
        ]
        if actionVerbs.contains(where: { q.contains($0) }) { return true }

        // Fall back to "imperative-looking": starts with a bare verb and mentions the page.
        let pageWords = ["page", "site", "tab", "this", "here", "video", "comments"]
        return pageWords.contains { q.contains($0) } && q.split(separator: " ").count <= 10
    }

    /// A browser-to-project handoff. These requests must continue to the scoped agent,
    /// which can read the page and resolve a second app, rather than the page-JavaScript
    /// author whose authority ends at the DOM.
    static func isCrossAppProjectRequest(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let projectTerms = [
            "project", "workspace", "repository", "repo", "codebase", "vs code",
            "vscode", "vscide", "xcode",
        ]
        let transferTerms = [
            "install", "add", "use", "copy", "save", "integrate", "set up", "setup",
            "apply", "bring", "move", "clone", "build",
        ]
        return projectTerms.contains(where: q.contains)
            && transferTerms.contains(where: q.contains)
    }

    static func crossAppProjectGuidance(_ query: String) -> String {
        guard isCrossAppProjectRequest(query) else { return "" }
        return """
            ## Explicit browser-to-project workflow
            This request is NOT a browser page-script task. Follow this order:
            1. Read the supplied current-page evidence and briefly state what package, tool,
               code, or installation instructions the page actually provides.
            2. Resolve the named editor/project app through registered capabilities. Treat
               obvious spelling variants such as "vscide" as a possible "VS Code", but ask
               for confirmation when the target is not certain.
            3. Before changing files, require the exact project/workspace or ask which open
               project the user means. Do not guess a directory.
            4. Propose the concrete file/command changes, obtain native approval, execute,
               and verify the project state. If this turn lacks the project path, stop after
               the page findings and that one clarification.
            Never answer that a page script cannot access local files: no page script was
            requested. Report each source read and each executed action as a visible receipt.
            """
    }

    /// Ask the configured provider for one snippet. Throws rather than returning a
    /// half-formed action — a script we cannot vouch for must never reach the page.
    func author(
        query: String,
        pageURL: String,
        pageTitle: String,
        appName: String
    ) async throws -> Authored {
        let request = AIRequest(
            text: prompt(query: query, pageURL: pageURL, pageTitle: pageTitle, appName: appName),
            context: .none,
            source: .contextDock
        )
        let response = try await AIProviderRouter.shared.send(request)
        guard let json = Self.firstJSONObject(in: response),
            let data = json.data(using: .utf8),
            let parsed = try? JSONDecoder().decode(Draft.self, from: data)
        else { throw AuthorError.unusableResponse }

        if parsed.feasible == false {
            throw AuthorError.notFeasible(
                parsed.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? parsed.reason!
                    : "That can't be done with a page script.")
        }

        let script = (parsed.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (parsed.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, !name.isEmpty else { throw AuthorError.unusableResponse }

        let description = (parsed.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = Self.normalizedTriggers(parsed.triggers, query: query, name: name)

        let action = AdapterAction(
            id: "ai.page.\(Self.slug(name))-\(UUID().uuidString.prefix(6).lowercased())",
            name: name,
            icon: parsed.icon?.isEmpty == false ? parsed.icon! : "wand.and.stars",
            description: description.isEmpty ? query : description,
            triggers: triggers,
            type: .pageJS,
            script: script,
            // Generated code always shows itself before it runs; the standing-grant
            // button on that sheet is what makes the second run unattended.
            requiresApproval: true,
            accentColor: "purple"
        )
        return Authored(action: action, summary: description.isEmpty ? name : description)
    }

    // MARK: - Prompt

    private func prompt(query: String, pageURL: String, pageTitle: String, appName: String) -> String {
        """
        You write ONE self-contained JavaScript snippet that runs inside a web page the \
        user is currently looking at, to carry out their request.

        REQUEST: \(query)
        APP: \(appName)
        PAGE TITLE: \(pageTitle.isEmpty ? "(unknown)" : pageTitle)
        PAGE URL: \(pageURL.isEmpty ? "(unknown)" : pageURL)

        RULES
        - The snippet is evaluated in the page's world. It must be a single IIFE that \
        RETURNS a short status string (under 60 characters) describing what it did.
        - No network requests, no navigation away from the page, no writing to storage \
        other than what the request requires, no external libraries, no eval of remote code.
        - Prefer a toggle when the request implies one (running it twice should undo it, \
        not stack up). Give injected elements a stable id so a rerun can find them.
        - Handle "element not found" by returning a short explanation instead of throwing.
        - Target the real page structure for the URL above when you know it; otherwise use \
        generic, defensive selectors.

        Respond with ONLY a JSON object, no prose and no code fences:
        {"feasible":true,"name":"Short Action Name","description":"one sentence",\
        "icon":"an SF Symbol name","triggers":["phrase","phrase"],"script":"(function(){...})()"}

        If the request genuinely cannot be done by a page script (it needs the browser \
        chrome, another app, or a native permission), respond with:
        {"feasible":false,"reason":"one sentence explaining why"}
        """
    }

    // MARK: - Parsing

    private struct Draft: Decodable {
        var feasible: Bool?
        var reason: String?
        var name: String?
        var description: String?
        var icon: String?
        var triggers: [String]?
        var script: String?
    }

    /// Providers wrap JSON in prose or fences often enough that a strict parse fails on
    /// otherwise good answers; take the outermost balanced object instead.
    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func normalizedTriggers(_ raw: [String]?, query: String, name: String) -> [String] {
        var triggers = (raw ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        // The phrase the user actually typed is the trigger most likely to come back.
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !typed.isEmpty, !triggers.contains(typed) { triggers.insert(typed, at: 0) }
        let lowerName = name.lowercased()
        if !triggers.contains(lowerName) { triggers.append(lowerName) }
        return Array(triggers.prefix(6))
    }

    private static func slug(_ text: String) -> String {
        let allowed = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
