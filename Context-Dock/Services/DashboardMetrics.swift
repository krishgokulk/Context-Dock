//
//  DashboardMetrics.swift
//  Context-Dock
//
//  What DoraX has actually learned about this user's work, read back out of the
//  stores that already hold it. Nothing here invents a number: every tile, node
//  and edge traces to a session index, a task-run file, or a route record. If a
//  store is empty the dashboard says so rather than showing a plausible shape.
//

import AppKit
import Combine
import Foundation

// MARK: - Snapshot model

struct DashboardSnapshot {
    var threads: Int = 0
    var messages: Int = 0
    var connectedApps: Int = 0
    var folders: Int = 0
    var combinedChats: Int = 0

    var taskRuns: Int = 0
    var taskCompleted: Int = 0
    var taskFailed: Int = 0
    var taskInterrupted: Int = 0
    var commandReceipts: Int = 0
    var verifiedReceipts: Int = 0

    var activity: [ActivityDay] = []
    var knowledge = KnowledgeGraph()
    var routes: [RouteRow] = []
    var providers: [AIProviderUsage] = []
    var adapters: [AdapterRow] = []
    var connectors: [ConnectorRow] = []
    var notes: Int = 0
    var memoryFacts: Int = 0
    /// Conversations and notes with nothing linking them to anything, left off the graph.
    var unlinkedNodes: Int = 0
    var generatedAt = Date()

    /// Actions the assistant could actually call right now: an action on a disabled adapter,
    /// or on an app that is not installed, is not a capability the user has.
    var reachableActions: Int {
        adapters.filter(\.isReachable).reduce(0) { $0 + $1.actionCount }
    }

    var totalActions: Int { adapters.reduce(0) { $0 + $1.actionCount } }

    /// Completed over everything that reached a terminal state. Nil while nothing has
    /// finished — a rate over zero runs is a number with no meaning behind it.
    var taskSuccessRate: Double? {
        let finished = taskCompleted + taskFailed
        guard finished > 0 else { return nil }
        return Double(taskCompleted) / Double(finished)
    }

    var isEmpty: Bool {
        threads == 0 && messages == 0 && taskRuns == 0
            && knowledge.nodes.isEmpty && connectors.isEmpty
    }
}

struct ActivityDay: Identifiable {
    let date: Date
    var userMessages: Int
    var assistantMessages: Int
    var id: Date { date }
    var total: Int { userMessages + assistantMessages }
}

/// One route the resolver has learned an opinion about, ranked by how much it has been
/// exercised. `route` is the resolver's own identifier.
struct RouteRow: Identifiable {
    let id: String
    let intent: String
    let app: String
    let route: String
    let successes: Int
    let failures: Int
    var attempts: Int { successes + failures }
}

// MARK: - Adapters & connectors

/// One app adapter, with the part of its state that decides whether its actions can run.
/// `isEnabled` is the user's switch; `isInstalled` is whether the app is still on this Mac.
/// Both have to hold, which is why neither one alone is reported as "ready".
struct AdapterRow: Identifiable {
    let id: String
    let name: String
    let bundleId: String
    let symbol: String
    let isBuiltIn: Bool
    let isEnabled: Bool
    let isInstalled: Bool
    let isRunning: Bool
    let actionCount: Int
    let approvalCount: Int
    let destructiveCount: Int
    let contextReaders: Int

    var isReachable: Bool { isEnabled && isInstalled }

    var statusLabel: String {
        if !isInstalled { return "App not installed" }
        if !isEnabled { return "Disabled" }
        return isRunning ? "Ready · running" : "Ready"
    }

    /// Actions that run without an approval prompt — the ones that can fire straight from a
    /// sentence, which is the number worth knowing.
    var directCount: Int { max(0, actionCount - approvalCount) }
}

/// A reachable channel and what is actually known about its state. Nothing here is probed
/// live: a row says what the store recorded, and says so in its own words rather than
/// implying a health check that never ran.
struct ConnectorRow: Identifiable {
    enum Kind: String, CaseIterable {
        case adapter, mcp, api, cli

