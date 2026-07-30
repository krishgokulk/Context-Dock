import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum DoraXSpotlightScopeType: String, Codable, CaseIterable {
    case globalAction
    case cliTool
    case appAdapterAction
    case aiProfile
}

struct DoraXSpotlightRecord: Hashable, Identifiable {
    let id: String
    let title: String
    let description: String
    let keywords: [String]
    let actionId: String
    let scopeType: DoraXSpotlightScopeType
    let appBundleId: String?
    let profileId: String?
    let command: String?

    var uniqueIdentifier: String {
        [
            "dorax",
            scopeType.rawValue,
            stableIdentifierComponent(actionId),
            stableIdentifierComponent(appBundleId ?? "global"),
            stableIdentifierComponent(profileId ?? "default"),
        ].joined(separator: ":")
    }

    var domainIdentifier: String {
        "\(DoraXSpotlightIndexService.domainPrefix).\(scopeType.rawValue)"
    }
}

struct DoraXSpotlightSearchResult: Hashable, Identifiable {
    let id: String
    let title: String
    let description: String
    let keywords: [String]
    let actionId: String
    let scopeType: DoraXSpotlightScopeType
    let appBundleId: String?
    let profileId: String?
    let command: String?
}

@MainActor
final class DoraXSpotlightIndexService {
    static let shared = DoraXSpotlightIndexService()
    static let domainPrefix = "com.krishgokul.ContextDock.dorax"

    private let index = CSSearchableIndex(name: "DoraXActions")
    private var rebuildTask: Task<Void, Never>?
    private var lastFingerprint = ""
    private var cachedRecords: [DoraXSpotlightRecord] = []

    private init() {}

