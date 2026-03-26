// FavouriteActionsAI.swift
// ILauncher
//
// On-device AI engine that maps natural language queries to the user's
// favourited menu-bar actions across all apps.
//
// Priority chain:
//   1. Apple Intelligence (FoundationModels, macOS 26+) — private, no API key
//   2. Token-overlap scorer — instant, always works
//
// Cross-app chains: when the AI (or token scorer) finds matches in two
// different apps, executeChain() activates each app in sequence.
//

import AppKit
import ApplicationServices
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - FavouriteMatch

struct FavouriteMatch: Identifiable, Equatable {
    let id       = UUID()
    let bundleId : String
    let appName  : String
    let itemName : String     // exact title stored in favourites
    let confidence: Float     // 0–1
}

// MARK: - FavouriteActionsAI

@MainActor
final class FavouriteActionsAI {
    static let shared = FavouriteActionsAI()
    private init() {}

    // MARK: - Public: match

    /// Returns up to 3 best-matching favourited actions for the natural language query.
    /// Tries on-device Apple Intelligence first; falls back to token scoring.
    func match(query: String, bundleId: String? = nil) async -> [FavouriteMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }

        var all = allFavourites()
        if let bid = bundleId, !bid.isEmpty {
            all = all.filter { $0.bundleId == bid }
        }
        guard !all.isEmpty else { return [] }

