import AppKit
import Foundation

struct AppContentSearchIntent: Identifiable {
    let bundleId: String
    let appName: String
    let query: String

    var id: String { "\(bundleId):\(query.lowercased())" }
}

@MainActor
final class AppContentSearchRouter {
    static let shared = AppContentSearchRouter()

    private struct SearchTarget {
        let bundleId: String
        let name: String
        let aliases: Set<String>
        let suggestionRank: Int
    }

    private let builtInTargets: [SearchTarget] = [
        SearchTarget(
            bundleId: "com.apple.mail", name: "Mail",
            aliases: ["mail", "email", "emails"], suggestionRank: 100),
        SearchTarget(
            bundleId: "com.apple.Safari", name: "Safari",
            aliases: ["safari", "browser", "web", "google"], suggestionRank: 95),
        SearchTarget(
            bundleId: "com.apple.AddressBook", name: "Contacts",
            aliases: ["contacts", "contact", "people"], suggestionRank: 90),
        SearchTarget(
            bundleId: "com.apple.Photos", name: "Photos",
            aliases: ["photos", "photo", "pictures", "images"], suggestionRank: 85),
        SearchTarget(
            bundleId: "com.apple.Notes", name: "Notes",
            aliases: ["notes"], suggestionRank: 80),
        SearchTarget(
            bundleId: "com.apple.MobileSMS", name: "Messages",
            aliases: ["messages", "message", "imessage", "texts"], suggestionRank: 75),
        SearchTarget(
            bundleId: "com.apple.finder", name: "Finder",
            aliases: ["finder", "files", "file"], suggestionRank: 70),
        SearchTarget(
            bundleId: "com.microsoft.VSCode", name: "Visual Studio Code",
            aliases: ["visual studio code", "vs code", "vscode", "code"], suggestionRank: 65),
        SearchTarget(
            bundleId: "com.openai.chat", name: "ChatGPT",
            aliases: ["chatgpt", "chat gpt"], suggestionRank: 60),
        SearchTarget(
            bundleId: "com.google.Chrome", name: "Google Chrome",
            aliases: ["google chrome", "chrome"], suggestionRank: 55),
        SearchTarget(
            bundleId: "org.mozilla.firefox", name: "Firefox",
            aliases: ["firefox"], suggestionRank: 50),
    ]

    private init() {
        InstalledApplicationsCatalog.warmUp()
    }

    func intents(for rawQuery: String, suggestionLimit: Int = 6) -> [AppContentSearchIntent] {
        let normalized = normalize(rawQuery)
        guard !normalized.isEmpty else { return [] }

        let targets = searchableTargets()
        if let explicit = explicitIntent(in: normalized, targets: targets) {
            return [explicit]
        }

        guard let content = contentAfterSearchVerb(in: normalized), !content.isEmpty else {
            return []
        }
        return targets
            .filter(isInstalled)
            .sorted { $0.suggestionRank > $1.suggestionRank }
            .prefix(suggestionLimit)
            .map { intent(target: $0, query: content) }
    }

    func scopedIntent(
        for rawQuery: String,
        bundleId: String,
        appName: String
    ) -> AppContentSearchIntent? {
        let normalized = normalize(rawQuery)
        guard !normalized.isEmpty else { return nil }

        guard bundleId != "com.apple.finder",
            let content = contentAfterSearchVerb(in: normalized),
            !content.isEmpty
        else { return nil }
        return AppContentSearchIntent(bundleId: bundleId, appName: appName, query: content)
    }

    func execute(_ intent: AppContentSearchIntent) async -> String {
        if intent.bundleId == "com.apple.MobileSMS" {
            return await MessagesAutomation.openSearch(query: intent.query)
        }
        if intent.bundleId == "com.apple.mail" {
            return await MailAutomation.openMailboxSearch(query: intent.query)
        }

        guard let app = await activateOrLaunch(bundleId: intent.bundleId) else {
            return "❌ Couldn't open \(intent.appName)."
        }
        return await AXSearchFieldInjector.shared.inject(query: intent.query, into: app)
    }

    private func explicitIntent(
        in query: String,
        targets: [SearchTarget]
    ) -> AppContentSearchIntent? {
        let verbs = ["search for ", "look for ", "look up ", "search ", "find "]
        let stripped = verbs.first(where: query.hasPrefix).map {
            String(query.dropFirst($0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? query

        for target in targets {
            for alias in target.aliases.sorted(by: { $0.count > $1.count }) {
                let inSuffix = " in \(alias)"
                if stripped.hasSuffix(inSuffix) {
                    let content = String(stripped.dropLast(inSuffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty { return intent(target: target, query: content) }
                }

                let prefix = "\(alias) "
                if stripped.hasPrefix(prefix) {
                    var rawContent = String(stripped.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if rawContent.hasPrefix("for ") {
                        rawContent = String(rawContent.dropFirst(4))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let content = normalizeSearchPayload(rawContent)
                    if !content.isEmpty { return intent(target: target, query: content) }
                }

                let suffix = " \(alias)"
                if stripped.hasSuffix(suffix) {
                    let content = normalizeSearchPayload(
                        String(stripped.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    if !content.isEmpty { return intent(target: target, query: content) }
                }
            }
        }
        return nil
    }

    private func normalizeSearchPayload(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return contentAfterSearchVerb(in: value) ?? value
    }

    private func contentAfterSearchVerb(in query: String) -> String? {
        for verb in ["search for ", "look for ", "look up ", "search ", "find "] {
            if query.hasPrefix(verb) {
                return String(query.dropFirst(verb.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func searchableTargets() -> [SearchTarget] {
        var seen = Set<String>()
        var targets: [SearchTarget] = []

        for target in builtInTargets where seen.insert(target.bundleId).inserted {
            targets.append(target)
        }

        for app in InstalledApplicationsCatalog.cachedInstalledApps()
        where seen.insert(app.bundleId).inserted {
            let normalizedName = normalize(app.name)
            targets.append(
                SearchTarget(
                    bundleId: app.bundleId,
                    name: app.name,
                    aliases: [normalizedName],
                    suggestionRank: 10
                ))
        }

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            guard let bundleId = app.bundleIdentifier,
                seen.insert(bundleId).inserted
            else { continue }
            let name = app.localizedName ?? bundleId
            targets.append(
                SearchTarget(
                    bundleId: bundleId,
                    name: name,
                    aliases: [normalize(name)],
                    suggestionRank: 20
                ))
        }
        return targets
    }

    private func isInstalled(_ target: SearchTarget) -> Bool {
        target.bundleId == "com.apple.finder"
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId) != nil
    }

    private func intent(target: SearchTarget, query: String) -> AppContentSearchIntent {
        AppContentSearchIntent(bundleId: target.bundleId, appName: target.name, query: query)
    }

    private func activateOrLaunch(bundleId: String) async -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first(where: { !$0.isTerminated })
        {
            _ = running.activate(options: [.activateIgnoringOtherApps])
            return running
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let launched = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        if launched != nil {
            try? await Task.sleep(nanoseconds: 650_000_000)
        }
        return launched
    }

    private func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
