// AppAgentProfileStore.swift
// Context-Dock
//
// Where an app's profile lives, and how a turn gets it.
//
// One file per app, in the folder that app's config already uses:
//
//     ~/Library/Application Support/Context-Dock/apps/<bundle id>/AGENT.md
//
// Read on demand and cached by modification date, because a profile is read on every turn and
// edited about once a month. Writing it invalidates its own cache entry, so the authoring UI and
// a chat cannot disagree about what the file says.

import Combine
import Foundation
import OSLog

@MainActor
final class AppAgentProfileStore: ObservableObject {
    static let shared = AppAgentProfileStore()

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "AgentProfile")

    private var cache: [String: (modified: Date, profile: AppAgentProfile)] = [:]

    /// Where profiles live. Exposed so a pack can be written from or installed into the same
    /// place a turn reads, rather than each side deriving the path and eventually disagreeing.
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Context-Dock/apps", isDirectory: true)
            self.root = base
        }
    }

    func fileURL(forBundleID bundleID: String) -> URL {
        root
            .appendingPathComponent(bundleID.lowercased(), isDirectory: true)
            .appendingPathComponent("AGENT.md")
    }

    /// The app's profile, or nil when it has none. Nil is the ordinary case and must stay
    /// cheap: every app without a profile behaves exactly as DoraX behaves today.
    func profile(forBundleID bundleID: String, appName: String = "") -> AppAgentProfile? {
        guard !bundleID.isEmpty else { return nil }
        let url = fileURL(forBundleID: bundleID)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate] as? Date
        else { return nil }

        let key = bundleID.lowercased()
        if let cached = cache[key], cached.modified == modified { return cached.profile }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let profile = AppAgentProfile.parse(text, bundleID: bundleID, appName: appName)
        cache[key] = (modified, profile)
        if !profile.problems.isEmpty {
            Self.log.notice(
                "profile \(bundleID, privacy: .public) has \(profile.problems.count, privacy: .public) unreadable line(s)")
        }
        return profile
    }

    @discardableResult
    func save(_ profile: AppAgentProfile, forBundleID bundleID: String) throws -> URL {
        let url = fileURL(forBundleID: bundleID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try profile.markdown().write(to: url, atomically: true, encoding: .utf8)
        cache[bundleID.lowercased()] = nil
        return url
    }

    /// Forget what was cached for one app, after its file was written by someone else — the
    /// editor writes the user's text verbatim rather than re-serialising it, so the store has
    /// to be told rather than inferring from its own save.
    func invalidate(bundleID: String) {
        cache[bundleID.lowercased()] = nil
    }

    /// Apps that have written one, for the Integrations list.
    func bundleIDsWithProfiles() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return entries
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("AGENT.md").path)
            }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// A first draft from what is already installed, so authoring starts from the app's real
    /// inventory rather than an empty file.
    func draft(forBundleID bundleID: String, appName: String) -> AppAgentProfile {
        var tools = AppAgentProfile.Tools()

        // Everything this app's chat may actually reach, not only what names it.
        //
        // Filtering on `appBundleID == bundleID` drafted one line for Safari —
        // `safari.summarizePage` — while `browser.tabs`, `browser.currentPage`,
        // `browser.history` and every file, git and clipboard capability were left out,
        // because those belong to no app and so matched nothing. A tab question then had no
        // declared route and fell back to inference, which is the behaviour profiles exist to
        // replace. The same filter a scoped turn uses decides it here.
        let capabilities = AgentToolRegistry.capabilitiesInScope(
            CapabilityRegistry.shared.all, scopedBundleID: bundleID)
            .map(\.id)
            .sorted()
        if !capabilities.isEmpty { tools.capabilities = capabilities }

        if let adapter = AppAdapterManager.shared.adapter(for: bundleID) {
            let actions = adapter.actions.filter { $0.type != .aiPrompt }.map(\.id).sorted()
            if !actions.isEmpty { tools.actions = actions }
        }

        let mcp = MCPServerManager.shared.servers
            .filter { $0.bundleIds.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame } }
            .map(\.name)
            .sorted()
        if !mcp.isEmpty { tools.mcp = mcp }

        let clis = ScopedGroundingBlocks.runnableCommandBinaries(forBundleId: bundleID).sorted()
        if !clis.isEmpty { tools.cli = clis }

        return AppAgentProfile(
            appName: appName,
            bundleID: bundleID,
            summary: "",
            never: [],
            verify: [:],
            tools: tools,
            // A comment, not prose. The draft used to leave its own guidance in the body as
            // plain text, so a profile saved before the user replaced it handed the model an
            // instruction addressed to the user — "Write how DoraX should work with Safari…".
            // Anything inside `<!-- -->` is stripped before the body reaches a prompt.
            instructions: [
                "<!--",
                "Write how DoraX should work with \(appName): which route to prefer for",
                "which kind of request, what to read before acting, and how to check the",
                "result. Anything between these markers is for you, never sent to the model.",
                "",
                "Two more keys worth adding above:",
                "  never:",
                "    - something this app must never be made to do",
                "  verify:",
                "    outcome-word: capability.that.reads.it.back",
                "-->",
            ].joined(separator: "\n"),
            problems: [])
    }

    /// The action ids an app declares, with their human names beside them.
    ///
    /// `shortcut-89992C66` and `ai.page.dark-mode-9a4861` are what the inventory calls them
    /// and what the runtime needs — and nobody can edit a list of those. The names go in a
    /// comment so the file stays readable without the ids turning into prose.
    func actionLegend(forBundleID bundleID: String) -> String? {
        guard let adapter = AppAdapterManager.shared.adapter(for: bundleID) else { return nil }
        let named = adapter.actions
            .filter { $0.type != .aiPrompt }
            .sorted { $0.id < $1.id }
            .map { "  \($0.id) — \($0.name)" }
        guard !named.isEmpty else { return nil }
        return "<!-- actions, by name:\n" + named.joined(separator: "\n") + "\n-->"
    }
}
