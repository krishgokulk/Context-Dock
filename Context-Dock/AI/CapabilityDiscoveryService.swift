// CapabilityDiscoveryService.swift
// Context-Dock
//
// Central, query-first capability discovery for DoraX chat surfaces.
//
// This does not execute anything. It normalizes the existing resolver output into one
// ranked candidate list so AI Assistant, Context Dock Chat and Selection Chat can all
// reason from the same authority boundary:
// - AI Assistant: system-wide and cross-app candidates.
// - Context Dock Chat: only the frontmost/scoped app candidates.
// - Selection Chat: selection-safe instruction/share candidates only; no app reads.

import Foundation

struct CapabilityDiscoveryResult {
    let scope: AIConversationScope
    let query: String
    let candidates: [DoraXActionCandidate]
    let generatedAt: Date

    var isEmpty: Bool { candidates.isEmpty }

    var promptLines: [String] {
        guard !candidates.isEmpty else { return [] }
        var lines: [String] = [
            "## Ranked DoraX Capability Candidates",
            "These candidates came from the local capability index. Use them before generic advice.",
            "Never execute a route unless DoraX approval/execution confirms it.",
        ]
        for candidate in candidates.prefix(12) {
            let app = candidate.appName.map { " app=\($0)" } ?? ""
            let bundle = candidate.bundleID.map { " bundle=\($0)" } ?? ""
            let capability = candidate.capabilityID.map { " capability=\($0)" } ?? ""
            let type = candidate.operation == .read ? "read" : "execute"
            let confidence = String(format: "%.2f", candidate.confidence)
            lines.append(
                "- [\(type)] \(candidate.title) | source=\(candidate.source.rawValue) route=\(candidate.route.rawValue)\(capability)\(app)\(bundle) confidence=\(confidence) reason=\(candidate.debugReason)"
            )
        }
        return lines
    }
}

@MainActor
final class CapabilityDiscoveryService {
    static let shared = CapabilityDiscoveryService()

    private init() {}

    func discover(
        query: String,
        scope: AIConversationScope
    ) async -> CapabilityDiscoveryResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CapabilityDiscoveryResult(
                scope: scope, query: trimmed, candidates: [], generatedAt: Date())
        }

        let candidates: [DoraXActionCandidate]
        switch scope {
        case .general:
            candidates = await generalCandidates(query: trimmed)

        case .contextDock(let bundleID, let appName):
            candidates = await contextDockCandidates(
                query: trimmed,
                bundleID: bundleID,
                appName: appName
            )

        case .selection:
            candidates = selectionCandidates(query: trimmed)
        }

        return CapabilityDiscoveryResult(
            scope: scope,
            query: trimmed,
            candidates: deduplicate(candidates),
            generatedAt: Date()
        )
    }

    private func generalCandidates(query: String) async -> [DoraXActionCandidate] {
        var candidates = await GeneralAIActionResolver.shared.resolveReadCandidates(query: query)
        let executable = await GeneralAIActionResolver.shared.resolve(query: query)
        if case .candidates(let routes) = executable {
            candidates.append(contentsOf: routes)
        }
        // Authority is per route, not per app. Requiring an App Adapter for everything
        // discarded candidates DoraX could already carry out safely — a cached menu command
        // is a public, observable action the user could take themselves, and refusing to
        // click one while naming it in the same breath is the app declining work it knows
        // how to do. What stays adapter-gated is everything that reads private state.
        return candidates.filter { candidate in
            guard let bundleID = candidate.bundleID else { return true }
            let level = AppAccessPolicy.level(for: bundleID)
            guard AppAccessPolicy.allows(candidate.route, at: level) else { return false }
            // A read at menu-only level is the case this must not let through: knowing an
            // app's menus says nothing about being allowed to read its documents.
            return level == .adapter || candidate.operation != .read
        }
    }

    private func contextDockCandidates(
        query: String,
        bundleID: String,
        appName: String
    ) async -> [DoraXActionCandidate] {
        let all = await GeneralAIActionResolver.shared.resolveReadCandidates(query: "\(query) \(appName)")
        return all.filter { $0.bundleID == bundleID }
    }

    private func selectionCandidates(query: String) -> [DoraXActionCandidate] {
        let lowered = query.lowercased()
        guard lowered.contains("share")
            || lowered.contains("send")
            || lowered.contains("copy")
            || lowered.contains("export")
        else { return [] }
        var candidate = DoraXActionCandidate(
            id: "selection.system.share",
            title: "Share selected content",
            appName: "macOS Share Sheet",
            bundleID: nil,
            source: .system,
            route: .adapter,
            capabilityID: "system.share",
            requiredInputs: [],
            riskLevel: .medium,
            confidence: 0.82,
            permissionKey: "selection.share",
            debugReason: "selection scope only permits explicit selected payload sharing")
        candidate.operation = .execute
        return [candidate]
    }

    private func deduplicate(_ candidates: [DoraXActionCandidate]) -> [DoraXActionCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }
}
