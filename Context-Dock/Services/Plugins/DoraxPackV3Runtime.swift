// Context-Dock/Services/Plugins/DoraxPackV3Runtime.swift
// Context-Dock
//
// Unified .doraxpack v3 Registry, Stale-While-Revalidate Runtime, Per-Command Config,
// Per-Pack Log Ring Buffer, Frontmost App + Web-App Scope Ranking, and AI `@pack` Mention Resolver.

import AppKit
import Combine
import Foundation

// MARK: - Per-Command & Per-Pack Configuration (`⌘K → Configure Command / Pack`)

struct DoraxCommandConfig: Codable, Equatable {
    var isEnabled: Bool = true
    var alias: String = ""
    var hotkey: String = ""
    var tintHex: String = ""
}

struct DoraxPackUserConfig: Codable, Equatable {
    var hooksEnabled: Bool = true
    var grantedPermissions: Set<String> = []
    var commands: [String: DoraxCommandConfig] = [:]
}

// MARK: - Per-Pack Log Entry (`⌘K → View Pack Logs`)

struct DoraxPackLogEntry: Identifiable, Equatable {
    enum Level: String { case info, warning, error }
    let id = UUID()
    let timestamp: Date
    let packID: String
    let commandID: String
    let level: Level
    let durationMs: Int
    let message: String
    let detail: String
}

// MARK: - Scoped Command Binding

struct DoraxBoundCommand: Identifiable, Equatable {
    let pack: DoraxPackV2
    let command: DoraxPackCommand
    let sectionTitle: String
    let isContextual: Bool

    var id: String { "\(pack.id)::\(command.id)" }

    var effectiveAppearance: DoraxPackAppearance? {
        command.appearance ?? pack.metadata.appearance
    }
}

// MARK: - `@pack` AI Mention Resolution

struct DoraxPackMentionMatch: Equatable {
    let pack: DoraxPackV2
    let targetName: String? // Optional tool or command id after `.`
    let matchedToken: String
    let tool: DoraxPackTool?
    let command: DoraxPackCommand?
}

// MARK: - Registry

@MainActor
final class DoraxPackV3Registry: ObservableObject {
    static let shared = DoraxPackV3Registry()

    @Published private(set) var packs: [DoraxPackV2] = []
    @Published private(set) var configs: [String: DoraxPackUserConfig] = [:]

