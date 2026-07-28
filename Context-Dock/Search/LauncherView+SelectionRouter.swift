import AppKit
import Foundation
import SwiftUI

/// Selection Scope "Ask AI" routing.
///
/// The result sheet already exposes everything the user can do with a selection — share
/// destinations, selection extensions, Finder/app menu items, Shortcuts, built-in workflows.
/// Before this router, Ask AI ignored all of it: the model got the selection text and nothing
/// else, so it narrated ("Should I: 1… 2… 3…") or claimed success for work that never ran.
///
/// Order of operations once the user presses Enter on Ask AI:
///   1. classify intent — a question answers from facts and never executes
///   2. build the catalog (the same pills the sheet renders, unfiltered)
///   3. exact-title match → run it, no provider call
///   4. otherwise the model picks ONE id from the catalog (semantic re-rank)
///   5. execute, and report from the execution — never from generated prose
///   6. no route → hand back to the answer path, which explains the gap and proposes an extension
extension LauncherView {

    enum SelectionQueryIntent {
        case question   // "size of this folder" — answer from facts, never execute
        case action     // "airdrop this", "save to quick note" — must route or say it can't
        case transform  // "rewrite this" — text in, text out
    }

    struct SelectionRouteCandidate {
        let id: String
        let title: String
        let group: String
        let accepts: String
    }

    // MARK: - Intent

    func classifySelectionQueryIntent(_ query: String) -> SelectionQueryIntent {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return .question }
        // "can you add this to reminders" is a request, not a question. Strip the polite wrapper
        // before judging, or every phrased-as-a-favour action reads as something to answer.
        let politeLeads = [
            "can you ", "could you ", "would you ", "will you ", "please ", "pls ",
            "i want you to ", "i need you to ", "help me ", "hey ",
        ]
        var strippedPolite = false
        var changed = true
        while changed {
            changed = false
            for lead in politeLeads where q.hasPrefix(lead) {
                q = String(q.dropFirst(lead.count))
                strippedPolite = true
                changed = true
            }
        }
        let trailing = CharacterSet(charactersIn: " .!")
        let core = q.trimmingCharacters(in: trailing)
        guard !core.isEmpty else { return .question }

        let transformVerbs = [
            "rewrite", "reword", "rephrase", "translate", "proofread", "fix grammar",
        ]
        if transformVerbs.contains(where: { core.contains($0) }) { return .transform }

        // An action verb anywhere wins: "summarize and send to notes" is a send.
        if selectionActionVerbs.contains(where: { core.contains($0) }) { return .action }