        // Try Apple Intelligence (macOS 26+)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability,
               let aiResult = try? await matchWithAI(query: q, favourites: all) {
                return aiResult
            }
        }

        // Fallback: fast token overlap
        return tokenMatch(query: q, favourites: all)
    }

    // MARK: - Public: execute

    /// Execute a single favourite action — activates the target app if needed.
    func execute(_ match: FavouriteMatch) {
        let bundleId = match.bundleId
        let name     = match.itemName

        if let app = runningApp(bundleId: bundleId) {
            activateAndRun(app: app, itemName: name)
        } else {
            // Launch the app first, then execute after it's ready
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, _ in
                guard let app else { return }
                Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { self.activateAndRun(app: app, itemName: name) }
                }
            }
        }
    }

    /// Execute two actions in sequence — for cross-app chains.
    func executeChain(_ first: FavouriteMatch, then second: FavouriteMatch) {
        execute(first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [self] in execute(second) }
    }

    // MARK: - All Favourites Snapshot

    /// Flat list of every user-favourited action across all apps.
    func allFavourites() -> [(bundleId: String, appName: String, name: String)] {
        let dict = AppSettings.shared.allFavouriteMenuPills()
        var result: [(bundleId: String, appName: String, name: String)] = []
        for (bundleId, names) in dict {
            let appName = resolvedAppName(bundleId: bundleId)
            for name in names {
                result.append((bundleId: bundleId, appName: appName, name: name))
            }
        }
        return result
    }

    // MARK: - Private: on-device AI matching

    @available(macOS 26.0, *)
    private func matchWithAI(
        query: String,
        favourites: [(bundleId: String, appName: String, name: String)]
    ) async throws -> [FavouriteMatch] {

        // Build compact action list for the prompt
        var byApp: [String: (bundleId: String, names: [String])] = [:]
        for fav in favourites {
            let key = fav.appName
            if byApp[key] == nil { byApp[key] = (fav.bundleId, []) }
            byApp[key]!.names.append(fav.name)
        }
        let actionLines = byApp.map { appName, pair in
            "\(appName): \(pair.names.joined(separator: " | "))"
        }.joined(separator: "\n")

        let prompt = """
        Match the user's query to one or two macOS app actions from the list below.
        Reply ONLY with a JSON object, no explanation. Format: {"matches":[{"bundleId":"...","name":"..."}]}
        Return empty matches array if nothing fits. Max 2 items (for cross-app chains).
        The "name" must match exactly one of the listed action names.

        Available actions:
        \(actionLines)

        User query: "\(query)"
        """

        // LanguageModelSession can throw if Apple Intelligence catalog service is unavailable
        let session = LanguageModelSession(
            instructions: "You map natural language to macOS app actions. Respond only with valid compact JSON."
        )
        do {
            let response = try await session.respond(to: prompt)
            return parseAIResponse(response.content, favourites: favourites, byApp: byApp)
        } catch {
            // Catalog connection failure or model unavailable — fall through to token scorer
            return []
        }
    }

    private func parseAIResponse(
        _ text: String,
        favourites: [(bundleId: String, appName: String, name: String)],
        byApp: [String: (bundleId: String, names: [String])]
    ) -> [FavouriteMatch] {
        // Extract the first JSON object from the response (use lowerBound on } to avoid endIndex crash)
        guard let start = text.range(of: "{"),
              let end   = text.range(of: "}", options: .backwards),
              start.lowerBound <= end.lowerBound else { return [] }

        let jsonStr = String(text[start.lowerBound...end.lowerBound])
        guard let data = jsonStr.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr  = obj["matches"] as? [[String: String]] else { return [] }

        return arr.compactMap { dict in
            guard let bundleId = dict["bundleId"], !bundleId.isEmpty,
                  let name     = dict["name"],     !name.isEmpty else { return nil }
            // Validate: must exist in our stored favourites
            guard favourites.contains(where: { $0.bundleId == bundleId && $0.name == name }) else {
                // AI might have returned wrong bundleId — try matching by name only
                if let match = favourites.first(where: { $0.name == name }) {
                    return FavouriteMatch(bundleId: match.bundleId, appName: match.appName,
                                         itemName: name, confidence: 0.85)
                }
                return nil
            }
            let appName = resolvedAppName(bundleId: bundleId)
            return FavouriteMatch(bundleId: bundleId, appName: appName,
                                  itemName: name, confidence: 0.92)
        }
    }

    // MARK: - Private: token overlap fallback

    private func tokenMatch(
        query: String,
        favourites: [(bundleId: String, appName: String, name: String)]
    ) -> [FavouriteMatch] {
        let sep   = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let qToks = Set(query.lowercased().components(separatedBy: sep).filter { !$0.isEmpty })

        var scored: [(FavouriteMatch, Float)] = []
        for fav in favourites {
            let nameToks = Set(fav.name.lowercased().components(separatedBy: sep).filter { !$0.isEmpty })
            let appToks  = Set(fav.appName.lowercased().components(separatedBy: sep).filter { !$0.isEmpty })
            let allToks  = nameToks.union(appToks)

            let overlap = Float(qToks.intersection(allToks).count)
            guard overlap > 0 else { continue }

            // Jaccard-like: intersection / union of query and name tokens
            let score = overlap / Float(qToks.union(nameToks).count)
            let m = FavouriteMatch(bundleId: fav.bundleId, appName: fav.appName,
                                   itemName: fav.name, confidence: score)
            scored.append((m, score))
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .compactMap { $0.1 >= 0.25 ? $0.0 : nil }
    }

    // MARK: - Private: AX execution

    private func activateAndRun(app: NSRunningApplication, itemName: String) {
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) {
            app.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 200_000_000)
            let items = AXMenuReader.shared.cachedAllMenuItems(for: pid, maxDepth: 6)
            guard let item = items.first(where: { $0.title == itemName }) else { return }
            if let ch = item.shortcutChar, !ch.isEmpty {
                AXMenuReader.shared.executeShortcut(char: ch, modifiers: item.shortcutModifiers, in: pid)
            } else {
                AXMenuReader.shared.clickMenuItem(path: item.path, in: pid)
            }
        }
    }

    // MARK: - Helpers

    private func runningApp(bundleId: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleId && !$0.isTerminated
        }
    }

    private func resolvedAppName(bundleId: String) -> String {
        if let running = runningApp(bundleId: bundleId) {
            return running.localizedName ?? bundleId.components(separatedBy: ".").last ?? bundleId
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleId.components(separatedBy: ".").last ?? bundleId
    }
}