    static var userV3Directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock/plugins/v3", isDirectory: true)
    }

    private static var userV2Directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock/plugins/v2", isDirectory: true)
    }

    private let configFileURL: URL
    private let extraRoots: [URL]

    init(
        roots: [URL]? = nil,
        configFileURL: URL? = nil
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock/plugins", isDirectory: true)
        self.configFileURL = configFileURL ?? support.appendingPathComponent("pack-v3-config.json")
        self.extraRoots = roots ?? []
        loadConfigs()
        reload()
    }

    func reload() {
        var searchDirs: [URL] = []
        if !extraRoots.isEmpty {
            searchDirs = extraRoots
        } else {
            // Precedence (lowest -> highest):
            // 1. Legacy v2 packs (`plugins/v2/`) so stale copies never shadow built-in v3 packs
            // 2. First-party shipped packs (`Packs/*.doraxpack`)
            // 3. Explicit v3 user overrides & imported/Studio packs (`plugins/v3/`)
            searchDirs.append(Self.userV2Directory)
            if let firstParty = FirstPartyPacks.resolvePacksDirectory() {
                searchDirs.append(firstParty)
            }
            searchDirs.append(Self.userV3Directory)
        }

        var byID: [String: DoraxPackV2] = [:]
        var order: [String] = []
        for dir in searchDirs {
            for packURL in DoraxPackV2Loader.discoverPacks(in: dir) {
                guard let loaded = try? DoraxPackV2Loader.load(from: packURL) else { continue }
                if byID[loaded.id] == nil { order.append(loaded.id) }
                byID[loaded.id] = loaded
            }
        }
        packs = order.compactMap { byID[$0] }
    }

    /// Registers an in-memory pack (useful for tests and hot-reload previews).
    func register(_ pack: DoraxPackV2) {
        if let idx = packs.firstIndex(where: { $0.id == pack.id }) {
            packs[idx] = pack
        } else {
            packs.append(pack)
        }
    }

    /// Installs a `.doraxpack` folder into `plugins/v3/<id>.doraxpack`, binds v2 capabilities,
    /// and hot-reloads the registry.
    @discardableResult
    func installPackFolder(
        from sourceFolder: URL,
        into destinationRoot: URL? = nil,
        grantHookPermissions: Bool = false,
        persistToDisk: Bool = !AppDelegate.isHostingTests
    ) throws -> DoraxPackV2 {
        let pack = try DoraxPackV2Loader.load(from: sourceFolder)
        let destRoot = destinationRoot ?? Self.userV3Directory
        let fm = FileManager.default
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        let destURL = destRoot.appendingPathComponent("\(pack.id).doraxpack", isDirectory: true)
        if sourceFolder.standardizedFileURL != destURL.standardizedFileURL {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceFolder, to: destURL)
        }
        let installed = try DoraxPackV2Loader.load(from: destURL)
        if grantHookPermissions, let hooks = installed.metadata.hooks {
            var cfg = packConfig(for: installed.id)
            for h in hooks {
                cfg.grantedPermissions.insert(h.on.requiredPermission)
            }
            setPackConfig(cfg, for: installed.id)
        }
        _ = try? StorePackInstaller.installV2(installed, persistToDisk: persistToDisk)
        register(installed)
        NotificationCenter.default.post(name: .globalSearchIndexRebuildRequested, object: nil)
        return installed
    }

    func pack(id: String) -> DoraxPackV2? {
        packs.first { $0.id.lowercased() == id.lowercased() }
    }

    // MARK: - Config Persistence

    func packConfig(for packID: String) -> DoraxPackUserConfig {
        configs[packID] ?? DoraxPackUserConfig()
    }

    func setPackConfig(_ config: DoraxPackUserConfig, for packID: String) {
        configs[packID] = config
        saveConfigs()
    }

    func commandConfig(packID: String, commandID: String) -> DoraxCommandConfig {
        configs[packID]?.commands[commandID] ?? DoraxCommandConfig()
    }

    func updateCommandConfig(packID: String, commandID: String, mutate: (inout DoraxCommandConfig) -> Void) {
        var packCfg = packConfig(for: packID)
        var cmdCfg = packCfg.commands[commandID] ?? DoraxCommandConfig()
        mutate(&cmdCfg)
        packCfg.commands[commandID] = cmdCfg
        configs[packID] = packCfg
        saveConfigs()
    }

    private func loadConfigs() {
        guard let data = try? Data(contentsOf: configFileURL),
              let decoded = try? JSONDecoder().decode([String: DoraxPackUserConfig].self, from: data)
        else { return }
        configs = decoded
    }

    private func saveConfigs() {
        guard !AppDelegate.isHostingTests || configFileURL.path.contains(FileManager.default.temporaryDirectory.path) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: configFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(configs) {
            try? data.write(to: configFileURL, options: .atomic)
        }
    }

    // MARK: - Step 5: Frontmost App + Web-App (`domains`) Scope Ranking

    /// Returns commands from packs matching the frontmost macOS app OR active browser URL domain,
    /// ranked FIRST under `"Contextual — <PackName>"`.
    func contextualCommands(
        frontmostBundleID: String?,
        frontmostURL: String?,
        query: String
    ) -> [DoraxBoundCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [DoraxBoundCommand] = []

        for pack in packs {
            let scope = pack.metadata.effectiveScope
            let matchesApp = frontmostBundleID.map { scope.matchesBundleID($0) } ?? false
            let matchesDomain = frontmostURL.map { scope.matchesDomain($0) } ?? false
            guard matchesApp || matchesDomain else { continue }

            let sectionTitle = "Contextual — \(pack.name)"
            for cmd in pack.metadata.commands ?? [] {
                let cfg = commandConfig(packID: pack.id, commandID: cmd.id)
                guard cfg.isEnabled else { continue }
                if !q.isEmpty && !matchesQuery(q, command: cmd, pack: pack, alias: cfg.alias) {
                    continue
                }
                out.append(DoraxBoundCommand(
                    pack: pack, command: cmd, sectionTitle: sectionTitle, isContextual: true))
            }
        }
        return out
    }

    /// Returns commands searchable globally by name, keyword, pack name, or user alias
    /// whenever the pack's `scope.surfaces` includes `"global"`.
    func globalSearchCommands(
        query: String,
        excludingContextualIDs: Set<String> = []
    ) -> [DoraxBoundCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var scored: [(DoraxBoundCommand, Int)] = []

        for pack in packs {
            guard pack.metadata.effectiveScope.includesGlobal else { continue }
            for cmd in pack.metadata.commands ?? [] {
                let boundID = "\(pack.id)::\(cmd.id)"
                if excludingContextualIDs.contains(boundID) { continue }
                let cfg = commandConfig(packID: pack.id, commandID: cmd.id)
                guard cfg.isEnabled else { continue }
                if q.isEmpty {
                    let bound = DoraxBoundCommand(
                        pack: pack, command: cmd, sectionTitle: "Extensions", isContextual: false)
                    scored.append((bound, 10))
                } else {
                    let s = matchScore(q, command: cmd, pack: pack, alias: cfg.alias)
                    if s > 0 {
                        let bound = DoraxBoundCommand(
                            pack: pack, command: cmd, sectionTitle: "Extensions", isContextual: false)
                        scored.append((bound, s))
                    }
                }
            }
        }

        return scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.command.title.localizedCaseInsensitiveCompare(b.0.command.title) == .orderedAscending
            }
            .map(\.0)
    }

    private func matchesQuery(_ q: String, command: DoraxPackCommand, pack: DoraxPackV2, alias: String) -> Bool {
        matchScore(q, command: command, pack: pack, alias: alias) > 0
    }

    private func matchScore(_ q: String, command: DoraxPackCommand, pack: DoraxPackV2, alias: String) -> Int {
        let aliasLower = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !aliasLower.isEmpty {
            if aliasLower == q { return 1000 }
            if aliasLower.hasPrefix(q) { return 850 }
        }
        let title = command.title.lowercased()
        let packName = pack.name.lowercased()
        let packID = pack.id.lowercased()
        if title == q { return 900 }
        if title.hasPrefix(q) { return 750 }
        if title.contains(q) { return 600 }
        if packName == q || packID == q { return 550 }
        if packName.contains(q) || packID.contains(q) { return 450 }
        if command.keywords.contains(where: { $0.lowercased() == q }) { return 500 }
        if command.keywords.contains(where: { $0.lowercased().contains(q) }) { return 350 }
        if pack.metadata.keywords.contains(where: { $0.lowercased().contains(q) }) { return 250 }
        let words = q.split(separator: " ").map(String.init)
        if words.count > 1 {
            let haystack = "\(packName) \(title) \(command.subtitle.lowercased()) \(command.keywords.joined(separator: " ").lowercased())"
            if words.allSatisfy({ haystack.contains($0) }) { return 400 }
        }
        return 0
    }

    // MARK: - AI Chat `@pack` Mentions

    /// Parses `@<pack-id>` or `@<pack-id>.<toolOrCommand>` tokens from an AI chat prompt.
    func resolveMentions(in prompt: String) -> [DoraxPackMentionMatch] {
        guard prompt.contains("@") else { return [] }
        let pattern = #"@([A-Za-z0-9_-]+)(?:\.([A-Za-z0-9_-]+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = prompt as NSString
        let matches = regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length))
        var resolved: [DoraxPackMentionMatch] = []
        var seen = Set<String>()

        for match in matches {
            let full = ns.substring(with: match.range)
            guard seen.insert(full.lowercased()).inserted else { continue }
            let packToken = ns.substring(with: match.range(at: 1))
            let subToken: String? = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2)) : nil

            guard let pack = packs.first(where: {
                $0.id.lowercased() == packToken.lowercased()
                    || $0.name.lowercased().replacingOccurrences(of: " ", with: "-") == packToken.lowercased()
            }) else { continue }

            let tool = subToken.flatMap { t in
                pack.metadata.tools?.first { $0.id.lowercased() == t.lowercased() }
            }
            let command = subToken.flatMap { c in
                pack.metadata.commands?.first { $0.id.lowercased() == c.lowercased() }
            }
            resolved.append(DoraxPackMentionMatch(
                pack: pack, targetName: subToken, matchedToken: full, tool: tool, command: command))
        }
        return resolved
    }
}