        var title: String {
            switch self {
            case .adapter: return "App adapter"
            case .mcp: return "MCP server"
            case .api: return "API connection"
            case .cli: return "CLI tool"
            }
        }

        var symbol: String {
            switch self {
            case .adapter: return "app.dashed"
            case .mcp: return "server.rack"
            case .api: return "network"
            case .cli: return "terminal"
            }
        }
    }

    /// Deliberately not a boolean. "Configured" is the honest word for a server DoraX has
    /// never dialled, and calling that "connected" would be a claim the app cannot back.
    enum State: String {
        case ready, configured, disabled, unavailable

        var label: String {
            switch self {
            case .ready: return "Ready"
            case .configured: return "Configured"
            case .disabled: return "Disabled"
            case .unavailable: return "Unavailable"
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let state: State
}

// MARK: - Knowledge graph

struct KnowledgeGraph {
    var nodes: [KnowledgeNode] = []
    var edges: [KnowledgeEdge] = []

    var isEmpty: Bool { nodes.isEmpty }
}

struct KnowledgeNode: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case thread, note, app, folder, tool

        var label: String {
            switch self {
            case .thread: return "Conversations"
            case .note: return "Notes"
            case .app: return "Apps"
            case .folder: return "Folders"
            case .tool: return "Tools"
            }
        }

        var symbol: String {
            switch self {
            case .thread: return "bubble.left.and.bubble.right"
            case .note: return "note.text"
            case .app: return "app.dashed"
            case .folder: return "folder"
            case .tool: return "terminal"
            }
        }
    }

    let id: String
    let label: String
    let kind: Kind
    /// How much this node is used — messages for a conversation, links for everything else.
    var weight: Int
}

struct KnowledgeEdge: Identifiable, Hashable {
    let from: String
    let to: String
    var id: String { "\(from)→\(to)" }
}

// MARK: - Builder

@MainActor
final class DashboardMetrics: ObservableObject {
    static let shared = DashboardMetrics()

    @Published private(set) var snapshot = DashboardSnapshot()
    @Published private(set) var isLoading = false

    private var lastBuild: Date?

    private init() {}

    /// Rebuilds unless a build is already fresh — the dashboard is opened by a mode switch,
    /// which can fire repeatedly while the user flicks between pills.
    func refreshIfStale(maxAge: TimeInterval = 20) {
        if let lastBuild, Date().timeIntervalSince(lastBuild) < maxAge { return }
        refresh()
    }

    /// Reads the stores on the main actor — they live here — then does the slow part off it.
    ///
    /// The slow part is not the arithmetic. It is `urlForApplication(withBundleIdentifier:)`,
    /// once per adapter: with sixty adapters that is sixty Launch Services round trips, and
    /// on the main thread it froze the window for as long as they took. Every transcript is
    /// read for the activity chart too, which is file work that has no business blocking a
    /// scroll.
    func refresh() {
        guard !isLoading else { return }
        isLoading = true

        let sessions = GeneralChatSessionStore.index()
        let input = BuildInput(
            sessions: sessions,
            attachedApps: Dictionary(
                uniqueKeysWithValues: sessions.map {
                    ($0.scope.storageKey, GeneralChatSessionStore.loadAttachedApps(scope: $0.scope))
                }),
            transcripts: Dictionary(
                uniqueKeysWithValues: sessions.map { session in
                    (session.scope.storageKey,
                     GeneralChatSessionStore.load(scope: session.scope)
                        .map { MessageStamp(date: $0.timestamp, role: $0.role) })
                }),
            adapters: AppAdapterManager.shared.adapters,
            servers: MCPServerManager.shared.servers,
            connections: APIConnectionStore.shared.connections,
            packages: TerminalPackageManager.shared.packages,
            providers: AIProviderUsageStore.shared.usage,
            runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))

        Task.detached(priority: .userInitiated) {
            let built = Self.build(input)
            await MainActor.run {
                self.snapshot = built
                self.lastBuild = built.generatedAt
                self.isLoading = false
            }
        }
    }

