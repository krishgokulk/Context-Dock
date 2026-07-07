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

    let id: String
    let title: String
    let appName: String?
    let bundleID: String?
    let source: Source
    let route: ExecutionRoute
    let capabilityID: String?
    let requiredInputs: [String]
    let riskLevel: AICapabilityRiskLevel
    let confidence: Double
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
        case .verifiedMenu: return "verified menu"
        case .axFallback: return "accessibility action"
        case .appLaunch: return "app launch"
        case .automation: return "app automation"
        }
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
}

// MARK: - Resolver

@MainActor
final class GeneralAIActionResolver {
    static let shared = GeneralAIActionResolver()

    /// Per-app capability routers — consulted BEFORE the generic ranking so each app
    /// can pick its most deterministic route (Safari: bridge/history-cache/CLI over menus).
    private let appRouters: [String: any AppCapabilityRouting]

    private init() {
        let routers: [any AppCapabilityRouting] = [
            SafariCapabilityRouter()
        ]
        appRouters = Dictionary(uniqueKeysWithValues: routers.map { ($0.bundleID, $0) })
    }

    // MARK: Public entry

    func resolve(query: String) async -> GeneralAIActionResolution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyExecutable(trimmed) else { return .none }
        let lowered = trimmed.lowercased()

        // Domain intents first — they are more specific than generic app actions.
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

        // Generic app-scoped action: "open safari new private window", "quit music", …
        if let target = resolveTargetApp(in: lowered) {
            // Per-app router first — it knows the best route for that app's tasks.
            if let router = appRouters[target.bundleId],
               let routed = await router.route(
                   actionPhrase: target.remainingPhrase, original: trimmed) {
                return routed
            }
            return resolveAppScopedAction(
                appName: target.name,
                bundleID: target.bundleId,
                actionPhrase: target.remainingPhrase,
                original: trimmed
            )
        }

        // Browser action with no browser named ("new private window") — ask which one
        // when several browsers are installed instead of guessing.
        if let browserResolution = await resolveUnscopedBrowserAction(lowered, original: trimmed) {
            return browserResolution
        }

        return .none
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