// MARK: - Stale-While-Revalidate Runtime & Execution Engine

struct DoraxCommandCacheEntry: Equatable {
    var output: DoraxCommandOutput?
    var fetchedAt: Date?
    var isRefreshing: Bool
    var lastError: String?
}

@MainActor
final class DoraxPackV3Runtime: ObservableObject {
    static let shared = DoraxPackV3Runtime()

    struct CacheKey: Hashable {
        let packID: String
        let commandID: String
        let filter: String
    }

    @Published private(set) var cache: [CacheKey: DoraxCommandCacheEntry] = [:]
    @Published private(set) var logsByPack: [String: [DoraxPackLogEntry]] = [:]

    private let runner = PluginScriptRunner()
    private let maxLogsPerPack = 100

    init() {}

    func state(packID: String, commandID: String, filter: String = "") -> DoraxCommandCacheEntry {
        cache[CacheKey(packID: packID, commandID: commandID, filter: filter)]
            ?? DoraxCommandCacheEntry(output: nil, fetchedAt: nil, isRefreshing: false, lastError: nil)
    }

    func logs(for packID: String) -> [DoraxPackLogEntry] {
        logsByPack[packID] ?? []
    }

    func clearLogs(for packID: String) {
        logsByPack[packID] = []
    }

    func invalidateCache(forPackID packID: String) {
        cache = cache.filter { $0.key.packID != packID }
    }

    func appendLog(
        packID: String,
        commandID: String,
        level: DoraxPackLogEntry.Level,
        durationMs: Int,
        message: String,
        detail: String = ""
    ) {
        let entry = DoraxPackLogEntry(
            timestamp: Date(),
            packID: packID,
            commandID: commandID,
            level: level,
            durationMs: durationMs,
            message: message,
            detail: detail)
        var arr = logsByPack[packID] ?? []
        arr.insert(entry, at: 0)
        if arr.count > maxLogsPerPack { arr = Array(arr.prefix(maxLogsPerPack)) }
        logsByPack[packID] = arr
    }

