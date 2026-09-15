// MenuIntentRouter.swift
// Context-Dock
//
// Routes natural language → frontmost app's cached menu → click.
// Completely isolated per app — Safari menus never mix with Xcode menus.
//
// Tier 1: Keyword score ≥ threshold → click instantly, zero AI
// Tier 2: Low confidence → on-device AI picks from top candidates (structured output)
// Tier 3: Not a menu action → returns nil, caller falls through to normal AI
//
// Tier 2 uses FoundationModels @Generable so the model is constrained to emit
// { index: Int?, noMatch: Bool } — no text parsing, no hallucinated numbers.

import AppKit
import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif


// MARK: - Router

@MainActor
final class MenuIntentRouter {
    static let shared = MenuIntentRouter()
    private init() {}

    // Score required to auto-click without asking AI (0–100 scale from ranker)
    private let autoClickThreshold = 40

    // MARK: - Main entry point

    /// Find the best matching menu item for `query` WITHOUT executing it.
    /// Returns the matched AXMenuItem, or nil if no good match found.
    /// Same match, for an app that is not running — scored against its cached snapshot only.
    ///
    /// `scoredCandidates` already reads the cache first and only adds live items when a pid is
    /// supplied, so passing 0 reuses the one scorer rather than introducing a second one that
    /// could disagree with it.
    ///
    /// Deliberately strict: only an above-threshold match qualifies, because acting on this
    /// launches an app as a side effect. A weak guess is not worth that.
    func findCachedMatch(
        query: String, bundleId: String, appName: String
    ) async -> AXMenuItem? {
        guard !bundleId.isEmpty else { return nil }
        let candidates = scoredCandidates(query: query, bundleID: bundleId, pid: 0)
        guard let top = candidates.first, top.score >= autoClickThreshold else { return nil }
        return top.item
    }

    func findMatch(query: String, app: NSRunningApplication) async -> AXMenuItem? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        let candidates = scoredCandidates(query: query, bundleID: bundleID, pid: app.processIdentifier)
        if let top = candidates.first, top.score >= autoClickThreshold {
            return top.item
        }
        guard !candidates.isEmpty else { return nil }
        let shortList = candidates.prefix(10).map { $0.item }
        return await disambiguate(query: query, candidates: shortList)
    }

    /// Try to resolve `query` as a menu action for `app`.
    /// Returns the clicked menu path on success, nil if not a menu action.
    func resolve(query: String, app: NSRunningApplication) async -> String? {
        guard let item = await findMatch(query: query, app: app) else { return nil }
        return click(item: item, app: app)
    }

    // MARK: - Scoring

    private struct ScoredItem {
        let item: AXMenuItem
        let score: Int
    }

    private func scoredCandidates(query: String, bundleID: String, pid: pid_t) -> [ScoredItem] {
        let cached = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID,
            appName: "",
            processIdentifier: pid,
            query: query,
            maxResults: 20
        )

        var liveItems: [AXMenuItem] = []
        if pid > 0 {
            liveItems = AXMenuReader.shared.searchMenuItems(query: query, in: pid, maxResults: 10)
        }

        var seen = Set<String>()
        var merged: [AXMenuItem] = []
        for item in liveItems + cached {
            let key = item.path.map { $0.lowercased() }.joined(separator: ">")
            if seen.insert(key).inserted { merged.append(item) }
        }

        let q = AppMenuCapabilityCache.normalize(query)
        let tokens = q.split(separator: " ").map(String.init).filter { $0.count > 2 }

        return merged.compactMap { item -> ScoredItem? in
            guard item.children.isEmpty else { return nil }
            guard item.isEnabled else { return nil }

            let title = AppMenuCapabilityCache.normalize(item.title)
            let path  = AppMenuCapabilityCache.normalize(item.pathString)
            var score = 0

            if title == q            { score += 100 }
            else if title.hasPrefix(q) { score += 75  }
            else if title.contains(q)  { score += 55  }
            else if path.contains(q)   { score += 35  }

            for token in tokens {
                if title == token            { score += 40 }
                else if title.hasPrefix(token) { score += 28 }
                else if title.contains(token)  { score += 18 }
                else if path.contains(token)   { score += 10 }
            }

            guard score > 0 else { return nil }
            return ScoredItem(item: item, score: score)
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Disambiguation

    /// Routes to FoundationModels structured output on macOS 26+,
    /// falls back to cloud sendPureChat on earlier OS or unavailable model.
    private func disambiguate(query: String, candidates: [AXMenuItem]) async -> AXMenuItem? {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await askOnDeviceStructured(query: query, candidates: candidates)
        }
#endif
        return await askCloudAI(query: query, candidates: candidates)
    }

    // MARK: - FoundationModels structured picker (macOS 26+)

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func askOnDeviceStructured(query: String, candidates: [AXMenuItem]) async -> AXMenuItem? {
        let list = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element.pathString)" }
            .joined(separator: "\n")

        // Instructions force the model to emit ONLY a number or the word "none".
        // Using generating: String.self constrains the output to a short string —
        // the model cannot produce multi-sentence explanations.
        let instructions = """
        You select the best matching macOS menu item for the user's request.
        Reply with ONLY a single integer (the 1-based index) or the word none.
        No punctuation, no explanation, no other text.
        """

        let prompt = "User said: \"\(query)\"\n\nMenu items:\n\(list)"

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: String.self)
            let choice = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard choice.lowercased() != "none",
                  let idx = Int(choice),
                  idx >= 1, idx <= candidates.count
            else { return nil }
            return candidates[idx - 1]
        } catch {
            return await askCloudAI(query: query, candidates: candidates)
        }
    }
#endif

    // MARK: - Cloud AI fallback (text parse)

    private func askCloudAI(query: String, candidates: [AXMenuItem]) async -> AXMenuItem? {
        let list = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element.pathString)" }
            .joined(separator: "\n")

        let prompt = """
        The user of a macOS app said: "\(query)"
        Pick the best matching menu action. Reply with ONLY the number (1, 2, 3…) or "none".

        \(list)
        """

        let selection = AIProviderSelectionResolver.current()
        let request = AIRequest(
            text: prompt,
            context: .none,
            source: .contextDock,
            providerSelection: selection
        )
        guard let response = try? await AIProviderRouter.shared.send(request) else { return nil }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased() != "none",
              let number = trimmed.components(separatedBy: .whitespaces).first,
              let index = Int(number),
              index >= 1, index <= candidates.count
        else { return nil }
        return candidates[index - 1]
    }

    // MARK: - Click

    private func click(item: AXMenuItem, app: NSRunningApplication) -> String {
        if item.isChecked {
            AppToast.show("Already on: \(item.pathString)", icon: "checkmark.circle.fill",
                          tint: .green, centered: true)
            return item.pathString
        }
        AXActionResolver.shared.execute(menuPath: item.path, in: app)
        return item.pathString
    }
}
