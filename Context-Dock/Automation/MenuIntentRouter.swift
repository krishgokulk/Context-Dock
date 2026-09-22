// MenuIntentRouter.swift
// Context-Dock
//
// Routes natural language → frontmost app's cached menu → click.
// Completely isolated per app — Safari menus never mix with Xcode menus.
//
// Tier 1: Keyword score ≥ threshold → click instantly, zero AI
// Tier 2: Low confidence → on-device AI picks from top candidates (typed output)
// Tier 3: Not a menu action → returns nil, caller falls through to normal AI
//
// Tier 2 answers with a @Generable value rather than prose: the model fills in an index and
// how sure it is, and the app reads fields instead of parsing a sentence. The older picker
// asked for "ONLY a single integer" and threw the answer away whenever the model wrote
// "Item 3" — a correct pick lost to its formatting.
//
// A pick the model is guessing at is dropped rather than offered. Tier 2 is reached only
// because tier 1 already found no confident match, so a shaky guess on top of an already
// weak shortlist is worth less than saying nothing and letting the request fall through to
// a normal AI answer.

import AppKit
import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif


// MARK: - Typed answer

#if canImport(FoundationModels)
/// What the on-device model is allowed to answer with when it disambiguates a menu query.
///
/// Two fields, both read as fields. There is no output format for the model to get wrong,
/// which is the whole point of asking this way.
@available(macOS 26.0, *)
@Generable
struct MenuPick {
    @Guide(
        description:
            "The 1-based number of the menu item that does what the user asked, or 0 if none of them do."
    )
    var index: Int

    @Guide(
        description:
            "How sure you are: 'certain' if the item plainly does what was asked, 'likely' if it probably does, 'unsure' if you are guessing."
    )
    var certainty: String
}
#endif

/// The rule applied to a pick, kept out of the model call so it can be tested without one.
enum MenuPickRule {
    /// Words that mean the model was guessing.
    ///
    /// Matched as a reject list rather than by requiring an approved word: an answer like
    /// "very sure" should still count as a pick, and would be thrown away by a rule that
    /// only accepted three exact spellings.
    static let lowConfidenceWords: Set<String> = [
        "unsure", "uncertain", "guess", "guessing", "low", "none", "no",
    ]

    /// The index into the candidate list to propose, or nil when nothing should be proposed.
    ///
    /// Index 0, an index outside the list, and a guess all collapse to the same answer here:
    /// no menu proposal.
    static func candidateIndex(index: Int, certainty: String, candidateCount: Int) -> Int? {
        guard candidateCount > 0, index >= 1, index <= candidateCount else { return nil }
        let word = certainty.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowConfidenceWords.contains(word) else { return nil }
        return index - 1
    }
}


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

    // MARK: - FoundationModels typed picker (macOS 26+)

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func askOnDeviceStructured(query: String, candidates: [AXMenuItem]) async -> AXMenuItem? {
        let list = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element.pathString)" }
            .joined(separator: "\n")

        // Nothing here dictates a reply format, because the shape of the reply is no longer
        // the model's problem: `generating: MenuPick.self` decodes fields.
        let instructions = """
        You pick the macOS menu item that does what the user asked.
        Answer with that item's number and how sure you are.
        Use 0 when none of the items do what was asked.
        """

        let prompt = "User said: \"\(query)\"\n\nMenu items:\n\(list)"

        do {
            let session = LanguageModelSession(instructions: instructions)
            let pick = try await session.respond(to: prompt, generating: MenuPick.self).content
            guard
                let index = MenuPickRule.candidateIndex(
                    index: pick.index,
                    certainty: pick.certainty,
                    candidateCount: candidates.count)
            else { return nil }
            return candidates[index]
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
