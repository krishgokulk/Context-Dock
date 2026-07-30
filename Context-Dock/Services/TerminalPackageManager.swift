import Foundation
import SwiftUI
import Combine

// MARK: - Terminal Package System

/// Manages user-installed terminal packages/tools for L2 natural language execution
class TerminalPackageManager: ObservableObject {
    static let shared = TerminalPackageManager()

    @Published var packages: [TerminalPackage] = []

    /// Did the user deliberately make this tool a global CLI scope?
    ///
    /// `packages` is not a user-curated list — BinaryWatcherService discovers executables on
    /// PATH, so it holds hundreds of entries the user never chose (`tac`, `new-localization`).
    /// Two places disagreed about that: Settings → CLI Tool Scope lists only the deliberate
    /// ones, while the global search index accepted every enabled package, so typing "tac"
    /// ghost-completed a scope the user never added and Settings could not show or remove.
    ///
    /// Deliberate means pinned, or wired into an App Adapter as a CLI tool. This is the one
    /// definition; both the index and Settings must use it.
    func isUserAddedGlobalScope(_ package: TerminalPackage) -> Bool {
        let command = package.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return false }
        if AppSettings.shared.isCLIToolPinned(command) { return true }
        let commandKey = command.lowercased()
        return AppAdapterManager.shared.adapters.contains { adapter in
            if adapter.bundleId.lowercased().hasPrefix("cli://") {
                return adapter.bundleId.lowercased().contains(commandKey)
                    || adapter.appName.lowercased() == commandKey
            }
            return adapter.actions.contains {
                $0.type == .cliTool
                    && ($0.cliToolCommand ?? "").caseInsensitiveCompare(command) == .orderedSame
            }
        }
    }

    private let packagesKey = "L2TerminalPackages"

    init() {
        loadPackages()
        registerBuiltInMarkItDownIfAvailable()
        // Auto-add any binary that BinaryWatcherService discovers (installed via brew, curl, etc.)
        NotificationCenter.default.addObserver(
            forName: .newBinaryDiscovered, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let name = note.userInfo?["toolName"] as? String,
                  let path = note.userInfo?["toolPath"] as? String else { return }
            Task { await self.autoAddDiscoveredBinary(name: name, path: path) }
        }
    }

    private func registerBuiltInMarkItDownIfAvailable() {
        guard let executable = MarkItDownService.executableURL?.path else { return }
        let appScopes = [
            "com.apple.finder", "com.apple.Preview", "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
        ]
        if let index = packages.firstIndex(where: { $0.command == "markitdown" }) {
            packages[index].installedPath = executable
            packages[index].isEnabled = true
            packages[index].contextAppBundleIds = Array(
                Set(packages[index].contextAppBundleIds + appScopes)
            ).sorted()
        } else {
            packages.append(
                TerminalPackage(
                    name: "Microsoft MarkItDown",
                    command: "markitdown",
                    description: "Built-in document ingestion for token-efficient AI context",
                    installedPath: executable,
                    keywords: [
                        "markdown", "pdf", "document", "office", "extract", "ocr",
                        "youtube", "epub", "spreadsheet", "presentation",
                    ],
                    usageExamples: [
                        "markitdown \"<file>\"",
                        "markitdown \"<file>\" -o \"<output>.md\"",
                    ],
                    helpText: "Convert PDF, Office, images, audio, HTML, ZIP, EPUB, and URLs to structured Markdown.",
                    subcommands: [],
                    usagePattern: "markitdown <input> [-o output.md]",
                    taskCategories: ["documents", "conversion", "extraction", "ai-context"],
                    contextAppBundleIds: appScopes
                ))
        }
        savePackages()
    }

    /// Called when BinaryWatcherService detects a new binary in any monitored bin dir.
    /// Auto-adds it to My CLI Tools and runs --help to learn its commands.
    /// Called when BinaryWatcherService detects a new binary. Just registers it —
    /// no blocking --help scan here. User clicks "Scan --help" in Task Defaults to learn commands.
    func autoAddDiscoveredBinary(name: String, path: String) async {
        guard !packages.contains(where: { $0.command == name }) else { return }
        let pkg = TerminalPackage(
            name: name,
            command: name,
            description: "Installed in \(URL(fileURLWithPath: path).deletingLastPathComponent().path)",
            installedPath: path,
            keywords: [name],
            usageExamples: []
        )
        await MainActor.run {
            self.packages.append(pkg)
            self.savePackages()
        }
    }
    
    // MARK: - Package Management
    
    func addPackage(_ package: TerminalPackage) {
        if !packages.contains(where: { $0.id == package.id }) {
            packages.append(package)
            savePackages()
        }
    }
    
    func removePackage(_ package: TerminalPackage) {
        packages.removeAll { $0.id == package.id }
        savePackages()
    }
    
    func updatePackage(_ package: TerminalPackage) {
        if let index = packages.firstIndex(where: { $0.id == package.id }) {
            packages[index] = package
            savePackages()
        }
    }
    
    // MARK: - Package Discovery
    
    /// Scan system for installed terminal tools
    func scanForInstalledTools() async -> [TerminalPackage] {
        var discovered: [TerminalPackage] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Directories that contain user-installed tools (not macOS system tools)
        let userBinDirs = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/go/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.poetry/bin"
        ]

        // macOS built-in binaries to skip (so we don't flood the list with system tools)
        let systemNoise: Set<String> = [
            "bash","zsh","sh","fish","dash","tcsh","ksh",
            "ls","cp","mv","rm","mkdir","rmdir","touch","cat","echo","printf",
            "find","grep","sed","awk","sort","uniq","head","tail","wc","xargs",
            "open","osascript","defaults","launchctl","caffeinate","diskutil",
            "ssh","scp","sftp","rsync","curl","wget","nc","ncat","nmap",
            "python","python3","ruby","perl","php","node","deno","bun",
            "git","svn","hg","cvs",
            "vim","nano","emacs","nvim","hx",
            "make","cmake","ninja","meson","gradle","mvn",
            "docker","podman","kubectl","helm","terraform","ansible",
            "brew","pip","pip3","npm","yarn","cargo","go","swift","rustc",
            "cc","clang","gcc","g++","ld","ar","nm","strip","ranlib",
            "tar","zip","unzip","gzip","bzip2","xz","zstd",
            "ps","top","kill","lsof","netstat","ifconfig","ipconfig","ping",
            "man","less","more","file","which","where","type","hash",
            "date","cal","bc","expr","true","false","test","[","[[",
        ]

        var alreadyAdded = Set(packages.map { $0.command })

        for dir in userBinDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in contents.sorted() {
                guard !alreadyAdded.contains(name) else { continue }
                guard !systemNoise.contains(name) else { continue }
                let path = "\(dir)/\(name)"
                guard fm.isExecutableFile(atPath: path) else { continue }
                // Skip dot-files and shell completions
                guard !name.hasPrefix("."), !name.hasSuffix(".sh"), !name.hasSuffix(".py") else { continue }

                let pkg = TerminalPackage(
                    name: name,
                    command: name,
                    description: "Installed in \(dir)",
                    installedPath: path,
                    keywords: [name],
                    usageExamples: []
                )
                discovered.append(pkg)
                alreadyAdded.insert(name)
            }
        }

        return discovered
    }
    
    private func findCommandPath(_ command: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]

        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:" + currentPath
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    return path
                }
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to find command '\(command)': \(error)")
            #endif
        }

        return nil
    }

    // MARK: - Natural Language Matching

    /// Find best matching package for a natural language query
    func findPackageForQuery(_ query: String) -> TerminalPackage? {
        let queryLower = query.lowercased()

        var bestMatch: (package: TerminalPackage, score: Int)? = nil

        for package in packages where package.isEnabled {
            var score = 0

            // Exact package name match (highest priority)
            if queryLower.contains(package.name.lowercased()) {
                score += 25
            }

            // Exact command match
            if queryLower.contains(package.command.lowercased()) {
                score += 20
            }

            // Name word parts: "youtube-music-cli" → ["youtube", "music"]
            // This catches abbreviated queries like "ytube music" matching "youtube"
            let nameWords = package.name.lowercased()
                .components(separatedBy: CharacterSet(charactersIn: "-_ "))
                .filter { $0.count > 2 && !["cli", "cmd", "tool", "app"].contains($0) }
            for word in nameWords {
                if queryLower.contains(word) {
                    score += 10
                }
            }

            // Keyword matching
            for keyword in package.keywords {
                if queryLower.contains(keyword.lowercased()) {
                    score += 8
                }
            }

            // Description word matching (lower weight)
            let descWords = package.description.lowercased()
                .components(separatedBy: .whitespaces)
                .filter { $0.count > 4 }
            for word in descWords {
                if queryLower.contains(word) {
                    score += 3
                }
            }

            if score > 0 {
                if let current = bestMatch {
                    if score > current.score {
                        bestMatch = (package, score)
                    }
                } else {
                    bestMatch = (package, score)
                }
            }
        }

        return bestMatch?.package
    }

    func packages(forContextBundleId bundleId: String, query: String = "", maxResults: Int = 6)
        -> [TerminalPackage]
    {
        guard !bundleId.isEmpty else { return [] }
        let normalizedQuery = normalizeQuery(query)

        let scored = packages.compactMap { package -> (TerminalPackage, Int)? in
            guard package.isEnabled, package.isAssociated(with: bundleId) else { return nil }

            let score = score(package: package, normalizedQuery: normalizedQuery)
            if normalizedQuery.isEmpty {
                return (package, score)
            }
            return score > 0 ? (package, score) : nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .prefix(maxResults)
            .map(\.0)
    }
    
    // MARK: - Command Generation
    
    /// Generate command from natural language using package info
    func generateCommand(for query: String, using package: TerminalPackage) -> String? {
        // Basic heuristics for common operations
        let queryLower = query.lowercased()
        
        // YouTube download example
        if package.command.contains("yt-dlp") || package.command.contains("youtube-dl") {
            if queryLower.contains("download") {
                if queryLower.contains("current") || queryLower.contains("this") {
                    return "\(package.command) [URL]"
                }
                if queryLower.contains("audio") || queryLower.contains("mp3") {
                    return "\(package.command) -x --audio-format mp3 [URL]"
                }
                return "\(package.command) [URL]"
            }
        }
        
        // Brew commands
        if package.command == "brew" {
            if queryLower.contains("update") {
                return "brew update"
            }
            if queryLower.contains("upgrade") {
                return "brew upgrade"
            }
            if queryLower.contains("install") {
                return "brew install [package]"
            }
        }
        
        // Git commands
        if package.command == "git" {
            if queryLower.contains("status") {
                return "git status"
            }
            if queryLower.contains("commit") {
                return "git commit -m \"[message]\""
            }
            if queryLower.contains("push") {
                return "git push"
            }
        }
        
        // Generic fallback - use first usage example if available
        return package.usageExamples.first
    }
    // MARK: - Help Text Discovery

    /// Run `command --help` (or `-h`, or `binary help sub1 sub2`) and return output.
    /// `binary` is passed so we can also try the Swift ArgumentParser `help` subcommand pattern.
    // MARK: - Live scan log (shown in settings while scanning)
    @Published var scanLog: [String] = []   // e.g. ["✓ ekctl --help", "✓ ekctl list --help", ...]

    // Meta-commands that are never worth recursing into
    private static let metaSubcommands: Set<String> = [
        "help", "version", "completion", "completions",
        "__complete", "_complete", "generate-completion-script",
        "man", "doc", "docs"
    ]

    func scanHelpText(for command: String, binary: String? = nil) async -> String? {
        let env = buildEnv()
        let bin = binary ?? command.components(separatedBy: " ").first ?? command
        let subPath: String = {
            guard command.hasPrefix(bin) else { return "" }
            return String(command.dropFirst(bin.count)).trimmingCharacters(in: .whitespaces)
        }()

        // Try every known help-invocation pattern, in priority order:
        // 1. cmd sub --help       (universal)
        // 2. cmd sub -h           (short flag)
        // 3. binary help sub1 sub2  (Swift ArgumentParser: ekctl, tuist, mint, …)
        // 4. cmd sub help         (some Go CLIs: kubectl sub help)
        var attempts = ["\(command) --help 2>&1", "\(command) -h 2>&1"]
        if !subPath.isEmpty {
            attempts.append("\(bin) help \(subPath) 2>&1")
            attempts.append("\(command) help 2>&1")
        }

        for attempt in attempts {
            let output = Self.strippingANSI(await runQuiet(attempt, env: env))
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Accept output that looks like real help (>20 chars, no error markers)
            if trimmed.count > 20
                && !trimmed.lowercased().contains("command not found")
                && !trimmed.lowercased().contains("unknown command")
                && !trimmed.lowercased().contains("no help topic") {
                return String(trimmed.prefix(4000))
            }
        }
        return nil
    }

    /// Fully recursive deep scan with live progress logging.
    /// Scans every subcommand path up to 5 levels deep, in parallel per level.
    /// Tries all help patterns (--help, -h, `binary help sub`, `cmd sub help`).
    /// Total output capped at 30 000 chars.
    func scanDeepHelp(for command: String) async -> String? {
        await MainActor.run { scanLog = [] }
        let actor = ScanAccumulator()
        await scanRecursiveHelp(command: command, binary: command,
                                depth: 0, accumulator: actor)
        let result = await actor.text
        let count  = await actor.count
        await MainActor.run { scanLog.append("━━ Scan complete: \(count) command path\(count == 1 ? "" : "s") ━━") }
        return result.isEmpty ? nil : String(result.prefix(30000))
    }

    /// Recursive parallel worker for scanDeepHelp.
    private func scanRecursiveHelp(command: String, binary: String,
                                   depth: Int, accumulator: ScanAccumulator) async {
        guard depth < 5 else { return }
        guard await accumulator.markVisited(command) else { return }  // deduplicate

        guard let help = await scanHelpText(for: command, binary: binary) else {
            await MainActor.run { scanLog.append("✗ \(command) (no help)") }
            return
        }
        await MainActor.run { scanLog.append("✓ \(command) --help") }

        let header = depth == 0 ? help : "\n\n--- \(command) --help ---\n\(help)"
        await accumulator.append(header)

        // Stop digging if we've already collected enough text
        guard await accumulator.text.count < 28000 else { return }

        let subs = parseSubcommands(from: help, binary: binary)
            .filter { !Self.metaSubcommands.contains($0) }
            .prefix(12)  // max breadth per level

        // Scan all sibling subcommands in parallel
        await withTaskGroup(of: Void.self) { group in
            for sub in subs {
                let childCmd = "\(command) \(sub)"
                group.addTask {
                    await self.scanRecursiveHelp(command: childCmd, binary: binary,
                                                 depth: depth + 1, accumulator: accumulator)
                }
            }
        }
    }

    /// Parse the subcommand list from --help output.
    /// Handles: "SUBCOMMANDS:", "COMMANDS:", "Available commands:", indented lists.
    /// `binary` (and any alias the help text invokes itself by) lets rows written as full
    /// invocations — `mo clean    Free up disk space` — resolve to the subcommand rather
    /// than to the binary name repeated 15 times.
    func parseSubcommands(from helpText: String, binary: String? = nil) -> [String] {
        let text = Self.strippingANSI(helpText)
        var subcommands: [String] = []
        var inSection = false
        var rows: [[String]] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")

            if !isIndented, Self.isCommandSectionHeader(trimmedLine) {
                inSection = true
                continue
            }
            // New unindented section header ends the commands section
            if inSection && !trimmedLine.isEmpty && !isIndented {
                inSection = false
            }
            // Blank line ends section only if already well inside it
            if inSection && trimmedLine.isEmpty && !rows.isEmpty {
                inSection = false
            }

            guard inSection || line.hasPrefix("  ") || line.hasPrefix("\t") else { continue }
            let tokens = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if !tokens.isEmpty { rows.append(tokens) }
        }

        var invocationNames = Self.invocationNames(in: text, binary: binary)
        // Help written as invocations ("mo clean  Free up disk space") repeats one leading
        // token on nearly every row. Whatever that token is — the binary or an installed
        // alias the help is written against — it is not a subcommand.
        if let dominant = Self.dominantLeadingToken(in: rows) {
            invocationNames.insert(dominant)
        }

        for row in rows {
            var tokens = row
            if let first = tokens.first?.lowercased(), invocationNames.contains(first) {
                tokens.removeFirst()
            }
            guard var word = tokens.first else { continue }
            // Strip trailing parenthetical like "(default)" or "[hidden]"
            if word.hasPrefix("(") || word.hasPrefix("[") { continue }
            // Strip trailing suffix like ":" or a list comma
            if word.hasSuffix(":") || word.hasSuffix(",") { word = String(word.dropLast()) }
            guard word.count > 1, word.count < 30,
                  !word.hasPrefix("-"), !word.hasPrefix("("), !word.hasPrefix("["),
                  !word.hasPrefix("<"), !word.hasPrefix("{"),
                  word == word.lowercased(),
                  word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                  !invocationNames.contains(word),
                  !subcommands.contains(word),
                  !Self.metaSubcommands.contains(word)
            else { continue }
            subcommands.append(word)
        }
        return Array(subcommands.prefix(20))
    }

    /// The leading token shared by most command rows, when there is one — that is the
    /// tool's own invocation name, not a subcommand.
    private static func dominantLeadingToken(in rows: [[String]]) -> String? {
        guard rows.count >= 3 else { return nil }
        var counts: [String: Int] = [:]
        for row in rows {
            guard let first = row.first?.lowercased(), first.count > 1, !first.hasPrefix("-") else {
                continue
            }
            counts[first, default: 0] += 1
        }
        guard let (token, count) = counts.max(by: { $0.value < $1.value }),
            count >= 3,
            Double(count) >= Double(rows.count) * 0.5
        else { return nil }
        return token
    }

    /// A commands heading. The colon is optional: plenty of CLIs (mole, many Go and Rust
    /// tools) print a bare, colour-coded `COMMANDS` heading, and requiring the colon meant
    /// their entire command list was skipped.
    private static func isCommandSectionHeader(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard lower.contains("command"), !lower.contains("usage") else { return false }
        if line.hasSuffix(":") { return true }
        let words = lower.split(separator: " ")
        guard words.count <= 3 else { return false }
        return line == line.uppercased()
            || lower.hasPrefix("commands")
            || lower.hasPrefix("subcommands")
            || lower.hasPrefix("available")
    }

    /// Names the help text uses to invoke the tool: the binary itself plus whatever the
    /// `Usage:` line names (Homebrew formulae often install a short alias — mole ships
    /// `mo` — and the help text is written in terms of the alias).
    private static func invocationNames(in helpText: String, binary: String?) -> Set<String> {
        var names = Set<String>()
        if let binary {
            let base = binary.components(separatedBy: " ").first ?? binary
            let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
            if !trimmed.isEmpty {
                names.insert(trimmed)
                names.insert((trimmed as NSString).lastPathComponent)
            }
        }
        for line in helpText.components(separatedBy: .newlines) {
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard lower.hasPrefix("usage:") || lower.hasPrefix("usage ") else { continue }
            let after = lower.drop(while: { $0 != ":" }).dropFirst()
            let candidate = after.split(separator: " ").first.map(String.init)
                ?? lower.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let name = (candidate as NSString).lastPathComponent
            if name.count > 1, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                names.insert(name)
            }
        }
        return names
    }

    /// Parse the primary usage pattern line from --help output.
    func parseUsagePattern(from helpText: String) -> String? {
        let lines = helpText.components(separatedBy: .newlines)
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("usage:") || lower.hasPrefix("usage") {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Scan --help (plus all sub-command help) for a package and update stored fields.
    func refreshHelpText(for packageId: UUID) async {
        guard let index = packages.firstIndex(where: { $0.id == packageId }) else { return }
        let pkg = packages[index]
        // Use top-level help for structure parsing; use deep help for AI context
        guard let topHelp = await scanHelpText(for: pkg.command) else { return }
        let deepHelp = await scanDeepHelp(for: pkg.command) ?? topHelp
        packages[index].helpText       = deepHelp
        packages[index].subcommands    = parseSubcommands(from: topHelp, binary: pkg.command)
        packages[index].usagePattern   = parseUsagePattern(from: topHelp)
        savePackages()
    }

    /// Re-scan a package by command name (used after tool change / new install).
    func refreshHelpTextByCommand(_ command: String) async {
        guard let index = packages.firstIndex(where: { $0.command == command }) else { return }
        await refreshHelpText(for: packages[index].id)
    }

    private var autoScanInFlight: Set<String> = []
    private var autoScannedOnce: Set<String> = []

    /// A tool needs (re)scanning when it has no help at all, when the stored help still
    /// carries raw ANSI escapes, or when the scan produced no subcommands. The last two
    /// cover everything pinned before the parser learned to strip colour codes and read
    /// colon-less `COMMANDS` headings: those entries cached unusable help and an empty
    /// command list, and would otherwise never be scanned again.
    func needsHelpScan(_ package: TerminalPackage) -> Bool {
        let help = (package.helpText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if help.isEmpty { return true }
        if help.contains("\u{1B}") { return true }
        return package.subcommands.isEmpty
    }

    /// Fire-and-forget `--help` scan for a linked CLI whose reference is still empty.
    /// A newly pinned binary is registered WITHOUT a blocking scan, so its `helpText` is
    /// empty until the user hits "Scan --help". Entering the tool's scope should not chat
    /// blind — this scans on demand (deduped) so the model gets the real command set. Safe
    /// to call repeatedly; it no-ops once help is present or a scan is already running.
    func ensureHelpScanned(command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty,
            let pkg = packages.first(where: { $0.command == cmd || $0.name == cmd }),
            needsHelpScan(pkg),
            !autoScanInFlight.contains(pkg.command),
            // A tool that genuinely has no subcommands (jq, markitdown…) stays "needs
            // scan" forever, so cap the automatic retry at once per launch.
            !autoScannedOnce.contains(pkg.command)
        else { return }
        autoScanInFlight.insert(pkg.command)
        autoScannedOnce.insert(pkg.command)
        let target = pkg.command
        Task { @MainActor in
            await refreshHelpTextByCommand(target)
            autoScanInFlight.remove(target)
        }
    }

    // MARK: - Per-App Subcommand Intelligence

    /// Given a CLI binary name and an app context (key + human label), returns the best
    /// matching subcommand, or "" if none found.
    /// e.g. toolName="memo", appKey="notes", appLabel="Notes" → "memo notes"
    ///      toolName="memo", appKey="reminders"               → "memo rem"
    func autoDetectSubcommand(toolName: String, appKey: String, appLabel: String) -> String {
        guard let pkg = packages.first(where: { $0.command == toolName }), !pkg.subcommands.isEmpty else {
            return ""
        }
        let candidates = [appKey, appLabel.lowercased()]
            .flatMap { [$0, String($0.prefix(4)), String($0.prefix(3))] }  // "notes","note","not" / "rem","remi"
            .filter { $0.count >= 3 }
        for sub in pkg.subcommands {
            let s = sub.lowercased()
            if candidates.contains(where: { s == $0 || s.hasPrefix($0) || $0.hasPrefix(s) }) {
                return "\(toolName) \(sub)"
            }
        }
        return ""
    }

    /// For CLIs that distinguish app contexts via flags (e.g. `ekctl list --reminders` vs
    /// `ekctl list --calendars`), detect the right flag by scanning the help text for
    /// flags whose names match the appKey / appLabel.
    /// e.g. toolName="ekctl", appKey="reminders" → "--reminders"
    ///      toolName="ekctl", appKey="calendars"  → "--calendars"
    func autoDetectContextFlag(toolName: String, appKey: String, appLabel: String) -> String {
        guard let pkg = packages.first(where: { $0.command == toolName }),
              let helpText = pkg.helpText, !helpText.isEmpty else { return "" }

        var candidates: [String] = []
        for raw in [appKey, appLabel.lowercased()] {
            candidates.append(raw)
            if raw.count > 4 { candidates.append(String(raw.prefix(6))) }
            if raw.count > 3 { candidates.append(String(raw.prefix(4))) }
            if raw.count > 2 { candidates.append(String(raw.prefix(3))) }
        }
        candidates = candidates.filter { $0.count >= 3 }

        var shortFallback = ""
        for line in helpText.components(separatedBy: .newlines) {
            // Tokenise every whitespace-separated piece of the line and look for flag tokens
            let tokens = line.components(separatedBy: .whitespaces)
            for token in tokens {
                var flag = token.trimmingCharacters(in: CharacterSet(charactersIn: ",|[]()<>"))
                guard flag.hasPrefix("-") else { continue }
                let isLong  = flag.hasPrefix("--")
                let flagName = (isLong ? String(flag.dropFirst(2)) : String(flag.dropFirst(1))).lowercased()
                guard flagName.count >= 2 else { continue }
                if candidates.contains(where: { c in
                    flagName == c || flagName.hasPrefix(c) || c.hasPrefix(flagName)
                }) {
                    if isLong { return flag }          // prefer long form — return immediately
                    if shortFallback.isEmpty { shortFallback = flag }
                }
            }
        }
        return shortFallback
    }

    /// From the deep-scanned help text (which includes `--- cmd sub --help ---` sections),
    /// extract only the portion relevant to a given subcommand or effective command.
    /// Falls back to the full help text when no scoped section exists.
    func helpText(for effectiveCommand: String, baseCommand: String) -> String? {
        guard let pkg = packages.first(where: { $0.command == baseCommand }),
              let full = pkg.helpText, !full.isEmpty else { return nil }

        // If effectiveCommand == baseCommand, return the whole thing
        guard effectiveCommand != baseCommand, effectiveCommand.hasPrefix(baseCommand + " ") else {
            return full
        }

        // Try to find the `--- <effectiveCommand> --help ---` section
        let marker = "--- \(effectiveCommand) --help ---"
        if let range = full.range(of: marker) {
            let after = String(full[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Take until the next `---` section or end
            if let nextRange = after.range(of: "\n--- ") {
                return String(after[..<nextRange.lowerBound])
            }
            return String(after.prefix(1500))
        }

        return full  // section not found → give full help
    }

    // MARK: - Contextual Learning

    /// Record a successful (or failed) query→command mapping so future queries can skip the AI call.
    func recordCommand(query: String, command: String, success: Bool, forPackageName packageName: String) {
        guard let index = packages.firstIndex(where: { $0.name == packageName }) else { return }
        let example = ContextualExample(query: query, command: command, wasSuccessful: success)
        // Keep last 50 examples per package
        var examples = packages[index].contextualExamples
        examples.append(example)
        if examples.count > 50 { examples.removeFirst(examples.count - 50) }
        packages[index].contextualExamples = examples
        savePackages()
    }

    /// Find a cached successful command for a query (exact or fuzzy word match).
    func cachedCommand(for query: String, packageName: String) -> String? {
        guard let pkg = packages.first(where: { $0.name == packageName }) else { return nil }
        let queryWords = Set(query.lowercased().components(separatedBy: .whitespaces).filter { $0.count > 2 })
        // Exact match first
        if let exact = pkg.contextualExamples.first(where: {
            $0.wasSuccessful && $0.query.lowercased() == query.lowercased()
        }) { return exact.command }
        // Fuzzy: majority of query words match a stored query
        return pkg.contextualExamples.filter { $0.wasSuccessful }.first(where: { example in
            let exWords = Set(example.query.lowercased().components(separatedBy: .whitespaces).filter { $0.count > 2 })
            let overlap = queryWords.intersection(exWords).count
            return overlap >= max(1, queryWords.count - 1)
        })?.command
    }

    // MARK: - Helpers

    private func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:" + current
        // Ask tools for plain help. Colour-coded output is the norm for modern CLIs and
        // its escape sequences broke subcommand parsing outright; these three variables
        // are what most CLI frameworks honour. Output is still sanitised after the fact
        // for the tools that ignore them.
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"
        env["TERM"] = "dumb"
        return env
    }

    /// Strips ANSI colour/cursor escapes (CSI + OSC) and carriage returns. Coloured help
    /// text turned every parsed token into `\u{1B}[0;32mclean`, which failed the
    /// alphanumeric check and produced zero subcommands — and the raw escapes were also
    /// being fed to the model as "command syntax".
    static func strippingANSI(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression
            )
            .replacingOccurrences(
                of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\u{1B}", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private func runQuiet(_ command: String, env: [String: String]) async -> String {
        await withCheckedContinuation { continuation in
            // MUST dispatch to background queue — waitUntilExit() blocks the thread.
            // Calling it on the Swift concurrency pool starves all async tasks.
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - Persistence

    private func savePackages() {
        if let encoded = try? JSONEncoder().encode(packages) {
            UserDefaults.standard.set(encoded, forKey: packagesKey)
        }
        Task { @MainActor in
            DoraXSpotlightIndexService.shared.scheduleRebuild(reason: "cli-packages")
        }
    }

    private func normalizeQuery(_ query: String) -> String {
        query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func score(package: TerminalPackage, normalizedQuery: String) -> Int {
        guard !normalizedQuery.isEmpty else {
            let helpBonus = package.helpText == nil ? 0 : 10
            return package.subcommands.count + package.keywords.count + helpBonus
        }

        var score = 0
        let corpus = [
            package.name,
            package.command,
            package.description,
            package.keywords.joined(separator: " "),
            package.subcommands.joined(separator: " "),
            package.taskCategories.joined(separator: " "),
            package.usageExamples.joined(separator: " "),
        ].map(normalizeQuery(_:))

        for text in corpus where !text.isEmpty {
            if text == normalizedQuery {
                score += 120
            } else if text.hasPrefix(normalizedQuery) {
                score += 72
            } else if text.contains(normalizedQuery) {
                score += 40
            }
        }

        for token in normalizedQuery.split(separator: " ").map(String.init) where token.count >= 2 {
            if normalizeQuery(package.name).contains(token) { score += 28 }
            if normalizeQuery(package.command).contains(token) { score += 24 }
            if package.keywords.contains(where: { normalizeQuery($0).contains(token) }) { score += 16 }
            if package.subcommands.contains(where: { normalizeQuery($0).contains(token) }) { score += 14 }
            if package.usageExamples.contains(where: { normalizeQuery($0).contains(token) }) { score += 10 }
        }

        return score
    }
    
    func loadPackages() {
        if let data = UserDefaults.standard.data(forKey: packagesKey),
           let decoded = try? JSONDecoder().decode([TerminalPackage].self, from: data) {
            packages = decoded
            Task { @MainActor in
                DoraXSpotlightIndexService.shared.scheduleRebuild(reason: "cli-packages-loaded")
            }
        }
    }
    
}

// MARK: - Contextual Example (learned query → command mapping)

struct ContextualExample: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var query: String
    var command: String
    var wasSuccessful: Bool
    var timestamp: Date = Date()
}

// MARK: - Terminal Package Model

struct TerminalPackage: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var command: String
    var description: String
    var installedPath: String?
    var keywords: [String]
    var usageExamples: [String]
    var readmeContent: String?
    var isEnabled: Bool
    var customNotes: String

    // --- Help-text intelligence (populated by scanHelpText) ---
    var helpText: String?          // raw `command --help` output (injected into AI prompt)
    var subcommands: [String]      // discovered subcommands, e.g. ["search", "play", "next"]
    var usagePattern: String?      // e.g. "youtube-music-cli [OPTIONS] COMMAND [ARGS]"
    var taskCategories: [String]   // task types this handles, e.g. ["music", "search"]
    var contextAppBundleIds: [String]  // app-scoped pills, loaded from context_app/context_apps

    // --- Learned examples (built up over time) ---
    var contextualExamples: [ContextualExample]

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        description: String,
        installedPath: String? = nil,
        keywords: [String] = [],
        usageExamples: [String] = [],
        readmeContent: String? = nil,
        isEnabled: Bool = true,
        customNotes: String = "",
        helpText: String? = nil,
        subcommands: [String] = [],
        usagePattern: String? = nil,
        taskCategories: [String] = [],
        contextAppBundleIds: [String] = [],
        contextualExamples: [ContextualExample] = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.description = description
        self.installedPath = installedPath
        self.keywords = keywords
        self.usageExamples = usageExamples
        self.readmeContent = readmeContent
        self.isEnabled = isEnabled
        self.customNotes = customNotes
        self.helpText = helpText
        self.subcommands = subcommands
        self.usagePattern = usagePattern
        self.taskCategories = taskCategories
        self.contextAppBundleIds = Array(Set(contextAppBundleIds)).sorted()
        self.contextualExamples = contextualExamples
    }

    var isInstalled: Bool {
        installedPath != nil
    }

    /// Help text sized for a prompt. Cut on a line boundary and labelled when shortened —
    /// a mid-flag cut reads to the model as a real flag, which is how invented flags get
    /// into generated commands.
    var helpTextForPrompt: String? {
        guard let ht = helpText, !ht.isEmpty else { return nil }
        return AIContextBudget.fitReference(ht, budget: 2_000)
    }

    func isAssociated(with bundleId: String) -> Bool {
        guard !bundleId.isEmpty else { return false }
        return contextAppBundleIds.contains(bundleId)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case description
        case installedPath
        case keywords
        case usageExamples
        case readmeContent
        case isEnabled
        case customNotes
        case helpText
        case subcommands
        case usagePattern
        case taskCategories
        case contextAppBundleIds
        case contextApps = "context_apps"
        case contextApp = "context_app"
        case contextualExamples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        installedPath = try container.decodeIfPresent(String.self, forKey: .installedPath)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        usageExamples = try container.decodeIfPresent([String].self, forKey: .usageExamples) ?? []
        readmeContent = try container.decodeIfPresent(String.self, forKey: .readmeContent)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        customNotes = try container.decodeIfPresent(String.self, forKey: .customNotes) ?? ""
        helpText = try container.decodeIfPresent(String.self, forKey: .helpText)
        subcommands = try container.decodeIfPresent([String].self, forKey: .subcommands) ?? []
        usagePattern = try container.decodeIfPresent(String.self, forKey: .usagePattern)
        taskCategories = try container.decodeIfPresent([String].self, forKey: .taskCategories) ?? []

        let decodedContextApps =
            try container.decodeIfPresent([String].self, forKey: .contextAppBundleIds)
            ?? (try container.decodeIfPresent([String].self, forKey: .contextApps))
            ?? []
        let decodedSingleContextApp = try container.decodeIfPresent(String.self, forKey: .contextApp)
        let mergedContextApps = decodedContextApps + (decodedSingleContextApp.map { [$0] } ?? [])
        contextAppBundleIds = Array(Set(mergedContextApps.filter { !$0.isEmpty })).sorted()

        contextualExamples =
            try container.decodeIfPresent([ContextualExample].self, forKey: .contextualExamples)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(installedPath, forKey: .installedPath)
        try container.encode(keywords, forKey: .keywords)
        try container.encode(usageExamples, forKey: .usageExamples)
        try container.encodeIfPresent(readmeContent, forKey: .readmeContent)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(customNotes, forKey: .customNotes)
        try container.encodeIfPresent(helpText, forKey: .helpText)
        try container.encode(subcommands, forKey: .subcommands)
        try container.encodeIfPresent(usagePattern, forKey: .usagePattern)
        try container.encode(taskCategories, forKey: .taskCategories)
        try container.encode(contextAppBundleIds, forKey: .contextApps)
        try container.encodeIfPresent(contextAppBundleIds.first, forKey: .contextApp)
        try container.encode(contextualExamples, forKey: .contextualExamples)
    }
}

// MARK: - Thread-safe scan accumulator (used by parallel TaskGroup scanning)

actor ScanAccumulator {
    private var visited: Set<String> = []
    private(set) var text: String = ""
    private(set) var count: Int = 0

    /// Returns true if this is the first time this command is visited (not yet scanned).
    func markVisited(_ command: String) -> Bool {
        guard !visited.contains(command) else { return false }
        visited.insert(command)
        return true
    }

    func append(_ chunk: String) {
        text += chunk
        count += 1
    }
}