    /// Everything the build needs, copied off the stores in one main-actor pass so the
    /// worker never reaches back into them.
    /// One message, reduced to the two fields the charts need. Copying this out on the main
    /// actor means the worker never touches an `AIChatMessage` or the store behind it.
    struct MessageStamp {
        let date: Date
        let role: AIChatMessage.ChatRole
    }

    private struct BuildInput: @unchecked Sendable {
        let sessions: [GeneralChatSession]
        let attachedApps: [String: [String]]
        let transcripts: [String: [MessageStamp]]
        let adapters: [AppAdapter]
        let servers: [MCPServerConfig]
        let connections: [APIConnection]
        let packages: [TerminalPackage]
        let providers: [AIProviderUsage]
        let runningBundleIDs: Set<String>
    }

    private nonisolated static func build(_ input: BuildInput) -> DashboardSnapshot {
        // The brief is derived from the same receipts this build reads, so refreshing it
        // here keeps the two from disagreeing. It writes a file, which is why it happens
        // on the worker rather than while a view is drawing.
        DailyBrief.rebuildToday()

        var next = DashboardSnapshot()
        buildSessionFacts(input, into: &next)
        buildActivity(input, into: &next)
        buildTaskRuns(into: &next)
        buildVault(into: &next)
        pruneUnlinked(&next)
        buildAdapters(input, into: &next)
        buildConnectors(input, into: &next)
        next.routes = topRoutes()
        next.providers = input.providers
        next.generatedAt = Date()
        return next
    }

    // MARK: Sessions → tiles + graph

    private nonisolated static func buildSessionFacts(_ input: BuildInput, into out: inout DashboardSnapshot) {
        let sessions = input.sessions
        var nodes: [String: KnowledgeNode] = [:]
        var edges = Set<KnowledgeEdge>()

        func bump(_ node: KnowledgeNode) {
            if var existing = nodes[node.id] {
                existing.weight += node.weight
                nodes[node.id] = existing
            } else {
                nodes[node.id] = node
            }
        }

        for session in sessions {
            out.messages += session.messageCount

            let threadID = "thread:" + session.scope.storageKey
            let scopeNodeID: String

            switch session.scope {
            case .app(let bundleId):
                let name = Self.appName(bundleId: bundleId)
                scopeNodeID = "app:" + name.lowercased()
                bump(KnowledgeNode(id: scopeNodeID, label: name, kind: .app, weight: 1))
            case .cli(let command):
                scopeNodeID = "tool:" + command.lowercased()
                bump(KnowledgeNode(id: scopeNodeID, label: command, kind: .tool, weight: 1))
            case .folder(let path):
                scopeNodeID = "folder:" + path
                let name = URL(fileURLWithPath: path).lastPathComponent
                bump(KnowledgeNode(id: scopeNodeID, label: name.isEmpty ? path : name,
                                   kind: .folder, weight: 1))
            case .thread, .general:
                scopeNodeID = ""
            }

            // Only conversations the user actually held become nodes; an empty scope is a
            // sidebar row, not knowledge.
            if session.messageCount > 0 {
                out.threads += 1
                bump(KnowledgeNode(id: threadID, label: session.title,
                                   kind: .thread, weight: max(1, session.messageCount)))
                if !scopeNodeID.isEmpty {
                    edges.insert(KnowledgeEdge(from: threadID, to: scopeNodeID))
                }
            }

            // The apps a thread was widened to — this is what makes it a combined chat, and
            // these edges are the only place cross-app reach shows up as a shape.
            let attached = input.attachedApps[session.scope.storageKey] ?? []
            if attached.count > 1 { out.combinedChats += 1 }
            for appName in attached {
                let id = "app:" + appName.lowercased()
                bump(KnowledgeNode(id: id, label: appName, kind: .app, weight: 1))
                if session.messageCount > 0 {
                    edges.insert(KnowledgeEdge(from: threadID, to: id))
                }
            }
        }

        // A node nothing links to is noise on a graph — drop orphan scopes, keep threads.
        let linked = Set(edges.flatMap { [$0.from, $0.to] })
        let kept = nodes.values.filter { $0.kind == .thread || linked.contains($0.id) }

        out.knowledge = KnowledgeGraph(
            nodes: kept.sorted { $0.weight > $1.weight },
            edges: Array(edges))
        out.connectedApps = kept.filter { $0.kind == .app }.count
        out.folders = kept.filter { $0.kind == .folder }.count
    }

