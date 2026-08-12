// LocalDataCapabilities.swift
// Context-Dock
//
// The things DoraX can already read about this Mac, registered so the model can ask for
// them.
//
// A capability is the model's map of the machine. Anything not on it does not exist as far
// as the model is concerned, however good the model is — and until now the map was built
// almost entirely out of *actions*. The readers were missing: browser history, recent
// documents, the file index, saved captures, which apps actually get used. All of it
// already collected, none of it askable.
//
// That gap is what makes an assistant look stupid rather than limited. Asked "did I visit
// any website today?", the model found no capability that reads browsing history, so it
// answered from nothing and reported finding nothing — a claim about the user's day made
// from its own missing wiring. The one path that could answer was a hardcoded phrase match
// in the chat view, and a question one word outside that list fell straight through it.
//
// With these registered, `find_capability` finds them, the tool loop calls them, and the
// phrase match demotes from the only path to a fast path.
//
// Risk is `.low` throughout: these read local data and change nothing. Sending any of it to
// a cloud provider is a separate decision, already gated by AIPrivacyApprovalCenter — the
// layer that owns "what leaves this Mac". Asking twice for one read would be friction
// without added protection.

import AppKit
import Foundation

@MainActor
enum LocalDataCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerBrowserHistory(registry)
        registerBrowserBookmarks(registry)
        registerBrowserTabs(registry)
        registerRecentDocuments(registry)
        registerFileSearch(registry)
        registerQuickNotesSearch(registry)
        registerMostUsedApps(registry)
        registerClipboardHistory(registry)
        registerExtensionsList(registry)
        registerCLITools(registry)
        registerMemory(registry)
    }

    // MARK: - Memory

    /// What DoraX has been told to remember, asked for rather than pushed.
    ///
    /// Memory reaches the model today by injection: a heuristic decides a question sounds
    /// like recall and prepends the relevant file. When it fires the answer is grounded;
    /// when it does not, the model has no idea memory exists and answers from nothing. It
    /// cannot go looking, and it cannot write — which is why people.md and tasks.md sit at
    /// zero facts while the user has been talking to it for weeks.
    ///
    /// Reading and writing are both plain Markdown under Application Support, so nothing
    /// here is a new store — only a way to reach the one that exists.
    private static func registerMemory(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "memory.search",
                title: "Search Saved Memory",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "query",
                        description: "Words to look for. Omit to list what memory holds.",
                        required: false)
                ]),
                riskLevel: .low
            ) { request in
                let query = (request.input["query"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let summaries = MarkdownMemoryStore.shared.fileSummaries()
                guard !summaries.isEmpty else {
                    return .init(success: true, output: "Memory is empty.")
                }
                guard !query.isEmpty else {
                    let lines = summaries.map {
                        "- \($0.relativePath): \($0.factCount) fact\($0.factCount == 1 ? "" : "s")"
                    }
                    return .init(
                        success: true,
                        output: "Memory files:\n" + lines.joined(separator: "\n"))
                }
                // Line-level matches, with the file they came from. A fact without its
                // source is not checkable, and memory the user cannot check is memory they
                // cannot correct.
                var hits: [String] = []
                for summary in summaries {
                    guard let markdown = try? String(contentsOf: summary.url, encoding: .utf8)
                    else { continue }
                    for line in markdown.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("- "), trimmed.lowercased().contains(query)
                        else { continue }
                        hits.append("- [\(summary.relativePath)] \(trimmed.dropFirst(2))")
                        if hits.count >= 40 { break }
                    }
                    if hits.count >= 40 { break }
                }
                guard !hits.isEmpty else {
                    return .init(
                        success: true, output: "Nothing in memory mentions “\(query)”.")
                }
                return .init(success: true, output: hits.joined(separator: "\n"))
            }
        )

        registry.register(
            AICapability(
                id: "memory.save",
                title: "Save a Fact to Memory",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "text",
                        description: "The fact to remember, in the user's own terms.",
                        required: true),
                    .init(
                        name: "bundleId",
                        description: "Save under a specific app's memory instead of the general files.",
                        required: false),
                ]),
                // Writes a durable file the user will be answered from later. Cheap to undo
                // — the files are plain Markdown they can open — but never silent.
                riskLevel: .medium
            ) { request in
                let text = (request.input["text"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AICapabilityError.missingInput("text") }
                let bundleID = request.input["bundleId"] ?? request.input["bundleID"]
                guard let confirmation = MarkdownMemoryStore.shared.remember(
                    text, appBundleID: bundleID)
                else {
                    return .init(
                        success: false,
                        output: "I couldn't work out where that belongs in memory.")
                }
                return .init(success: true, output: confirmation)
            }
        )
    }

    // MARK: - CLI tools

    /// The command-line tools the user linked, and how to run one.
    ///
    /// These resolve inside an app-scoped chat, through the route resolver, and nowhere
    /// else — so General Chat could not see them at all. An adapter listing "3 CLI" was
    /// describing tools the model had no way to find, and the shell fallback reached for
    /// whatever happened to be on PATH instead of the tool the user deliberately linked.
    ///
    /// Listing and running are separate for the same reason extensions are: an id the model
    /// cannot discover is a capability that does not exist.
    private static func registerCLITools(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "cli.list",
                title: "List Linked CLI Tools",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Words to match", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let query = (request.input["query"] ?? "").lowercased()
                let enabled = TerminalPackageManager.shared.packages.filter(\.isEnabled)
                let matched = query.isEmpty
                    ? enabled
                    : enabled.filter {
                        "\($0.command) \($0.name) \($0.description) \($0.keywords.joined(separator: " "))"
                            .lowercased().contains(query)
                    }
                guard !matched.isEmpty else {
                    return .init(
                        success: true,
                        output: enabled.isEmpty
                            ? "No CLI tools are linked. The user can add them in Settings → CLI Tool Scope."
                            : "No linked CLI tool matches “\(query)”.")
                }
                let lines = matched.prefix(25).map { package -> String in
                    var line = "- \(package.command)"
                    if !package.description.isEmpty { line += " — \(package.description)" }
                    if !package.subcommands.isEmpty {
                        line += "\n    subcommands: "
                            + package.subcommands.prefix(12).joined(separator: ", ")
                    }
                    return line
                }
                return .init(
                    success: true,
                    output: "Linked CLI tools — run one with cli.run:\n"
                        + lines.joined(separator: "\n"))
            }
        )

        registry.register(
            AICapability(
                id: "cli.run",
                title: "Run a Linked CLI Tool",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "command", description: "Tool name, e.g. \"rem\"", required: true),
                    .init(
                        name: "arguments",
                        description: "Arguments after the tool name, e.g. \"list --today\"",
                        required: false),
                ]),
                riskLevel: .high
            ) { request in
                let command = (request.input["command"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { throw AICapabilityError.missingInput("command") }

                // Only tools the user linked and left enabled. Without this the capability
                // would be a second, less inspectable run_command — the shell already has
                // one, and this exists to run what the user chose, not anything at all.
                let enabled = TerminalPackageManager.shared.packages.filter(\.isEnabled)
                guard let package = enabled.first(where: {
                    $0.command.caseInsensitiveCompare(command) == .orderedSame
                }) else {
                    let names = enabled.map(\.command).sorted()
                    return .init(
                        success: false,
                        output: names.isEmpty
                            ? "“\(command)” isn't a linked CLI tool, and none are linked."
                            : "“\(command)” isn't a linked CLI tool. Linked: "
                                + names.joined(separator: ", ") + ".")
                }
                let arguments = (request.input["arguments"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let line = arguments.isEmpty
                    ? package.command : "\(package.command) \(arguments)"
                let result = await TerminalCommandExecutor.shared.run(
                    line, purpose: "Run the linked tool \(package.command)")
                return .init(
                    success: result.success,
                    output: result.output.isEmpty
                        ? (result.success ? "\(line) finished with no output." : "\(line) failed.")
                        : result.output)
            }
        )
    }

    // MARK: - Clipboard

    /// Everything copied recently, not just what is on the pasteboard now.
    ///
    /// `clipboard.read` returns the current clip, which answers "paste this" and nothing
    /// else. "What did I copy earlier", "where did that snippet go", "what did I capture
    /// from that page" are all questions about the history — which DoraX keeps, shows in
    /// its own Clipboard scope, and had no way to be asked about.
    ///
    /// Captures land here too: Take Screenshot, Capture Area and Capture Text all write a
    /// clip, and Capture Text writes its OCR into the same record. So this is also how the
    /// model reads what a capture actually said.
    private static func registerClipboardHistory(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "clipboard.history",
                title: "Search Clipboard History",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "query",
                        description: "Words to match in the copied text or OCR. Omit for the most recent.",
                        required: false),
                    // Named separately from `query` because "captures from Code" is two
                    // conditions, and folding the app into the text search would return
                    // any clip that merely mentions the word.
                    .init(
                        name: "app",
                        description: "Only clips taken from this app, e.g. \"Code\", \"Safari\".",
                        required: false),
                    .init(
                        name: "captures_only",
                        description: "\"true\" for only screenshots / Capture Area / Capture Text.",
                        required: false),
                    .init(name: "limit", description: "Max clips (default 20)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                let entries = loadClipboardHistory()
                guard !entries.isEmpty else {
                    return .init(success: true, output: "Clipboard history is empty.")
                }
                let query = (request.input["query"] ?? "").lowercased()
                let capturesOnly = (request.input["captures_only"] ?? "").lowercased() == "true"
                let limit = Int(request.input["limit"] ?? "") ?? 20

                let app = (request.input["app"] ?? "").lowercased()
                var matched = entries
                if capturesOnly { matched = matched.filter(\.isScreenCapture) }
                if !app.isEmpty {
                    matched = matched.filter {
                        $0.sourceAppName.lowercased().contains(app)
                            || $0.sourceBundleId.lowercased().contains(app)
                    }
                }
                if !query.isEmpty {
                    matched = matched.filter {
                        $0.text.lowercased().contains(query)
                            || $0.ocrText.lowercased().contains(query)
                    }
                }
                guard !matched.isEmpty else {
                    // Say which condition emptied it. "No clips from Code" and "no clips
                    // at all" send the user to different next steps.
                    var conditions: [String] = []
                    if capturesOnly { conditions.append("captures") }
                    if !app.isEmpty { conditions.append("from \(request.input["app"] ?? app)") }
                    if !query.isEmpty { conditions.append("mentioning “\(query)”") }
                    let known = Set(entries.map(\.sourceAppName)).filter { !$0.isEmpty }
                    let hint = app.isEmpty || known.isEmpty
                        ? ""
                        : " Clips exist from: " + known.sorted().prefix(8).joined(separator: ", ")
                            + "."
                    return .init(
                        success: true,
                        output: conditions.isEmpty
                            ? "Clipboard history is empty."
                            : "No clips \(conditions.joined(separator: " ")).\(hint)")
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "EEE d MMM HH:mm"
                let lines = matched.sorted { $0.timestamp > $1.timestamp }
                    .prefix(limit)
                    .map { clip -> String in
                        // OCR is the readable content of a capture; the clip's own text is
                        // empty for one, so showing `text` alone would list blank rows.
                        let body = clip.text.isEmpty ? clip.ocrText : clip.text
                        let kind = clip.isScreenCapture ? "capture" : "copied"
                        let from = clip.sourceAppName.isEmpty ? "" : " from \(clip.sourceAppName)"
                        let flat = body.replacingOccurrences(of: "\n", with: " ")
                        return "- [\(kind)\(from) · \(formatter.string(from: clip.timestamp))] "
                            + String(flat.prefix(200))
                    }
                return .init(
                    success: true,
                    output: "\(matched.count) clip\(matched.count == 1 ? "" : "s"):\n"
                        + lines.joined(separator: "\n"))
            }
        )
    }

    /// The same file the Clipboard scope persists to. Read from disk rather than from the
    /// launcher's state so this works whether or not the dock view happens to be alive.
    private static func loadClipboardHistory() -> [LauncherView.ClipboardEntry] {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let url = base
            .appendingPathComponent("Context-Dock", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
        guard let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode(
                [LauncherView.ClipboardEntry].self, from: data)
        else { return [] }
        return entries
    }

    // MARK: - Extensions

    /// What `extension.run` can actually be called with.
    ///
    /// extension.run takes a UUID and there was no way to obtain one: the model cannot
    /// invent a UUID, and nothing listed them. A capability reachable only by guessing a
    ///128-bit number is a capability that does not exist.
    private static func registerExtensionsList(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "extensions.list",
                title: "List Installed Extensions",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Words to match", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let query = (request.input["query"] ?? "").lowercased()
                let manifests = ExtensionRegistry.shared.manifests
                let matched = query.isEmpty
                    ? manifests
                    : manifests.filter {
                        $0.name.lowercased().contains(query)
                            || $0.summary.lowercased().contains(query)
                    }
                guard !matched.isEmpty else {
                    return .init(
                        success: true,
                        output: query.isEmpty
                            ? "No extensions installed."
                            : "No extension matches “\(query)”.")
                }
                let lines = matched.prefix(40).map { manifest in
                    "- \(manifest.id.uuidString): \(manifest.name)"
                        + (manifest.summary.isEmpty ? "" : " — \(manifest.summary)")
                }
                return .init(
                    success: true,
                    output: "Run one with extension.run using its id:\n"
                        + lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Browser

    private static func registerBrowserHistory(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "browser.history",
                title: "Read Browser History",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "query",
                        description: "Words to match in the page title or URL. Omit for everything recent.",
                        required: false),
                    .init(
                        name: "days",
                        description: "Only visits within this many days back, e.g. \"1\" for today.",
                        required: false),
                    .init(name: "limit", description: "Max rows (default 40)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                let query = request.input["query"] ?? ""
                let limit = Int(request.input["limit"] ?? "") ?? 40
                let entries = await BrowserURLLibraryService.shared.refreshedEntries(
                    matching: query.isEmpty ? "history" : query,
                    limit: max(limit, 200))

                var history = entries.filter { $0.kind == .history }
                if let days = Double(request.input["days"] ?? ""), days > 0 {
                    let cutoff = Date().addingTimeInterval(-days * 86_400)
                    history = history.filter { ($0.visitDate ?? .distantPast) >= cutoff }
                }
                guard !history.isEmpty else {
                    // Unreadable and empty look identical from here, and only one of them
                    // is a fact about the user. Say which this is.
                    let safariDB = NSHomeDirectory() + "/Library/Safari/History.db"
                    if FileManager.default.fileExists(atPath: safariDB),
                        !FileManager.default.isReadableFile(atPath: safariDB)
                    {
                        return .init(
                            success: false,
                            output: "I can't read Safari's history database. macOS requires "
                                + "Full Disk Access for that: System Settings → Privacy & "
                                + "Security → Full Disk Access → add Context-Dock. This is "
                                + "not the same as there being no history.")
                    }
                    return .init(success: true, output: "No matching history entries.")
                }
                return .init(success: true, output: describe(Array(history.prefix(limit))))
            }
        )
    }

    private static func registerBrowserBookmarks(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "browser.bookmarks",
                title: "Read Browser Bookmarks",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Words to match", required: false),
                    .init(name: "limit", description: "Max rows (default 40)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                let query = request.input["query"] ?? ""
                let limit = Int(request.input["limit"] ?? "") ?? 40
                let entries = await BrowserURLLibraryService.shared.refreshedEntries(
                    matching: query.isEmpty ? "bookmarks" : query, limit: max(limit, 200))
                let bookmarks = entries.filter { $0.kind == .bookmark }
                guard !bookmarks.isEmpty else {
                    return .init(success: true, output: "No matching bookmarks.")
                }
                return .init(success: true, output: describe(Array(bookmarks.prefix(limit))))
            }
        )
    }

    private static func registerBrowserTabs(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "browser.tabs",
                title: "List Open Browser Tabs",
                appBundleID: nil,
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                // Live app state, not library data — a tab open right now may never have
                // been written to history, and history holds pages closed hours ago.
                let tabs = ContextDetector.shared.getAllSafariTabs()
                guard !tabs.isEmpty else {
                    return .init(
                        success: true,
                        output: "No open Safari tabs (or Safari isn't running).")
                }
                let lines = tabs.prefix(60).map { tab in
                    "- \(tab.title.isEmpty ? tab.url : tab.title) — \(tab.url)"
                }
                return .init(
                    success: true,
                    output: "\(tabs.count) open tab\(tabs.count == 1 ? "" : "s"):\n"
                        + lines.joined(separator: "\n"))
            }
        )
    }

    /// One row per entry, with the date, because "today" questions are answered by the date
    /// and a list without one cannot support the answer it is being used for.
    private static func describe(_ entries: [BrowserURLLibraryEntry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM HH:mm"
        let lines = entries.map { entry -> String in
            let when = entry.visitDate.map { " · \(formatter.string(from: $0))" } ?? ""
            let title = entry.title.isEmpty ? entry.domain : entry.title
            return "- \(title) — \(entry.url.absoluteString)\(when) · \(entry.browserName)"
        }
        return "\(entries.count) result\(entries.count == 1 ? "" : "s"):\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - Files

    private static func registerRecentDocuments(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "files.recentDocuments",
                title: "List Recent Documents",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "limit", description: "Max rows (default 20)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let limit = Int(request.input["limit"] ?? "") ?? 20
                let docs = RecentItemsService.shared.recentDocuments().prefix(limit)
                guard !docs.isEmpty else {
                    return .init(success: true, output: "No recent documents.")
                }
                return .init(
                    success: true,
                    output: docs.map { "- \($0.name) — \($0.url.path)" }
                        .joined(separator: "\n"))
            }
        )
    }

    private static func registerFileSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "files.search",
                title: "Search Indexed Files",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Filename words to match", required: true),
                    .init(name: "limit", description: "Max rows (default 25)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                guard let query = request.input["query"], !query.isEmpty else {
                    throw AICapabilityError.missingInput("query")
                }
                let limit = Int(request.input["limit"] ?? "") ?? 25
                let results = FileIndexManager.shared.search(query: query, limit: limit)
                guard !results.isEmpty else {
                    return .init(success: true, output: "No indexed files match “\(query)”.")
                }
                return .init(
                    success: true,
                    output: results.map { "- \($0.title) — \($0.subtitle)" }
                        .joined(separator: "\n"))
            }
        )
    }

    // MARK: - DoraX's own capture

    private static func registerQuickNotesSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "quicknotes.search",
                title: "Search Quick Notes",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "query",
                        description: "Words to match. Omit for the most recent notes.",
                        required: false),
                    .init(name: "limit", description: "Max notes (default 15)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                let query = (request.input["query"] ?? "").lowercased()
                let limit = Int(request.input["limit"] ?? "") ?? 15
                let all = QuickNotesStore.shared.notes
                let matched = query.isEmpty
                    ? all : all.filter { $0.text.lowercased().contains(query) }
                guard !matched.isEmpty else {
                    return .init(
                        success: true,
                        output: query.isEmpty
                            ? "No Quick Notes yet."
                            : "No Quick Note mentions “\(query)”.")
                }
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                let lines = matched.prefix(limit).map { note -> String in
                    let firstLine = note.text.split(separator: "\n").first.map(String.init)
                        ?? "(empty)"
                    return "- \(firstLine.prefix(160)) · \(formatter.string(from: note.createdAt))"
                }
                return .init(
                    success: true,
                    output: "\(matched.count) note\(matched.count == 1 ? "" : "s"):\n"
                        + lines.joined(separator: "\n"))
            }
        )
    }

    private static func registerMostUsedApps(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "apps.mostUsed",
                title: "List Most-Used Apps",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "limit", description: "Max apps (default 15)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let limit = Int(request.input["limit"] ?? "") ?? 15
                let ranked = AppUsageLearner.shared.rankedAppBundleIDs(limit: limit)
                guard !ranked.isEmpty else {
                    return .init(success: true, output: "No app usage recorded yet.")
                }
                let installed = InstalledApplicationsCatalog.cachedInstalledApps()
                let lines = ranked.map { bundleID -> String in
                    let name = installed.first { $0.bundleId == bundleID }?.name ?? bundleID
                    return "- \(name) (\(bundleID))"
                }
                return .init(
                    success: true,
                    output: "Most used, in order:\n" + lines.joined(separator: "\n"))
            }
        )
    }
}
