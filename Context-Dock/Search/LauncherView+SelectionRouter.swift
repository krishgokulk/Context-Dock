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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return .question }
        let questionLeads = [
            "what", "why", "how many", "how much", "how big", "when", "who", "which",
            "explain", "describe", "tell me", "summar", "is this", "are these", "does this",
            "size of", "count of",
        ]
        if q.hasSuffix("?") { return .question }
        if questionLeads.contains(where: { q.hasPrefix($0) || q.contains($0) }) {
            // "summarize and send to notes" is still an action — a destination verb wins.
            if !selectionActionVerbs.contains(where: { q.contains($0) }) { return .question }
        }
        let transformVerbs = ["rewrite", "reword", "rephrase", "translate", "proofread", "fix grammar"]
        if transformVerbs.contains(where: { q.contains($0) }) { return .transform }
        if selectionActionVerbs.contains(where: { q.contains($0) }) { return .action }
        return .question
    }

    private var selectionActionVerbs: [String] {
        [
            "share", "send", "airdrop", "email", "mail", "message", "post",
            "compress", "zip", "archive", "unzip", "extract",
            "convert", "resize", "export", "rename", "duplicate", "move", "copy",
            "delete", "trash", "tag", "open", "run", "save", "add to", "put in",
            "print", "upload", "quick look", "preview", "info", "reveal", "ocr",
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
        let systemPrompt = """
            You are DoraX's Selection Scope router. The user has \(payloadKind) selected and asked \
            for an ACTION. Below is the COMPLETE list of actions available for this selection — \
            share destinations, installed extensions, app menu commands, Shortcuts and built-in \
            tools. These are the only things that can run.

            Available routes:
            \(catalogBlock)

            Reply with ONE line of JSON and nothing else:
            {"selection_action":{"id":"<exact id from the list>"}}
            or, when NOTHING in the list performs the request:
            {"selection_action":{"id":"none","reason":"<short reason>"}}

            Rules:
            - The id must be copied exactly from the list. Never invent one.
            - Pick the route whose effect matches the request, not one that merely shares a word.
            - The route must accept \(payloadKind) (or "any").
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

        guard let chosenID = parseSelectionRouteID(from: raw) else {
            await selectionRouterStep("No usable route returned — falling back to a plain answer")
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

    /// Pulls the id out of `{"selection_action":{"id":"…"}}`, tolerating code fences and prose.
    func parseSelectionRouteID(from response: String) -> String? {
        guard let range = response.range(of: "\"selection_action\"") else { return nil }
        let tail = response[range.upperBound...]
        guard let idRange = tail.range(of: "\"id\"") else { return nil }
        let afterID = tail[idRange.upperBound...]
        guard let colon = afterID.firstIndex(of: ":") else { return nil }
        let valuePart = afterID[afterID.index(after: colon)...]
        guard let openQuote = valuePart.firstIndex(of: "\"") else { return nil }
        let valueStart = valuePart.index(after: openQuote)
        guard let closeQuote = valuePart[valueStart...].firstIndex(of: "\"") else { return nil }
        let id = String(valuePart[valueStart..<closeQuote])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