        let questionLeads = [
            "what", "why", "how many", "how much", "how big", "how do", "when", "who", "which",
            "explain", "describe", "tell me", "summar", "is this", "are these", "does this",
            "size of", "count of", "about this",
        ]
        if questionLeads.contains(where: { core.hasPrefix($0) || core.contains($0) }) {
            return .question
        }
        // "…?" only means a question once no action verb matched.
        if query.trimmingCharacters(in: .whitespaces).hasSuffix("?") { return .question }
        // A stripped "can you …" with no recognised verb is still a request for something to
        // happen — let the router look for a route rather than answering.
        return strippedPolite ? .action : .question
    }

    private var selectionActionVerbs: [String] {
        [
            "share", "send", "airdrop", "email", "mail", "message", "post", "text ",
            "compress", "zip", "archive", "unzip", "extract",
            "convert", "resize", "export", "rename", "duplicate", "move", "copy",
            "delete", "trash", "tag", "open", "run", "print", "upload", "ocr",
            "quick look", "preview", "info", "reveal",
            // Capture / scheduling destinations. These are the verbs users actually type at a
            // selection ("add this to reminders", "remind me at 10pm", "save to notes").
            "save", "add to", "add this", "put in", "put this", "note this", "make a note",
            "remind", "reminder", "schedule", "calendar", "event", "todo", "to-do", "task",
        ]
    }

    // MARK: - Catalog

    /// The unfiltered set of rows Selection Scope can execute right now. Built from the exact
    /// same pipeline the sheet renders (`buildDockPills` with an empty query), so the model can
    /// only ever pick something the user could have clicked.
    @MainActor
    func selectionRouteCatalogPills() -> [DockPill] {
        guard hasSelectionScopeSurface else { return [] }
        return selectionScopedDockPills(buildDockPills(query: ""))
            .filter { pill in
                guard !pill.isSeparator, pill.isEnabled else { return false }
                // The Ask AI row is the thing that got us here — never route back into it.
                return pill.rankingKind != "selectionAI" && pill.id != "selection-ask-ai"
            }
    }

    func selectionRouteIdentifier(for pill: DockPill) -> String {
        pill.trackingIdentifier.isEmpty ? pill.id : pill.trackingIdentifier
    }

    func selectionRouteGroup(for pill: DockPill) -> String {
        if pill.isShareAction { return "Share" }
        let kind = pill.rankingKind.lowercased()
        if kind.contains("finder") || kind == "menu" || kind == "submenuchild" {
            return pill.menuContext ?? "Menu"
        }
        if let badge = pill.badge, !badge.isEmpty { return badge }
        return "Action"
    }

    /// What payload each route expects, so a folder never gets routed into a text-only tool.
    func selectionRouteAccepts(_ pill: DockPill) -> String {
        let name = pill.name.lowercased()
        if pill.isShareAction { return "any" }
        if name.contains("text") || name.contains("rewrite") || name.contains("summar") {
            return "text"
        }
        if name.contains("file") || name.contains("folder") || name.contains("compress")
            || name.contains("zip") || name.contains("info")
        {
            return "files"
        }
        return "any"
    }

    func selectionCatalogPromptBlock(_ pills: [DockPill]) -> String {
        guard !pills.isEmpty else { return "" }
        let rows = pills.prefix(60).map { pill -> String in
            let id = selectionRouteIdentifier(for: pill)
            let group = selectionRouteGroup(for: pill)
            return "- id: \(id) | \(pill.name) | \(group) | accepts: \(selectionRouteAccepts(pill))"
        }
        return rows.joined(separator: "\n")
    }

    /// What the selection actually is, for the payload guard.
    func selectionPayloadKind() -> String {
        if !aiMode.selectionFiles.isEmpty { return "files" }
        if aiMode.selectionURL?.isEmpty == false { return "url" }
        if aiMode.selectionText?.isEmpty == false { return "text" }
        switch effectiveSelectionForScope {
        case .files: return "files"
        case .text: return "text"
        case .url: return "url"
        case nil: return "none"
        }
    }

    // MARK: - File operation routes

    /// Finder-style file work the sheet has no single row for ("move to pictures", "rename to X").
    /// These run through FileManager/NSWorkspace — see SelectionFileOperations for why that beats
    /// shelling out to mv/cp or scripting Finder.
    var selectionFileOperationRoutes: [(id: String, title: String, args: String)] {
        [
            ("fileop.move", "Move to folder", "destination (folder name or path)"),
            ("fileop.copy", "Copy to folder", "destination (folder name or path)"),
            ("fileop.rename", "Rename", "name (new file name, single item only)"),
            ("fileop.duplicate", "Duplicate", "—"),
            ("fileop.trash", "Move to Trash", "—"),
            ("fileop.newfolder", "New folder containing the selection", "name (folder name)"),
            ("fileop.tag", "Add Finder tag", "tags (comma separated)"),
            ("fileop.reveal", "Reveal in Finder", "—"),
        ]
    }

    func selectionFileOperationPromptBlock() -> String {
        selectionFileOperationRoutes
            .map { "- id: \($0.id) | \($0.title) | File operation | args: \($0.args)" }
            .joined(separator: "\n")
    }

    /// Executes a `fileop.*` route and reports exactly what the filesystem did.
    func runSelectionFileOperation(id: String, args: [String: String]) async -> String? {
        let urls = await MainActor.run { effectiveSelectedFileURLsForConversation() }
        guard !urls.isEmpty else { return nil }
        let ops = SelectionFileOperations.shared

        let result: SelectionFileOperationResult
        switch id {
        case "fileop.move", "fileop.copy":
            let raw = args["destination"] ?? ""
            guard let directory = ops.resolveDestinationDirectory(raw) else {
                await selectionRouterStep("Destination \"\(raw)\" did not resolve — nothing moved")
                return "I did not move anything: \"\(raw)\" is not a folder I can resolve. "
                    + "Give me a folder name (Pictures, Downloads, Desktop) or a full path."
            }
            await selectionRouterStep(
                "\(id == "fileop.move" ? "Moving" : "Copying") \(urls.count) item(s) → \(directory.lastPathComponent)…"
            )
            result = id == "fileop.move"
                ? ops.move(urls, to: directory)
                : ops.copy(urls, to: directory)
        case "fileop.rename":
            await selectionRouterStep("Renaming…")
            result = ops.rename(urls, to: args["name"] ?? "")
        case "fileop.duplicate":
            await selectionRouterStep("Duplicating \(urls.count) item(s)…")
            result = ops.duplicate(urls)
        case "fileop.trash":
            await selectionRouterStep("Moving \(urls.count) item(s) to Trash…")
            result = ops.trash(urls)
        case "fileop.newfolder":
            await selectionRouterStep("Creating folder…")
            result = ops.newFolder(named: args["name"] ?? "", containing: urls)
        case "fileop.tag":
            let tags = (args["tags"] ?? "").split(separator: ",").map(String.init)
            await selectionRouterStep("Tagging \(urls.count) item(s)…")
            result = ops.tag(urls, names: tags)
        case "fileop.reveal":
            await selectionRouterStep("Revealing in Finder…")
            result = await MainActor.run { ops.reveal(urls) }
        default:
            return nil
        }

        let title = selectionFileOperationRoutes.first { $0.id == id }?.title ?? id
        await MainActor.run {
            aiMode.pendingToolChips = [title]
            selectionRouterExecutedRouteTitle = result.success ? title : nil
        }
        guard result.success else {
            await selectionRouterStep("\(title) did not complete")
            return "**\(title) did not run.** \(result.summary)"
        }
        await selectionRouterStep("\(title) completed")
        return "**\(title)**\n\n\(result.summary)"
    }

    // MARK: - Router

    /// Runs the ordered Ask AI flow. Returns the final answer when a route ran (or when the
    /// request is impossible to route), or nil to fall through to the normal answer path.
    func runSelectionActionRouter(
        query: String,
        providerSelection: AIProviderSelection
    ) async -> String? {
        let intent = await MainActor.run { classifySelectionQueryIntent(query) }
        // Questions and text transforms are answered, not executed.
        guard intent == .action else {
            await selectionRouterStep(
                intent == .question
                    ? "Read as a question — answering from the selection, not running anything"
                    : "Read as a text transform — no action route needed")
            return nil
        }

        await selectionRouterStep("Reading selection…")
        let catalog = await MainActor.run { selectionRouteCatalogPills() }
        guard !catalog.isEmpty else {
            await selectionRouterStep("No actions available for this selection")
            return nil
        }

        let payloadKind = await MainActor.run { selectionPayloadKind() }
        let groups = await MainActor.run {
            Dictionary(grouping: catalog) { selectionRouteGroup(for: $0) }.count
        }
        await selectionRouterStep(
            "Matching \(catalog.count) actions across \(groups) groups (share, menus, extensions)…"
        )

        // 3 — exact title hit: run it without spending a provider call.
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = catalog.first(where: { $0.name.lowercased() == normalizedQuery }) {
            await selectionRouterStep("Exact match — no model needed")
            return await executeSelectionRoute(exact, payloadKind: payloadKind)
        }

        // 4 — model picks one id from the catalog. It may answer only with the JSON below.
        await selectionRouterStep("Choosing the best path…")
        let catalogBlock = await MainActor.run { selectionCatalogPromptBlock(catalog) }
        let fileOpsBlock = payloadKind == "files" ? selectionFileOperationPromptBlock() : ""
        let systemPrompt = """
            You are DoraX's Selection Scope router. The user has \(payloadKind) selected and asked \
            for an ACTION. Below is the COMPLETE list of actions available for this selection — \
            share destinations, installed extensions, app menu commands, Shortcuts and built-in \
            tools. These are the only things that can run.

            Available routes:
            \(catalogBlock)
            \(fileOpsBlock.isEmpty ? "" : "\n" + fileOpsBlock)

            Reply with ONE line of JSON and nothing else:
            {"selection_action":{"id":"<exact id from the list>"}}
            {"selection_action":{"id":"fileop.move","args":{"destination":"Pictures"}}}
            or, when NOTHING in the list performs the request:
            {"selection_action":{"id":"none","reason":"<short reason>"}}

            Rules:
            - The id must be copied exactly from the list. Never invent one.
            - Pick the route whose effect matches the request, not one that merely shares a word.
            - The route must accept \(payloadKind) (or "any").
            - Include "args" only for routes that list them, using the exact key names shown.
            - Prefer a single route. Do not explain, do not add prose.
            """
        let request = AIRequestBuilder.aiChat(text: query, history: [])
        let snapshot = await MainActor.run { currentAISelectionSnapshot }
        let raw: String
        do {
            raw = try await AIOrchestrationEngine.shared.submit(
                AIOrchestrationRequest(
                    providerRequest: request,
                    scope: .selection(snapshot),
                    policy: .generalChat,
                    providerSelection: providerSelection,
                    contextPrompt: systemPrompt
                )
            ).text
        } catch {
            await selectionRouterStep("Route lookup failed — falling back to a plain answer")
            return nil
        }

        guard let choice = parseSelectionRoute(from: raw) else {
            await selectionRouterStep("No usable route returned — falling back to a plain answer")
            return nil
        }
        let chosenID = choice.id
        if chosenID.hasPrefix("fileop.") {
            await selectionRouterStep("Best path: File operation · \(chosenID)")
            if let answer = await runSelectionFileOperation(id: chosenID, args: choice.args) {
                return answer
            }
            await selectionRouterStep("File operation could not run — falling back to an answer")
            return nil
        }
        guard chosenID != "none" else {
            // 6 — nothing fits. Fall through so the answer path explains the gap and offers the
            // extension proposal, with the catalog size stated so the reply isn't a bare "no".
            await MainActor.run {
                selectionRouterNoRouteNote =
                    "The Selection Scope router checked all \(catalog.count) available actions, "
                    + "menus, extensions and share destinations for this selection and found no "
                    + "route that performs the request."
            }
            await selectionRouterStep("No route performs this — explaining the gap instead")
            return nil
        }
        guard let pill = catalog.first(where: { selectionRouteIdentifier(for: $0) == chosenID })
        else {
            await selectionRouterStep("Model picked an unknown id — falling back to a plain answer")
            return nil
        }
        await selectionRouterStep("Best path: \(selectionRouteGroupLabel(pill)) · \(pill.name)")

        // 3b — payload guard: a route that needs files must not run on a text selection.
        let accepts = await MainActor.run { selectionRouteAccepts(pill) }
        guard accepts == "any" || accepts == payloadKind else {
            await MainActor.run {
                selectionRouterNoRouteNote =
                    "The closest match (\(pill.name)) does not accept \(payloadKind)."
            }
            await selectionRouterStep("\(pill.name) does not accept \(payloadKind) — not running it")
            return nil
        }

        return await executeSelectionRoute(pill, payloadKind: payloadKind)
    }

    /// Runs the chosen row and reports what ran. The confirmation is composed here, from the
    /// execution — never generated — so the chat can't claim work that did not happen.
    private func executeSelectionRoute(_ pill: DockPill, payloadKind: String) async -> String {
        let title = pill.name
        await selectionRouterStep("Running \(title)…")
        await MainActor.run {
            aiMode.pendingToolChips = [title]
            selectionRouterExecutedRouteTitle = title
            pill.execute()
        }
        let label = await MainActor.run { selectionRouteSubjectLabel() }
        return "Ran **\(title)**\(label.isEmpty ? "" : " on \(label)")."
    }

    /// Last line of defence for the execution-truth rule. When Selection Scope answered an action
    /// request without running anything, a model can still open with "IMG_4588.jpg moved to
    /// Pictures — Done." — prose that reads exactly like a receipt. Stamp the truth on top rather
    /// than letting the claim stand alone.
    func enforceNoFalseSelectionSuccess(_ text: String) -> String {
        let head = String(text.prefix(240)).lowercased()
        let claims = [
            "moved to", "saved to", "sent to", "shared to", "copied to", "renamed to",
            "added to", "created ", "deleted", "compressed", "converted", "uploaded",
            "has been moved", "has been saved", "successfully",
        ]
        guard claims.contains(where: head.contains) else { return text }
        return """
            **Nothing ran.** No action in this selection's sheet performs that, so DoraX did not \
            change anything. What follows is a suggestion, not a result.

            \(text)
            """
    }

    /// Leaving Selection Scope ends its conversation too — the chat is grounded in a selection
    /// that no longer applies, so keeping it would answer the next selection with stale content.
    func exitSelectionScopeAIChat() {
        aiMode.currentTask?.cancel()
        aiMode.currentTask = nil
        aiMode.isActive = false
        aiMode.messages = []
        aiMode.isLoading = false
        aiMode.loadingStatus = nil
        aiMode.streamingId = nil
        aiMode.pendingToolChips = []
        aiMode.routerTrace = []
        aiMode.pendingShare = nil
        aiMode.pendingEnableApp = nil
        aiMode.attachments = []
        aiMode.selectionText = nil
        aiMode.selectionFiles = []
        aiMode.selectionURL = nil
        selectionRouterExecutedRouteTitle = nil
        selectionRouterNoRouteNote = nil
        hasUserSentMessageInCurrentSession = false
        clearGeneralAIConversation()
    }

    /// One step of the live trace: shown next to the typing indicator now, kept on the answer
    /// afterwards. Every line describes work the app performed, never model reasoning.
    func selectionRouterStep(_ text: String) async {
        await MainActor.run {
            aiMode.loadingStatus = text
            aiMode.routerTrace.append(text)
        }
    }

    func selectionRouteGroupLabel(_ pill: DockPill) -> String {
        selectionRouteGroup(for: pill)
    }

    func selectionRouteSubjectLabel() -> String {
        if aiMode.selectionFiles.count > 1 { return "\(aiMode.selectionFiles.count) selected files" }
        if let file = aiMode.selectionFiles.first { return file.lastPathComponent }
        if let text = aiMode.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return "the selected text"
        }
        return ""
    }

    /// Pulls the route out of `{"selection_action":{"id":"…","args":{…}}}`, tolerating code
    /// fences and surrounding prose by scanning for the balanced object.
    func parseSelectionRoute(from response: String) -> (id: String, args: [String: String])? {
        guard let keyRange = response.range(of: "\"selection_action\"") else { return nil }
        // Walk back to the enclosing "{", then forward to its matching "}".
        guard let objectStart = response[..<keyRange.lowerBound].lastIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var objectEnd: String.Index?
        var index = objectStart
        while index < response.endIndex {
            let character = response[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    objectEnd = response.index(after: index)
                    break
                }
            }
            index = response.index(after: index)
        }
        guard let objectEnd,
            let data = String(response[objectStart..<objectEnd]).data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = root["selection_action"] as? [String: Any],
            let id = (action["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty
        else { return nil }

        var args: [String: String] = [:]
        if let rawArgs = action["args"] as? [String: Any] {
            for (key, value) in rawArgs {
                if let string = value as? String {
                    args[key] = string
                } else if let array = value as? [String] {
                    args[key] = array.joined(separator: ",")
                } else {
                    args[key] = String(describing: value)
                }
            }
        }
        return (id, args)
    }
}
