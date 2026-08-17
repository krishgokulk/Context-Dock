// GeneralAIActionResolver.swift
// Context-Dock
//
// DoraX Action Chat — the General AI Chat capability routing layer.
//
// Before a General Chat query goes to the selected AI provider, this resolver checks
// whether the query is an EXECUTABLE request ("open safari new private window",
// "add reminder to buy milk") and, if so, looks up real routes across DoraX's
// capability sources: registered capabilities, app adapters, the warm menu cache,
// keyboard shortcuts, the Shortcuts catalog, and CLI tool manifests.
//
// The resolver NEVER executes anything and NEVER live-scans AX menus — it reads only
// cached/registry metadata, so it is safe to run once per submitted chat message.
// Execution happens later in GeneralAIActionExecutor after first-run approval.

import AppKit
import Foundation

// MARK: - Candidate model

/// One executable route DoraX found for a General Chat request.
struct DoraXActionCandidate: Identifiable, Codable, Hashable {
    enum Operation: String, Codable {
        case read
        case execute
    }

    enum Source: String, Codable {
        case appAdapter
        case cachedMenu
        case keyboardShortcut
        case mcp
        case api
        case cli
        case shortcut
        case skill
        case automation
        case system
    }

    enum ExecutionRoute: String, Codable {
        case adapter          // registered capability / adapter action executor
        case mcp
        case api
        case cli
        case shortcutRunner
        case keyboardShortcut
        case verifiedMenu
        case axFallback
        case appLaunch        // plain launch/activate of the target app
        case automation       // app automation service (Messages compose, …)
    }

    enum SemanticType: String, Codable {
        case history
        case recent
        case recentFiles
        case recentDocuments
        case recentProjects
        case downloads
        case bookmarks
        case playlist
        case currentItem
        case status
        case unknown
    }

    let id: String
    let title: String
    let appName: String?
    let bundleID: String?
    let source: Source
    let route: ExecutionRoute
    let capabilityID: String?
    let requiredInputs: [String]
    let riskLevel: AICapabilityRiskLevel
    /// Mutable so a caller can lower it — a query that reached the resolver without an
    /// explicit verb is offered for confirmation rather than executed outright.
    var confidence: Double
    let permissionKey: String
    let debugReason: String

    // Execution payload — filled by the resolver so the executor never re-derives routes.
    var inputValues: [String: String] = [:]
    var menuPath: [String]? = nil
    var shortcutChar: String? = nil
    var shortcutModifiers: Int = 0
    var shortcutName: String? = nil
    var adapterActionID: String? = nil
    /// Honest limitation surfaced with the result ("couldn't automate the Automation tab").
    var caveat: String? = nil
    /// Unified capability operation. Existing routes default to execute; read candidates
    /// are grounded data only and must never trigger menu/API execution.
    var operation: Operation = .execute
    var semanticType: SemanticType? = nil
    var readValues: [String] = []
    var readContext: String? = nil
    var readSourceLabel: String? = nil

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// Short human label for the chosen route, shown in chat status/chips.
    var routeLabel: String {
        switch route {
        case .adapter: return "app capability"
        case .mcp: return "MCP tool"
        case .api: return "API"
        case .cli: return "CLI tool"
        case .shortcutRunner: return "macOS Shortcut"
        case .keyboardShortcut:
            let display = MenuShortcutFormatter.display(
                char: shortcutChar, modifiers: shortcutModifiers) ?? ""
            return display.isEmpty ? "keyboard shortcut" : "shortcut \(display)"
        case .verifiedMenu: return "cached menu click"
        case .axFallback: return "accessibility action"
        case .appLaunch: return "app launch"
        case .automation: return "app automation"
        }
    }
}

extension DoraXActionCandidate.SemanticType {
    var displayName: String {
        switch self {
        case .history: return "History"
        case .recent: return "Recent"
        case .recentFiles: return "Recent Files"
        case .recentDocuments: return "Recent Documents"
        case .recentProjects: return "Recent Projects"
        case .downloads: return "Downloads"
        case .bookmarks: return "Bookmarks"
        case .playlist: return "Playlist"
        case .currentItem: return "Current Item"
        case .status: return "Status"
        case .unknown: return "Read Context"
        }
    }
}

extension DoraXActionCandidate {
    /// Stable key for failure-driven availability tracking.
    var availabilityKey: String {
        CapabilityAvailabilityStore.key(
            route: route.rawValue, bundleID: bundleID ?? "",
            capabilityID: capabilityID ?? "", id: id)
    }
}

/// Resolver output for one query.
enum GeneralAIActionResolution {
    /// Not an executable request — continue normal Q&A through the provider.
    case none
    /// Executable, but DoraX needs the user to pick/complete something first.
    case clarify(question: String, options: [String])
    /// Executable but no usable route exists — answer honestly without the provider.
    case explain(String)
    /// Ranked executable routes, best first.
    case candidates([DoraXActionCandidate])
    /// An ordered multi-step plan against one app ("save and quit vscode" → [save, quit]).
    /// Each step resolves independently through the normal candidate path at execution time.
    case compound(appName: String, bundleID: String, steps: [String])
}

// MARK: - Resolver

@MainActor
final class GeneralAIActionResolver {
    static let shared = GeneralAIActionResolver()

    /// Per-app capability routers — consulted BEFORE the generic ranking so each app
    /// can pick its most deterministic route (Safari: bridge/history-cache/CLI over menus).
    private let appRouters: [String: any AppCapabilityRouting]
    private struct PendingClarification {
        let originalQuery: String
        let options: [String]
        let expiresAt: Date
    }
    private var pendingClarification: PendingClarification?

    /// Live trace sink for the current `resolve` call. Every line describes work this
    /// resolver actually performed — a count it read, a route it matched, a candidate it
    /// dropped — never model reasoning. Set for the duration of one resolve, then cleared.
    private var stepReporter: ((String) -> Void)?

    private func step(_ text: String) { stepReporter?(text) }

    private init() {
        let routers: [any AppCapabilityRouting] = [
            SafariCapabilityRouter()
        ]
        appRouters = Dictionary(uniqueKeysWithValues: routers.map { ($0.bundleID, $0) })
    }

    // MARK: Public entry

    /// - Parameter chatAllowedBundleIds: apps the user granted to *this chat* via the
    ///   "Enable <app> for this chat" tap. App Adapters is the persistent, Settings-level
    ///   grant; this is the per-conversation one, and it expires with the conversation.
    ///   Both are explicit user consent, so either one makes an app actionable — without
    ///   this, the Enable tap granted reading but not acting, and the resolver told the user
    ///   to go add an App Adapter for an app they had just enabled.
    /// - Parameter scopedApp: the app this chat surface is already scoped to (Context Dock's
    ///   frontmost-app chat). The surface names the app, so the sentence does not have to:
    ///   "new private window" typed into Safari's chat means Safari. Without this the
    ///   resolver could only find a target by reading the text, so it fell through to
    ///   browser disambiguation and asked which browser — while sitting inside Safari's own
    ///   chat. An app named in the text still wins, since that is the more explicit signal.
    /// - Parameter onStep: live trace sink; see `stepReporter`.
    func resolve(
        query: String,
        chatAllowedBundleIds: Set<String> = [],
        scopedApp: (name: String, bundleId: String)? = nil,
        onStep: ((String) -> Void)? = nil
    ) async -> GeneralAIActionResolution {
        stepReporter = onStep
        defer { stepReporter = nil }
        // Opening a scoped chat is itself the grant for that app.
        var chatAllowedBundleIds = chatAllowedBundleIds
        if let scopedApp { chatAllowedBundleIds.insert(scopedApp.bundleId) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pending = pendingClarification {
            if Date() > pending.expiresAt {
                pendingClarification = nil
            } else if let option = pending.options.first(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
                    || trimmed.lowercased().contains($0.lowercased())
            }) {
                pendingClarification = nil
                return await resolve(
                    query: pending.originalQuery + " using " + option,
                    chatAllowedBundleIds: chatAllowedBundleIds,
                    scopedApp: scopedApp, onStep: onStep)
            } else if !trimmed.isEmpty {
                // A non-option response starts a new request rather than trapping the user
                // in stale clarification state.
                pendingClarification = nil
            }
        }
        let lowered = trimmed.lowercased()

        // Intent used to be decided by the verb list alone, which runs before any lookup —
        // so "duckduckgo ai" was filed as conversation while the local index held
        // "Open Duck.ai" one call away. The verb list stays as the fast path; when it says
        // no, ask the index instead of giving up. Retrieve, then decide.
        let verbShaped = isLikelyExecutable(trimmed)
        let nounShapedTarget = verbShaped
            ? nil : nounShapedAppTarget(lowered, scopedApp: scopedApp)
        guard verbShaped || nounShapedTarget != nil else { return .none }

        // Domain intents (media transport, reminders, screenshots…) read as commands only
        // with a verb — "play", "remind me", "capture". A noun phrase never means those, so
        // they stay behind the fast path and skip straight to the app the index matched.
        guard verbShaped else {
            guard let target = nounShapedTarget else { return .none }
            // No verb means no proof the user wants this run, only proof of what they meant.
            // Offer it: the chat path lists candidates below 0.7 instead of executing.
            return offeringOnly(
                await appScopedResolution(
                    target: target, trimmed: trimmed,
                    chatAllowedBundleIds: chatAllowedBundleIds))
        }

        // An explicitly named app is stronger evidence than a generic domain word.  In
        // particular, “open deleted message in Messages” is a Messages menu lookup, not
        // a request to compose/share a message.  Resolve the app before the broad intent
        // detectors so app menus and adapters get the first chance to answer it.
        if let target = resolveTargetApp(in: lowered) {
            return await appScopedResolution(
                target: target, trimmed: trimmed,
                chatAllowedBundleIds: chatAllowedBundleIds)
        }

        // Domain intents are more specific than an *unnamed* generic app action.
        if let media = await resolveMediaTransportIntent(lowered, original: trimmed) {
            return media
        }
        if let share = await resolveNativeShareIntent(trimmed) {
            return share
        }
        if let reminders = resolveReminderIntent(lowered, original: trimmed) {
            return reminders
        }
        if let calendar = resolveCalendarIntent(lowered, original: trimmed) {
            return calendar
        }
        if let messaging = resolveMessagingIntent(lowered, original: trimmed) {
            return messaging
        }
        if let fileCreation = resolveCreateFileIntent(lowered) {
            return fileCreation
        }
        if let screenshot = resolveScreenshotIntent(lowered, original: trimmed) {
            return screenshot
        }

        // Scoped chat with no app named in the text: the surface is the target. Checked
        // before browser disambiguation so Safari's own chat never asks which browser.
        if let scopedTarget = scopedTargetApp(scopedApp, lowered: lowered) {
            return await appScopedResolution(
                target: scopedTarget, trimmed: trimmed,
                chatAllowedBundleIds: chatAllowedBundleIds)
        }

        // Browser action with no browser named ("new private window") — ask which one
        // when several browsers are installed instead of guessing.
        if let browserResolution = await resolveUnscopedBrowserAction(lowered, original: trimmed) {
            return browserResolution
        }

        // App-less tool routes (yt-dlp, docker, battery/network reads) — only reached when
        // no app/domain owned the request, so app actions always win.
        if let cli = resolveCLIToolAction(lowered: lowered, original: trimmed) {
            return cli
        }
        if let api = resolveAPIToolAction(lowered: lowered) {
            return api
        }

        // Last resort: search every app's cached menus by content, the way Global Context
        // does. Everything above needs the app to be named in the sentence, so "open deleted
        // message in mesages app" died on a typo while Global Context found
        // Messages ▸ View ▸ Recently Deleted from "deleted message" alone — no app name at
        // all. Same index, so the two surfaces stop disagreeing.
        if let crossApp = crossAppCachedMenuResolution(query: trimmed) {
            return crossApp
        }

        return .none
    }

    // MARK: - Cross-app menu fallback