    /// Executes a `.doraxpack` v3 command with stale-while-revalidate semantics:
    /// - Immediately preserves any previous good `output` while `isRefreshing == true`.
    /// - Resolves `dorax.*` native sources, `mode: cli` argv binaries, or `commands/` scripts
    ///   with permission-gated `$DORAX_CONTEXT` JSON on `stdin`.
    @discardableResult
    func runCommand(
        _ command: DoraxPackCommand,
        in pack: DoraxPackV2,
        query: String = "",
        filter: String = "",
        formValues: [String: String]? = nil,
        forceRefresh: Bool = false
    ) async -> Result<DoraxCommandOutput, PluginRunFailure> {
        let key = CacheKey(packID: pack.id, commandID: command.id, filter: filter)
        var existing = cache[key] ?? DoraxCommandCacheEntry(output: nil, fetchedAt: nil, isRefreshing: false, lastError: nil)

        // Serve fresh cache without spawning when within TTL and not forced.
        if !forceRefresh,
           let cachedOutput = existing.output,
           let fetchedAt = existing.fetchedAt,
           command.cacheTTLSeconds > 0,
           Date().timeIntervalSince(fetchedAt) < TimeInterval(command.cacheTTLSeconds),
           formValues == nil
        {
            return .success(cachedOutput)
        }

        // Apple Intelligence commands act on the user's current selection/clipboard,
        // so never flash stale previous results while computing a fresh response.
        if (command.source ?? "").hasPrefix("dorax.appleIntelligence."),
           command.cacheTTLSeconds == 0,
           formValues == nil
        {
            existing.output = nil
        }

        // Stale-while-revalidate: keep showing last good output while refreshing.
        existing.isRefreshing = true
        existing.lastError = nil
        cache[key] = existing

        let started = Date()

        // 1. Native `dorax.*` zero-script data source OR pure AI command (`mode == .ai` without script)
        if let source = command.source, !source.isEmpty {
            let output: DoraxCommandOutput
            if source.hasPrefix("dorax.appleIntelligence.") {
                output = await DoraxAppleIntelligenceRunner.run(
                    source: source,
                    query: query,
                    formValues: formValues,
                    commandTitle: command.title)
            } else if source.hasPrefix("dorax.ai") {
                output = await runUserSelectedAI(
                    promptText: query,
                    systemInstructions: pack.agentInstructions,
                    commandTitle: command.title,
                    packName: pack.name,
                    formValues: formValues)
            } else {
                output = DoraxContextBridge.resolveNativeSource(source, query: query)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            cache[key] = DoraxCommandCacheEntry(output: output, fetchedAt: Date(), isRefreshing: false, lastError: nil)
            appendLog(packID: pack.id, commandID: command.id, level: .info, durationMs: ms,
                      message: "Resolved native source \(source) (\(output.items.count) items)")
            applySideEffects(from: output, pack: pack, command: command)
            return .success(output)
        }

        if command.mode == .ai && (command.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let output = await runUserSelectedAI(
                promptText: query,
                systemInstructions: pack.agentInstructions,
                commandTitle: command.title,
                packName: pack.name,
                formValues: formValues)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            cache[key] = DoraxCommandCacheEntry(output: output, fetchedAt: Date(), isRefreshing: false, lastError: nil)
            appendLog(packID: pack.id, commandID: command.id, level: .info, durationMs: ms,
                      message: "Completed AI command using \(AppSettings.shared.selectedAIProvider.rawValue)")
            applySideEffects(from: output, pack: pack, command: command)
            return .success(output)
        }

        // Build permission-gated $DORAX_CONTEXT JSON for stdin
        let contextPayload = DoraxContextBridge.buildContext(
            pack: pack.metadata,
            commandID: command.id,
            query: query,
            filter: filter.isEmpty ? nil : filter,
            formValues: formValues)
        let stdinData: Data? = {
            guard let base = DoraxContextBridge.encodeJSON(contextPayload) else { return nil }
            guard let formValues, !formValues.isEmpty,
                  var obj = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any]
            else { return base }
            obj["arguments"] = formValues
            return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        }()

        var env: [String: String] = [
            "DORAX_PACK_ID": pack.id,
            "DORAX_COMMAND_ID": command.id,
            "DORAX_PACK_DIR": pack.folderURL.path,
            "DORAX_QUERY": query,
            "DORAX_FILTER": filter,
            "DORAX_CONTEXT_STDIN": "1",
        ]
        // NOTE: Never place `$DORAX_CONTEXT` JSON (which may carry Keychain secrets) in process
        // environment variables (visible via `ps eww`); it is passed strictly over private `stdin`.
        if let formValues {
            for (k, v) in formValues {
                env["DORAX_FORM_\(k.uppercased())"] = v
                env["DORAX_ARG_\(k.uppercased())"] = v
            }
        }

        let timeout = TimeInterval(max(1, command.timeoutSeconds))
        let runResult: Result<PluginRunResult, PluginRunFailure>

        // 2. `mode: cli` — strict argv-only execution, never a shell string
        if command.mode == .cli {
            guard let binary = command.binary, !binary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let failure = PluginRunFailure(message: "CLI command \"\(command.title)\" has no binary configured", kind: .blocked)
                recordFailure(failure, key: key, existing: existing, packID: pack.id, commandID: command.id, started: started)
                return .failure(failure)
            }
            let args = (command.args ?? []).map { arg in
                arg.replacingOccurrences(of: "{{query}}", with: query)
                   .replacingOccurrences(of: "{{filter}}", with: filter)
            }
            runResult = await runner.runArgv(
                executable: binary,
                arguments: args,
                env: env,
                timeout: timeout,
                workingDirectory: pack.folderURL.path,
                stdinData: stdinData)
        } else if let script = command.script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runResult = await executePackScript(
                script,
                in: pack,
                env: env,
                timeout: timeout,
                stdinData: stdinData)
        } else {
            let output = DoraxCommandOutput(
                detail: DoraxItemDetail(
                    markdown: "### \(command.title)\n\(command.subtitle)",
                    metadata: [DoraxMetadataEntry(label: "Pack", value: pack.name)]))
            cache[key] = DoraxCommandCacheEntry(output: output, fetchedAt: Date(), isRefreshing: false, lastError: nil)
            return .success(output)
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch runResult {
        case .failure(let failure):
            recordFailure(failure, key: key, existing: existing, packID: pack.id, commandID: command.id, started: started)
            return .failure(failure)
        case .success(let res):
            var output: DoraxCommandOutput
            if command.mode == .cli {
                let text = res.stdout.isEmpty ? "(No output)" : res.stdout
                output = DoraxCommandOutput(
                    detail: DoraxItemDetail(
                        markdown: "```\n\(text)\n```",
                        metadata: [
                            DoraxMetadataEntry(label: "Binary", value: command.binary ?? ""),
                            DoraxMetadataEntry(label: "Exit Code", value: "\(res.exitCode)"),
                            DoraxMetadataEntry(label: "Duration", value: "\(ms) ms"),
                        ]))
            } else {
                output = DoraxCommandOutput.parse(stdout: res.stdout, commandTitle: command.title)
            }

            // 3. Script -> User Selected AI bridge (`ai_prompt` emitted by extension script)
            if let aiPrompt = output.aiPrompt, !aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let aiOut = await runUserSelectedAI(
                    promptText: aiPrompt,
                    systemInstructions: output.aiSystem ?? pack.agentInstructions,
                    commandTitle: command.title,
                    packName: pack.name,
                    formValues: nil)
                if output.detail == nil {
                    output.detail = aiOut.detail
                } else if let aiText = aiOut.detail?.markdown, !aiText.isEmpty {
                    output.detail?.markdown = aiText
                    output.detail?.metadata.append(contentsOf: aiOut.detail?.metadata ?? [])
                }
                if output.items.isEmpty {
                    output.items = aiOut.items
                }
            }

            cache[key] = DoraxCommandCacheEntry(output: output, fetchedAt: Date(), isRefreshing: false, lastError: nil)
            appendLog(
                packID: pack.id, commandID: command.id, level: .info, durationMs: ms,
                message: "Succeeded (\(output.items.count) items)",
                detail: String(res.stdout.prefix(500)))
            applySideEffects(from: output, pack: pack, command: command)
            return .success(output)
        }
    }

    private func runUserSelectedAI(
        promptText: String,
        systemInstructions: String?,
        commandTitle: String,
        packName: String,
        formValues: [String: String]?
    ) async -> DoraxCommandOutput {
        let started = Date()
        var effectivePrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let formValues, !formValues.isEmpty {
            let joined = formValues.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            effectivePrompt = effectivePrompt.isEmpty ? joined : "\(effectivePrompt)\n\nInputs:\n\(joined)"
        }
        if effectivePrompt.isEmpty {
            let live = DoraxAppleIntelligenceRunner.resolveLiveSelection()?.text ?? ""
            let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            effectivePrompt = !live.isEmpty ? live : clip
        }
        guard !effectivePrompt.isEmpty else {
            return DoraxCommandOutput(
                detail: DoraxItemDetail(
                    markdown: "Type a prompt in the top bar (or select text / copy content first) to run **\(commandTitle)** with your selected AI.",
                    metadata: [DoraxMetadataEntry(label: "AI Engine", value: AppSettings.shared.selectedAIProvider.rawValue)]))
        }

        let provider = AppSettings.shared.selectedAIProvider
        let answer: String
        let engineLabel: String
        if let reply = try? await PanelAssistant.ask(
            effectivePrompt,
            title: commandTitle,
            subtitle: packName,
            extraPrompt: systemInstructions ?? "Follow the command instructions accurately and return concise Markdown.",
            history: [],
            provider: provider
        ), !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            engineLabel = provider.rawValue
        } else {
            let fallback = await DoraxAppleIntelligenceRunner.run(
                source: "dorax.appleIntelligence.ask",
                query: effectivePrompt,
                formValues: formValues,
                commandTitle: commandTitle)
            return fallback
        }

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return DoraxCommandOutput(
            items: [
                DoraxCommandItem(
                    id: "ai-answer",
                    title: commandTitle,
                    subtitle: String(answer.prefix(120)),
                    icon: "sparkles",
                    actions: [
                        DoraxItemAction(id: "copy", title: "Copy Result", icon: "doc.on.doc", shortcut: "↵", kind: "copy", value: answer),
                        DoraxItemAction(id: "refresh", title: "Regenerate", icon: "arrow.clockwise", shortcut: "⌘R", kind: "refresh"),
                    ])
            ],
            detail: DoraxItemDetail(
                markdown: answer,
                metadata: [
                    DoraxMetadataEntry(label: "Engine", value: engineLabel, colorHex: "#A855F7"),
                    DoraxMetadataEntry(label: "Latency", value: "\(elapsed) ms"),
                ]))
    }

    /// Executes a headless pack `tool` (e.g. from AI Chat `@pack.tool` mentions).
    func runTool(
        _ tool: DoraxPackTool,
        in pack: DoraxPackV2,
        query: String
    ) async -> Result<String, PluginRunFailure> {
        let contextPayload = DoraxContextBridge.buildContext(
            pack: pack.metadata, commandID: tool.id, query: query)
        let stdinData = DoraxContextBridge.encodeJSON(contextPayload)
        let env: [String: String] = [
            "DORAX_PACK_ID": pack.id,
            "DORAX_TOOL_ID": tool.id,
            "DORAX_PACK_DIR": pack.folderURL.path,
            "DORAX_QUERY": query,
        ]
        let started = Date()
        let result: Result<PluginRunResult, PluginRunFailure>
        if let binary = tool.binary, !binary.isEmpty {
            let args = (tool.args ?? []).map { $0.replacingOccurrences(of: "{{query}}", with: query) }
            result = await runner.runArgv(
                executable: binary, arguments: args, env: env, timeout: 10,
                workingDirectory: pack.folderURL.path, stdinData: stdinData)
        } else if let script = tool.script, !script.isEmpty {
            result = await executePackScript(script, in: pack, env: env, timeout: 10, stdinData: stdinData)
        } else {
            return .failure(PluginRunFailure(message: "Tool \(tool.id) has no script or binary", kind: .blocked))
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .success(let r):
            appendLog(packID: pack.id, commandID: "tool:\(tool.id)", level: .info, durationMs: ms, message: "Tool succeeded")
            return .success(r.stdout)
        case .failure(let f):
            appendLog(packID: pack.id, commandID: "tool:\(tool.id)", level: .error, durationMs: ms, message: f.message)
            return .failure(f)
        }
    }

    struct DoraxActionExecutionResult: Equatable {
        var message: String
        var didReplaceOutput: Bool
    }

    /// Executes a typed item action from the `680 × 440` Result Sheet or `⌘K` Actions panel.
    @discardableResult
    func runItemAction(
        _ action: DoraxItemAction,
        in pack: DoraxPackV2,
        item: DoraxCommandItem? = nil
    ) async -> Result<String, PluginRunFailure> {
        let detailed = await runItemActionDetailed(action, in: pack, command: nil, item: item, filter: "")
        return detailed.map(\.message)
    }

    @discardableResult
    func runItemActionDetailed(
        _ action: DoraxItemAction,
        in pack: DoraxPackV2,
        command: DoraxPackCommand? = nil,
        item: DoraxCommandItem? = nil,
        filter: String = ""
    ) async -> Result<DoraxActionExecutionResult, PluginRunFailure> {
        let started = Date()
        switch action.kind.lowercased() {
        case "copy":
            let text = action.value ?? item?.title ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            appendLog(packID: pack.id, commandID: action.id, level: .info, durationMs: 0, message: "Copied to clipboard")
            return .success(DoraxActionExecutionResult(message: "Copied", didReplaceOutput: false))
        case "paste":
            let text = action.value ?? item?.title ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            appendLog(packID: pack.id, commandID: action.id, level: .info, durationMs: 0, message: "Staged paste to clipboard")
            return .success(DoraxActionExecutionResult(message: "Copied for paste", didReplaceOutput: false))
        case "open", "url":
            let raw = action.value ?? ""
            guard let url = URL(string: raw) else {
                return .failure(PluginRunFailure(message: "Invalid URL: \(raw)", kind: .launch))
            }
            NSWorkspace.shared.open(url)
            return .success(DoraxActionExecutionResult(message: raw, didReplaceOutput: false))
        case "reveal":
            let rawPath = action.value ?? ""
            let path = NSString(string: rawPath).expandingTildeInPath
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return .success(DoraxActionExecutionResult(message: path, didReplaceOutput: false))
        case "notify":
            let msg = action.value ?? action.title
            ILauncherNotificationManager.shared.post(title: pack.name, body: msg, icon: pack.metadata.icon)
            return .success(DoraxActionExecutionResult(message: msg, didReplaceOutput: false))
        case "window":
            let cmdID = action.value ?? item?.id ?? ""
            guard let cmd = WindowManagementService.shared.matchingCommands(query: "").first(where: { $0.id == cmdID }) else {
                return .failure(PluginRunFailure(message: "Window layout not found: \(cmdID)", kind: .launch))
            }
            guard let frontApp = AppDelegate.shared?.previousFrontmostApp
                ?? AppDelegate.shared?.menuBarOwningUserFacingApplication()
                ?? NSWorkspace.shared.frontmostApplication
            else {
                return .failure(PluginRunFailure(message: "No target window application found", kind: .launch))
            }
            _ = WindowManagementService.shared.execute(cmd, sourceApp: frontApp)
            appendLog(packID: pack.id, commandID: action.id, level: .info, durationMs: 0, message: "Applied window layout \(cmd.title)")
            return .success(DoraxActionExecutionResult(message: "Applied \(cmd.title)", didReplaceOutput: false))
        case "notch":
            let msg = action.value ?? action.title
            DynamicNotchState.shared.publishPackActivity(
                DoraxNotchLiveActivity(
                    packID: pack.id,
                    packName: pack.name,
                    payload: DoraxNotchPayload(
                        wingText: String(msg.prefix(12)),
                        wingIcon: action.icon,
                        wingColorHex: pack.metadata.appearance?.tint,
                        title: action.title,
                        subtitle: msg)))
            return .success(DoraxActionExecutionResult(message: msg, didReplaceOutput: false))
        case "cli":
            guard let binary = action.binary, !binary.isEmpty else {
                return .failure(PluginRunFailure(message: "CLI action missing binary", kind: .blocked))
            }
            let res = await runner.runArgv(
                executable: binary,
                arguments: action.args ?? [],
                env: ["DORAX_PACK_ID": pack.id, "DORAX_ITEM_ID": item?.id ?? ""],
                timeout: 15,
                workingDirectory: pack.folderURL.path,
                stdinData: nil)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch res {
            case .success(let r):
                appendLog(packID: pack.id, commandID: action.id, level: .info, durationMs: ms, message: "Action \(action.title) succeeded")
                return .success(DoraxActionExecutionResult(message: r.stdout, didReplaceOutput: false))
            case .failure(let f):
                appendLog(packID: pack.id, commandID: action.id, level: .error, durationMs: ms, message: f.message)
                return .failure(f)
            }
        case "refresh":
            return .success(DoraxActionExecutionResult(message: "", didReplaceOutput: false))
        case "pick_folder":
            let prefID = action.value ?? "folder"
            let pref = pack.metadata.preferences?.first(where: { $0.id == prefID })
                ?? DoraxPackPreference(id: prefID, title: action.title, type: .directory)
            let initial = DoraxPackPreferenceStore.value(for: pref, packID: pack.id)
            guard let chosen = DoraxMediaPickers.chooseDirectory(title: action.title, initialPath: initial) else {
                return .success(DoraxActionExecutionResult(message: "", didReplaceOutput: false))
            }
            DoraxPackPreferenceStore.setValue(chosen, for: pref, packID: pack.id)
            invalidateCache(forPackID: pack.id)
            let folderName = URL(fileURLWithPath: chosen).lastPathComponent
            appendLog(packID: pack.id, commandID: action.id, level: .info, durationMs: 0, message: "Selected folder \(folderName)")
            return .success(DoraxActionExecutionResult(message: "Folder set to \(folderName)", didReplaceOutput: false))
        case "pick_files":
            let rawDest = (action.value?.isEmpty == false ? action.value! : "~/Library/Application Support/Context-Dock/wallpapers/collection")
            let destPath = NSString(string: rawDest).expandingTildeInPath
            let destURL = URL(fileURLWithPath: destPath, isDirectory: true)
            let added = DoraxMediaPickers.chooseImageFiles(title: action.title, into: destURL)
            guard !added.isEmpty else {
                return .success(DoraxActionExecutionResult(message: "", didReplaceOutput: false))
            }
            invalidateCache(forPackID: pack.id)
            appendLog(packID: pack.id, commandID: action.id, level: .info, durationMs: 0, message: "Added \(added.count) picture(s)")
            return .success(DoraxActionExecutionResult(message: "Added \(added.count) picture(s)", didReplaceOutput: false))
        case "script", "run":
            let resolvedScript = (action.script?.isEmpty == false ? action.script : nil) ?? command?.script
            guard let script = resolvedScript, !script.isEmpty else {
                return .failure(PluginRunFailure(message: "Action missing target script", kind: .blocked))
            }
            let contextPayload = DoraxContextBridge.buildContext(
                pack: pack.metadata, commandID: command?.id ?? action.id, query: "")
            let actionPayloadJSON = action.payloadJSON ?? "{}"
            let stdinData: Data? = {
                guard let baseData = DoraxContextBridge.encodeJSON(contextPayload),
                      var obj = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any]
                else {
                    return DoraxContextBridge.encodeJSON(contextPayload)
                }
                if let payloadData = actionPayloadJSON.data(using: .utf8),
                   let parsedAction = try? JSONSerialization.jsonObject(with: payloadData)
                {
                    obj["action"] = parsedAction
                } else {
                    obj["action"] = ["id": action.id, "value": action.value ?? ""]
                }
                return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            }()

            let res = await executePackScript(
                script,
                in: pack,
                env: [
                    "DORAX_PACK_ID": pack.id,
                    "DORAX_COMMAND_ID": command?.id ?? "",
                    "DORAX_ITEM_ID": item?.id ?? "",
                    "DORAX_ITEM_TITLE": item?.title ?? "",
                    "DORAX_ACTION": actionPayloadJSON,
                    "DORAX_ACTION_VALUE": action.value ?? "",
                    "DORAX_CONTEXT_STDIN": "1",
                ],
                timeout: 15,
                stdinData: stdinData)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch res {
            case .success(let r):
                let trimmed = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if let command,
                   trimmed.hasPrefix("{"),
                   let outData = trimmed.data(using: .utf8),
                   let rawObj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                   rawObj["items"] != nil || rawObj["detail"] != nil
                {
                    let output = DoraxCommandOutput.parse(stdout: r.stdout, commandTitle: command.title)
                    let key = CacheKey(packID: pack.id, commandID: command.id, filter: filter)
                    cache[key] = DoraxCommandCacheEntry(output: output, fetchedAt: Date(), isRefreshing: false, lastError: nil)
                    applySideEffects(from: output, pack: pack, command: command)
                    let msg = output.toast ?? ""
                    appendLog(packID: pack.id, commandID: action.id, level: .info, durationMs: ms, message: "Action \(action.title) updated view (\(output.items.count) items)")
                    return .success(DoraxActionExecutionResult(message: msg, didReplaceOutput: true))
                }
                appendLog(packID: pack.id, commandID: action.id, level: .info, durationMs: ms, message: "Action \(action.title) succeeded")
                return .success(DoraxActionExecutionResult(message: r.stdout, didReplaceOutput: false))
            case .failure(let f):
                appendLog(packID: pack.id, commandID: action.id, level: .error, durationMs: ms, message: f.message)
                return .failure(f)
            }
        default:
            return .failure(PluginRunFailure(message: "Unknown action kind: \(action.kind)", kind: .blocked))
        }
    }

    // MARK: - Private Helpers

    private func executePackScript(
        _ script: String,
        in pack: DoraxPackV2,
        env: [String: String],
        timeout: TimeInterval,
        stdinData: Data?
    ) async -> Result<PluginRunResult, PluginRunFailure> {
        let candidateURL = pack.folderURL.appendingPathComponent(script)
        if !script.contains("\n"), FileManager.default.fileExists(atPath: candidateURL.path) {
            let ext = candidateURL.pathExtension.lowercased()
            switch ext {
            case "py":
                return await runner.runArgv(
                    executable: "/usr/bin/python3",
                    arguments: [candidateURL.path],
                    env: env, timeout: timeout,
                    workingDirectory: pack.folderURL.path,
                    stdinData: stdinData)
            case "sh", "zsh":
                return await runner.runArgv(
                    executable: "/bin/zsh",
                    arguments: [candidateURL.path],
                    env: env, timeout: timeout,
                    workingDirectory: pack.folderURL.path,
                    stdinData: stdinData)
            case "applescript":
                return await runner.runArgv(
                    executable: "/usr/bin/osascript",
                    arguments: [candidateURL.path],
                    env: env, timeout: timeout,
                    workingDirectory: pack.folderURL.path,
                    stdinData: stdinData)
            case "js", "jxa":
                return await runner.runArgv(
                    executable: "/usr/bin/osascript",
                    arguments: ["-l", "JavaScript", candidateURL.path],
                    env: env, timeout: timeout,
                    workingDirectory: pack.folderURL.path,
                    stdinData: stdinData)
            default:
                return await runner.runArgv(
                    executable: candidateURL.path,
                    arguments: [],
                    env: env, timeout: timeout,
                    workingDirectory: pack.folderURL.path,
                    stdinData: stdinData)
            }
        }
        return await runner.run(
            type: .bash,
            script: script,
            env: env,
            timeout: timeout,
            workingDirectory: pack.folderURL.path,
            stdinData: stdinData)
    }

    private func recordFailure(
        _ failure: PluginRunFailure,
        key: CacheKey,
        existing: DoraxCommandCacheEntry,
        packID: String,
        commandID: String,
        started: Date
    ) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        // Preserve stale output if available alongside inline error!
        cache[key] = DoraxCommandCacheEntry(
            output: existing.output,
            fetchedAt: existing.fetchedAt,
            isRefreshing: false,
            lastError: failure.message)
        appendLog(packID: packID, commandID: commandID, level: .error, durationMs: ms, message: failure.message)
    }

    private func applySideEffects(
        from output: DoraxCommandOutput,
        pack: DoraxPackV2,
        command: DoraxPackCommand
    ) {
        if let notch = output.notch {
            DynamicNotchState.shared.publishPackActivity(
                DoraxNotchLiveActivity(packID: pack.id, packName: pack.name, payload: notch))
        }
        if let appearance = output.appearance ?? command.appearance ?? pack.metadata.appearance,
           appearance.glow.normalized != .none
        {
            DockAuraEngine.shared.activate(
                id: "pack-cmd:\(pack.id):\(command.id)",
                appearance: appearance,
                priority: 60,
                ttlSeconds: command.mode == .notch ? nil : 12)
        }
        if let toast = output.toast, !toast.isEmpty {
            ILauncherNotificationManager.shared.post(title: pack.name, body: toast, icon: pack.metadata.icon)
        }
    }
}

