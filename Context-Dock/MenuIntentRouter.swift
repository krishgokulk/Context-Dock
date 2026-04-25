// MenuIntentRouter.swift
// Context-Dock
//
// Routes natural language → frontmost app's cached menu → click.
// Completely isolated per app — Safari menus never mix with Xcode menus.
//
// Tier 1: Keyword score ≥ threshold → click instantly, zero AI
// Tier 2: Low confidence → on-device AI picks from top candidates (tiny prompt)
// Tier 3: Not a menu action → returns nil, caller falls through to normal AI

import AppKit
import Foundation

@MainActor
final class MenuIntentRouter {
    static let shared = MenuIntentRouter()
    private init() {}

    // Score required to auto-click without asking AI (0–100 scale from ranker)
    private let autoClickThreshold = 40

    // MARK: - Main entry point

    /// Try to resolve `query` as a menu action for `app`.
    /// Returns the clicked menu path on success, nil if not a menu action.
    func resolve(query: String, app: NSRunningApplication) async -> String? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        let pid = app.processIdentifier

        // ── Tier 1: keyword score ─────────────────────────────────────────────
        let candidates = scoredCandidates(query: query, bundleID: bundleID, pid: pid)
        if let top = candidates.first, top.score >= autoClickThreshold {
            return click(item: top.item, pid: pid)
        }

        // ── Tier 2: on-device AI picks from top candidates ────────────────────
        // Only if we have some candidates (i.e. it looks menu-related)
        guard !candidates.isEmpty else { return nil }
        let shortList = candidates.prefix(10).map { $0.item }
        guard let picked = await askOnDeviceAI(query: query, candidates: shortList) else { return nil }
        return click(item: picked, pid: pid)
    }

    // MARK: - Scoring

    private struct ScoredItem {
        let item: AXMenuItem
        let score: Int
    }

    private func scoredCandidates(query: String, bundleID: String, pid: pid_t) -> [ScoredItem] {
        // Pull from persistent cache first (works even if app is closed)
        let cached = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID,
            appName: "",
            processIdentifier: pid,
            query: query,
            maxResults: 20
        )

        // If app is live, also do a quick live AX search and merge
        var liveItems: [AXMenuItem] = []
        if pid > 0 {
            liveItems = AXMenuReader.shared.searchMenuItems(query: query, in: pid, maxResults: 10)
        }

        // Merge: prefer live items (they have real AX elements for clicking)
        var seen = Set<String>()
        var merged: [AXMenuItem] = []
        for item in liveItems + cached {
            let key = item.path.map { $0.lowercased() }.joined(separator: ">")
            if seen.insert(key).inserted { merged.append(item) }
        }

        let q = AppMenuCapabilityCache.normalize(query)
        let tokens = q.split(separator: " ").map(String.init).filter { $0.count > 2 }

        return merged.compactMap { item -> ScoredItem? in
            let title = AppMenuCapabilityCache.normalize(item.title)
            let path  = AppMenuCapabilityCache.normalize(item.pathString)
            var score = 0

            // Exact / prefix / contains on title
            if title == q            { score += 100 }
            else if title.hasPrefix(q) { score += 75  }
            else if title.contains(q)  { score += 55  }
            else if path.contains(q)   { score += 35  }

            // Per-token scoring
            for token in tokens {
                if title == token            { score += 40 }
                else if title.hasPrefix(token) { score += 28 }
                else if title.contains(token)  { score += 18 }
                else if path.contains(token)   { score += 10 }
            }

            // Disabled items can still be surfaced but get a penalty
            if !item.isEnabled { score = max(0, score - 20) }

            guard score > 0 else { return nil }
            return ScoredItem(item: item, score: score)
        }.sorted { $0.score > $1.score }
    }

    // MARK: - On-device AI disambiguation (tiny prompt)

    private func askOnDeviceAI(query: String, candidates: [AXMenuItem]) async -> AXMenuItem? {
        let list = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element.pathString)" }
            .joined(separator: "\n")

        let prompt = """
        The user of a macOS app said: "\(query)"
        Pick the best matching menu action. Reply with ONLY the number (1, 2, 3…) or "none".

        \(list)
        """

        return await withCheckedContinuation { cont in
            AIProviderService.shared.sendPureChat(
                message: prompt,
                onComplete: { response in
                    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.lowercased() == "none" {
                        cont.resume(returning: nil)
                        return
                    }
                    // Parse the number
                    if let n = Int(trimmed.components(separatedBy: .whitespaces).first ?? ""),
                       n >= 1, n <= candidates.count {
                        cont.resume(returning: candidates[n - 1])
                    } else {
                        cont.resume(returning: nil)
                    }
                },
                onError: { _ in cont.resume(returning: nil) }
            )
        }
    }

    // MARK: - Click

    private func click(item: AXMenuItem, pid: pid_t) -> String {
        Task.detached {
            AXMenuReader.shared.clickMenuItem(path: item.path, in: pid)
        }
        return item.pathString
    }
}
