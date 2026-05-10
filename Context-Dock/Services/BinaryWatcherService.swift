import Foundation
import SwiftUI
import Combine

// MARK: - Binary Watcher Service
// Monitors common binary install directories for newly installed CLI tools
// and offers to add them to L2 automatically.

@MainActor
class BinaryWatcherService: ObservableObject {
    static let shared = BinaryWatcherService()

    @Published var newToolsFound: [DiscoveredTool] = []
    @Published var isWatching = false

    private var sources: [DispatchSourceFileSystemObject] = []
    private var knownExecutables: [String: Set<String>] = [:] // path -> set of filenames
    private let queue = DispatchQueue(label: "com.ilauncher.binarywatcher", qos: .background)

    /// Dynamically resolved at startup from the user's actual shell PATH.
    /// Never hardcoded — covers any tool the user installs anywhere.
    private var watchedPaths: [String] = []

    // MARK: - Discovered Tool Model

    struct DiscoveredTool: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let helpText: String?
        let directory: String
        let discoveredAt: Date
        var isAdded: Bool = false
        var isDismissed: Bool = false
    }

    // MARK: - Lifecycle

    func startWatching() {
        guard !isWatching else { return }
        isWatching = true

        // Resolve the user's real PATH asynchronously, then start watchers.
        // This sources ~/.zshrc / ~/.zprofile so every tool the user ever installed is covered.
        Task {
            let resolved = await Self.resolveWatchPaths()
            watchedPaths = resolved
            print("👀 [BinaryWatcher] Watching \(resolved.count) PATH dirs: \(resolved.joined(separator: ", "))")
            attachWatchers(for: resolved)
        }
    }

    private func attachWatchers(for paths: [String]) {
        let fm = FileManager.default
        for pathString in paths {
            guard fm.fileExists(atPath: pathString) else { continue }
            let initial = executablesIn(pathString)
            knownExecutables[pathString] = initial

            let fd = open(pathString, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: queue)
            let capturedPath = pathString
            source.setEventHandler { [weak self] in self?.directoryChanged(capturedPath) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    // MARK: - Dynamic PATH Resolution

    /// Reads the user's real shell PATH (login shell) + well-known language dirs.
    /// Called once at startup — never hardcoded, works for any tool the user installs.
    static func resolveWatchPaths() async -> [String] {
        var paths = Set<String>()

        // 1. Current process environment (fast, always available)
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        envPath.split(separator: ":").map(String.init).forEach { paths.insert($0) }

        // 2. User's login shell PATH — sources ~/.zprofile, ~/.zshrc, /etc/paths etc.
        //    This is the full PATH the user sees in their terminal.
        let shellPath = await readLoginShellPATH()
        shellPath.split(separator: ":").map(String.init).forEach { paths.insert($0) }

        // 3. Well-known language dirs — even if not in PATH yet (e.g. just installed)
        let home = NSHomeDirectory()
        let extras = [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",          // Rust (rustup)
            "\(home)/go/bin",              // Go
            "\(home)/.npm-global/bin",     // npm -g
            "\(home)/.yarn/bin",           // yarn global
            "\(home)/.pyenv/shims",        // pyenv
            "\(home)/.pyenv/bin",
            "\(home)/.rbenv/shims",        // rbenv
            "\(home)/.rbenv/bin",
            "\(home)/.volta/bin",          // Volta (JS toolchain)
            "\(home)/.deno/bin",           // Deno
            "\(home)/.bun/bin",            // Bun
            "/opt/homebrew/bin",           // Apple Silicon homebrew
            "/opt/homebrew/sbin",
            "/usr/local/bin",              // Intel homebrew / manual installs
        ]
        extras.forEach { paths.insert($0) }

        // Filter to only dirs that exist; skip pure system dirs (no user tools there)
        let systemOnly = Set(["/usr/bin", "/bin", "/sbin", "/usr/sbin",
                              "/usr/libexec", "/System", "/Library"])
        let fm = FileManager.default
        return paths
            .filter { !systemOnly.contains($0) }
            .filter { p in !systemOnly.contains(where: { p.hasPrefix($0) }) }
            .filter { fm.fileExists(atPath: $0) }
            .sorted()
    }

    private static func readLoginShellPATH() async -> String {
        await Task.detached(priority: .utility) {
            // Use the user's actual shell (respects fish, bash, zsh etc.)
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            // -l = login shell → sources profile files → full PATH
            process.arguments = ["-l", "-c", "echo $PATH"]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = Pipe()  // suppress errors silently
            guard (try? process.run()) != nil else { return "" }
            // 3-second timeout so a broken shell profile doesn't hang startup
            let deadline = DispatchTime.now() + .seconds(3)
            let sema = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in sema.signal() }
            _ = sema.wait(timeout: deadline)
            if process.isRunning { process.terminate() }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }

    func stopWatching() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        knownExecutables.removeAll()
        isWatching = false
    }

    // MARK: - Directory Change Handler

    private func directoryChanged(_ dirPath: String) {
        let current = executablesIn(dirPath)
        let previous = knownExecutables[dirPath] ?? []
        let newOnes = current.subtracting(previous)
        knownExecutables[dirPath] = current

        for name in newOnes where !name.hasPrefix(".") {
            let toolPath = dirPath + "/" + name
            Task { await self.handleNewBinary(name: name, path: toolPath, directory: dirPath) }
        }
    }

    private func executablesIn(_ path: String) -> Set<String> {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        return Set(contents.filter { name in
            let fullPath = path + "/" + name
            return FileManager.default.isExecutableFile(atPath: fullPath)
        })
    }

    // MARK: - New Binary Handler

    private func handleNewBinary(name: String, path: String, directory: String) async {
        // Skip if already tracked
        let pm = TerminalPackageManager.shared
        if pm.packages.contains(where: { $0.command == name }) { return }

        // Skip common system binaries that shouldn't be in L2
        let skipList = Set(["sh", "bash", "zsh", "fish", "python", "python3", "ruby",
                             "perl", "node", "java", "cc", "c++", "clang", "swift", "make",
                             "ld", "ar", "nm", "strip", "lipo", "ranlib", "dsymutil",
                             "install", "ln", "rm", "cp", "mv", "ls", "cat", "grep"])
        guard !skipList.contains(name) else { return }

        print("🆕 [BinaryWatcher] New binary detected: \(name)")

        // Run --help scan in background
        let helpText = await pm.scanHelpText(for: name)

        let tool = DiscoveredTool(
            name: name,
            path: path,
            helpText: helpText,
            directory: directory,
            discoveredAt: Date()
        )

        newToolsFound.append(tool)

        // Post notification for the banner UI
        NotificationCenter.default.post(
            name: .newBinaryDiscovered,
            object: nil,
            userInfo: ["toolName": name, "toolPath": path]
        )
    }

    // MARK: - Add Tool to L2

    func addToL2(_ tool: DiscoveredTool) async {
        let pm = TerminalPackageManager.shared

        // If helpText is nil (fast-path startup discovery), fetch it now on demand
        let helpText: String?
        if tool.helpText == nil {
            helpText = await pm.scanHelpText(for: tool.name)
        } else {
            helpText = tool.helpText
        }

        let description = extractDescription(from: helpText ?? "", toolName: tool.name)
        let keywords = extractKeywords(from: helpText ?? "", toolName: tool.name)

        var package = TerminalPackage(
            name: tool.name,
            command: tool.name,
            description: description,
            installedPath: tool.path,
            keywords: keywords,
            helpText: helpText
        )

        if let ht = helpText {
            package.subcommands = pm.parseSubcommands(from: ht)
            package.usagePattern = pm.parseUsagePattern(from: ht)
        }

        pm.addPackage(package)

        // Mark as added
        if let index = newToolsFound.firstIndex(where: { $0.id == tool.id }) {
            newToolsFound[index].isAdded = true
        }

        // Intent auto-assignment (keyword-based — fast, runs now)
        await L2IntentRegistry.shared.autoAssignIntent(for: package)

        // AI manifest generation (slow — runs in background, updates DB when done)
        if let ht = helpText {
            Task {
                await ManifestGenerationService.shared.generateAndSave(
                    toolName: tool.name,
                    binaryPath: tool.path,
                    helpText: ht
                )
            }
        }

        print("✅ [BinaryWatcher] Added '\(tool.name)' to L2 packages")

        // Auto-register in FileTypeToolRegistry (marks it installed if in built-in catalog)
        FileTypeToolRegistry.shared.autoRegister(toolName: tool.name)
    }

    func dismiss(_ tool: DiscoveredTool) {
        newToolsFound.removeAll { $0.id == tool.id }
    }

    func dismissAll() {
        newToolsFound.removeAll()
    }

    // MARK: - Manual Scan

    /// Scan watched directories and surface executables not yet in the L2 package DB.
    /// Pass `skipHelpScan: true` for startup (avoids spawning 100+ --help subprocesses at once).
    func scanNow(skipHelpScan: Bool = false) async {
        let skipList: Set<String> = [
            "sh", "bash", "zsh", "fish", "dash", "tcsh", "python", "python3", "ruby",
            "perl", "perl5", "node", "nodejs", "java", "deno", "lua", "lua5.4",
            "cc", "c++", "clang", "clang++", "gcc", "g++", "swift", "swiftc",
            "make", "cmake", "ninja", "meson", "bazel", "xcodebuild",
            "ld", "lld", "ar", "nm", "strip", "lipo", "ranlib", "dsymutil",
            "install", "install_name_tool", "otool", "codesign",
            "ln", "rm", "cp", "mv", "ls", "cat", "grep", "find", "sed", "awk",
            "head", "tail", "sort", "uniq", "cut", "tr", "wc", "tee",
            "git", "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat",
            "tar", "zip", "unzip", "gzip", "gunzip", "xz", "bzip2", "zstd", "lz4",
            "glib-mkenums", "glib-genmarshal", "glib-compile-resources",
            "glib-compile-schemas", "gdbus-codegen", "gobject-query",
            "fourcc2pixfmt", "prun", "pctrl", "pquery", "palloc",
            "pkg-config", "pkgconf", "autoconf", "automake", "libtool", "aclocal",
            "autoreconf", "autoupdate", "autoscan", "ifnames",
            "msgfmt", "msginit", "msgmerge", "msgcat", "xgettext", "envsubst",
            "openssl", "libassuan-config", "gpg-error-config",
        ]

        // Ensure paths are resolved (in case scanNow is called before startWatching completes)
        if watchedPaths.isEmpty {
            watchedPaths = await Self.resolveWatchPaths()
        }
        // Capture registered commands before going off-actor
        let registeredCommands = Set(TerminalPackageManager.shared.packages.map { $0.command })
        let pathsToScan = watchedPaths

        // Heavy file I/O on background thread — never block the main actor
        let discovered: [(name: String, path: String, dir: String)] = await Task.detached(priority: .utility) {
            var results: [(name: String, path: String, dir: String)] = []
            let fm = FileManager.default
            let maxPerScan = 20

            for pathString in pathsToScan {
                guard fm.fileExists(atPath: pathString),
                      let contents = try? fm.contentsOfDirectory(atPath: pathString)
                else { continue }

                let executables = contents.filter { name in
                    let fullPath = pathString + "/" + name
                    return fm.isExecutableFile(atPath: fullPath)
                }

                for name in executables {
                    guard results.count < maxPerScan else { break }
                    guard !name.hasPrefix("."),
                          !skipList.contains(name),
                          !name.hasSuffix("-config"),
                          !name.hasPrefix("lib"),
                          name.count <= 30,
                          !registeredCommands.contains(name)
                    else { continue }
                    results.append((name: name, path: pathString + "/" + name, dir: pathString))
                }
            }
            return results
        }.value

        // Update state on main actor
        for item in discovered {
            knownExecutables[item.dir, default: []].insert(item.name)
            if skipHelpScan {
                if !newToolsFound.contains(where: { $0.name == item.name }) {
                    let tool = DiscoveredTool(name: item.name, path: item.path,
                                             helpText: nil, directory: item.dir,
                                             discoveredAt: Date())
                    newToolsFound.append(tool)
                    NotificationCenter.default.post(
                        name: .newBinaryDiscovered, object: nil,
                        userInfo: ["toolName": item.name, "toolPath": item.path]
                    )
                }
            } else {
                await handleNewBinary(name: item.name, path: item.path, directory: item.dir)
            }
        }

        if !discovered.isEmpty {
            print("🔍 [BinaryWatcher] scanNow found \(discovered.count) untracked tool(s)")
        }
    }

    // MARK: - Keyword / Description Extraction

    private func extractDescription(from helpText: String, toolName: String) -> String {
        guard !helpText.isEmpty else { return "\(toolName) - command line tool" }

        let lines = helpText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count > 10
                && !trimmed.lowercased().hasPrefix(toolName.lowercased())
                && !trimmed.hasPrefix("-")
                && !trimmed.lowercased().hasPrefix("usage")
                && !trimmed.lowercased().hasPrefix("version") {
                return String(trimmed.prefix(120))
            }
        }
        return "\(toolName) - command line tool"
    }

    private func extractKeywords(from helpText: String, toolName: String) -> [String] {
        var keywords: Set<String> = []

        let intentKeywords: [String: [String]] = [
            "music": ["play", "music", "song", "audio", "playlist"],
            "video": ["video", "download", "youtube", "stream"],
            "download": ["download", "fetch", "get", "http"],
            "image": ["image", "photo", "picture", "convert", "resize"],
            "git": ["git", "commit", "branch", "merge"],
            "compress": ["zip", "tar", "compress", "archive", "extract"],
            "system": ["cpu", "memory", "disk", "process", "monitor"],
            "network": ["network", "http", "request", "api"],
            "timer": ["timer", "alarm", "remind", "countdown"],
            "format": ["json", "yaml", "xml", "format", "parse"]
        ]

        let helpLower = helpText.lowercased()
        for (keyword, variants) in intentKeywords {
            if variants.contains(where: { helpLower.contains($0) }) {
                keywords.insert(keyword)
            }
        }

        // Add tool name parts
        let nameParts = toolName.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "-_"))
            .filter { $0.count > 2 && !["cli", "cmd", "app", "tool"].contains($0) }
        nameParts.forEach { keywords.insert($0) }

        return Array(keywords).prefix(8).map { $0 }
    }
}