// MARK: - Global Hotkey Parser & Monitor for `Configure Command` (`DoraxCommandConfig.hotkey`)

struct DoraxHotkeyShortcut: Equatable {
    let modifiers: NSEvent.ModifierFlags
    let keyEquivalent: String

    /// Parses human-friendly hotkey strings such as `"⌥⇧P"`, `"⌘⇧M"`, `"⌃⌥K"`, or `"cmd+shift+p"`.
    /// Requires at least one non-Shift modifier (`⌘`, `⌥`, or `⌃`) so plain typing is never captured.
    static func parse(_ raw: String) -> DoraxHotkeyShortcut? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var mods: NSEvent.ModifierFlags = []
        var remainder = trimmed.lowercased()

        let wordTokens: [(String, NSEvent.ModifierFlags)] = [
            ("command+", .command), ("cmd+", .command), ("super+", .command),
            ("option+", .option), ("opt+", .option), ("alt+", .option),
            ("control+", .control), ("ctrl+", .control),
            ("shift+", .shift),
        ]
        for (token, flag) in wordTokens {
            if remainder.contains(token) {
                mods.insert(flag)
                remainder = remainder.replacingOccurrences(of: token, with: "")
            }
        }

        var keyChars = ""
        for ch in remainder {
            switch ch {
            case "⌘": mods.insert(.command)
            case "⌥": mods.insert(.option)
            case "⌃": mods.insert(.control)
            case "⇧": mods.insert(.shift)
            case " ", "+": continue
            default: keyChars.append(ch)
            }
        }

