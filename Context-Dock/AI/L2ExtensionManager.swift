// L2ExtensionManager.swift
// ILauncher
//
// User-created custom tools for the L2 terminal layer.
// Each extension is a folder containing extension.json + a script file.
// The AI can call them as first-class tools alongside run_command.
//
// Directory: ~/Library/Application Support/ILauncher/L2Extensions/
// Format:
//   my-tool/
//     extension.json   ← metadata + parameter schema
//     script.sh        ← executable script (bash, python, etc.)

import Foundation
import AppKit
import Combine

// MARK: - Extension Models

struct L2ExtensionParameter: Codable {
    let type: String          // "string", "number", "boolean"
    let description: String
    let required: Bool
    let defaultValue: String? // JSON string representation of default

    enum CodingKeys: String, CodingKey {
        case type, description, required
        case defaultValue = "default"
    }
}

struct L2Extension: Codable, Identifiable {
    var id: UUID = UUID()
    let toolName: String        // snake_case, unique — used in AI tool schema
    let displayName: String     // shown in UI
    let description: String     // shown to AI + in UI
    let version: String
    let author: String
    let icon: String            // SF Symbol name
    let parameters: [String: L2ExtensionParameter]
    let script: String          // filename relative to extension folder
    let scriptType: ScriptType
    let taskCategory: String?   // optional: matches TerminalPackageManager task types
    let triggers: [String]      // keywords for auto-matching
    /// Apps this extension activates for. Supports both old `context_app` (single string)
    /// and new `context_apps` (array). Empty = always available.
    let contextApps: [String]

    /// First context app — used for backward-compat display (single-app pickers, etc.)
    var contextApp: String? { contextApps.first }

    // Runtime-set after loading
    var folderPath: URL?
    var isEnabled: Bool = true
    var lastUsed: Date?
    var usageCount: Int = 0

    enum ScriptType: String, Codable {
        case bash       = "bash"
        case python     = "python"
        case ruby       = "ruby"
        case node       = "node"
        case appleScript = "applescript"
        case jxa        = "jxa"
    }

    enum CodingKeys: String, CodingKey {
        case toolName     = "tool_name"
        case displayName  = "display_name"
        case description, version, author, icon, parameters, script
        case scriptType   = "script_type"
        case taskCategory = "task_category"
        case triggers
        case contextApp   = "context_app"    // old single-app field (read only)
        case contextApps  = "context_apps"   // new multi-app field
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolName     = try c.decode(String.self,                           forKey: .toolName)
        displayName  = try c.decode(String.self,                           forKey: .displayName)
        description  = try c.decode(String.self,                           forKey: .description)
        version      = try c.decodeIfPresent(String.self,                  forKey: .version) ?? "1.0"
        author       = try c.decodeIfPresent(String.self,                  forKey: .author)  ?? ""
        icon         = try c.decodeIfPresent(String.self,                  forKey: .icon)    ?? "hammer"
        parameters   = try c.decodeIfPresent([String: L2ExtensionParameter].self, forKey: .parameters) ?? [:]
        script       = try c.decode(String.self,                           forKey: .script)
        scriptType   = try c.decodeIfPresent(ScriptType.self,              forKey: .scriptType) ?? .bash
        taskCategory = try c.decodeIfPresent(String.self,                  forKey: .taskCategory)
        triggers     = try c.decodeIfPresent([String].self,                forKey: .triggers) ?? []
        // Multi-app: prefer `context_apps` array, fall back to wrapping old `context_app` string
        if let arr = try c.decodeIfPresent([String].self, forKey: .contextApps), !arr.isEmpty {
            contextApps = arr
        } else if let single = try c.decodeIfPresent(String.self, forKey: .contextApp), !single.isEmpty {
            contextApps = [single]
        } else {
            contextApps = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolName,     forKey: .toolName)
        try c.encode(displayName,  forKey: .displayName)
        try c.encode(description,  forKey: .description)
        try c.encode(version,      forKey: .version)
        try c.encode(author,       forKey: .author)
        try c.encode(icon,         forKey: .icon)
        try c.encode(parameters,   forKey: .parameters)
        try c.encode(script,       forKey: .script)
        try c.encode(scriptType,   forKey: .scriptType)
        try c.encodeIfPresent(taskCategory, forKey: .taskCategory)
        try c.encode(triggers,     forKey: .triggers)
        try c.encode(contextApps,  forKey: .contextApps)
        // Also write single-app for compat with older readers
        try c.encodeIfPresent(contextApps.first, forKey: .contextApp)
    }

