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
        let packageNameKey = package.name
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if AppAdapterManager.shared.adapters.contains(where: { adapter in
            let adapterKey = adapter.bundleId.lowercased()
            let adapterNameKey = adapter.appName
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if adapterKey.hasPrefix("cli://") {
                return adapterKey.contains(commandKey)
                    || (!packageNameKey.isEmpty && adapterKey.contains(packageNameKey))
                    || adapterNameKey == commandKey
                    || (!packageNameKey.isEmpty && adapterNameKey == packageNameKey)
            }
            return adapter.actions.contains { action in
                action.type == .cliTool
                    && (action.cliToolCommand ?? "").caseInsensitiveCompare(command) == .orderedSame
            }
        }) {
            return true
        }
        // Wired into a scope directly rather than through an adapter.
        let scopeIds = Set(["cli://\(command)", "cli_\(command)", command])
        return package.contextAppBundleIds.contains { scopeIds.contains($0) }
    }

    /// Commands the user marked as needing a real terminal, lowercased.
    ///
    /// Cached rather than scanned: isTUICommand runs on every command execution, and
    /// `packages` holds ~950 discovered binaries. Rebuilt whenever packages change, which is
    /// rare — a pin, a scan, a new binary appearing.
    @Published private(set) var interactiveCommands: Set<String> = []

    func refreshInteractiveCommands() {
        interactiveCommands = Set(
            packages
                .filter(\.isInteractive)
                .map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// Records an invocation that exited zero, so the next task can start from something
    /// known to work rather than from a guess at the documentation.
    ///
    /// Only for tools the user pinned — a scope's memory is worth keeping; a passing
    /// reference to some discovered binary is not. Kept to the most recent few: this text
    /// goes into a prompt, and an unbounded list would crowd out the documentation it sits
    /// beside.
    func recordSuccessfulInvocation(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tool = trimmed.components(separatedBy: " ").first ?? ""
        guard !tool.isEmpty,
            let index = packages.firstIndex(where: {
                $0.command.caseInsensitiveCompare(tool) == .orderedSame
            }),
            isUserAddedGlobalScope(packages[index])
        else { return }

        var proven = packages[index].provenInvocations
        proven.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        proven.insert(trimmed, at: 0)
        packages[index].provenInvocations = Array(proven.prefix(8))
        savePackages()
    }

    /// Current modification date of the tool's binary, following the symlinks Homebrew and
    /// pipx install.
    nonisolated static func binaryModificationDate(_ path: String?) -> Date? {
        guard let path, !path.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return (try? FileManager.default.attributesOfItem(atPath: resolved))?[.modificationDate]
            as? Date
    }

    /// True when the binary has changed since its help was scanned, so what is cached may
    /// describe a version the user no longer has.
    func helpIsStale(_ package: TerminalPackage) -> Bool {
        guard package.helpText?.isEmpty == false else { return false }
        guard let scanned = package.scannedBinaryModified,
            let current = Self.binaryModificationDate(package.installedPath)
        else { return false }
        return abs(current.timeIntervalSince(scanned)) > 1
    }

    /// Re-scans any pinned tool whose binary has changed since its last scan.
    ///
    /// Only pinned tools: those are the ones whose help reaches a prompt, and rescanning
    /// hundreds of discovered binaries would spawn hundreds of processes for documentation
    /// nobody is reading. Runs at most one tool at a time, off the typing path.
    func refreshStaleHelpForPinnedTools() async {
        let stale = packages.filter { isUserAddedGlobalScope($0) && helpIsStale($0) }
        for package in stale {
            await refreshHelpText(for: package.id)
            await refreshManText(for: package.id)
        }
    }

    /// Reads the tool's man page, once, and caches it.
    ///
    /// `col -b` strips the overstrike backspaces roff emits for bold and underline, which
    /// would otherwise reach the model as "ffiinndd" and burn tokens on nothing. Tools with no
    /// man page exit non-zero and are recorded as having none, so this is not retried on every
    /// scope entry.
    @discardableResult
    func refreshManText(for packageID: UUID) async -> String? {
        guard let index = packages.firstIndex(where: { $0.id == packageID }) else { return nil }
        let command = packages[index].command
        guard !command.isEmpty else { return nil }

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // MANWIDTH keeps lines from wrapping to the terminal width of whoever ran it.
            process.arguments = ["-lc", "MANWIDTH=100 man \(command) 2>/dev/null | col -b"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run {
            guard let i = self.packages.firstIndex(where: { $0.id == packageID }) else { return }
            // Empty string, not nil: "checked, there is none" must be distinguishable from
            // "never checked", or every scope entry pays for the same failed lookup.
            self.packages[i].manText = trimmed
            self.savePackages()
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The stored `--help` for one subcommand, or the top-level help when `subcommand` is
    /// empty. Nil when the tool has never been scanned or that path is not in the tree.
    ///
    /// scanDeepHelp records the tree as sections delimited by `--- <cmd path> --help ---`,
    /// so a section can be handed back whole. That matters: a subcommand's flags are only
    /// trustworthy as the block the tool printed, not as a relevance-ranked excerpt of a 30k
    /// document, which is how invented flags get through.
    func helpSection(command: String, subcommand: String) -> String? {
        guard
            let package = packages.first(where: {
                $0.command.caseInsensitiveCompare(command) == .orderedSame
            }),
            let help = package.helpText, !help.isEmpty
        else { return nil }

        let wanted = subcommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            // Top-level: everything before the first subcommand section.
            return help.components(separatedBy: "\n--- ").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let marker = "\(command) \(wanted) --help ---"
        for part in help.components(separatedBy: "\n--- ") {
            guard part.lowercased().hasPrefix(marker.lowercased()) else { continue }
            let body = part.dropFirst(marker.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    /// Marks a tool as needing a terminal, and persists it.
    func setInteractive(_ isInteractive: Bool, for packageID: UUID) {
        guard let index = packages.firstIndex(where: { $0.id == packageID }) else { return }
        packages[index].isInteractive = isInteractive
        savePackages()
        refreshInteractiveCommands()
        // The mark changed, so the per-subcommand verdicts learned under the old one are no
        // longer evidence about anything.
        CommandInteractivity.forget(tool: packages[index].command)
    }

    /// Directories holding the tools the user deliberately scoped, most-specific first.
    ///
    /// Prepended to PATH for every command DoraX runs. A tool installed to ~/.local/bin (pipx,
    /// cargo, a curl installer) is on PATH only if one of the user's dotfiles puts it there —
    /// so a tool DoraX had scanned, listed with its full path and let the user scope could
    /// still come back "command not found" the moment the model invoked it by name.
    /// Directories that hold user-installed CLIs (not macOS system tools). The single source
    /// of truth for both scanning (`scanForInstalledTools`) and resolving a learned binary's
    /// absolute path when no `installedPath` was recorded — the two must not drift, or a tool
    /// the scanner finds becomes one the runner reports "no executable" for.
    static func userBinDirectories() -> [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/go/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.poetry/bin",
        ]
    }

    func pinnedToolDirectories() -> [String] {
        var seen = Set<String>()
        return packages
            .filter { $0.isEnabled && isUserAddedGlobalScope($0) }
            .compactMap { $0.installedPath }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private let packagesKey = "L2TerminalPackages"

    init() {
        loadPackages()
        refreshInteractiveCommands()
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
        // Directories that contain user-installed tools (not macOS system tools)
        let userBinDirs = Self.userBinDirectories()

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

    /// Which command's scan is running right now — the spinner in Settings needs a state
    /// the view can read, and a scan that takes tens of seconds with no visible feedback
    /// reads as a dead button.
    @Published private(set) var scanningCommands: Set<String> = []

    /// The last scan outcome per command, for the row beneath the Scan button. The old
    /// wording, "Not scanned — no commands learned yet", told a lie for the two cases the
    /// owner then hit: a tool that scanned fine but takes only flags has no subcommands,
    /// and a tool whose `--help` could not be run at all was indistinguishable from
    /// "never scanned".
    @Published private(set) var scanStatuses: [String: String] = [:]

    // Meta-commands that are never worth recursing into
    private static let metaSubcommands: Set<String> = [
        "help", "version", "completion", "completions",
        "__complete", "_complete", "generate-completion-script",
        "man", "doc", "docs"
    ]

    /// A run that goes nowhere must not hang the scan forever: `Obsidian --help` LAUNCHES
    /// the app, writes runtime logs to stdout, and never exits — the scan blocked on it
    /// until the app was quit, with no spinner and no result. This is why no scan of a
    /// GUI "tool" ever came back.
    static let scanTimeoutSeconds = 20

    func scanHelpText(for command: String, binary: String? = nil,
                      run runPath: String? = nil, display: String? = nil) async -> String? {
        let env = buildEnv()
        // `run` is the shell string to execute; `command` (and `display`) name the tool
        // for parsing and logs. They differ when the scan runs a recorded absolute path —
        // "'/Applications/IINA.app/Contents/MacOS/iina-cli' messages" runs, but only
        // `iina-cli messages` parses.
        let run = runPath ?? command
        let bin = binary ?? command.components(separatedBy: " ").first ?? command
        let shown = display ?? command
        let subPath: String = {
            guard shown != bin else { return "" }
            guard shown.hasPrefix(bin + " ") else { return shown }
            return String(shown.dropFirst(bin.count + 1))
        }()

        // Try every known help-invocation pattern, in priority order:
        // 1. cmd sub --help       (universal)
        // 2. cmd sub -h           (short flag)
        // 3. binary help sub1 sub2  (Swift ArgumentParser: ekctl, tuist, mint, …)
        // 4. cmd sub help         (some Go CLIs: kubectl sub help)
        var attempts = ["\(run) --help 2>&1", "\(run) -h 2>&1"]
        if !subPath.isEmpty {
            attempts.append("\(run) help \(subPath) 2>&1")
            attempts.append("\(run) \(subPath) help 2>&1")
        }

        for attempt in attempts {
            let (raw, timedOut) = await runQuiet(attempt, env: env)
            // A tool that hung on one help pattern hangs on them all (a GUI app). Fail
            // fast: the acceptance checks below would otherwise mistake the app's runtime
            // log lines — which the killed run left in the pipe — for help text.
            if timedOut { return nil }
            let output = Self.strippingANSI(raw)
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
    func scanDeepHelp(for command: String, binary: String? = nil,
                      run runPath: String? = nil) async -> String? {
        await MainActor.run { scanLog = [] }
        let actor = ScanAccumulator()
        await scanRecursiveHelp(command: runPath ?? command, binary: binary ?? command,
                                depth: 0, accumulator: actor, display: command)
        let result = await actor.text
        let count  = await actor.count
        await MainActor.run { scanLog.append("━━ Scan complete: \(count) command path\(count == 1 ? "" : "s") ━━") }
        return result.isEmpty ? nil : String(result.prefix(30000))
    }

    /// Recursive parallel worker for scanDeepHelp.
    /// `command` is the runnable form (a quoted absolute path when the scan resolved one);
    /// `display` is the readable path that headers and logs use — `--- iina-cli messages
    /// --help ---` — because the manifest is parsed back out of those headers and must not
    /// contain the quoted path.
    private func scanRecursiveHelp(command: String, binary: String,
                                   depth: Int, accumulator: ScanAccumulator,
                                   display: String) async {
        guard depth < 5 else { return }
        guard await accumulator.markVisited(command) else { return }  // deduplicate

        guard let help = await scanHelpText(for: command, binary: binary,
                                            run: command, display: display) else {
            await MainActor.run { scanLog.append("✗ \(display) (no help)") }
            return
        }
        await MainActor.run { scanLog.append("✓ \(display) --help") }

        let header = depth == 0 ? help : "\n\n--- \(display) --help ---\n\(help)"
        await accumulator.append(header)

        // Stop digging if we've already collected enough text
        guard await accumulator.text.count < 28000 else { return }

        // A command cannot be its own descendant. A leaf's help repeats its own path —
        // "mail-app-cli messages list [flags]", and a description that spells out the
        // invocation ("…use jq: mail-app-cli messages list -a Account | jq") — so reading
        // the second word back as a subcommand sent the scan down a branch that does not
        // exist: "messages list messages", "send send", "open open open".
        let ancestors = Set(
            command.split(separator: " ")
                .dropFirst(binary.split(separator: " ").count)
                .map(String.init))

        let subs = parseSubcommands(from: help, binary: binary)
            .filter { !Self.metaSubcommands.contains($0) }
            .filter { !ancestors.contains($0) }
            // 24 per level, not 12: `mail-app-cli messages` alone has 14 commands, and a
            // cap of 12 dropped "trash" and "unread" — two commands the owner's review
            // then could not name. The 28k text cap above still bounds the whole walk.
            .prefix(24)  // max breadth per level

        // Scan all sibling subcommands in parallel
        await withTaskGroup(of: Void.self) { group in
            for sub in subs {
                let childCmd = "\(command) \(sub)"
                let childDisplay = "\(display) \(sub)"
                group.addTask {
                    await self.scanRecursiveHelp(command: childCmd, binary: binary,
                                                 depth: depth + 1, accumulator: accumulator,
                                                 display: childDisplay)
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
        var sectionRows: [[String]] = []       // harvested inside a commands section
        var invocationRows: [[String]] = []    // lines written as `binary sub …`
        let invocations = Self.invocationNames(in: text, binary: binary)

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
            if inSection && trimmedLine.isEmpty && !sectionRows.isEmpty {
                inSection = false
            }

            // Only inside a commands section, or on a line written as an invocation of the
            // tool. Harvesting every indented line was the rule before, and a tool whose
            // help is nothing but indented flag descriptions — HandBrakeCLI, and most
            // C-era tools — had the first word of each wrapped description line recorded as
            // one of its subcommands. That produced "write", "console", "marks" and
            // "default" for a binary that takes no subcommands at all, and the assistant
            // then worked through the list running `--help` on each invention in turn.
            let tokens = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard !tokens.isEmpty else { continue }
            let startsWithInvocation = tokens.first.map {
                invocations.contains($0.lowercased())
            } ?? false
            if inSection {
                sectionRows.append(tokens)
            } else if startsWithInvocation {
                invocationRows.append(tokens)
            }
        }

        // Prefer a real commands section when the help has one. A cobra / ArgumentParser Long
        // description commonly leads with the binary name ("kubectl controls the Kubernetes
        // cluster manager", "gh works with GitHub…"), and the invocation-prefix heuristic would
        // read its second word ("controls", "works") as a phantom subcommand. That heuristic is
        // only the fallback for help that prints no commands section at all.
        let rows = sectionRows.isEmpty ? invocationRows : sectionRows

        var invocationNames = invocations
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
    ///
    /// Every outcome is recorded in `scanStatuses`, so the Settings row says what happened
    /// instead of leaving "Not scanned" hanging there forever.
    func refreshHelpText(for packageId: UUID) async {
        guard let index = packages.firstIndex(where: { $0.id == packageId }) else { return }
        let original = packages[index]
        guard original.isInstalled else {
            await MainActor.run {
                scanStatuses[original.command] = "Not installed — install it first, then scan."
            }
            return
        }
        // Run through the path recorded at discovery time. The command NAME is resolved
        // on the scan PATH, which misses app-bundle tools — `iina-cli` installs to
        // /Applications/IINA.app/Contents/MacOS — and a name the shell cannot resolve
        // produced "command not found" and, before that was recorded, silence.
        let runPath: String? = {
            if let path = original.installedPath,
               !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return quoted(path)
            }
            if let path = resolveOnScanPath(original.command) { return quoted(path) }
            return nil
        }()
        let runnable = runPath ?? original.command
        let name = original.command  // the bare tool name, for statuses and parsing
        await MainActor.run {
            scanningCommands.insert(name)
            scanStatuses[name] = "Scanning…"
            scanLog = []
        }
        defer { Task { @MainActor in scanningCommands.remove(name) } }

        let topHelp = await scanHelpText(for: runnable, binary: name, display: name)
        guard let topHelp else {
            await MainActor.run {
                // A failed scan must also clear what an earlier scan stored. Obsidian's
                // stored "help" WAS its runtime log lines — the old run accepted them —
                // and the model would keep describing flags the tool does not have.
                packages[index].helpText = nil
                packages[index].subcommands = []
                scanStatuses[name] =
                    "Could not read \(name) --help — the tool may print no help, be a GUI app " +
                    "(scans quit after \(Self.scanTimeoutSeconds)s), or live outside the scanned paths."
            }
            return
        }
        let deepHelp = await scanDeepHelp(for: name, binary: name, run: runnable)
        let paths = learnedCommandPaths(
            topHelp: topHelp, deepHelp: deepHelp ?? topHelp, binary: name)
        packages[index].helpText       = deepHelp ?? topHelp
        packages[index].subcommands    = paths
        packages[index].usagePattern   = parseUsagePattern(from: topHelp)
        // Stamp what was scanned, so a later upgrade is detectable rather than silently
        // leaving the model describing flags the installed version no longer has.
        packages[index].scannedBinaryModified = Self.binaryModificationDate(
            packages[index].installedPath)
        savePackages()
        await MainActor.run {
            scanStatuses[name] = paths.isEmpty
                ? "Scanned — \(name) takes flags, no subcommands (help text learned)."
                : "Scanned — learned \(paths.count) command paths."
        }
    }

    /// SMP-style single-quoted shell word: every `'` becomes `'\''`.
    private func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Resolve a bare command name on the scan PATH — the same list discovery uses.
    private func resolveOnScanPath(_ command: String) -> String? {
        let name = command.components(separatedBy: " ").first ?? command
        for dir in Self.userBinDirectories() + ["/usr/bin", "/bin"] {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The manifest: every command the tool can run — the top-level commands first, then
    /// the nested ones the deep scan walked.
    ///
    /// A CLI whose destructive verbs live under a noun (`mail-app-cli messages delete`)
    /// must show them. The owner's review — "Learned N commands: X read, Y write, Z sends
    /// mail" — is the only place that names what the tool can do, and a manifest that
    /// listed only `messages` said nothing about the delete underneath it.
    func learnedCommandPaths(topHelp: String, deepHelp: String, binary: String) -> [String] {
        let top = parseSubcommands(from: topHelp, binary: binary)
        var paths = top
        var seen = Set(top.map { $0.lowercased() })
        for path in Self.commandPaths(inDeepHelp: deepHelp, binary: binary) {
            let key = path.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            paths.append(path)
        }
        return paths
    }

    /// The command tree the deep scan walked, read from the section headers it writes
    /// (`--- mail-app-cli messages delete --help ---`), as paths relative to the binary.
    ///
    /// The headers ARE the tree: the scan already visited every command path to collect
    /// its help, so the tree is a by-product of work already done.
    static func commandPaths(inDeepHelp help: String, binary: String) -> [String] {
        var paths: [String] = []
        for line in help.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--- "), trimmed.hasSuffix(" --help ---") else { continue }
            let full = String(trimmed.dropFirst(4).dropLast(" --help ---".count))
                .trimmingCharacters(in: .whitespaces)
            var relative = full
            if full.lowercased().hasPrefix(binary.lowercased()) {
                relative = String(full.dropFirst(binary.count)).trimmingCharacters(in: .whitespaces)
            }
            guard !relative.isEmpty else { continue }
            // A meta command is not a thing the tool can do; it is how the tool talks
            // about its own commands.
            let leaf = relative.split(separator: " ").last.map(String.init) ?? relative
            guard !metaSubcommands.contains(leaf) else { continue }
            paths.append(relative)
        }
        return paths
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
        // The user's own binary directories come first, and they are the SAME list
        // discovery and the runtime resolver use. `go install` puts a tool in ~/go/bin,
        // which is on no default PATH, and a scan that cannot find the binary learns
        // nothing at all — the tool was discoverable (the directory is searched) but its
        // help was unreadable, so it never had a command to show.
        env["PATH"] = (Self.userBinDirectories() + ["/usr/bin", "/bin"])
            .joined(separator: ":") + ":" + current
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

    private func runQuiet(_ command: String, env: [String: String]) async -> (String, Bool) {
        await withCheckedContinuation { continuation in
            // MUST dispatch to background queue — waitUntilExit() blocks the thread.
            // Calling it on the Swift concurrency pool starves all async tasks.
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", "exec " + command]
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                var timedOut = false
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + .seconds(Self.scanTimeoutSeconds), execute: watchdog)
                do {
                    try process.run()
                    process.waitUntilExit()
                    watchdog.cancel()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (String(data: data, encoding: .utf8) ?? "", timedOut))
                } catch {
                    watchdog.cancel()
                    continuation.resume(returning: ("", false))
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
            // Subcommands are derived from the stored help, so they are re-derived rather
            // than trusted. A list parsed by an older, looser parser would otherwise outlive
            // the fix to that parser forever: a tool only rescans when its subcommand list
            // is empty, and a wrong list is not an empty one. HandBrakeCLI's invented
            // "write", "console" and "marks" would have stayed on disk permanently.
            packages = decoded.map { package in
                guard let help = package.helpText, !help.isEmpty else { return package }
                var repaired = package
                repaired.subcommands = parseSubcommands(from: help, binary: package.command)
                return repaired
            }
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
    /// Needs a real terminal. Full-screen tools (a pager, an editor, a TUI browser) cannot
    /// run with their output piped: with no tty they either hang waiting for one or emit
    /// escape sequences into what should be an answer. The built-in allowlist cannot know
    /// every such tool, so this lets the user mark one without a code change.
    var isInteractive: Bool = false
    /// `man` output, plain text. Separate from helpText because they fail in opposite
    /// directions: a system tool like `find` prints a usage stub for --help and documents
    /// itself in man, while a modern CLI often ships no man page at all.
    var manText: String?
    /// Modification date of the binary when its help was last scanned. An upgrade rewrites
    /// the file, so a mismatch means the cached help may describe a version that is gone —
    /// flags removed, subcommands renamed. Nil for tools scanned before this was recorded.
    var scannedBinaryModified: Date?
    /// Invocations of this tool that ran and exited zero, most recent first.
    ///
    /// Help says what a tool *can* do; this says what worked on this Mac — the flag spelling
    /// that exists in the installed version, the argument order it accepts. Capped, because
    /// this goes into a prompt.
    var provenInvocations: [String] = []

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
        case isInteractive
        case manText
        case scannedBinaryModified
        case provenInvocations
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
        isInteractive = try container.decodeIfPresent(Bool.self, forKey: .isInteractive) ?? false
        manText = try container.decodeIfPresent(String.self, forKey: .manText)
        scannedBinaryModified = try container.decodeIfPresent(
            Date.self, forKey: .scannedBinaryModified)
        provenInvocations =
            try container.decodeIfPresent([String].self, forKey: .provenInvocations) ?? []
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
        try container.encode(isInteractive, forKey: .isInteractive)
        try container.encodeIfPresent(manText, forKey: .manText)
        try container.encodeIfPresent(scannedBinaryModified, forKey: .scannedBinaryModified)
        try container.encode(provenInvocations, forKey: .provenInvocations)
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