    /// Cheap local check: does this look like a command rather than a question?
    /// Runs only on submit (never while typing) and uses no AX or provider calls.
    private func isLikelyExecutable(_ query: String) -> Bool {
        let lowered = query.lowercased()
        guard !lowered.isEmpty, lowered.count < 160 else { return false }
        // Questions and explanations stay in normal chat.
        if lowered.hasSuffix("?") { return false }
        // Page-grounded browser tasks are executable even though they start like
        // a chat request ("summarize this safari page" → Safari router).
        if (lowered.contains("summarize") || lowered.contains("summarise"))
            && lowered.contains("page") {
            return true
        }
        let questionStarts = [
            "how ", "what", "why ", "who ", "when ", "where ", "which ", "explain",
            "tell me", "can you explain", "describe", "compare", "summarize", "translate",
            "write ", "is ", "are ", "does ", "do ", "did ", "should ",
        ]
        if questionStarts.contains(where: lowered.hasPrefix) { return false }

        let verbs = [
            "open ", "launch ", "start ", "create ", "new ", "add ", "make ",
            "quit ", "close ", "show ", "hide ", "toggle ", "enable ", "disable ",
            "turn ", "mute ", "unmute ", "minimize ", "maximize ", "empty ",
            "run ", "activate ", "switch ", "remind ", "schedule ", "send ",
            "compose ", "email ", "text ", "play ", "pause ",
            "bookmark ", "download ",
        ]
        return verbs.contains(where: lowered.hasPrefix)
            // "safari new private window" — app name first, verb inside.
            || verbs.contains(where: { lowered.contains(" \($0)") })
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

    private func resolveTargetApp(in lowered: String) -> TargetApp? {
        // Longest alias match first so "text edit" beats "text".
        let sortedAliases = appAliases.keys.sorted { $0.count > $1.count }
        for alias in sortedAliases {
            guard containsWordPhrase(lowered, phrase: alias) else { continue }
            let bundleId = appAliases[alias]!
            guard let name = installedAppName(bundleId: bundleId) else { continue }
            return TargetApp(
                name: name,
                bundleId: bundleId,
                remainingPhrase: removePhrase(alias, from: lowered)
            )
        }
        // Installed-apps catalog (already warmed at startup; in-memory read).
        let installed = InstalledApplicationsCatalog.cachedInstalledApps()
        var best: (entry: InstalledApplicationEntry, nameLength: Int)?
        for entry in installed {
            let name = entry.name.lowercased()
            guard name.count > 2, containsWordPhrase(lowered, phrase: name) else { continue }
            if best == nil || name.count > best!.nameLength {
                best = (entry, name.count)
            }
        }
        guard let best else { return nil }
        return TargetApp(
            name: best.entry.name,
            bundleId: best.entry.bundleId,
            remainingPhrase: removePhrase(best.entry.name.lowercased(), from: lowered)
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
        original: String
    ) -> GeneralAIActionResolution {
        var candidates: [DoraXActionCandidate] = []

        // Bare "open <app>" → plain launch, high confidence.
        if actionPhrase.isEmpty || actionPhrase == "open" {
            candidates.append(launchCandidate(appName: appName, bundleID: bundleID, confidence: 0.92))
            return .candidates(candidates)
        }

        // 1. App adapter actions (native registered capability).
        let adapterActions = AppAdapterManager.shared.actions(for: bundleID, query: actionPhrase)
        if let action = adapterActions.first {
            candidates.append(adapterCandidate(
                action: action, appName: appName, bundleID: bundleID, confidence: 0.88))
        }

        // 2. Cached menu commands — index-backed read, no live AX scan.
        let menuMatches = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID, appName: appName, query: actionPhrase, maxResults: 6)
        if let match = bestMenuMatch(menuMatches, actionPhrase: actionPhrase) {
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
        }

        // 3. Seeded shortcuts for common intents when the menu cache is cold.
        if candidates.allSatisfy({ $0.route == .adapter }) {
            if let seeded = seededShortcutCandidate(
                bundleID: bundleID, appName: appName, actionPhrase: actionPhrase) {
                candidates.append(seeded)
            }
        }

        // 4. User's macOS Shortcuts whose name matches the whole request.
        if let shortcut = matchingMacShortcut(for: original) {
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

        guard !candidates.isEmpty else {
            // Executable request against a real app, but no verified route — launch the app
            // and say honestly what could not be automated. Never fake success.
            var launch = launchCandidate(appName: appName, bundleID: bundleID, confidence: 0.72)
            launch.caveat =
                "I couldn't find a verified route for “\(actionPhrase)” in \(appName) — "
                + "no adapter action, cached menu command, or shortcut matches it. "
                + "Open \(appName) once so DoraX can warm its menu cache, then try again."
            return .candidates([launch])
        }

        candidates.sort { rank($0) < rank($1) }
        return .candidates(candidates)
    }

    /// Route ranking per the DoraX Action Chat spec: adapter > MCP/API > CLI >
    /// shortcutRunner > keyboardShortcut > verifiedMenu > axFallback > launch.
    private func rank(_ c: DoraXActionCandidate) -> Int {
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

    private func bestMenuMatch(_ items: [AXMenuItem], actionPhrase: String) -> AXMenuItem? {
        guard !items.isEmpty else { return nil }
        let tokens = actionPhrase
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
            .filter { $0.count > 1 }
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
        return .clarify(
            question: "Where should I create it?",
            options: [
                "TextEdit — new unsaved document",
                "Finder — empty file on the Desktop",
                "VS Code — new untitled file",
            ])
    }

    // MARK: - Candidate builders

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
        return candidate
    }

    private func stableKey(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}