    // Computed: full path to script file
    var scriptURL: URL? {
        folderPath?.appendingPathComponent(script)
    }

    // Computed: interpreter argv prefix for scriptType. The script path is appended
    // as a separate argument by the caller — never concatenated into a command string,
    // so a script filename containing quotes or $( ) cannot break out into a shell.
    var interpreterArgv: [String] {
        switch scriptType {
        case .bash:        return ["/bin/bash"]
        case .python:      return ["/usr/bin/env", "python3"]
        case .ruby:        return ["/usr/bin/env", "ruby"]
        case .node:        return ["/usr/bin/env", "node"]
        case .appleScript: return ["/usr/bin/osascript"]
        case .jxa:         return ["/usr/bin/osascript", "-l", "JavaScript"]
        }
    }
}

// MARK: - L2ExtensionManager

@MainActor
class L2ExtensionManager: ObservableObject {

    static let shared = L2ExtensionManager()

    @Published var extensions: [L2Extension] = []
    @Published var isLoading = false

    // ~/Library/Application Support/ILauncher/L2Extensions/
    let extensionsDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("ILauncher/L2Extensions", isDirectory: true)
    }()

    private init() {
        Task { await loadExtensions() }
    }

    // MARK: - Loading

    func loadExtensions() async {
        isLoading = true
        defer { isLoading = false }

        // Create directory + starters on first launch
        createDirectoryIfNeeded()

        var loaded: [L2Extension] = []
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            extensions = []
            return
        }

        for folderURL in contents {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let jsonURL = folderURL.appendingPathComponent("extension.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  var ext = try? JSONDecoder().decode(L2Extension.self, from: data)
            else { continue }

            ext.folderPath = folderURL
            loaded.append(ext)
        }

        // Sort by display name
        extensions = loaded.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Execution

    /// Execute a custom extension with given arguments. Returns (success, output).
    func execute(toolName: String, arguments: [String: Any]) async -> (Bool, String) {
        guard let ext = extensions.first(where: { $0.toolName == toolName && $0.isEnabled }),
              let scriptURL = ext.scriptURL,
              FileManager.default.fileExists(atPath: scriptURL.path)
        else {
            return (false, "L2 Extension '\(toolName)' not found or script missing")
        }

        // Build environment: pass parameters as uppercased env vars
        var env = ProcessInfo.processInfo.environment
        let homebrewPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        env["PATH"] = homebrewPath + ":/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")

        // Inject frontmost app context (the app active before ILauncher opened)
        if let app = AppDelegate.shared?.previousFrontmostApp {
            env["FRONTMOST_APP"]    = app.localizedName ?? ""
            env["FRONTMOST_BUNDLE"] = app.bundleIdentifier ?? ""
        }

        // Inject AX-read context: URL, window title, selected text
        let axCtx = AXContextReader.shared.current
        if let url   = axCtx.currentURL   { env["CURRENT_URL"]      = url }
        if let title = axCtx.windowTitle  { env["WINDOW_TITLE"]     = title }
        if let sel   = axCtx.selectedText { env["AX_SELECTED_TEXT"] = sel }

        for (key, value) in arguments {
            env[key.uppercased()] = "\(value)"
        }

        // Fill in defaults for parameters not provided
        for (paramName, paramDef) in ext.parameters {
            if arguments[paramName] == nil, let def = paramDef.defaultValue {
                env[paramName.uppercased()] = def
            }
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError  = stderr
        process.environment    = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        // Run script via its interpreter, always as argv — never through a shell.
        let argv = ext.interpreterArgv
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst()) + [scriptURL.path]

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outStr  = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errStr  = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let success = process.terminationStatus == 0
            let output  = success ? outStr : (errStr.isEmpty ? outStr : errStr)

            // Update usage stats
            if let idx = extensions.firstIndex(where: { $0.toolName == toolName }) {
                extensions[idx].lastUsed = Date()
                extensions[idx].usageCount += 1
            }

            return (success, output.isEmpty ? "(no output)" : output)

        } catch {
            return (false, "Failed to run extension: \(error.localizedDescription)")
        }
    }

    // MARK: - Tool Schema Generation

    /// Returns the tool definition dict for a given provider format.
    /// Extensions with `contextApp` are only included when that app is currently frontmost.
    func toolSchemas(for provider: ProviderFormat) -> [[String: Any]] {
        let frontApp = AppDelegate.shared?.previousFrontmostApp
            ?? NSWorkspace.shared.frontmostApplication
        let frontBundleId = frontApp?.bundleIdentifier ?? ""
        let frontName = frontApp?.localizedName ?? ""

        return extensions.filter { ext in
            guard ext.isEnabled else { return false }
            guard let required = ext.contextApp, !required.isEmpty else { return true }
            // Match by bundle ID or app name (case-insensitive)
            return required == frontBundleId
                || required.lowercased() == frontName.lowercased()
        }.map { ext in
            toolSchema(for: ext, provider: provider)
        }
    }

    enum ProviderFormat { case openAI, anthropic, gemini }

    private func toolSchema(for ext: L2Extension, provider: ProviderFormat) -> [String: Any] {
        let properties: [String: Any] = ext.parameters.mapValues { param -> [String: Any] in
            var p: [String: Any] = ["type": param.type, "description": param.description]
            if let def = param.defaultValue { p["default"] = def }
            return p
        }
        let required = ext.parameters.filter { $0.value.required }.map { $0.key }

        let paramSchema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": required
        ]

        switch provider {
        case .openAI:
            return [
                "type": "function",
                "function": [
                    "name": ext.toolName,
                    "description": ext.description,
                    "parameters": paramSchema
                ]
            ]
        case .anthropic:
            return [
                "name": ext.toolName,
                "description": ext.description,
                "input_schema": paramSchema
            ]
        case .gemini:
            return [
                "name": ext.toolName,
                "description": ext.description,
                "parameters": paramSchema
            ]
        }
    }

    // MARK: - Install / Remove

    func openExtensionsFolder() {
        NSWorkspace.shared.open(extensionsDirectory)
    }

    func removeExtension(_ ext: L2Extension) {
        guard let folder = ext.folderPath else { return }
        try? FileManager.default.removeItem(at: folder)
        extensions.removeAll { $0.toolName == ext.toolName }
    }

    func toggleEnabled(_ ext: L2Extension) {
        if let idx = extensions.firstIndex(where: { $0.toolName == ext.toolName }) {
            extensions[idx].isEnabled.toggle()
        }
    }

    // MARK: - Directory Setup + Starter Extensions

    private func createDirectoryIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: extensionsDirectory.path) else { return }
        try? fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        createStarterExtensions()
    }

    private func createStarterExtensions() {
        createExtension(
            folderName: "compress-image",
            json: """
            {
              "tool_name": "compress_image",
              "display_name": "Compress Image",
              "description": "Compress an image file to reduce file size. Supports JPEG, PNG. Saves a new file with _compressed suffix.",
              "version": "1.0",
              "author": "ILauncher",
              "icon": "photo.fill",
              "parameters": {
                "file_path": {
                  "type": "string",
                  "description": "Full path to the image file to compress",
                  "required": true
                },
                "quality": {
                  "type": "number",
                  "description": "JPEG quality level from 0 to 100. Default is 70.",
                  "required": false,
                  "default": "70"
                }
              },
              "script": "compress.sh",
              "script_type": "bash",
              "task_category": "compress image",
              "triggers": ["compress", "image", "photo", "reduce", "resize", "optimize"]
            }
            """,
            scripts: [
                "compress.sh": """
                #!/bin/bash
                # Compress Image — L2 Extension
                # Parameters: FILE_PATH, QUALITY (default 70)

                FILE="${FILE_PATH}"
                QUALITY="${QUALITY:-70}"

                if [ -z "$FILE" ]; then
                  echo "Error: FILE_PATH not provided"
                  exit 1
                fi

                if [ ! -f "$FILE" ]; then
                  echo "Error: File not found: $FILE"
                  exit 1
                fi

                EXT="${FILE##*.}"
                BASE="${FILE%.*}"
                OUTPUT="${BASE}_compressed.${EXT}"

                sips -s format jpeg -s formatOptions "$QUALITY" "$FILE" --out "$OUTPUT" 2>&1
                if [ $? -eq 0 ]; then
                  ORIG=$(du -sh "$FILE" | cut -f1)
                  NEW=$(du -sh "$OUTPUT" | cut -f1)
                  echo "Compressed: $FILE ($ORIG) → $OUTPUT ($NEW)"
                else
                  echo "Compression failed"
                  exit 1
                fi
                """
            ]
        )

        createExtension(
            folderName: "file-stats",
            json: """
            {
              "tool_name": "file_stats",
              "display_name": "File Stats",
              "description": "Get detailed statistics about a file or directory: size, item count, file types breakdown, largest files.",
              "version": "1.0",
              "author": "ILauncher",
              "icon": "chart.bar.fill",
              "parameters": {
                "path": {
                  "type": "string",
                  "description": "Full path to the file or directory to analyze",
                  "required": true
                }
              },
              "script": "stats.sh",
              "script_type": "bash",
              "task_category": "file info",
              "triggers": ["stats", "size", "analyze", "folder", "directory", "how big", "largest"]
            }
            """,
            scripts: [
                "stats.sh": """
                #!/bin/bash
                # File Stats — L2 Extension
                # Parameter: PATH

                TARGET="${PATH_:-$PATH}"
                # PATH_ used to avoid overriding system PATH env var
                TARGET="${TARGET:-$1}"

                if [ -z "$TARGET" ]; then
                  echo "Error: PATH not provided"
                  exit 1
                fi

                if [ ! -e "$TARGET" ]; then
                  echo "Error: Path not found: $TARGET"
                  exit 1
                fi

                echo "=== Stats for: $TARGET ==="
                echo ""

                TOTAL=$(du -sh "$TARGET" 2>/dev/null | cut -f1)
                echo "Total size: $TOTAL"

                if [ -d "$TARGET" ]; then
                  COUNT=$(find "$TARGET" -maxdepth 1 | wc -l | xargs)
                  echo "Items (top level): $((COUNT - 1))"
                  echo ""
                  echo "--- Top 10 largest items ---"
                  du -sh "$TARGET"/* 2>/dev/null | sort -rh | head -10
                  echo ""
                  echo "--- File types ---"
                  find "$TARGET" -maxdepth 2 -type f | sed 's/.*\\.//' | sort | uniq -c | sort -rn | head -10
                fi
                """
            ]
        )

        createExtension(
            folderName: "search-web",
            json: """
            {
              "tool_name": "search_web",
              "display_name": "Search Web",
              "description": "Open a web search in the default browser for a given query. Supports Google, DuckDuckGo, YouTube, GitHub.",
              "version": "1.0",
              "author": "ILauncher",
              "icon": "magnifyingglass",
              "parameters": {
                "query": {
                  "type": "string",
                  "description": "The search query",
                  "required": true
                },
                "engine": {
                  "type": "string",
                  "description": "Search engine: google, duckduckgo, youtube, github. Default: google",
                  "required": false,
                  "default": "google"
                }
              },
              "script": "search.sh",
              "script_type": "bash",
              "task_category": "web search",
              "triggers": ["search", "google", "youtube", "find", "look up", "browse"]
            }
            """,
            scripts: [
                "search.sh": """
                #!/bin/bash
                # Search Web — L2 Extension
                # Parameters: QUERY, ENGINE (default: google)

                QUERY="${QUERY}"
                ENGINE="${ENGINE:-google}"

                if [ -z "$QUERY" ]; then
                  echo "Error: QUERY not provided"
                  exit 1
                fi

                ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$QUERY'))")

                case "$ENGINE" in
                  youtube)    URL="https://www.youtube.com/results?search_query=${ENCODED}" ;;
                  github)     URL="https://github.com/search?q=${ENCODED}" ;;
                  duckduckgo) URL="https://duckduckgo.com/?q=${ENCODED}" ;;
                  *)          URL="https://www.google.com/search?q=${ENCODED}" ;;
                esac

                open "$URL"
                echo "Opened $ENGINE search for: $QUERY"
                """
            ]
        )

        createExtension(
            folderName: "git-summary",
            json: """
            {
              "tool_name": "git_summary",
              "display_name": "Git Summary",
              "description": "Show a comprehensive summary of a git repository: current branch, status, recent commits, and remote info.",
              "version": "1.0",
              "author": "ILauncher",
              "icon": "arrow.triangle.branch",
              "parameters": {
                "repo_path": {
                  "type": "string",
                  "description": "Path to the git repository. Defaults to current directory.",
                  "required": false,
                  "default": "."
                }
              },
              "script": "summary.sh",
              "script_type": "bash",
              "task_category": "git",
              "triggers": ["git", "repo", "branch", "commits", "changes", "status"]
            }
            """,
            scripts: [
                "summary.sh": """
                #!/bin/bash
                # Git Summary — L2 Extension
                # Parameter: REPO_PATH (default: .)

                REPO="${REPO_PATH:-.}"

                if [ ! -d "$REPO/.git" ]; then
                  echo "Error: Not a git repository: $REPO"
                  exit 1
                fi

                cd "$REPO" || exit 1

                echo "=== Git Summary: $(basename $(pwd)) ==="
                echo ""
                echo "Branch: $(git branch --show-current)"
                echo "Remote: $(git remote get-url origin 2>/dev/null || echo 'none')"
                echo ""

                echo "--- Status ---"
                git status --short
                echo ""

                echo "--- Last 5 commits ---"
                git log --oneline -5
                echo ""

                AHEAD=$(git rev-list @{u}..HEAD 2>/dev/null | wc -l | xargs)
                BEHIND=$(git rev-list HEAD..@{u} 2>/dev/null | wc -l | xargs)
                if [ "$AHEAD" -gt 0 ] || [ "$BEHIND" -gt 0 ]; then
                  echo "--- Remote sync ---"
                  [ "$AHEAD" -gt 0 ]  && echo "$AHEAD commit(s) ahead of remote"
                  [ "$BEHIND" -gt 0 ] && echo "$BEHIND commit(s) behind remote"
                fi
                """
            ]
        )
    }

    private func createExtension(folderName: String, json: String, scripts: [String: String]) {
        let folder = extensionsDirectory.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Write extension.json
        let jsonURL = folder.appendingPathComponent("extension.json")
        try? json.trimmingCharacters(in: .whitespacesAndNewlines)
                 .data(using: .utf8)?
                 .write(to: jsonURL)

        // Write script files and make executable
        for (filename, content) in scripts {
            let scriptURL = folder.appendingPathComponent(filename)
            try? content.data(using: .utf8)?.write(to: scriptURL)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        }
    }
}