    // MARK: Messages → activity

    /// Message timestamps only exist inside the transcripts, so they were copied out before
    /// this ran — the loading is the expensive half and it does not belong on the main actor.
    private nonisolated static func buildActivity(_ input: BuildInput, into out: inout DashboardSnapshot) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let window = calendar.date(byAdding: .day, value: -13, to: today) else { return }

        var buckets: [Date: (user: Int, assistant: Int)] = [:]
        for session in input.sessions where session.messageCount > 0 {
            for message in input.transcripts[session.scope.storageKey] ?? [] {
                let day = calendar.startOfDay(for: message.date)
                guard day >= window, day <= today else { continue }
                var bucket = buckets[day] ?? (0, 0)
                switch message.role {
                case .user: bucket.user += 1
                case .assistant: bucket.assistant += 1
                case .tool, .approval: continue
                }
                buckets[day] = bucket
            }
        }

        out.activity = (0..<14).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: window) else { return nil }
            let bucket = buckets[date] ?? (0, 0)
            return ActivityDay(date: date, userMessages: bucket.user, assistantMessages: bucket.assistant)
        }
    }

    // MARK: Task runs → workflow funnel

    /// Read from disk rather than from `TaskRunStore`, which keeps its runs private. The
    /// files are the same ones it writes, so the dashboard cannot drift from them.
    private nonisolated static func buildTaskRuns(into out: inout DashboardSnapshot) {
        let directory = ContextDockStore.root
            .appendingPathComponent("task-runs", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }

        let decoder = JSONDecoder.taskRun
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let run = try? decoder.decode(TaskRunStore.Run.self, from: data)
            else { continue }

            out.taskRuns += 1
            switch run.status {
            case .completed: out.taskCompleted += 1
            case .failed: out.taskFailed += 1
            case .interrupted, .running: out.taskInterrupted += 1
            }
            for receipt in run.receipts where receipt.success {
                if receipt.isVerification { out.verifiedReceipts += 1 } else { out.commandReceipts += 1 }
            }
        }
    }

    // MARK: Vault → graph

    /// Folds written memory into the graph.
    ///
    /// Until this ran, the graph drew conversations against apps — real, but it showed
    /// what the user had *said*, never what they had written down. Notes carry
    /// `[[apps/<bundle>]]` links, put there by the mirror when a note names an app the
    /// user has an adapter for, so the edges here are the links themselves rather than a
    /// similarity guess.
    private nonisolated static func buildVault(into out: inout DashboardSnapshot) {
        let store = MarkdownMemoryStore.shared
        let notes = (try? FileManager.default.contentsOfDirectory(
            at: store.notesFolderURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.filter { $0.pathExtension.lowercased() == "md" } ?? []

        var nodes = out.knowledge.nodes
        var edges = Set(out.knowledge.edges)
        let existing = Set(nodes.map(\.id))
        var appNodesByBundle: [String: String] = [:]
        for node in nodes where node.kind == .app {
            appNodesByBundle[node.label.lowercased()] = node.id
        }

        for url in notes {
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let title = markdown
                .components(separatedBy: .newlines)
                .first { $0.hasPrefix("# ") }
                .map { String($0.dropFirst(2)) }
                ?? url.deletingPathExtension().lastPathComponent
            let id = "note:" + url.lastPathComponent
            guard !existing.contains(id) else { continue }
            // Weight by length, capped. A note with real content in it is a bigger part of
            // what the user knows than a one-line reminder — but conversations are weighed
            // in messages and run to single digits, so an uncapped word count made one
            // 1,300-word note heavier than every conversation combined: the largest mark on
            // the graph, and enough to push real nodes out of the node budget entirely.
            let words = markdown.split(whereSeparator: { $0 == " " || $0.isNewline }).count
            let weight = min(max(1, words / 40), 12)
            nodes.append(KnowledgeNode(
                id: id, label: String(title.prefix(48)), kind: .note, weight: weight))
            out.notes += 1

            for bundleID in wikiLinkedBundleIDs(in: markdown) {
                let name = appName(bundleId: bundleID)
                let appID = appNodesByBundle[name.lowercased()] ?? "app:" + name.lowercased()
                if !nodes.contains(where: { $0.id == appID }) {
                    nodes.append(KnowledgeNode(id: appID, label: name, kind: .app, weight: 1))
                    appNodesByBundle[name.lowercased()] = appID
                }
                edges.insert(KnowledgeEdge(from: id, to: appID))
            }
        }

        out.memoryFacts = store.fileSummaries()
            .filter { !$0.relativePath.hasPrefix("notes/") && $0.relativePath != "MEMORY.md" }
            .reduce(0) { $0 + $1.factCount }

        out.knowledge = KnowledgeGraph(
            nodes: nodes.sorted { $0.weight > $1.weight },
            edges: Array(edges))
        out.connectedApps = nodes.filter { $0.kind == .app }.count
    }

    /// Drops nodes with no edges.
    ///
    /// A conversation that was never scoped to anything, and a note that names no app,
    /// connect to nothing — and most conversations are unscoped, so the graph came out as
    /// thirty loose dots in rows with a handful of linked nodes lost among them. A graph
    /// is its edges. What has none is counted and said out loud underneath instead, which
    /// is more honest than drawing it as though it were part of a structure.
    private nonisolated static func pruneUnlinked(_ out: inout DashboardSnapshot) {
        let linked = Set(out.knowledge.edges.flatMap { [$0.from, $0.to] })
        let kept = out.knowledge.nodes.filter { linked.contains($0.id) }
        out.unlinkedNodes = out.knowledge.nodes.count - kept.count
        out.knowledge = KnowledgeGraph(nodes: kept, edges: out.knowledge.edges)
    }

    /// `[[apps/com.example.App]]` → `com.example.App`.
    private nonisolated static func wikiLinkedBundleIDs(in markdown: String) -> [String] {
        var found: [String] = []
        var remainder = Substring(markdown)
        while let open = remainder.range(of: "[[apps/"),
              let close = remainder[open.upperBound...].range(of: "]]") {
            let bundleID = String(remainder[open.upperBound..<close.lowerBound])
            if !bundleID.isEmpty { found.append(bundleID) }
            remainder = remainder[close.upperBound...]
        }
        return found
    }

    // MARK: Adapters

    /// Every adapter the user has, user-added and built-in alike, with the two facts that
    /// decide whether it can be used: the enable switch, and whether the app is still here.
    private nonisolated static func buildAdapters(_ input: BuildInput, into out: inout DashboardSnapshot) {
        let running = input.runningBundleIDs

        out.adapters = input.adapters.map { adapter in
            let visible = adapter.visibleActions
            let installed = adapter.bundleId.isEmpty || isInstalled(bundleId: adapter.bundleId)
            return AdapterRow(
                id: adapter.id,
                name: adapter.appName,
                bundleId: adapter.bundleId,
                symbol: adapter.icon.isEmpty ? "app.dashed" : adapter.icon,
                isBuiltIn: adapter.isBuiltIn,
                isEnabled: adapter.isEnabled,
                isInstalled: installed,
                isRunning: running.contains(adapter.bundleId),
                actionCount: visible.count,
                approvalCount: visible.filter(\.requiresApproval).count,
                destructiveCount: visible.filter(\.isDestructive).count,
                contextReaders: adapter.contextReaders.count)
        }
        .sorted {
            // Reachable first, then by how much they can do — the useful reading order.
            ($0.isReachable ? 1 : 0, $0.actionCount) > ($1.isReachable ? 1 : 0, $1.actionCount)
        }
    }

    // MARK: Connectors

    /// The channels that reach an app whether or not it is frontmost, plus the adapters
    /// themselves. States are read from each store — none of this dials anything.
    private nonisolated static func buildConnectors(_ input: BuildInput, into out: inout DashboardSnapshot) {
        var rows: [ConnectorRow] = []

        for adapter in out.adapters {
            let state: ConnectorRow.State
            if !adapter.isInstalled { state = .unavailable }
            else if !adapter.isEnabled { state = .disabled }
            else { state = .ready }
            rows.append(ConnectorRow(
                id: "adapter:" + adapter.id,
                kind: .adapter,
                name: adapter.name,
                detail: "\(adapter.actionCount) actions"
                    + (adapter.contextReaders > 0 ? " · \(adapter.contextReaders) context readers" : "")
                    + (adapter.isBuiltIn ? "" : " · added by you"),
                state: state))
        }

        for server in input.servers {
            let linked = server.bundleIds.compactMap { Self.appName(bundleId: $0) }
            rows.append(ConnectorRow(
                id: "mcp:" + server.id.uuidString,
                kind: .mcp,
                name: server.name,
                detail: server.transport
                    + (linked.isEmpty ? "" : " · " + linked.joined(separator: ", ")),
                // Configured, not dialled — the manager stores servers, it does not health-check them.
                state: .configured))
        }

        for connection in input.connections {
            rows.append(ConnectorRow(
                id: "api:" + connection.id,
                kind: .api,
                name: connection.name,
                detail: connection.baseURL
                    + (connection.lastSync.map { " · synced \(Self.relative($0))" } ?? ""),
                state: connection.status == .connected ? .ready : .disabled))
        }

        for package in input.packages where package.isEnabled {
            rows.append(ConnectorRow(
                id: "cli:" + package.id.uuidString,
                kind: .cli,
                name: package.name,
                detail: package.command
                    + (package.contextAppBundleIds.isEmpty
                       ? ""
                       : " · " + package.contextAppBundleIds.map(Self.appName(bundleId:)).joined(separator: ", ")),
                state: package.installedPath == nil ? .unavailable : .ready))
        }

        out.connectors = rows
    }

    // MARK: Route confidence

    private nonisolated static func topRoutes(limit: Int = 6) -> [RouteRow] {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let url = support?.appendingPathComponent("DoraX/RouteConfidence.json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([String: RouteConfidenceRecord].self, from: data)
        else { return [] }

        return records.map { key, record in
            RouteRow(
                id: key,
                intent: record.intentKey,
                app: record.bundleID.isEmpty ? "—" : Self.appName(bundleId: record.bundleID),
                route: record.route,
                successes: record.successCount,
                failures: record.failureCount)
        }
        .filter { $0.attempts > 0 }
        .sorted { ($0.attempts, $0.successes) > ($1.attempts, $1.successes) }
        .prefix(limit)
        .map { $0 }
    }

    // MARK: Naming

    private nonisolated static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Launch Services answers are cached for the life of the process, behind a lock because
    /// the build runs off the main actor. An app does not appear or vanish often enough to
    /// be worth asking twice, and asking is the slow part.
    private static let lookupLock = NSLock()
    private nonisolated(unsafe) static var nameCache: [String: String] = [:]
    private nonisolated(unsafe) static var installedCache: [String: Bool] = [:]

    /// A bundle id is not a label. Falls back to the last path component so an app that is
    /// no longer installed still reads as a name rather than a reverse-DNS string.
    nonisolated static func appName(bundleId: String) -> String {
        lookupLock.lock()
        let cached = nameCache[bundleId]
        lookupLock.unlock()
        if let cached { return cached }

        var resolved = bundleId.components(separatedBy: ".").last ?? bundleId
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            resolved = FileManager.default.displayName(atPath: url.path)
        }
        lookupLock.lock()
        nameCache[bundleId] = resolved
        lookupLock.unlock()
        return resolved
    }

    nonisolated static func isInstalled(bundleId: String) -> Bool {
        lookupLock.lock()
        let cached = installedCache[bundleId]
        lookupLock.unlock()
        if let cached { return cached }

        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
        lookupLock.lock()
        installedCache[bundleId] = found
        lookupLock.unlock()
        return found
    }
}