    /// Phrases to try against the menu index, most literal first.
    ///
    /// The index matches a menu title, so it answers "deleted message" but not "open deleted
    /// message in mesages app" — a whole sentence carries verbs and filler no menu item
    /// contains. Stripping those leaves the words that actually name the command, which is
    /// what the user would have typed into Global Context.
    private func menuSearchPhrases(from query: String) -> [String] {
        let lowered = query.lowercased()
        var phrases = [lowered]

        let noise: Set<String> = [
            "open", "launch", "start", "run", "show", "go", "to", "in", "on", "the", "a", "an",
            "app", "application", "please", "me", "my", "for", "using", "with", "via", "and",
        ]
        let kept = lowered
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !noise.contains($0) }
        if kept.count >= 1, kept.count < lowered.split(separator: " ").count {
            phrases.append(kept.joined(separator: " "))
        }
        // Dropping the last token too, since a trailing app name ("… mesages") is not part of
        // any menu title and may be misspelled anyway.
        if kept.count >= 2 {
            phrases.append(kept.dropLast().joined(separator: " "))
        }
        var seen = Set<String>()
        return phrases.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Menu commands matching the phrase across every app with a cached snapshot, ranked by
    /// the shared global index rather than a matcher of this file's own.
    ///
    /// Offered, never auto-run: confidence stays under the chat path's 0.7 threshold, because
    /// this is a content guess about an app the user did not name, and acting on it can launch
    /// that app. Global Context has the same information but requires a keypress on a visible
    /// row; the chat equivalent of that keypress is picking from the list.
    private func crossAppCachedMenuResolution(query: String) -> GeneralAIActionResolution? {
        var candidates: [DoraXActionCandidate] = []
        var seenPaths = Set<String>()
        for phrase in menuSearchPhrases(from: query) {
            let docs = GlobalSearchService.shared.query(
                phrase, limit: 12, includeCachedMenus: true, includeRunningCachedMenus: true)
            for doc in docs {
                guard case .cachedMenu(let bundleId, let appName, let path, let char, let mods) =
                    doc.action, !path.isEmpty
                else { continue }

                // The literal sentence may return non-menu index rows first.  Keep trying
                // the normalized phrase, and never show one menu command twice if both
                // phrases matched it.
                guard seenPaths.insert("\(bundleId)|\(path.joined(separator: "→"))").inserted else {
                    continue
                }
                let title = path.last ?? doc.title
                if let char, !char.isEmpty {
                    candidates.append(
                        keyboardShortcutCandidate(
                            title: title, path: path, char: char, modifiers: mods,
                            appName: appName, bundleID: bundleId, confidence: 0.66,
                            reason: "cached \(appName) menu \(path.joined(separator: " → ")) matched the phrase"))
                } else {
                    candidates.append(
                        verifiedMenuCandidate(
                            title: title, path: path, shortcutChar: char, shortcutModifiers: mods,
                            appName: appName, bundleID: bundleId, confidence: 0.64))
                }
                if candidates.count >= 4 { break }
            }
            if candidates.count >= 4 { break }
        }
        guard !candidates.isEmpty else { return nil }
        step("Cross-app menu search: \(candidates.count) match(es) in cached menus")
        return .candidates(candidates)
    }

    // MARK: - Scoped-surface target

    /// The scoped chat's app as a resolution target, with the whole phrase as the action.
    /// Returns nil when there is no scope, or when the phrase already names some app — a
    /// name in the text is the more explicit signal and must win over the surface.
    private func scopedTargetApp(
        _ scopedApp: (name: String, bundleId: String)?, lowered: String
    ) -> TargetApp? {
        guard let scopedApp, !scopedApp.bundleId.isEmpty,
            !scopedApp.bundleId.hasPrefix("scope://"), !scopedApp.bundleId.hasPrefix("cli://")
        else { return nil }
        guard resolveTargetApp(in: lowered) == nil else { return nil }
        // Strips the filler words ("open ", " in ", " the ") the same way a named-app match
        // does, so the action phrase reaching the matchers looks identical either way.
        let phrase = removePhrase(scopedApp.name.lowercased(), from: lowered)
        guard !phrase.isEmpty else { return nil }
        step("Scope: \(scopedApp.name) — resolving “\(phrase)” against it")
        return TargetApp(
            name: scopedApp.name, bundleId: scopedApp.bundleId, remainingPhrase: phrase)
    }

    // MARK: - App-scoped resolution

    /// Everything that happens once a query is known to be about one installed app.
    /// Shared by the verb path and the retrieval-first noun path.
    private func appScopedResolution(
        target: TargetApp, trimmed: String, chatAllowedBundleIds: Set<String>
    ) async -> GeneralAIActionResolution {
        // Turned away at the door, an app with a perfectly good cached menu bar was told to
        // go and add an adapter — for a command DoraX could name exactly and verify live
        // before clicking. Authority now has three levels, and only the lowest stops here.
        let level = AppAccessPolicy.level(
            for: target.bundleId, chatGranted: chatAllowedBundleIds)
        guard level > .awareness else {
            return .explain(
                AppAccessPolicy.explanation(
                    for: target.name, level: level, wantedRead: false))
        }
        // Compound "save and quit" style requests → an ordered plan, each step resolved
        // independently. Checked before single-action routing so we don't hunt for one
        // combined "save and quit" menu that doesn't exist.
        if let steps = compoundSteps(in: target.remainingPhrase) {
            return .compound(
                appName: target.name, bundleID: target.bundleId, steps: steps)
        }
        // Per-app router first — it knows the best route for that app's tasks.
        if let router = appRouters[target.bundleId],
           let routed = await router.route(
               actionPhrase: target.remainingPhrase, original: trimmed) {
            return routed
        }
        let base = resolveAppScopedAction(
            appName: target.name,
            bundleID: target.bundleId,
            actionPhrase: target.remainingPhrase,
            original: trimmed,
            accessLevel: level
        )
        // Fold in MCP tools the app exposes so they compete in the same ranked list.
        return await augmentWithMCPCandidates(
            base, appName: target.name, bundleID: target.bundleId,
            actionPhrase: target.remainingPhrase, intentKey: Self.normalizedIntentKey(trimmed))
    }

    // MARK: - Retrieval-first intent (no verb)

    /// Which installed app a verb-less phrase is about, when the phrase is shaped like a
    /// target rather than a topic. Returns nil unless every condition holds, because this is
    /// the path that lets a sentence with no command in it reach the action machinery:
    ///
    /// - not a question ("what is safari" stays conversation)
    /// - not a browser-library read ("history" is answered from the URL library, not clicked)
    /// - names an installed app, and says something *after* the app name. A bare app name is
    ///   Global Context's job — General Chat is not a second launcher.
    /// - that remainder is short. "duckduckgo ai" is a target; "safari keeps crashing when I
    ///   open three windows" is a complaint, and belongs in conversation.
    private func nounShapedAppTarget(
        _ lowered: String, scopedApp: (name: String, bundleId: String)? = nil
    ) -> TargetApp? {
        guard !isQuestionShaped(lowered) else { return nil }
        guard !LauncherView.isBrowserLibraryReadPhrase(lowered) else { return nil }
        // In a scoped chat the app is the surface, so "private window" needs no app name.
        guard let target = resolveTargetApp(in: lowered)
            ?? scopedTargetApp(scopedApp, lowered: lowered)
        else { return nil }
        let remainder = target.remainingPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        let words = remainder.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= 3 else { return nil }
        return target
    }

    /// Caps confidence below the chat path's auto-run threshold (0.7), so candidates are
    /// listed for the user to pick instead of being executed. Used for verb-less queries,
    /// where the index proves what the user *meant* but nothing proves they want it run.
    private func offeringOnly(
        _ resolution: GeneralAIActionResolution
    ) -> GeneralAIActionResolution {
        guard case .candidates(let candidates) = resolution else { return resolution }
        return .candidates(
            candidates.map { candidate in
                var offered = candidate
                offered.confidence = min(candidate.confidence, 0.65)
                return offered
            })
    }

    // MARK: - Browser disambiguation

    private let browserBundles: [(name: String, bundleId: String)] = [
        ("Safari", "com.apple.Safari"),
        ("Chrome", "com.google.Chrome"),
        ("Arc", "company.thebrowser.Browser"),
        ("Firefox", "org.mozilla.firefox"),
        ("Brave", "com.brave.Browser"),
        ("Edge", "com.microsoft.edgemac"),
    ]