// MARK: - Notification Names

// MARK: - Discovery Banner View

struct BinaryDiscoveryBanner: View {
    @ObservedObject var watcher = BinaryWatcherService.shared
    @State private var isExpanded = false

    var pendingTools: [BinaryWatcherService.DiscoveredTool] {
        watcher.newToolsFound.filter { !$0.isAdded }
    }

    var body: some View {
        if !pendingTools.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.yellow)
                    Text("\(pendingTools.count) new tool\(pendingTools.count > 1 ? "s" : "") detected")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(action: { withAnimation(.easeInOut) { isExpanded.toggle() } }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    Button(action: { watcher.dismissAll() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if isExpanded {
                    Divider()
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(pendingTools) { tool in
                                DiscoveredToolRow(tool: tool)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 180)
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.yellow.opacity(0.5), lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct DiscoveredToolRow: View {
    let tool: BinaryWatcherService.DiscoveredTool
    @ObservedObject var watcher = BinaryWatcherService.shared

    var body: some View {
        HStack {
            Image(systemName: "terminal.fill")
                .foregroundColor(.green)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if let first = tool.helpText?.components(separatedBy: .newlines)
                    .first(where: { $0.trimmingCharacters(in: .whitespaces).count > 5 }) {
                    Text(first)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(tool.directory)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Add to L2") {
                Task { await watcher.addToL2(tool) }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(.green)

            Button(action: { watcher.dismiss(tool) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