        guard keyChars.count == 1,
              !mods.intersection([.command, .option, .control]).isEmpty
        else { return nil }

        return DoraxHotkeyShortcut(modifiers: mods, keyEquivalent: keyChars)
    }

    func matches(charactersIgnoringModifiers: String?, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevant == modifiers,
              let chars = charactersIgnoringModifiers?.lowercased(),
              chars == keyEquivalent
        else { return false }
        return true
    }
}

extension DoraxPackV3Registry {
    /// Resolves the first enabled `.doraxpack` v3 command matching the given key event's shortcut.
    func matchingCommand(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> DoraxBoundCommand? {
        let relevant = modifierFlags.intersection([.command, .option, .control, .shift])
        guard !relevant.intersection([.command, .option, .control]).isEmpty else { return nil }
        for pack in packs {
            for cmd in pack.metadata.commands ?? [] {
                let cfg = commandConfig(packID: pack.id, commandID: cmd.id)
                guard cfg.isEnabled,
                      let parsed = DoraxHotkeyShortcut.parse(cfg.hotkey),
                      parsed.matches(charactersIgnoringModifiers: charactersIgnoringModifiers, modifierFlags: relevant)
                else { continue }
                return DoraxBoundCommand(
                    pack: pack, command: cmd, sectionTitle: pack.name, isContextual: false)
            }
        }
        return nil
    }
}

@MainActor
final class DoraxPackHotkeyMonitor {
    static let shared = DoraxPackHotkeyMonitor()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    func start() {
        guard globalMonitor == nil, localMonitor == nil, !AppDelegate.isHostingTests else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                _ = self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if MainActor.assumeIsolated({ self?.handle(event) == true }) {
                return nil
            }
            return event
        }
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        guard let bound = DoraxPackV3Registry.shared.matchingCommand(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) else { return false }

        let controller = CornerDockController.shared
        controller.showCentred()
        controller.prompt.scopeIntoV3Command(bound)
        controller.refresh()
        return true
    }
}