    private func resolveUnscopedBrowserAction(
        _ lowered: String, original: String
    ) async -> GeneralAIActionResolution? {
        let browserPhrases = [
            "private window", "incognito", "new tab", "browser window",
            "bookmark this page", "new browsing window",
        ]
        guard browserPhrases.contains(where: lowered.contains) else { return nil }
        let installed = browserBundles.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil
        }
        guard !installed.isEmpty else { return nil }
        if installed.count > 1 {
            let names = installed.map(\.name)
            let list = names.dropLast().joined(separator: ", ")
            pendingClarification = PendingClarification(
                originalQuery: original, options: names,
                expiresAt: Date().addingTimeInterval(120))
            return .clarify(
                question: "Do you want \(names.count == 2 ? names.joined(separator: " or ") : "\(list), or \(names.last!)")?",
                options: names)
        }
        let only = installed[0]
        if let router = appRouters[only.bundleId],
           let routed = await router.route(actionPhrase: lowered, original: original) {
            return routed
        }
        return resolveAppScopedAction(
            appName: only.name, bundleID: only.bundleId,
            actionPhrase: lowered, original: original)
    }

    /// Public app matcher for General Chat grounding: which installed app (if any)
    /// does this query talk about? Used for status-style questions ("what's going on
    /// with vs code?") that are NOT executable but must be answered from real app
    /// state instead of provider guesses.
    func namedInstalledApp(in query: String) -> (name: String, bundleId: String)? {
        guard let target = resolveTargetApp(in: query.lowercased()) else { return nil }
        return (target.name, target.bundleId)
    }

    // MARK: - Executable-intent gate

    private static let questionStarts = [
        "how ", "what", "why ", "who ", "when ", "where ", "which ", "explain",
        "tell me", "can you explain", "describe", "compare", "summarize", "translate",
        "write ", "is ", "are ", "does ", "do ", "did ", "should ",
    ]

    /// Conversation, not a target — checked by both the verb gate and the noun-phrase path.
    private func isQuestionShaped(_ lowered: String) -> Bool {
        let text = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("?") { return true }
        return Self.questionStarts.contains(where: text.hasPrefix)
    }

    /// Cheap local check: does this look like a command rather than a question?
    /// Runs only on submit (never while typing) and uses no AX or provider calls.
    private func isLikelyExecutable(_ query: String) -> Bool {
        var lowered = query.lowercased()
        guard !lowered.isEmpty, lowered.count < 160 else { return false }
        // Treat polite assistant requests as commands while preserving real questions:
        // “can you take a screenshot?” becomes “take a screenshot”, but “can you explain”
        // becomes “explain” and is rejected by the conversational prefixes below.
        for prefix in ["please ", "can you please ", "could you please ", "would you please ",
                       "can you ", "could you ", "would you "] where lowered.hasPrefix(prefix) {
            lowered = String(lowered.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if lowered.hasSuffix("?") {
            lowered.removeLast()
            lowered = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Compact launcher-style noun phrases are commands even without an explicit verb.
        // Keep this allowlist narrow so ordinary topic phrases remain normal conversation.
        let implicitLaunchIntents: Set<String> = [
            "calculator",
            "basic calculator",
            "scientific calculator",
            "programmer calculator",
            "calculator basic",
            "calculator scientific",
            "calculator programmer",
        ]
        if implicitLaunchIntents.contains(lowered) { return true }
        // Questions and explanations stay in normal chat.
        // Page-grounded browser tasks are executable even though they start like
        // a chat request ("summarize this safari page" → Safari router).
        if (lowered.contains("summarize") || lowered.contains("summarise"))
            && lowered.contains("page") {
            return true
        }
        // Reading local browser data ("show all opened tabs", "list my history") is a READ
        // answered from the local URL library. Its leading verb ("show ") matched the verb
        // list below and routed the query to an executable capability — which opened a NEW
        // tab instead of listing the open ones.
        if LauncherView.isBrowserLibraryReadPhrase(lowered) { return false }
        if Self.questionStarts.contains(where: lowered.hasPrefix) { return false }

        let verbs = [
            "open ", "launch ", "start ", "create ", "new ", "add ", "make ",
            "take ", "capture ", "snap ",
            "quit ", "close ", "show ", "hide ", "toggle ", "enable ", "disable ",
            "turn ", "mute ", "unmute ", "minimize ", "maximize ", "empty ",
            "run ", "activate ", "switch ", "remind ", "schedule ", "send ",
            "compose ", "email ", "text ", "play ", "pause ", "paste ",
            "share ", "save ", "export ", "bookmark ", "download ",
            "print", "settings", "preferences", "extensions", "history", "bookmarks",
        ]
        return verbs.contains(where: lowered.hasPrefix)
            // "safari new private window" — app name first, verb inside.
            || verbs.contains(where: { lowered.contains(" \($0)") })
    }

    /// Public gate for callers (AppleScript-model fallback) that only want to act on
    /// automation-shaped requests, never plain Q&A.
    func looksExecutable(_ query: String) -> Bool { isLikelyExecutable(query) }

    /// Native macOS capture is a system-wide capability. A specifically named app still
    /// routes through its adapter, so requests such as “capture with CleanShot” keep the
    /// user's chosen workflow instead of being swallowed by this built-in fallback.
    private func resolveScreenshotIntent(
        _ lowered: String, original: String
    ) -> GeneralAIActionResolution? {
        let mentionsCapture = lowered.contains("screenshot")
            || lowered.contains("screen shot")
            || lowered.contains("capture the screen")
            || lowered.contains("capture my screen")
        guard mentionsCapture, resolveTargetApp(in: lowered) == nil else { return nil }

        let mode: String
        if lowered.contains("window") { mode = "window" }
        else if lowered.contains("region") || lowered.contains("area")
            || lowered.contains("portion") || lowered.contains("selection") {
            mode = "region"
        } else { mode = "screen" }

        let destination = lowered.contains("clipboard") ? "clipboard" : "file"
        let modeTitle: String
        switch mode {
        case "window": modeTitle = "window"
        case "region": modeTitle = "selected region"
        default: modeTitle = "screen"
        }
        var candidate = DoraXActionCandidate(
            id: "system.captureScreenshot.\(mode).\(destination)",
            title: "Capture \(modeTitle)\(destination == "clipboard" ? " to clipboard" : "")",
            appName: "macOS Screenshot",
            bundleID: nil,
            source: .system,
            route: .adapter,
            capabilityID: "system.captureScreenshot",
            requiredInputs: ["mode", "destination"],
            riskLevel: .medium,
            confidence: 0.98,
            permissionKey: "generalAI.execute.system.captureScreenshot.\(mode).\(destination)",
            debugReason: "native macOS screenshot capability for: \(original)")
        candidate.inputValues = ["mode": mode, "destination": destination]
        return .candidates([candidate])
    }

    /// Public read-intent gate for General Chat. This is still local and cheap: no AX,
    /// no provider, no app launch.
    func looksReadOnly(_ query: String) -> Bool { isLikelyReadOnly(query) }

    /// Discover local read capabilities for General Chat. This is the read half of the
    /// same capability model used for execution: app adapter readers, cached menu
    /// knowledge, MCP/API/CLI metadata already discovered elsewhere. It never scans live
    /// menus and never executes a menu command.
    func resolveReadCandidates(query: String) async -> [DoraXActionCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyReadOnly(trimmed) else { return [] }
        let lowered = trimmed.lowercased()
        let intentKey = Self.normalizedIntentKey(trimmed)

        var candidates: [DoraXActionCandidate] = []

        // Reading is the half of authority that a menu cache does not buy. Knowing an app's
        // menu bar means DoraX can press what the user could press; it says nothing about
        // being allowed to read what the app holds, and the two were being granted together
        // because one function gathered both.
        func reads(for app: (name: String, bundleId: String)) async -> [DoraXActionCandidate] {
            guard AppAccessPolicy.level(for: app.bundleId) == .adapter else { return [] }
            var out = adapterReadCandidates(app: app, query: trimmed)
            out += menuCacheReadCandidates(app: app, query: trimmed)
            out += await mcpReadCandidates(app: app, query: trimmed)
            out += cliReadCandidates(app: app, query: trimmed)
            return out
        }

        if let target = resolveTargetApp(in: lowered) {
            candidates.append(
                contentsOf: await reads(for: (name: target.name, bundleId: target.bundleId)))
        } else {
            for app in readDiscoveryApps(for: trimmed).prefix(10) {
                candidates.append(contentsOf: await reads(for: app))
            }
        }

        let available = candidates.filter {
            $0.operation == .read && CapabilityAvailabilityStore.shared.isAvailable(key: $0.availabilityKey)
        }
        let ranked = rankedWithPreferences(available, intentKey: intentKey)
        // Final relevance gate. Keyword routing can only ever match on the words it knows;
        // when the query's subject is a word no candidate accounts for, the honest answer
        // is that this router does not handle the question — so return nothing and let the
        // model answer instead of reading a plausible-looking wrong source.
        guard Self.candidatesExplain(ranked, query: lowered) else { return [] }
        return ranked
    }

    /// True when every subject word in the query is accounted for by at least one candidate
    /// (its title, app name, semantic, or capability id) — or is a generic read noun that
    /// the semantics cover by construction.
    private static func candidatesExplain(
        _ candidates: [DoraXActionCandidate],
        query: String
    ) -> Bool {
        guard !candidates.isEmpty else { return false }
        let content = contentWords(of: query)
        guard !content.isEmpty else { return true }
        let vocabulary = candidates.reduce(into: Set<String>()) { set, candidate in
            let text = [
                candidate.title,
                candidate.appName ?? "",
                candidate.capabilityID ?? "",
                candidate.semanticType?.displayName ?? "",
            ].joined(separator: " ").lowercased()
            set.formUnion(
                text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
            )
        }
        return content.allSatisfy { word in
            vocabulary.contains(word) || genericReadNouns.contains(word)
        }
    }

    private func isLikelyReadOnly(_ query: String) -> Bool {
        let lowered = query.lowercased()
        guard !lowered.isEmpty, lowered.count < 240 else { return false }
        let executeStarts = [
            "clear ", "delete ", "remove ", "erase ", "open ", "launch ", "start ",
            "stop ", "pause ", "play ", "quit ", "close ", "create ", "add ", "send ",
            "share ", "save ", "export ", "download ", "turn ", "enable ", "disable ",
        ]
        if executeStarts.contains(where: lowered.hasPrefix) { return false }
        let readSignals = [
            "what", "when", "where", "who", "which", "show", "list", "tell me",
            "latest", "last", "recent", "history", "watched", "played", "viewed",
            "opened", "bookmarks", "downloads", "playlist", "current", "status",
            "do i have", "did i", "how many", "what was", "what is", "what's", "whats",
        ]
        return readSignals.contains(where: lowered.contains)
    }

    // MARK: - App name resolution

    private struct TargetApp {
        let name: String
        let bundleId: String
        /// Query with the app-name tokens removed — the action part.
        let remainingPhrase: String
    }

    /// Common-name aliases resolved before scanning the installed-apps catalog.
    private let appAliases: [String: String] = [
        "safari": "com.apple.Safari",
        "shortcuts": "com.apple.shortcuts",
        "shortcut": "com.apple.shortcuts",
        "shortcut app": "com.apple.shortcuts",
        "reminders": "com.apple.reminders",
        "calendar": "com.apple.iCal",
        "notes": "com.apple.Notes",
        "mail": "com.apple.mail",
        "messages": "com.apple.MobileSMS",
        "finder": "com.apple.finder",
        "textedit": "com.apple.TextEdit",
        "text edit": "com.apple.TextEdit",
        "terminal": "com.apple.Terminal",
        "music": "com.apple.Music",
        "photos": "com.apple.Photos",
        "contacts": "com.apple.AddressBook",
        "maps": "com.apple.Maps",
        "facetime": "com.apple.FaceTime",
        "preview": "com.apple.Preview",
        "calculator": "com.apple.calculator",
        "xcode": "com.apple.dt.Xcode",
        "vs code": "com.microsoft.VSCode",
        "vscode": "com.microsoft.VSCode",
        "chrome": "com.google.Chrome",
        "arc": "company.thebrowser.Browser",
        "firefox": "org.mozilla.firefox",
        "brave": "com.brave.Browser",
        "edge": "com.microsoft.edgemac",
        "system settings": "com.apple.systempreferences",
        "settings": "com.apple.systempreferences",
    ]

    /// The installed app a bare name refers to, for callers that already know they are
    /// holding an app name rather than a sentence.
    func installedAppMatch(named name: String) -> (name: String, bundleId: String)? {
        guard let target = resolveTargetApp(in: name.lowercased()) else { return nil }
        return (target.name, target.bundleId)
    }

    private func resolveTargetApp(in lowered: String) -> TargetApp? {
        // Every name that appears in the sentence competes, whether it came from the alias
        // table or from the installed-apps catalog.
        //
        // The alias table used to win unconditionally, because it was checked first and
        // returned on the first hit. It holds "terminal" → com.apple.Terminal, so "quick
        // ghostty terminal" resolved to Apple's Terminal and never reached the catalog — the
        // only place Ghostty exists. A 30-row hardcoded table outranked every installed app.
        //
        // Ranking is by position in the sentence, then by matched length. People name the
        // target before qualifying it ("ghostty quick terminal", "safari new private window"),
        // so the leftmost name is the subject and later words describe what to do with it.
        // Length only breaks ties at the same position, which is what keeps "vs code" from
        // being read as "code".
        struct Match {
            let start: Int
            let matchedLength: Int
            let name: String
            let bundleId: String
            let matchedPhrase: String
        }
        var matches: [Match] = []

        for (alias, bundleId) in appAliases {
            guard let offset = wordPhraseOffset(lowered, phrase: alias) else { continue }
            // Aliases still matter: they carry colloquial names the catalog cannot match,
            // like "vs code" for "Visual Studio Code".
            guard let name = installedAppName(bundleId: bundleId) else { continue }
            matches.append(
                Match(
                    start: offset, matchedLength: alias.count, name: name,
                    bundleId: bundleId, matchedPhrase: alias))
        }

        // Installed-apps catalog. Discovery rather than a cached read, because this is the
        // list that decides whether an app the user named exists at all — and a cold cache
        // answers that question with "nothing is installed". After the first call it is the
        // same in-memory read it always was.
        for entry in InstalledApplicationsCatalog.discoverInstalledApps() {
            let name = entry.name.lowercased()
            guard name.count > 2, let offset = wordPhraseOffset(lowered, phrase: name) else {
                continue
            }
            matches.append(
                Match(
                    start: offset, matchedLength: name.count, name: entry.name,
                    bundleId: entry.bundleId, matchedPhrase: name))
        }

        let best = matches.min { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.matchedLength != rhs.matchedLength { return lhs.matchedLength > rhs.matchedLength }
            return lhs.name < rhs.name  // stable, so the same query always resolves the same way
        }
        guard let best else { return nil }
        return TargetApp(
            name: best.name,
            bundleId: best.bundleId,
            remainingPhrase: removePhrase(best.matchedPhrase, from: lowered)
        )
    }

    private func installedAppName(bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func containsWordPhrase(_ text: String, phrase: String) -> Bool {
        guard let range = text.range(of: phrase) else { return false }
        let before = range.lowerBound == text.startIndex
            ? nil : text[text.index(before: range.lowerBound)]
        let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
        let boundary = { (c: Character?) in c == nil || !(c!.isLetter || c!.isNumber) }
        return boundary(before) && boundary(after)
    }

    /// Character offset of `phrase` in `text` when it appears on word boundaries, else nil.
    /// The offset is what lets competing app names be ranked by where they appear.
    private func wordPhraseOffset(_ text: String, phrase: String) -> Int? {
        guard !phrase.isEmpty, let range = text.range(of: phrase) else { return nil }
        let before = range.lowerBound == text.startIndex
            ? nil : text[text.index(before: range.lowerBound)]
        let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
        // An app name inside a filesystem/URL-style token is data, not an app target.
        // `/tmp/context-dock-verification.txt` used to resolve as the Context-Dock app and
        // interrupt a shell task with an unrelated "Enable Context-Dock" permission card.
        let pathJoiners: Set<Character> = ["/", "\\", "-", "_", "."]
        guard before.map({ !pathJoiners.contains($0) }) ?? true,
              after.map({ !pathJoiners.contains($0) }) ?? true else {
            return nil
        }
        let boundary = { (c: Character?) in c == nil || !(c!.isLetter || c!.isNumber) }
        guard boundary(before), boundary(after) else { return nil }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    private func removePhrase(_ phrase: String, from text: String) -> String {
        var result = text.replacingOccurrences(of: phrase, with: " ")
        for filler in ["open ", "launch ", " in ", " on ", " the ", " app ", " a ", " an "] {
            result = result.replacingOccurrences(of: filler, with: " ")
        }
        return result
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - App-scoped action resolution

    private func resolveAppScopedAction(
        appName: String,
        bundleID: String,
        actionPhrase: String,
        original: String,
        accessLevel: AppAccessLevel? = nil
    ) -> GeneralAIActionResolution {
        // Passed in where the caller already asked, because only the caller knows what the
        // user granted this chat; recomputed otherwise so no route reaches the ranker
        // unchecked.
        let level = accessLevel ?? AppAccessPolicy.level(for: bundleID)
        var candidates: [DoraXActionCandidate] = []

        // Bare "open <app>" → plain launch, high confidence.
        if actionPhrase.isEmpty || actionPhrase == "open" {
            candidates.append(launchCandidate(appName: appName, bundleID: bundleID, confidence: 0.92))
            return .candidates(candidates)
        }

        if let paste = pasteClipboardCandidate(
            appName: appName, bundleID: bundleID, actionPhrase: actionPhrase) {
            return .candidates([paste])
        }

        // 1. App adapter actions (native registered capability). Exclude `.aiPrompt` actions
        // ("Ask AI about Safari") — those are knowledge/Q&A, not executable, and must never
        // outrank a real executable route for an executable intent.
        let adapterActions = AppAdapterManager.shared.scoredActions(for: bundleID, query: actionPhrase)
            .filter { $0.action.type != .aiPrompt }
        step(
            adapterActions.isEmpty
                ? "App adapter: no action matched"
                : "App adapter: \(adapterActions.count) action(s) matched, best “\(adapterActions[0].action.name)”")
        if let top = adapterActions.first {
            // Confidence tracks how well the action matched, not the fact that it is an
            // adapter. A flat 0.88 here outranked the cached menu's 0.82 even when the
            // adapter match was a single shared word: "new private window in safari" ran
            // "New Tab" because both contain "new", while the menu cache held the exact
            // "New Private Window". The menu matcher requires *every* query token, so an
            // exact menu hit deserves to win over a partial adapter hit.
            let strong = top.score >= AppAdapterManager.adapterActionStrongMatchScore
            candidates.append(adapterCandidate(
                action: top.action, appName: appName, bundleID: bundleID,
                confidence: strong ? 0.88 : 0.62))
        }

        // Built-in/imported tools shown under App Adapters → Tools. Previously Settings
        // exposed these while scoped chat never searched them.
        let registered = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: appName, bundleID: bundleID, query: actionPhrase)
        step(registered.isEmpty
            ? "Registered tools: no capability matched"
            : "Registered tools: \(registered.count) matched, selected \(registered[0].capabilityID ?? registered[0].title)")
        candidates.append(contentsOf: registered)

        // 2. Cached menu commands — product fallback when no app adapter/MCP/API route fits.
        // Execution still launches the app and live-verifies the menu item before clicking.
        let menuMatches = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID, appName: appName, query: actionPhrase, maxResults: 6)
        let menuBest = bestMenuMatch(menuMatches, actionPhrase: actionPhrase)
        step(
            menuMatches.isEmpty
                ? "\(appName) menu cache: cold or no match"
                : "\(appName) menus: \(menuMatches.count) candidate(s), "
                    + (menuBest.map { "exact match \($0.pathString)" } ?? "none matched every word"))
        if let match = menuBest {
            if let char = match.shortcutChar, !char.isEmpty {
                candidates.append(keyboardShortcutCandidate(
                    title: match.title, path: match.path, char: char,
                    modifiers: match.shortcutModifiers,
                    appName: appName, bundleID: bundleID, confidence: 0.82,
                    reason: "cached menu \(match.pathString) carries a shortcut"))
            }
            candidates.append(verifiedMenuCandidate(
                title: match.title, path: match.path,
                shortcutChar: match.shortcutChar, shortcutModifiers: match.shortcutModifiers,
                appName: appName, bundleID: bundleID, confidence: 0.76))
        } else if !menuMatches.isEmpty {
            // Ranked but not exact. "open disk utility about window" matched nothing under
            // the every-token rule — "window" appears in no Disk Utility menu — so the whole
            // request fell through to launching the app and admitting defeat, while the very
            // item wanted, "About Disk Utility", sat in the cache the resolver had just read.
            //
            // The every-token rule stays: it is what stops "new private window" settling for
            // "New Window", and a near match must never be *run* as if it were the thing
            // asked for. But near matches are worth *offering*. Below the ask-first
            // threshold, so they arrive as a pick list — the user confirms the one they
            // meant, which is what someone who knew this app would have said back.
            for near in menuMatches.prefix(3) {
                candidates.append(verifiedMenuCandidate(
                    title: near.title, path: near.path,
                    shortcutChar: near.shortcutChar, shortcutModifiers: near.shortcutModifiers,
                    appName: appName, bundleID: bundleID, confidence: 0.5))
            }
            step("\(appName) menus: offering \(min(menuMatches.count, 3)) near match(es) to pick from")
        }

        // 3. Seeded shortcuts for common intents when the menu cache is cold.
        if candidates.allSatisfy({ $0.route == .adapter }) {
            if let seeded = seededShortcutCandidate(
                bundleID: bundleID, appName: appName, actionPhrase: actionPhrase) {
                step("Built-in shortcut for \(appName): \(seeded.title)")
                candidates.append(seeded)
            }
        }

        // 4. User's macOS Shortcuts whose name matches the whole request.
        if let shortcut = matchingMacShortcut(for: original) {
            step("Your macOS Shortcuts: matched “\(shortcut.name)”")
            candidates.append(DoraXActionCandidate(
                id: "shortcutRunner.\(shortcut.name)",
                title: "Run Shortcut “\(shortcut.name)”",
                appName: "Shortcuts",
                bundleID: "com.apple.shortcuts",
                source: .shortcut,
                route: .shortcutRunner,
                capabilityID: nil,
                requiredInputs: [],
                riskLevel: .medium,
                confidence: 0.7,
                permissionKey: "generalAI.execute.shortcutRunner.\(stableKey(shortcut.name))",
                debugReason: "Shortcuts catalog name match",
                shortcutName: shortcut.name))
        }

        // 5. App-linked CLI tools. Product policy keeps these fallback-only: if an adapter,
        // MCP/API, Shortcut, cached menu, or keyboard shortcut exists for the same app,
        // productRouteFiltered(_:) removes CLI before ranking.
        candidates.append(contentsOf: appLinkedCLICandidates(
            appName: appName,
            bundleID: bundleID,
            actionPhrase: actionPhrase,
            original: original
        ))

        guard !candidates.isEmpty else {
            // Executable request against a real app, but no verified route — launch the app
            // and say honestly what could not be automated. Never fake success.
            var launch = launchCandidate(appName: appName, bundleID: bundleID, confidence: 0.72)
            // Two different failures wore one sentence. Telling someone to open the app so
            // DoraX can warm its menu cache is useless advice when the cache already holds
            // sixty-nine of that app's commands — it sends them to do a thing that is done,
            // and hides that the real answer is the app has no such command.
            let cached = AppMenuCapabilityCache.shared.summary(bundleIdentifier: bundleID) != nil
            launch.caveat =
                "I couldn't find a verified route for “\(actionPhrase)” in \(appName) — "
                + (cached
                    ? "nothing in its menus, adapters or shortcuts matches that. It may not "
                        + "be something \(appName) can do."
                    : "and I haven't read its menus yet. Open \(appName) once so DoraX can "
                        + "warm its menu cache, then try again.")
            return .candidates([launch])
        }

        // Authority is checked per route, and this list is where the routes are. The door
        // check above only asks whether the app may be touched at all; discovery filtered
        // per route and this path did not, so an app with nothing but a cached menu bar
        // could still be handed an adapter or CLI route out of the registered catalog —
        // two paths, one of them guarded, which is the shape of bug this codebase keeps
        // producing.
        let permitted = candidates.filter { AppAccessPolicy.allows($0.route, at: level) }
        guard !permitted.isEmpty else {
            var launch = launchCandidate(appName: appName, bundleID: bundleID, confidence: 0.6)
            launch.caveat = AppAccessPolicy.explanation(
                for: appName, level: level, wantedRead: true)
            return .candidates([launch])
        }

        let intentKey = Self.normalizedIntentKey(original)
        return .candidates(rankedWithPreferences(permitted, intentKey: intentKey))
    }

    /// Split a compound action phrase ("save and quit", "save all then quit") into ordered
    /// simple steps, each normalized to a known verb. Returns nil unless ≥2 known steps are
    /// present, so single actions ("quit", "save") stay on the normal path.
    private func compoundSteps(in phrase: String) -> [String]? {
        let connectors = [" and then ", " then ", " and ", " & ", ","]
        var parts = [phrase.lowercased()]
        for connector in connectors {
            parts = parts.flatMap { $0.components(separatedBy: connector) }
        }
        // Longest verbs first so "save all" wins over "save".
        let verbs = ["save all", "save", "quit", "exit", "close"]
        var steps: [String] = []
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            guard let verb = verbs.first(where: { part == $0 || part.contains($0) }) else {
                continue
            }
            steps.append(verb == "exit" ? "quit" : verb)
        }
        return steps.count >= 2 ? steps : nil
    }

    /// Ranked executable candidates for a single compound step, excluding the honest
    /// "couldn't automate" launch fallback (a caller decides whether to warm + retry).
    func rankedStepCandidates(appName: String, bundleID: String, actionPhrase: String)
        -> [DoraXActionCandidate]
    {
        let resolution = resolveAppScopedAction(
            appName: appName, bundleID: bundleID, actionPhrase: actionPhrase, original: actionPhrase)
        guard case .candidates(let candidates) = resolution else { return [] }
        return candidates.filter { !($0.route == .appLaunch && $0.caveat != nil) }
    }

    /// Hard route tier per the DoraX Action Chat spec: adapter > MCP/API > CLI >
    /// shortcutRunner > keyboardShortcut > verifiedMenu > axFallback > launch. Tiers are
    /// spaced 100 apart so learned adjustments (±40) can reorder WITHIN a tier but never
    /// cross one — AX can never outrank a native/adapter route.
    private func routeTier(_ c: DoraXActionCandidate) -> Int {
        if c.operation == .read {
            switch c.source {
            case .appAdapter: return 0
            case .api, .system: return 1
            case .mcp: return 2
            case .cachedMenu: return 4
            case .cli: return 5
            case .skill: return 6
            default: return 7
            }
        }
        switch c.route {
        case .adapter: return 0
        case .mcp: return 1
        case .api: return 2
        case .cli: return 3
        case .shortcutRunner: return 4
        case .keyboardShortcut: return 5
        case .verifiedMenu: return 6
        case .automation: return 7
        case .axFallback: return 8
        case .appLaunch: return 9
        }
    }

    /// Combined learned + explicit-preference adjustment, clamped below 50 so the ±budget
    /// can never span the 100-wide tier gap. Guarantees a preference/learning signal can
    /// reorder routes WITHIN a class but never lets AX outrank a native/adapter/MCP/CLI route.
    private static let maxCombinedAdjustment = 45

    /// Final rank = hard tier (×100) plus a clamped learned+preference adjustment. Lower is
    /// better. An explicit "preferred" pins the route to the top of its tier; "avoid" to the
    /// bottom; learning nudges within that.
    private func rankScore(_ c: DoraXActionCandidate, intentKey: String) -> Int {
        let learned = RouteConfidenceStore.shared.adjustment(
            intentKey: intentKey,
            bundleID: c.bundleID ?? "",
            route: c.route.rawValue,
            capabilityID: c.capabilityID ?? "")
        let prefRaw: Int
        switch RoutePreferenceStore.shared.strength(
            intentKey: intentKey, bundleID: c.bundleID ?? "", route: c.route.rawValue) {
        case .preferred: prefRaw = -1000
        case .avoid: prefRaw = 1000
        case nil: prefRaw = 0
        }
        let combined = max(
            -Self.maxCombinedAdjustment, min(Self.maxCombinedAdjustment, learned + prefRaw))
        return routeTier(c) * 100 + combined
    }

    /// Sort candidates by rankScore, and DROP any the user explicitly said to avoid when a
    /// non-avoided alternative exists (so "avoid AX for Safari" blocks the AX route rather
    /// than merely demoting it). Never returns an empty list.
    private func rankedWithPreferences(
        _ candidates: [DoraXActionCandidate], intentKey: String
    ) -> [DoraXActionCandidate] {
        let candidates = droppingWeakAdapterMatches(productRouteFiltered(candidates))
        let avoided = candidates.filter {
            RoutePreferenceStore.shared.strength(
                intentKey: intentKey, bundleID: $0.bundleID ?? "", route: $0.route.rawValue)
                == .avoid
        }
        // Routes that failed recently are skipped until their cooldown elapses.
        let unavailable = candidates.filter {
            !CapabilityAvailabilityStore.shared.isAvailable(key: $0.availabilityKey)
        }
        var list = candidates
        if !unavailable.isEmpty {
            step("\(unavailable.count) route(s) cooling down after a recent failure")
        }
        if !avoided.isEmpty {
            step("\(avoided.count) route(s) skipped — you set “avoid” for them")
        }
        let dropIDs = Set((avoided + unavailable).map(\.id))
        if !dropIDs.isEmpty, dropIDs.count < candidates.count {
            list.removeAll { dropIDs.contains($0.id) }
        }
        step("Ranking \(list.count) route(s)…")
        list.sort { rankScore($0, intentKey: intentKey) < rankScore($1, intentKey: intentKey) }
        return list
    }

    /// Ranking is by route tier, and the adapter route is tier 0 — so an adapter candidate
    /// leads regardless of how well it matched. That is right when the adapter action *is*
    /// what was asked for, and wrong when the match rests on one shared word: "new private
    /// window in safari" put Safari's "New Tab" adapter action ahead of the cached menu's
    /// exact "New Private Window", and ran it.
    ///
    /// Tier order itself is sound — an adapter capability really is more reliable than a
    /// menu click — so rather than penalise the tier, drop a weakly-matched adapter
    /// candidate whenever some other route matched the request properly. When nothing else
    /// matched, the weak candidate stays: it is still the best guess available, and its low
    /// confidence means the chat path offers it instead of running it.
    private func droppingWeakAdapterMatches(
        _ candidates: [DoraXActionCandidate]
    ) -> [DoraXActionCandidate] {
        let strongAlternativeExists = candidates.contains {
            $0.route != .adapter && $0.route != .appLaunch && $0.confidence >= 0.7
        }
        guard strongAlternativeExists else { return candidates }
        let pruned = candidates.filter { !($0.route == .adapter && $0.confidence < 0.7) }
        if pruned.count < candidates.count {
            step("Dropped \(candidates.count - pruned.count) partial adapter match — an exact route matched")
        }
        return pruned.isEmpty ? candidates : pruned
    }

    /// Product rule: terminal/CLI is fallback-only for app workflows. If DoraX has a real
    /// app capability for the same target (adapter/native, MCP, API, shortcut, cached menu,
    /// or keyboard shortcut), remove CLI candidates before ranking. This prevents a model or
    /// learned preference from choosing shell when the user added a better app integration.
    func productRouteFiltered(_ candidates: [DoraXActionCandidate]) -> [DoraXActionCandidate] {
        let capableTargets = Set(candidates.compactMap { candidate -> String? in
            guard candidate.route != .cli,
                  candidate.source != .cli,
                  candidate.route != .appLaunch,
                  candidate.route != .axFallback
            else { return nil }
            return candidate.bundleID ?? "__system__"
        })
        guard !capableTargets.isEmpty else { return candidates }
        let filtered = candidates.filter { candidate in
            guard candidate.route == .cli || candidate.source == .cli else { return true }
            return !capableTargets.contains(candidate.bundleID ?? "__system__")
        }
        return filtered.isEmpty ? candidates : filtered
    }

    // MARK: - Read capability candidates

    private struct MenuReadSemantic {
        let type: DoraXActionCandidate.SemanticType
        let queryWords: [String]
        let valueHints: [String]
    }

    private let menuReadSemantics: [MenuReadSemantic] = [
        .init(type: .history,
              queryWords: ["history", "watched", "viewed", "played", "last video", "recent video"],
              valueHints: ["history", "watched", "viewed", "played"]),
        .init(type: .recentFiles,
              queryWords: ["recent files", "recent file", "open recent", "opened file"],
              valueHints: ["recent files", "open recent", "recent"]),
        .init(type: .recentDocuments,
              queryWords: ["recent documents", "recent document", "open recent"],
              valueHints: ["recent documents", "open recent", "recent"]),
        .init(type: .recentProjects,
              queryWords: ["recent projects", "recent project", "open recent"],
              valueHints: ["recent projects", "open recent", "recent"]),
        .init(type: .downloads,
              queryWords: ["downloads", "downloaded", "download"],
              valueHints: ["downloads", "download"]),
        .init(type: .bookmarks,
              queryWords: ["bookmarks", "bookmark", "favorites", "favourites"],
              valueHints: ["bookmarks", "bookmark", "favorites", "favourites"]),
        .init(type: .playlist,
              queryWords: ["playlist", "queue", "current playlist", "now playing"],
              valueHints: ["playlist", "queue", "up next", "now playing"]),
        .init(type: .recent,
              queryWords: ["recent", "latest", "last", "opened"],
              valueHints: ["recent", "open recent", "latest", "last"]),
    ]

    private func readDiscoveryApps(for query: String) -> [(name: String, bundleId: String)] {
        let runningBundleIds = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let adapters = AppAdapterManager.shared.adapters.filter(\.isEnabled)
        let adapterByBundle = Dictionary(uniqueKeysWithValues: adapters.map { ($0.bundleId, $0) })
        let summaries = AppMenuCapabilityCache.shared.summaries()
        let summaryByBundle = Dictionary(uniqueKeysWithValues: summaries.map { ($0.bundleIdentifier, $0) })
        let q = query.lowercased()
        let semanticTypes = readSemanticTypes(for: q)

        var bundleIds = Set<String>()
        bundleIds.formUnion(adapterByBundle.keys)
        bundleIds.formUnion(summaryByBundle.keys)
        bundleIds.formUnion(runningBundleIds)
        if let frontmostBundleId { bundleIds.insert(frontmostBundleId) }

        let installed = InstalledApplicationsCatalog.discoverInstalledApps()
        let installedByBundle = Dictionary(uniqueKeysWithValues: installed.map { ($0.bundleId, $0) })
        let named = bundleIds.compactMap { bundleId -> (name: String, bundleId: String)? in
            if let adapter = adapterByBundle[bundleId] { return (adapter.appName, bundleId) }
            if let summary = summaryByBundle[bundleId] { return (summary.appName, bundleId) }
            if let entry = installedByBundle[bundleId] { return (entry.name, bundleId) }
            if let name = installedAppName(bundleId: bundleId) { return (name, bundleId) }
            return nil
        }

        return named.sorted { lhs, rhs in
            func score(_ app: (name: String, bundleId: String)) -> Int {
                var s = 0
                if app.bundleId == frontmostBundleId { s -= 100 }
                if runningBundleIds.contains(app.bundleId) { s -= 40 }
                if let adapter = adapterByBundle[app.bundleId] {
                    if !adapter.contextReaders.isEmpty { s -= 30 }
                    if !adapter.actions.isEmpty { s -= 5 }
                }
                if let summary = summaryByBundle[app.bundleId] {
                    s -= min(20, summary.recordCount / 20)
                    let samples = summary.samplePaths.joined(separator: " ").lowercased()
                    if semanticTypes.contains(where: { semantic in
                        menuReadSemantics.first(where: { $0.type == semantic })?.valueHints
                            .contains(where: samples.contains) ?? false
                    }) { s -= 30 }
                }
                return s
            }
            let ls = score(lhs)
            let rs = score(rhs)
            if ls != rs { return ls < rs }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func adapterReadCandidates(
        app: (name: String, bundleId: String),
        query: String
    ) -> [DoraXActionCandidate] {
        guard let adapter = AppAdapterManager.shared.adapter(for: app.bundleId),
              !adapter.contextReaders.isEmpty
        else { return [] }
        let qTokens = readTokens(query)
        return adapter.contextReaders.compactMap { reader in
            let readerTokens = readTokens(reader.name + " " + reader.id + " " + reader.type)
            let score = readerTokens.intersection(qTokens).count
            let genericStatus = qTokens.contains("status") || qTokens.contains("current")
                || qTokens.contains("what")
            guard score > 0 || genericStatus else { return nil }
            var candidate = DoraXActionCandidate(
                id: "read.adapter.\(app.bundleId).\(stableKey(reader.id))",
                title: "Read \(reader.name) from \(app.name)",
                appName: app.name,
                bundleID: app.bundleId,
                source: .appAdapter,
                route: .adapter,
                capabilityID: reader.id,
                requiredInputs: [],
                riskLevel: .low,
                confidence: 0.88,
                permissionKey: "generalAI.read.\(app.bundleId).adapter.\(stableKey(reader.id))",
                debugReason: "app adapter context reader \(reader.id)")
            candidate.operation = .read
            candidate.semanticType = .status
            candidate.readSourceLabel = "App Adapter"
            return candidate
        }
    }

    private func menuCacheReadCandidates(
        app: (name: String, bundleId: String),
        query: String
    ) -> [DoraXActionCandidate] {
        // Cached menus are discovery metadata, not timeless app state. Old snapshots may
        // still route execution (which is live-verified), but must not be quoted as a read.
        let maximumReadAge: TimeInterval = 15 * 60
        guard let age = AppMenuCapabilityCache.shared.snapshotAge(
            bundleIdentifier: app.bundleId), age <= maximumReadAge else { return [] }
        let semantics = readSemanticTypes(for: query)
        guard !semantics.isEmpty else { return [] }
        var candidates: [DoraXActionCandidate] = []
        for semantic in semantics {
            guard let spec = menuReadSemantics.first(where: { $0.type == semantic }) else { continue }
            var values: [String] = []
            for queryWord in spec.valueHints + spec.queryWords {
                let items = AppMenuCapabilityCache.shared.menuItems(
                    bundleIdentifier: app.bundleId,
                    appName: app.name,
                    query: queryWord,
                    maxResults: 24
                )
                values.append(contentsOf: readableMenuValues(from: items, semantic: spec))
            }
            let unique = stableUnique(values).prefix(12)
            guard !unique.isEmpty else { continue }
            var candidate = DoraXActionCandidate(
                id: "read.menuCache.\(app.bundleId).\(semantic.rawValue)",
                title: "Read \(semantic.displayName) from \(app.name)",
                appName: app.name,
                bundleID: app.bundleId,
                source: .cachedMenu,
                route: .verifiedMenu,
                capabilityID: semantic.rawValue,
                requiredInputs: [],
                riskLevel: .low,
                confidence: 0.78,
                permissionKey: "generalAI.read.\(app.bundleId).menuCache.\(semantic.rawValue)",
                debugReason: "cached menu semantic group \(semantic.rawValue)")
            candidate.operation = .read
            candidate.semanticType = semantic
            candidate.readValues = Array(unique)
            let ageMinutes = max(0, Int(age / 60))
            candidate.readSourceLabel = "Menu Cache (fresh, \(ageMinutes)m old)"
            candidate.readContext = Array(unique).enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            candidates.append(candidate)
        }
        return candidates
    }

    private func mcpReadCandidates(
        app: (name: String, bundleId: String),
        query: String
    ) async -> [DoraXActionCandidate] {
        let tools = await MCPRuntime.shared.cachedTools(forBundleId: app.bundleId)
        guard !tools.isEmpty else { return [] }
        let readWords: Set<String> = ["read", "get", "list", "search", "find", "query", "lookup", "fetch", "status", "history", "recent"]
        let qTokens = readTokens(query)
        return tools.compactMap { entry in
            let nameTokens = readTokens(entry.tool.name + " " + entry.tool.description)
            guard !nameTokens.isDisjoint(with: readWords),
                  !nameTokens.isDisjoint(with: qTokens) || qTokens.contains("what")
            else { return nil }
            let required = (entry.tool.inputSchema["required"] as? [String]) ?? []
            guard required.isEmpty else { return nil }
            var candidate = DoraXActionCandidate(
                id: "read.mcp.\(app.bundleId).\(stableKey(entry.server)).\(stableKey(entry.tool.name))",
                title: "Read \(entry.tool.name.replacingOccurrences(of: "_", with: " ")) from \(app.name)",
                appName: app.name,
                bundleID: app.bundleId,
                source: .mcp,
                route: .mcp,
                capabilityID: entry.tool.name,
                requiredInputs: [],
                riskLevel: .low,
                confidence: 0.84,
                permissionKey: "generalAI.read.\(app.bundleId).mcp.\(stableKey(entry.tool.name))",
                debugReason: "connected MCP read-style tool \(entry.tool.name)")
            candidate.operation = .read
            candidate.semanticType = .unknown
            candidate.readSourceLabel = "MCP"
            candidate.inputValues = [
                "mcpServer": entry.server,
                "mcpTool": entry.tool.name,
                "mcpArguments": "{}",
            ]
            return candidate
        }
    }

    private func cliReadCandidates(
        app: (name: String, bundleId: String),
        query: String
    ) -> [DoraXActionCandidate] {
        let packages = TerminalPackageManager.shared.packages.filter {
            $0.isEnabled && $0.isAssociated(with: app.bundleId)
        }
        guard !packages.isEmpty else { return [] }
        let qTokens = semanticCLITokens(query)
        guard !qTokens.isDisjoint(with: ["status", "info", "list", "show", "get", "current", "what"]) else {
            return []
        }
        return packages.compactMap { package in
            let command: String
            if let manifest = ToolManifestDB.shared.manifest(for: package.command),
               let chosen = manifest.commands
                   .map({ semantic, template in
                       (semantic: semantic, template: template,
                        score: semanticCLITokens(semantic + " " + template).intersection(qTokens).count)
                   })
                   .filter({ $0.score > 0 && Self.templateParameters(in: $0.template).isEmpty })
                   .sorted(by: { $0.score > $1.score })
                   .first,
               let built = manifest.buildCommand(chosen.semantic, params: [:]) {
                command = built
            } else {
                return nil
            }
            var candidate = DoraXActionCandidate(
                id: "read.cli.\(app.bundleId).\(stableKey(package.command))",
                title: "Read \(app.name) using \(package.command)",
                appName: app.name,
                bundleID: app.bundleId,
                source: .cli,
                route: .cli,
                capabilityID: "terminal.runCommand",
                requiredInputs: [],
                riskLevel: .low,
                confidence: 0.7,
                permissionKey: "generalAI.read.\(app.bundleId).cli.\(stableKey(package.command))",
                debugReason: "app-linked CLI can provide read/status data")
            candidate.operation = .read
            candidate.semanticType = .status
            candidate.readSourceLabel = "CLI"
            candidate.readContext = "\(package.command): \(package.description)"
            candidate.inputValues = ["command": command]
            return candidate
        }
    }

    /// Words that only *modify* a noun. On their own they say nothing about WHAT to read:
    /// "recent commit", "last email" and "latest build" all contain one, and none of them
    /// mean the app's Open Recent menu. Under plain substring matching they were
    /// indistinguishable from "recent files", which is how "what is recent commit i did?"
    /// ended up offering to read Recent in Code, Notes and Finder.
    static let temporalModifiers: Set<String> = [
        "recent", "recently", "last", "latest", "current", "previous", "newest",
    ]

    /// Nouns the generic recent/opened semantics actually cover. A temporal modifier may
    /// only select a semantic when the query also names one of these.
    private static let genericReadNouns: Set<String> = [
        "file", "files", "document", "documents", "doc", "docs",
        "project", "projects", "folder", "folders", "item", "items",
    ]

    private static let readStopwords: Set<String> = [
        "what", "whats", "is", "was", "were", "are", "the", "a", "an", "my", "me", "i",
        "did", "do", "does", "show", "tell", "list", "of", "in", "on", "for", "to", "from",
        "with", "and", "or", "any", "there", "how", "many", "much", "when", "who", "which",
        "where", "you", "your", "it", "this", "that", "can", "please", "give", "get", "see",
        "find", "look", "up", "about", "some", "all", "have", "has", "had", "been", "be",
    ]

    /// The words in a query that carry its subject — everything that is not a stopword and
    /// not a temporal modifier. For "what is recent commit i did?" this is ["commit"].
    static func contentWords(of query: String) -> Set<String> {
        Set(
            query.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter {
                    $0.count > 1
                        && !readStopwords.contains($0)
                        && !temporalModifiers.contains($0)
                }
        )
    }

    private func readSemanticTypes(for query: String) -> [DoraXActionCandidate.SemanticType] {
        let q = query.lowercased()
        let content = Self.contentWords(of: q)
        // Does the query name a noun the generic recent/opened semantics actually cover?
        let namesGenericNoun = !content.isDisjoint(with: Self.genericReadNouns)

        var out: [DoraXActionCandidate.SemanticType] = []
        for spec in menuReadSemantics {
            let matched = spec.queryWords.filter(q.contains)
            guard !matched.isEmpty else { continue }
            // A spec that matched only on a bare modifier has not identified a subject.
            // Let it through only when the query also names a noun the spec covers.
            let matchedSomethingSubstantive = matched.contains {
                !Self.temporalModifiers.contains($0)
            }
            guard matchedSomethingSubstantive || namesGenericNoun else { continue }
            out.append(spec.type)
        }
        if namesGenericNoun, q.contains("last") || q.contains("latest") || q.contains("recent") {
            out.append(.recent)
        }
        if q.contains("video") || q.contains("watched") || q.contains("played") {
            out.append(.history)
            out.append(.playlist)
        }
        return stableUnique(out)
    }

    private func readableMenuValues(from items: [AXMenuItem], semantic: MenuReadSemantic) -> [String] {
        items.compactMap { item -> String? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != "-", !item.isAppleMenu else { return nil }
            let haystack = (item.path + [title]).joined(separator: " ").lowercased()
            guard semantic.valueHints.contains(where: haystack.contains) else { return nil }
            let normalizedTitle = title.lowercased()
            let blocked = [
                "clear history", "show all history", "history", "downloads", "bookmarks",
                "show bookmarks", "edit bookmarks", "open recent", "clear menu",
                "recent files", "recent documents", "recent projects",
            ]
            guard !blocked.contains(normalizedTitle) else { return nil }
            guard !normalizedTitle.hasPrefix("clear ") else { return nil }
            if let resolved = item.resolvedFilePath, !resolved.isEmpty {
                return "\(title) — \(resolved)"
            }
            return title
        }
    }

    private func readTokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 })
    }

    private func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Order-independent intent key for confidence learning: significant tokens (stopwords
    /// dropped), sorted + joined, so "create a text file" and "create text file now" collapse
    /// to the same key. Local-only, never sent to a provider.
    static func normalizedIntentKey(_ query: String) -> String {
        let stop: Set<String> = [
            "a", "an", "the", "to", "in", "on", "my", "this", "that", "new", "please",
            "now", "for", "of", "with", "some", "me", "i", "do", "have",
        ]
        let tokens = query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 && !stop.contains($0) }
            // Light plural stemming so "text files" and "text file" share a key.
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
        return Set(tokens).sorted().joined(separator: "-")
    }

    // MARK: - MCP route candidates

    /// Merge MCP-tool candidates into an app-scoped resolution and re-rank. MCP tools slot
    /// just below native adapter/capability (rank 1) and above CLI, per the DoraX spec.
    private func augmentWithMCPCandidates(
        _ base: GeneralAIActionResolution,
        appName: String,
        bundleID: String,
        actionPhrase: String,
        intentKey: String
    ) async -> GeneralAIActionResolution {
        guard case .candidates(var candidates) = base else { return base }
        let mcp = await mcpCandidates(
            appName: appName, bundleID: bundleID, actionPhrase: actionPhrase)
        step(mcp.isEmpty ? "MCP tools: no match" : "MCP tools: \(mcp.count) matched")
        guard !mcp.isEmpty else { return base }
        // Drop the honest "no verified route" launch fallback if a real MCP route now exists.
        if candidates.count == 1, candidates[0].route == .appLaunch, candidates[0].caveat != nil {
            candidates = mcp
        } else {
            candidates.append(contentsOf: mcp)
        }
        return .candidates(rankedWithPreferences(candidates, intentKey: intentKey))
    }

    /// Build `.mcp` candidates for tools whose NAME matches the action phrase. Guards:
    /// - only ALREADY-CONNECTED servers (no live connect on the hot path),
    /// - only tools with NO required inputs (we never invent argument values),
    /// - tool name must be known (never provider-invented).
    /// Tools that need inputs are left to the provider tool-loop, which fills args safely.
    private func mcpCandidates(
        appName: String, bundleID: String, actionPhrase: String
    ) async -> [DoraXActionCandidate] {
        let phraseTokens = Set(
            actionPhrase.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() })
        guard !phraseTokens.isEmpty else { return [] }

        let tools = await MCPRuntime.shared.cachedTools(forBundleId: bundleID)
        var out: [DoraXActionCandidate] = []
        for entry in tools {
            let toolTokens = Set(
                entry.tool.name
                    .split { $0 == "_" || $0 == "-" || $0.isWhitespace }
                    .map { String($0).lowercased() })
            guard !toolTokens.isDisjoint(with: phraseTokens) else { continue }
            let required = (entry.tool.inputSchema["required"] as? [String]) ?? []
            guard required.isEmpty else { continue }

            let readable = entry.tool.name.replacingOccurrences(of: "_", with: " ")
            var candidate = DoraXActionCandidate(
                id: "mcp.\(bundleID).\(stableKey(entry.tool.name))",
                title: "\(appName): \(readable)",
                appName: appName,
                bundleID: bundleID,
                source: .mcp,
                route: .mcp,
                capabilityID: nil,
                requiredInputs: [],
                riskLevel: .medium,
                confidence: 0.85,
                permissionKey: "generalAI.execute.\(bundleID).mcp.\(stableKey(entry.tool.name))",
                debugReason: "MCP tool \(entry.tool.name) name-matches the request")
            candidate.inputValues = [
                "mcpServer": entry.server,
                "mcpTool": entry.tool.name,
                "mcpArguments": "{}",
            ]
            out.append(candidate)
        }
        return out
    }

    // MARK: - CLI tool route candidates

    /// Discover a CLI route from INSTALLED tools with a saved manifest only. The command is
    /// built from the manifest template with parameters filled from real context (a live URL
    /// for {url}-shaped params, the query phrase for {query}). We never run a bare binary or
    /// provider-authored shell text. Missing required parameters → clarify, never fabricate.
    private func resolveCLIToolAction(lowered: String, original: String)
        -> GeneralAIActionResolution?
    {
        guard let package = TerminalPackageManager.shared.findPackageForQuery(original),
            package.isEnabled
        else { return nil }
        guard let candidate = cliCandidate(
            package: package,
            appName: package.command,
            bundleID: nil,
            actionPhrase: lowered,
            original: original,
            confidence: 0.84,
            debugPrefix: "installed CLI")
        else { return nil }
        return .candidates([candidate])
    }

    private func appLinkedCLICandidates(
        appName: String,
        bundleID: String,
        actionPhrase: String,
        original: String
    ) -> [DoraXActionCandidate] {
        var packages = TerminalPackageManager.shared.packages.filter {
            $0.isEnabled && $0.isAssociated(with: bundleID)
        }
        let cliActions = AppAdapterManager.shared.actions(for: bundleID)
            .filter { $0.type == .cliTool }
        for action in cliActions {
            let command = (action.cliToolCommand ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty,
                !packages.contains(where: { $0.command.caseInsensitiveCompare(command) == .orderedSame })
            else { continue }
            packages.append(TerminalPackage(
                name: action.name.isEmpty ? command : action.name,
                command: command,
                description: action.description,
                keywords: action.triggers + [command],
                contextAppBundleIds: [bundleID]
            ))
        }
        return packages.compactMap {
            cliCandidate(
                package: $0,
                appName: appName,
                bundleID: bundleID,
                actionPhrase: actionPhrase,
                original: original,
                confidence: 0.86,
                debugPrefix: "app-linked CLI")
        }
    }

    private func cliCandidate(
        package: TerminalPackage,
        appName: String,
        bundleID: String?,
        actionPhrase: String,
        original: String,
        confidence: Double,
        debugPrefix: String
    ) -> DoraXActionCandidate? {
        guard let manifest = ToolManifestDB.shared.manifest(for: package.command),
            !manifest.commands.isEmpty
        else { return nil }

        let queryTokens = semanticCLITokens(actionPhrase + " " + original)
        var best: (semantic: String, template: String, score: Int)?
        for (semantic, template) in manifest.commands {
            let words = semanticCLITokens(semantic + " " + template)
            let score = words.intersection(queryTokens).count
            if score > (best?.score ?? 0) {
                best = (semantic, template, score)
            }
        }
        guard let chosen = best, chosen.score > 0 else { return nil }

        let paramNames = Self.templateParameters(in: chosen.template)
        var params: [String: String] = [:]
        for name in paramNames {
            let lname = name.lowercased()
            if ["url", "link", "video", "page", "address"].contains(where: lname.contains) {
                guard let url = currentContextURL(), !url.isEmpty else { return nil }
                params[name] = "\"\(url)\""
            } else if ["query", "search", "term", "q", "text"].contains(where: { lname == $0 }) {
                let phrase = strippedQueryPhrase(original, toolName: package.command)
                guard !phrase.isEmpty else { return nil }
                params[name] = "\"\(phrase)\""
            } else {
                return nil
            }
        }

        guard let command = manifest.buildCommand(chosen.semantic, params: params),
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var candidate = DoraXActionCandidate(
            id: "cli.\(package.command).\(stableKey(chosen.semantic))",
            title: "\(package.command): \(chosen.semantic.replacingOccurrences(of: "_", with: " "))",
            appName: appName,
            bundleID: bundleID,
            source: .cli,
            route: .cli,
            capabilityID: "terminal.runCommand",
            requiredInputs: [],
            riskLevel: .medium,
            confidence: confidence,
            permissionKey:
                "generalAI.execute.cli.\(stableKey(package.command)).\(stableKey(chosen.semantic))",
            debugReason: "\(debugPrefix) \(package.command) manifest command \(chosen.semantic)")
        candidate.inputValues = ["command": command]
        guard CapabilityAvailabilityStore.shared.isAvailable(key: candidate.availabilityKey) else {
            return nil
        }
        return candidate
    }

    private func semanticCLITokens(_ text: String) -> Set<String> {
        var tokens = Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 1 }
        )
        if tokens.contains("off") || tokens.contains("stop") || tokens.contains("disable") {
            tokens.formUnion(["down", "stop", "disable", "disconnect", "logout"])
        }
        if tokens.contains("on") || tokens.contains("start") || tokens.contains("enable") {
            tokens.formUnion(["up", "start", "enable", "connect", "login"])
        }
        if tokens.contains("status") || tokens.contains("state") || tokens.contains("running") {
            tokens.formUnion(["status", "info", "list"])
        }
        return tokens
    }

    /// Parameter names inside a `{name}` template.
    private static func templateParameters(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{(\\w+)\\}") else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        return regex.matches(in: template, range: range).compactMap {
            Range($0.range(at: 1), in: template).map { String(template[$0]) }
        }
    }

    /// A live URL from the current context for filling {url} params — browser page or an
    /// explicit selection/clipboard URL. No new AX scan; reads already-current context.
    private func currentContextURL() -> String? {
        if let url = AXContextReader.shared.current.currentURL,
            !url.trimmingCharacters(in: .whitespaces).isEmpty {
            return url
        }
        if let clip = NSPasteboard.general.string(forType: .string),
            clip.hasPrefix("http://") || clip.hasPrefix("https://") {
            return clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Query text with the tool name + common command verbs stripped, to use as a {query} arg.
    private func strippedQueryPhrase(_ query: String, toolName: String) -> String {
        var text = query.lowercased()
        for token in [toolName.lowercased(), "download", "run", "search", "play", "using", "with"] {
            text = text.replacingOccurrences(of: token, with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - API tool route candidates

    /// Known built-in API reads through APICommandHandler. Only real, no-arg status commands
    /// are emitted (volume/brightness are stubs and are deliberately excluded). Never invents
    /// an API name; the command line is a fixed, registered string.
    private func resolveAPIToolAction(lowered: String) -> GeneralAIActionResolution? {
        let statusSignal =
            lowered.contains("status") || lowered.contains("level") || lowered.contains("how much")
            || lowered.contains("what") || lowered.contains("is my") || lowered.contains("percent")
        let apiArgs: String?
        if lowered.contains("battery") {
            apiArgs = lowered.contains("charg") ? "battery charging" : "battery level"
        } else if (lowered.contains("wifi") || lowered.contains("wi-fi") || lowered.contains("ssid"))
            && statusSignal {
            apiArgs = "network ssid"
        } else if lowered.contains("ip address") || (lowered.contains(" ip") && statusSignal) {
            apiArgs = "network ip"
        } else {
            apiArgs = nil
        }
        guard let args = apiArgs else { return nil }

        let key = args.replacingOccurrences(of: " ", with: ".")
        var candidate = DoraXActionCandidate(
            id: "api.\(key)",
            title: "System: \(args)",
            appName: "System",
            bundleID: nil,
            source: .api,
            route: .api,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 0.8,
            permissionKey: "generalAI.execute.system.api.\(stableKey(key))",
            debugReason: "built-in API command \(args)")
        candidate.inputValues = ["apiArgs": args]
        guard CapabilityAvailabilityStore.shared.isAvailable(key: candidate.availabilityKey) else {
            return nil
        }
        return .candidates([candidate])
    }

    private func bestMenuMatch(_ items: [AXMenuItem], actionPhrase: String) -> AXMenuItem? {
        guard !items.isEmpty else { return nil }
        let conversationalNoise: Set<String> = [
            "a", "an", "as", "current", "currently", "in", "into", "my", "of", "on",
            "please", "selected", "that", "the", "this", "to", "using",
        ]
        let tokens = actionPhrase
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
            .filter { $0.count > 1 && !conversationalNoise.contains($0) }
        guard !tokens.isEmpty else { return nil }
        // Require every meaningful token to appear somewhere in the title or path —
        // "new private window" must not settle for plain "New Window".
        return items.first { item in
            let haystack = (item.path + [item.title]).joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: - Seeded common shortcuts

    /// Well-known keyboard routes so first-run works before the menu cache is warm.
    private struct SeededShortcut {
        let bundleID: String
        let phrases: [String]
        let title: String
        let menuPath: [String]
        let char: String
        let modifiers: Int   // 0=⌘ 1=⇧⌘ 2=⌥⌘
    }

    private let seededShortcuts: [SeededShortcut] = [
        .init(bundleID: "com.apple.Safari", phrases: ["new private window", "private window"],
              title: "New Private Window", menuPath: ["File", "New Private Window"],
              char: "n", modifiers: 1),
        .init(bundleID: "com.apple.Safari", phrases: ["new window"],
              title: "New Window", menuPath: ["File", "New Window"], char: "n", modifiers: 0),
        .init(bundleID: "com.apple.Safari", phrases: ["new tab"],
              title: "New Tab", menuPath: ["File", "New Tab"], char: "t", modifiers: 0),
        .init(bundleID: "com.apple.Safari",
              phrases: ["reopen recently closed tabs", "reopen last closed tab",
                        "reopen last closed tabs", "restore closed tab", "restore last tab"],
              title: "Reopen Last Closed Window",
              menuPath: ["History", "Reopen Last Closed Window"],
              char: "t", modifiers: 1),
        .init(bundleID: "com.apple.TextEdit", phrases: ["new document", "new file", "new text file"],
              title: "New Document", menuPath: ["File", "New"], char: "n", modifiers: 0),
        .init(bundleID: "com.apple.finder", phrases: ["new folder"],
              title: "New Folder", menuPath: ["File", "New Folder"], char: "n", modifiers: 1),
        .init(bundleID: "com.apple.finder", phrases: ["new window"],
              title: "New Finder Window", menuPath: ["File", "New Finder Window"],
              char: "n", modifiers: 0),
        .init(bundleID: "com.google.Chrome",
              phrases: ["new private window", "private window", "incognito"],
              title: "New Incognito Window", menuPath: ["File", "New Incognito Window"],
              char: "n", modifiers: 1),
        .init(bundleID: "com.google.Chrome", phrases: ["new window"],
              title: "New Window", menuPath: ["File", "New Window"], char: "n", modifiers: 0),
        .init(bundleID: "com.google.Chrome", phrases: ["new tab"],
              title: "New Tab", menuPath: ["File", "New Tab"], char: "t", modifiers: 0),
        .init(bundleID: "company.thebrowser.Browser",
              phrases: ["new private window", "private window", "incognito"],
              title: "New Incognito Window", menuPath: ["File", "New Incognito Window"],
              char: "n", modifiers: 1),
        .init(bundleID: "company.thebrowser.Browser", phrases: ["new tab"],
              title: "New Tab", menuPath: ["File", "New Tab"], char: "t", modifiers: 0),
    ]

    private func seededShortcutCandidate(
        bundleID: String, appName: String, actionPhrase: String
    ) -> DoraXActionCandidate? {
        for seed in seededShortcuts where seed.bundleID == bundleID {
            guard seed.phrases.contains(where: actionPhrase.contains) else { continue }
            return keyboardShortcutCandidate(
                title: seed.title, path: seed.menuPath, char: seed.char,
                modifiers: seed.modifiers, appName: appName, bundleID: bundleID,
                confidence: 0.8, reason: "built-in known shortcut for \(appName)")
        }
        return nil
    }

    private func matchingMacShortcut(for query: String) -> MacShortcut? {
        let lowered = query.lowercased()
        return ShortcutsCatalog.shared.shortcuts.first { shortcut in
            let name = shortcut.name.lowercased()
            return name.count > 3 && lowered.contains(name)
        }
    }

    // MARK: - Domain intents

    private func resolveMediaTransportIntent(
        _ lowered: String,
        original: String
    ) async -> GeneralAIActionResolution? {
        let command: MRCommand
        let verb: String
        if ["pause", "stop music", "stop song", "pause music", "pause song"].contains(lowered) {
            command = .pause
            verb = "Pause"
        } else if ["play", "resume", "resume music", "play music"].contains(lowered) {
            command = .play
            verb = "Play"
        } else if ["next", "next song", "next track", "skip"].contains(lowered) {
            command = .nextTrack
            verb = "Next Track"
        } else if ["previous", "prev", "previous song", "previous track"].contains(lowered) {
            command = .previousTrack
            verb = "Previous Track"
        } else {
            return nil
        }

        let info = await MediaRemoteBridge.shared.infoAsync()
        let parsed = MediaRemoteBridge.parse(info)
        let client = await MediaRemoteBridge.shared.clientAsync()
        let providerFallback = MediaInfoProvider.shared.getNowPlayingSourceInfo()
        let title = parsed.title.isEmpty ? (providerFallback.title ?? "") : parsed.title
        let artist = parsed.artist.isEmpty ? (providerFallback.artist ?? "") : parsed.artist
        let bundleID = client.bundleID ?? providerFallback.bundleID
        let observerAppName = MediaPlayerObserver.shared.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = client.displayName
            ?? bundleID.flatMap { installedAppName(bundleId: $0) }
            ?? (observerAppName.isEmpty ? nil : observerAppName)
            ?? "current media app"
        let isPlaying = parsed.isPlaying || providerFallback.playbackRate > 0

        guard !title.isEmpty || bundleID != nil || !appName.isEmpty else { return nil }
        if command == .pause && !isPlaying {
            return .explain("Nothing is currently playing.")
        }

        let target = title.isEmpty
            ? appName
            : "\(title)\(artist.isEmpty ? "" : " by \(artist)") in \(appName)"
        var candidate = DoraXActionCandidate(
            id: "automation.media.\(stableKey(verb))",
            title: "\(verb) \(target)",
            appName: appName,
            bundleID: bundleID,
            source: .automation,
            route: .automation,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 0.9,
            permissionKey: "generalAI.execute.media.\(stableKey(verb))",
            debugReason: "MediaRemote now-playing route from General Chat")
        candidate.inputValues = [
            "mediaCommand": "\(command.rawValue)",
            "verb": verb,
            "title": title,
            "artist": artist,
            "appName": appName,
        ]
        return .candidates([candidate])
    }

    private func resolveNativeShareIntent(_ original: String) async -> GeneralAIActionResolution? {
        guard let intent = ShareIntentRouter.shared.parse(original) else { return nil }
        var context = AXContextReader.shared.current
        // The AX context only carries a page URL for Safari. For any other browser
        // (DuckDuckGo, Chrome, Arc…) read its live address-bar URL so "share current
        // page" has something to share.
        if (context.currentURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let app = await AppDelegate.shared?.previousFrontmostApp,
            let bundleId = app.bundleIdentifier,
            SelectedContextResolver.isBrowserBundleId(bundleId),
            let liveURL = AXContextReader.shared.liveCurrentURL(
                pid: app.processIdentifier, bundleId: bundleId)
        {
            context.currentURL = liveURL
        }
        let items = ShareIntentRouter.shared.shareItems(for: context)
        guard !items.isEmpty else {
            return .explain(
                "I can share through macOS native sharing, but there is nothing selected, "
                + "no readable page URL, and no selected text right now.")
        }
        let resolution = await ShareIntentRouter.shared.resolve(intent)
        let destination = resolution.recipientDisplayName.isEmpty
            ? nativeShareDestinationName(intent.channelHint)
            : resolution.recipientDisplayName
        var candidate = DoraXActionCandidate(
            id: "automation.nativeShare",
            title: "Share current context to \(destination)",
            appName: nativeShareDestinationName(intent.channelHint),
            bundleID: nil,
            source: .automation,
            route: .automation,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .medium,
            confidence: 0.88,
            permissionKey: "generalAI.execute.nativeShare.\(stableKey(destination))",
            debugReason: "native macOS share route from General Chat")
        candidate.inputValues = ["rawQuery": original]
        return .candidates([candidate])
    }

    private func nativeShareDestinationName(_ hint: ShareChannelHint) -> String {
        switch hint {
        case .messages: return "Messages"
        case .mail: return "Mail"
        case .airDrop: return "AirDrop"
        case .picker: return "Share Sheet"
        }
    }

    private func resolveReminderIntent(
        _ lowered: String, original: String
    ) -> GeneralAIActionResolution? {
        let isReminder = lowered.contains("reminder") || lowered.hasPrefix("remind me")
        guard isReminder else { return nil }
        guard CapabilityRegistry.shared.capability(id: "reminders.create") != nil else {
            return .explain(
                "I can create real reminders, but the Reminders integration is disabled. "
                + "Enable it in Settings → App Adapters → Reminders → Tools, then ask again.")
        }
        let title = reminderTitle(from: lowered)
        guard !title.isEmpty else {
            return .clarify(
                question: "What should the reminder say?",
                options: [])
        }
        var candidate = DoraXActionCandidate(
            id: "capability.reminders.create",
            title: "Create reminder “\(title)”",
            appName: "Reminders",
            bundleID: "com.apple.reminders",
            source: .system,
            route: .adapter,
            capabilityID: "reminders.create",
            requiredInputs: ["title"],
            riskLevel: .medium,
            confidence: 0.9,
            permissionKey: "generalAI.execute.reminders.createReminder",
            debugReason: "reminders.create capability registered")
        candidate.inputValues = ["title": title]
        return .candidates([candidate])
    }

    private func reminderTitle(from lowered: String) -> String {
        var text = lowered
        for prefix in [
            "add a reminder to ", "add reminder to ", "add a reminder ", "add reminder ",
            "create a reminder to ", "create reminder to ", "create a reminder ",
            "create reminder ", "remind me to ", "remind me ", "new reminder ",
        ] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        if text == lowered { return "" }  // No known prefix — don't guess a title.
        for connector in [" for ", " about ", " that says "] where text.hasPrefix(connector) {
            text = String(text.dropFirst(connector.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func resolveCalendarIntent(
        _ lowered: String, original: String
    ) -> GeneralAIActionResolution? {
        let isEvent = (lowered.contains("event") || lowered.contains("meeting"))
            && (lowered.hasPrefix("add ") || lowered.hasPrefix("create ")
                || lowered.hasPrefix("schedule "))
        guard isEvent else { return nil }
        guard CapabilityRegistry.shared.capability(id: "calendar.create") != nil else {
            return .explain(
                "I can create real calendar events, but the Calendar integration is disabled. "
                + "Enable it in Settings → App Adapters → Calendar → Tools, then ask again.")
        }
        // Reliable date parsing needs the provider; require an explicit time phrase here
        // and let clarification collect the rest instead of guessing.
        return .clarify(
            question: "What's the event title, date, and time? (e.g. “Standup, tomorrow 9:30–10:00”)",
            options: [])
    }

    private func resolveMessagingIntent(
        _ lowered: String, original: String
    ) -> GeneralAIActionResolution? {
        let isMessage = lowered.hasPrefix("send message") || lowered.hasPrefix("send a message")
            || lowered.hasPrefix("text ") || lowered.hasPrefix("message ")
            || lowered.hasPrefix("imessage ")
        let isMail = lowered.hasPrefix("send mail") || lowered.hasPrefix("send email")
            || lowered.hasPrefix("send an email") || lowered.hasPrefix("email ")
        guard isMessage || isMail else { return nil }

        // "send message to Alex saying running late" — need recipient AND body.
        guard let toRange = lowered.range(of: " to ") else {
            return .clarify(
                question: isMail
                    ? "Who should the email go to, and what should it say?"
                    : "Who should the message go to, and what should it say?",
                options: [])
        }
        let afterTo = String(lowered[toRange.upperBound...])
        let bodySeparators = [" saying ", " that says ", " with body ", ": "]
        var recipient = afterTo
        var body = ""
        for separator in bodySeparators {
            if let range = afterTo.range(of: separator) {
                recipient = String(afterTo[..<range.lowerBound])
                body = String(afterTo[range.upperBound...])
                break
            }
        }
        recipient = recipient.trimmingCharacters(in: .whitespaces)
        body = body.trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty, !body.isEmpty else {
            return .clarify(
                question: "I need both a recipient and the message text — e.g. "
                    + "“send message to Alex saying running 10 min late”.",
                options: [])
        }
        if isMail {
            return .explain(
                "I don't have a verified compose-and-send route for Mail yet. "
                + "I can open Mail for you, but I won't pretend the email was sent.")
        }
        var candidate = DoraXActionCandidate(
            id: "automation.messages.compose",
            title: "Compose Message to \(recipient)",
            appName: "Messages",
            bundleID: "com.apple.MobileSMS",
            source: .automation,
            route: .automation,
            capabilityID: nil,
            requiredInputs: ["recipient", "body"],
            riskLevel: .high,
            confidence: 0.85,
            permissionKey: "generalAI.execute.messages.composeMessage",
            debugReason: "MessagesAutomation.composeMessage available")
        candidate.inputValues = ["recipient": recipient, "body": body]
        return .candidates([candidate])
    }

    private func resolveCreateFileIntent(_ lowered: String) -> GeneralAIActionResolution? {
        let wantsFile = (lowered.contains("text file") || lowered.contains("new file")
            || lowered.contains("empty file"))
            && (lowered.hasPrefix("create ") || lowered.hasPrefix("make ")
                || lowered.hasPrefix("new "))
        guard wantsFile else { return nil }
        // Ambiguous by design — the user didn't name an app or location.
        if lowered.contains("textedit") || lowered.contains("text edit") { return nil }
        if lowered.contains("finder") || lowered.contains("desktop")
            || lowered.contains("vs code") || lowered.contains("vscode") { return nil }

        // Honor an explicit user preference for this intent instead of asking every time.
        let intentKey = Self.normalizedIntentKey(lowered)
        let fileApps = [
            (name: "TextEdit", bundleID: "com.apple.TextEdit"),
            (name: "Finder", bundleID: "com.apple.finder"),
            (name: "VS Code", bundleID: "com.microsoft.VSCode"),
        ]
        for app in fileApps
        where RoutePreferenceStore.shared.strength(
            intentKey: intentKey, bundleID: app.bundleID, route: "appLaunch") == .preferred {
            return resolveAppScopedAction(
                appName: app.name, bundleID: app.bundleID,
                actionPhrase: "new document", original: lowered)
        }

        return .clarify(
            question: "Where should I create it?",
            options: [
                "TextEdit — new unsaved document",
                "Finder — empty file on the Desktop",
                "VS Code — new untitled file",
            ])
    }

    // MARK: - Candidate builders

    private func pasteClipboardCandidate(
        appName: String,
        bundleID: String,
        actionPhrase: String
    ) -> DoraXActionCandidate? {
        let phrase = actionPhrase.lowercased()
        guard phrase.contains("paste") && phrase.contains("clipboard") else { return nil }
        guard (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        var candidate = keyboardShortcutCandidate(
            title: "Paste Clipboard",
            path: ["Edit", "Paste"],
            char: "v",
            modifiers: 0,
            appName: appName,
            bundleID: bundleID,
            confidence: 0.86,
            reason: "clipboard paste requested for named app")
        candidate.caveat = "Activates \(appName), then sends Command-V to the focused field."
        return candidate
    }

    private func launchCandidate(
        appName: String, bundleID: String, confidence: Double
    ) -> DoraXActionCandidate {
        DoraXActionCandidate(
            id: "launch.\(bundleID)",
            title: "Open \(appName)",
            appName: appName,
            bundleID: bundleID,
            source: .system,
            route: .appLaunch,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: confidence,
            permissionKey: "generalAI.execute.\(bundleID).launch",
            debugReason: "plain app launch")
    }

    private func adapterCandidate(
        action: AdapterAction, appName: String, bundleID: String, confidence: Double
    ) -> DoraXActionCandidate {
        let risk: AICapabilityRiskLevel
        switch action.type.riskLevel {
        case .low: risk = .low
        case .medium: risk = .medium
        case .high: risk = .high
        }
        var candidate = DoraXActionCandidate(
            id: "adapter.\(bundleID).\(action.id)",
            title: "\(appName): \(action.name)",
            appName: appName,
            bundleID: bundleID,
            source: .appAdapter,
            route: .adapter,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: risk,
            confidence: confidence,
            permissionKey: "generalAI.execute.\(bundleID).adapter.\(stableKey(action.id))",
            debugReason: "adapter action trigger match")
        candidate.adapterActionID = action.id
        return candidate
    }

    private func keyboardShortcutCandidate(
        title: String, path: [String], char: String, modifiers: Int,
        appName: String, bundleID: String, confidence: Double, reason: String
    ) -> DoraXActionCandidate {
        var candidate = DoraXActionCandidate(
            id: "kbd.\(bundleID).\(stableKey(title))",
            title: "\(appName): \(title)",
            appName: appName,
            bundleID: bundleID,
            source: .keyboardShortcut,
            route: .keyboardShortcut,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: confidence,
            permissionKey: "generalAI.execute.\(bundleID).\(stableKey(title))",
            debugReason: reason)
        candidate.menuPath = path
        candidate.shortcutChar = char
        candidate.shortcutModifiers = modifiers
        return candidate
    }

    /// A menu command for an app, by name, for callers outside the resolver.
    ///
    /// The agent loop had no way to click a menu. It could run shell commands and named
    /// capabilities, and for an app whose only capability *is* its menu bar that left it
    /// nothing legal to call — so it recommended building an adapter pack, ten times, and
    /// then reported "commands completed" having done nothing.
    /// The three ways a requested menu path can turn out, told apart.
    ///
    /// One nil for all of them read as "that command does not exist", so a greyed-out item
    /// — Add Title with no entry open, All Entries when they are already showing — came back
    /// as "this specific command may not exist in Journal" about a command sitting in the
    /// cache. A command that exists and is unavailable right now is a different fact, and
    /// the user can act on it.
    enum MenuCommandLookup {
        case ready(DoraXActionCandidate)
        case disabled(path: String, appName: String)
        case missing(appName: String, nearest: [String])
    }

    func menuCommandCandidate(appName: String, path: [String]) -> MenuCommandLookup {
        guard let target = resolveTargetApp(in: appName.lowercased()) else {
            return .missing(appName: appName, nearest: [])
        }
        // Matched against the cache rather than trusted: a path the model wrote from memory
        // is a guess, and clicking a guessed menu item is how an agent ends up in Erase.
        let wanted = path.map { $0.lowercased() }
        let records = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: target.bundleId, appName: target.name,
            query: path.last ?? "", maxResults: 24)
        let match = records.first { record in
            let recorded = record.path.map { $0.lowercased() }
            return recorded == wanted || (recorded.last == wanted.last && wanted.count == 1)
        }
        guard let match else {
            return .missing(
                appName: target.name, nearest: records.prefix(5).map(\.pathString))
        }
        guard match.isEnabled else {
            return .disabled(path: match.pathString, appName: target.name)
        }
        return .ready(verifiedMenuCandidate(
            title: match.path.joined(separator: " → "),
            path: match.path,
            shortcutChar: match.shortcutChar, shortcutModifiers: match.shortcutModifiers,
            appName: target.name, bundleID: target.bundleId, confidence: 0.9))
    }

    private func verifiedMenuCandidate(
        title: String, path: [String], shortcutChar: String?, shortcutModifiers: Int,
        appName: String, bundleID: String, confidence: Double
    ) -> DoraXActionCandidate {
        var candidate = DoraXActionCandidate(
            id: "menu.\(bundleID).\(stableKey(path.joined(separator: ">")))",
            title: "\(appName): \(path.joined(separator: " → "))",
            appName: appName,
            bundleID: bundleID,
            source: .cachedMenu,
            route: .verifiedMenu,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .medium,
            confidence: confidence,
            permissionKey: "generalAI.execute.\(bundleID).menu.\(stableKey(path.joined(separator: ">")))",
            debugReason: "cached menu match, will live-verify before executing")
        candidate.menuPath = path
        candidate.shortcutChar = shortcutChar
        candidate.shortcutModifiers = shortcutModifiers
        candidate.caveat =
            "No better app adapter/MCP/API route matched. DoraX can launch \(appName), "
            + "live-check this cached menu item, then click it only if it is available."
        return candidate
    }

    private func stableKey(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}