    func scheduleRebuild(reason: String, delayNanoseconds: UInt64 = 400_000_000) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await rebuild(reason: reason)
            rebuildTask = nil
        }
    }

    func rebuild(reason: String) async {
        let started = Date()
        let records = makeRecords()
        let fingerprint = records
            .map { "\($0.uniqueIdentifier)|\($0.title)|\($0.description)|\($0.keywords.joined(separator: ","))" }
            .joined(separator: "\u{1F}")

        guard fingerprint != lastFingerprint else { return }
        let items = records.map(makeSearchableItem)
        let domains = Set(DoraXSpotlightScopeType.allCases.map { "\(Self.domainPrefix).\($0.rawValue)" })

        do {
            try await deleteDomains(Array(domains))
            try await indexItems(items)
            cachedRecords = records
            lastFingerprint = fingerprint
            SearchPerformanceLog.shared.record(
                label: "DoraXSpotlightIndexService.rebuild.\(reason)",
                elapsedMS: Date().timeIntervalSince(started) * 1_000,
                query: "records=\(records.count)",
                pills: records.count
            )
        } catch {
            #if DEBUG
            print("⚠️ [DoraXSpotlight] Rebuild failed: \(error.localizedDescription)")
            #endif
        }
    }

    func search(_ text: String, limit: Int = 12) async -> [DoraXSpotlightSearchResult] {
        let queryText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryText.isEmpty else { return [] }

        let query = spotlightQuery(for: queryText)
        let attributes = [
            "title",
            "contentDescription",
            "keywords",
            "identifier",
            "domainIdentifier",
        ]

        return await withCheckedContinuation { continuation in
            let queryContext = CSSearchQueryContext()
            queryContext.fetchAttributes = attributes
            let searchQuery = CSSearchQuery(queryString: query, queryContext: queryContext)
            var results: [DoraXSpotlightSearchResult] = []
            let lock = NSLock()

            searchQuery.foundItemsHandler = { [weak self] items in
                guard let self else { return }
                let mapped = items.compactMap { item -> DoraXSpotlightSearchResult? in
                    self.result(for: item)
                }
                lock.lock()
                for result in mapped where results.count < limit && !results.contains(result) {
                    results.append(result)
                }
                lock.unlock()
            }
            searchQuery.completionHandler = { _ in
                lock.lock()
                let output = Array(results.prefix(limit))
                lock.unlock()
                continuation.resume(returning: output)
            }
            searchQuery.start()
        }
    }

    private func makeRecords() -> [DoraXSpotlightRecord] {
        var records: [DoraXSpotlightRecord] = []
        records.reserveCapacity(256)

        records.append(contentsOf: systemCommandRecords())
        records.append(contentsOf: cliToolRecords())
        records.append(contentsOf: appAdapterActionRecords())
        records.append(contentsOf: aiProfileRecords())

        var seen: Set<String> = []
        return records.filter { seen.insert($0.uniqueIdentifier).inserted }
    }

    private func systemCommandRecords() -> [DoraXSpotlightRecord] {
        SystemCommandsRegistry.shared.commands
            .filter(\.isEnabled)
            .map { command in
                DoraXSpotlightRecord(
                    id: command.id.uuidString,
                    title: command.name,
                    description: clean(command.description),
                    keywords: uniqueTerms(command.keywords + [command.name, command.actionTypeLabel, "global action"]),
                    actionId: "syscmd://\(command.id.uuidString)",
                    scopeType: .globalAction,
                    appBundleId: nil,
                    profileId: nil,
                    command: command.scriptType
                )
            }
    }

    private func cliToolRecords() -> [DoraXSpotlightRecord] {
        TerminalPackageManager.shared.packages
            .filter(\.isEnabled)
            // Only tools the user deliberately added. `packages` holds every executable found
            // on PATH, and publishing those put hundreds of system binaries into macOS
            // Spotlight as DoraX items.
            .filter(TerminalPackageManager.shared.isUserAddedGlobalScope)
            .map { package in
                let title = package.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? package.command
                    : package.name
                let keywords = uniqueTerms(
                    package.keywords
                        + package.subcommands
                        + package.taskCategories
                        + package.usageExamples
                        + [package.command, "cli", "terminal", "tool"]
                )
                return DoraXSpotlightRecord(
                    id: package.id.uuidString,
                    title: title,
                    description: clean(package.description),
                    keywords: keywords,
                    actionId: "cli://\(package.command)",
                    scopeType: .cliTool,
                    appBundleId: package.contextAppBundleIds.first,
                    profileId: nil,
                    command: package.command
                )
            }
    }

    private func appAdapterActionRecords() -> [DoraXSpotlightRecord] {
        AppAdapterManager.shared.adapters
            .filter(\.isEnabled)
            .flatMap { adapter in
                adapter.visibleActions.map { action in
                    DoraXSpotlightRecord(
                        id: action.id,
                        title: action.name,
                        description: clean(action.description),
                        keywords: uniqueTerms(
                            action.triggers
                                + [action.name, action.type.displayName, adapter.appName, adapter.bundleId]
                                + (action.menuPath ?? [])
                                + [action.cliToolCommand, action.shortcutName, action.urlScheme].compactMap { $0 }
                        ),
                        actionId: "adapter://\(adapter.bundleId)/\(action.id)",
                        scopeType: action.type == .cliTool ? .cliTool : .appAdapterAction,
                        appBundleId: adapter.bundleId,
                        profileId: nil,
                        command: action.cliToolCommand ?? action.shortcutName
                    )
                }
            }
    }

    private func aiProfileRecords() -> [DoraXSpotlightRecord] {
        AIProfileStore.shared.profiles
            .filter(\.enabled)
            .map { profile in
                DoraXSpotlightRecord(
                    id: profile.id.uuidString,
                    title: profile.name,
                    description: clean(profile.systemInstruction),
                    keywords: uniqueTerms(
                        profile.triggerKeywords
                            + profile.appBundleIds
                            + [
                                profile.name,
                                profile.routingStrategy.rawValue,
                                profile.enableCLITools ? "cli tools" : "",
                                profile.enableAppAdapterActions ? "app adapter actions" : "",
                            ]
                    ),
                    actionId: "aiprofile://\(profile.id.uuidString)",
                    scopeType: .aiProfile,
                    appBundleId: profile.appBundleIds.first,
                    profileId: profile.id.uuidString,
                    command: nil
                )
            }
    }

    private func makeSearchableItem(_ record: DoraXSpotlightRecord) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .data)
        attributes.title = record.title
        attributes.contentDescription = recordDescription(record)
        attributes.keywords = record.keywords
        attributes.displayName = record.title
        attributes.identifier = record.actionId
        attributes.contentType = "com.krishgokul.ContextDock.dorax.\(record.scopeType.rawValue)"
        attributes.creator = "DoraX"
        attributes.kind = record.scopeType.rawValue

        let item = CSSearchableItem(
            uniqueIdentifier: record.uniqueIdentifier,
            domainIdentifier: record.domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    private func result(for item: CSSearchableItem) -> DoraXSpotlightSearchResult? {
        if let record = cachedRecords.first(where: { $0.uniqueIdentifier == item.uniqueIdentifier }) {
            return DoraXSpotlightSearchResult(record)
        }
        let parts = item.uniqueIdentifier.split(separator: ":").map(String.init)
        guard parts.count >= 3, parts[0] == "dorax",
            let scope = DoraXSpotlightScopeType(rawValue: parts[1])
        else { return nil }

        let title = item.attributeSet.title ?? item.attributeSet.displayName ?? parts[2]
        return DoraXSpotlightSearchResult(
            id: item.uniqueIdentifier,
            title: title,
            description: item.attributeSet.contentDescription ?? "",
            keywords: item.attributeSet.keywords ?? [],
            actionId: item.attributeSet.identifier ?? item.uniqueIdentifier,
            scopeType: scope,
            appBundleId: nil,
            profileId: nil,
            command: nil
        )
    }

    private func recordDescription(_ record: DoraXSpotlightRecord) -> String {
        [
            record.description,
            "Action ID: \(record.actionId)",
            "Scope: \(record.scopeType.rawValue)",
            record.appBundleId.map { "App: \($0)" },
            record.profileId.map { "Profile: \($0)" },
            record.command.map { "Command: \($0)" },
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private func spotlightQuery(for text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let domains = DoraXSpotlightScopeType.allCases
            .map { "domainIdentifier == \"\(Self.domainPrefix).\($0.rawValue)\"" }
            .joined(separator: " || ")
        return "(\(domains)) && (title == \"*\(escaped)*\"cd || contentDescription == \"*\(escaped)*\"cd || keywords == \"*\(escaped)*\"cd)"
    }

    private func indexItems(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func deleteDomains(_ domains: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domains) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueTerms(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        return terms
            .flatMap { term in
                term
                    .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

private extension DoraXSpotlightSearchResult {
    init(_ record: DoraXSpotlightRecord) {
        self.init(
            id: record.uniqueIdentifier,
            title: record.title,
            description: record.description,
            keywords: record.keywords,
            actionId: record.actionId,
            scopeType: record.scopeType,
            appBundleId: record.appBundleId,
            profileId: record.profileId,
            command: record.command
        )
    }
}

private func stableIdentifierComponent(_ value: String) -> String {
    value
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: "-")
}
