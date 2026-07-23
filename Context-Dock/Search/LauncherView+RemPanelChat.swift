import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension LauncherView {
    // MARK: - rem-powered Reminders panel chat

    /// Appends a message to the panel chat and immediately persists it to disk.
    func appendPanelMessage(_ msg: AIChatMessage) {
        remPanelChatMessages.append(msg)
        if let key = searchState.activeSmartQueryKey ?? searchState.contextApp?.key {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: key)
        }
    }

    func handleRemPanelQuery() {
        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        remPanelAITask?.cancel()
        appendPanelMessage(AIChatMessage(role: .user, content: query))
        remPanelIsProcessing = true
        // Add a separator between query sessions so history is readable
        let ck = prepareScopedWorkspaceTerminal()
        if !(panelConsoleLinesMap[ck]?.isEmpty ?? true) {
            panelConsoleLinesMap[ck, default: []].append(
                (line: "────────────────────", isCommand: false))
        }
        searchState.query = ""

        // Wire live streaming into this panel's terminal drawer
        TerminalAIBridge.shared.streamLineHandler = { line in
            DispatchQueue.main.async {
                // Streaming lines go into the drawer live as they arrive
                self.panelConsoleLinesMap[ck, default: []].append((line: line, isCommand: false))
                self.panelShowConsoleMap[ck] = true
            }
        }

        let provider = settings.selectedAIProvider
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        if provider == .shortcuts {
            remPanelChatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "This panel doesn't support the Shortcuts provider. Select On-Device, OpenAI, Anthropic, Gemini, or Ollama in Settings → AI Provider.",
                    isError: true))
            remPanelIsProcessing = false
            return
        }

        // Only OpenAI / Anthropic / Gemini require an API key — bridges (VibeProxy),
        // Ollama, and OpenAI-compatible endpoints work without one.
        if provider.requiresAPIKey && apiKey == nil {
            remPanelChatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "No API key found for \(provider.displayName). Add your key in Settings → AI Provider.",
                    isError: true))
            remPanelIsProcessing = false
            return
        }

        // Build system prompt dynamically — Reminders uses hard-coded rem knowledge,
        // Build system prompt — covers reminders, apps, files, contacts, etc.
        // searchState.activeSmartQueryKey is set when user explicitly opens an app panel;
        // fall back to autoDetectedAppKey (set from NSWorkspace app-switch observer).
        let activeKey =
            searchState.activeSmartQueryKey ?? settings.autoDetectedAppKey ?? "reminders"

        // Any browser scope (DuckDuckGo, Chrome, Arc… not just Safari) gets a page
        // assistant. Page content comes from Safari's bridge when available, else from
        // MarkItDown converting the live URL — so "about this page" works everywhere.
        let scopedBrowserBundle =
            l2.targetApp?.bundleId
            ?? AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier ?? ""
        let isBrowserScope =
            activeKey != "safari"
            && SelectedContextResolver.isBrowserBundleId(scopedBrowserBundle)

        let ctx = searchState.contextApp
        let appLabel =
            ctx?.name ?? settings.customAppEntries.first(where: { $0.key == activeKey })?.label
            ?? activeKey.capitalized
        if executeScopedMenuIntentIfAvailable(
            query: query,
            activeKey: activeKey,
            contextApp: ctx,
            appLabel: appLabel
        ) {
            return
        }
        // For file/folder contexts, also include "Files & Folders" (finder) extensions
        let isFileContext =
            ctx?.resultType == .folder || ctx?.resultType == .file || ctx?.resultType == .document
        // Use scored + installed-only extensions (top 5 most relevant to the query)
        let _userQuery = query  // captured before closures
        let toolExts =
            settings.topExtensions(for: activeKey, query: _userQuery, maxCount: 5)
            + (isFileContext
                ? settings.topExtensions(for: "finder", query: _userQuery, maxCount: 3).filter {
                    ext in
                    !settings.topExtensions(for: activeKey, query: _userQuery, maxCount: 5)
                        .contains(where: { $0.toolName == ext.toolName })
                } : [])
        let contextualCliPackages = contextualCLIPackages(for: ctx, query: _userQuery)

        // AI Prompt extensions — always active. For file/folder contexts also include "finder" prompts.
        let promptExts: [AppToolExtension] = {
            var exts = settings.activePromptExtensions(for: activeKey)
            if isFileContext && activeKey != "finder" {
                let finderPrompts = settings.activePromptExtensions(for: "finder")
                    .filter { fp in !exts.contains(where: { $0.id == fp.id }) }
                exts += finderPrompts
            }
            return exts
        }()

        let systemPrompt: String
        // Generic context for non-app results (files, folders, contacts, etc.)
        let isGenericContext =
            ctx != nil && ctx?.resultType != .application && activeKey != "reminders"
        let globalInlineCLICommand: String? = {
            guard let bundleId = globalInlineAppScope?.bundleId,
                bundleId.hasPrefix("cli://")
            else { return nil }
            let command = String(bundleId.dropFirst("cli://".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }()
        // Core tool rules — appended to every system prompt
        let toolRules = """

            ══ EXECUTION RULES — READ CAREFULLY ══
            You have exactly THREE callable tools: run_command, spawn_worker, send_keys.
            DO NOT invent other tool names. DO NOT call "reminders", "remind", "notes", or any
            tool name from the AVAILABLE TOOLS section — those are shell commands to run INSIDE run_command.

            ✅ CORRECT — silently invoke the tool:
               run_command(command: "osascript -l JavaScript /path/script.js \\"list today\\"")
            ❌ WRONG — writing JSON or describing what you'll do:
               {"name": "reminders", "parameters": {...}}
               "I will call the reminders tool with..."
               "Here is the function call: ..."

            RULE: ACT FIRST, EXPLAIN AFTER. Never explain a tool call before making it.
            RULE: run_command for any non-interactive shell command or script.
            RULE: For DESTRUCTIVE actions (delete/remove/overwrite) — preview first, confirm, then execute.
            RULE: Summarise output in plain English. Never dump raw output at the user.
            RULE: STAY ON TOPIC — politely decline unrelated requests.

            ══ ERROR DETECTION — CRITICAL ══
            After EVERY run_command, read the output before responding.
            A command FAILED if its output contains ANY of: "Error:", "error:", "Unknown option",
            "Unknown subcommand", "Missing expected", "Invalid", "not found", "Usage:", "USAGE:".
            ▸ NEVER claim an operation succeeded when the output shows an error.
            ▸ NEVER fabricate results — only report what the actual output says.
            ▸ If a command fails with "Unknown subcommand" or similar, IMMEDIATELY run
              run_command("<tool> --help") to get the real subcommand list, then pick the correct one.
            ▸ NEVER guess or invent subcommands from general knowledge — only use what --help shows.
            ▸ If the error output shows a correct usage line, retry with that exact syntax.
            ▸ Only after 2 failed retries should you report the error to the user verbatim.
            """

        let cliToolCommand: String? = {
            if ctx?.resultType == .cliTool, let ctx { return ctx.name }
            return globalInlineCLICommand
        }()

        // CLI tool panel/scope — build system prompt from stored --help text and subcommands
        if let toolCmd = cliToolCommand {
            let pkg = TerminalPackageManager.shared.packages.first(where: {
                $0.name == toolCmd || $0.command == toolCmd
            })
            let isTUI = TerminalAIBridge.shared.isTUICommand(toolCmd)
            // Inject the FULL scanned help tree — this is what prevents hallucination.
            // The AI must only use commands that appear here.
            let helpSnippet: String = {
                guard let ht = pkg?.helpText, !ht.isEmpty else { return "" }
                return
                    "\n\n══ TOOL REFERENCE (exact output of \(toolCmd) --help) ══\n\(String(ht.prefix(4000)))\n══ END TOOL REFERENCE ══"
            }()
            let subcommandList: String = {
                guard let subs = pkg?.subcommands, !subs.isEmpty else { return "" }
                let list = subs.prefix(30).joined(separator: ", ")
                return
                    "\n\n⚠️ VERIFIED SUBCOMMANDS (from --help scan): \(list)\nDO NOT use any subcommand not in this list. If unsure, run `\(toolCmd) --help` first."
            }()
            let launchNote =
                isTUI
                ? """

                This is a full-screen TUI app (ncurses). The embedded terminal panel on the right is where it runs.

                HOW TO CONTROL THIS TUI:
                1. Launch: spawn_worker(command="\(toolCmd)", purpose="Launch TUI")
                2. After launching, wait ~1s for the TUI to draw its first screen, then navigate using send_keys.
                3. Menu selection: send_keys(keys="5\\r") sends key "5" then Enter.
                4. Arrow keys: "\\u{1B}[A"=up, "\\u{1B}[B"=down, "\\u{1B}[C"=right, "\\u{1B}[D"=left, "\\r"=Enter.
                5. Exit: send_keys(keys="q") or send_keys(keys="\\u{03}") for Ctrl-C.

                RULES:
                - NEVER call run_command('\(toolCmd)') — requires PTY, will fail.
                - NEVER call run_command('\(toolCmd) --help') — same reason.
                - Use ONLY the stored TOOL REFERENCE below to know menus/options.
                - Chain: spawn_worker → (brief pause) → send_keys to automate the TUI for the user.
                """
                : "\nUse run_command for all operations. Pass flags and subcommands as part of the command string."
            // Always inject real home directory — prevents AI from using placeholder /Users/username
            let homeDir = NSHomeDirectory()
            let folderAccessEnabled = settings.isFolderAccessEnabled(for: toolCmd)
            let folderSection: String = {
                if folderAccessEnabled {
                    return """

                        FOLDER ACCESS: Granted by user.
                        HOME: \(homeDir)
                        Downloads: \(homeDir)/Downloads
                        Documents: \(homeDir)/Documents
                        Desktop:   \(homeDir)/Desktop
                        Pictures:  \(homeDir)/Pictures
                        Movies:    \(homeDir)/Movies
                        Music:     \(homeDir)/Music
                        ALWAYS use these exact absolute paths. NEVER use /Users/username or placeholder paths.
                        """
                } else {
                    return """

                        HOME DIRECTORY: \(homeDir)
                        ALWAYS use this exact home path in commands. NEVER use /Users/username or placeholder paths.
                        NOTE: User has not granted folder access for \(toolCmd). Avoid reading or writing ~/Documents, ~/Downloads etc. unless the user explicitly asks.
                        """
                }
            }()
            systemPrompt = """
                You are an expert AI assistant for the TUI app '\(toolCmd)' inside ILauncher.
                The embedded terminal on the right is where '\(toolCmd)' runs.\(folderSection)\(launchNote)\(helpSnippet)\(subcommandList)
                \(toolRules)
                """
        } else if isGenericContext, let ctx = ctx {
            // Build the explicit path line so AI always knows exactly where to look
            let contextPath: String = ctx.filePath ?? ctx.subtitle
            let isFolder = ctx.resultType == .folder
            let pathDirective: String = {
                if isFolder && !contextPath.isEmpty {
                    return
                        "\nCURRENT FOLDER: \(contextPath)\nALWAYS use this absolute path in every command. Never use relative paths like './' or '~' — use the full path above."
                } else if let fp = ctx.filePath, !fp.isEmpty {
                    return
                        "\nFILE PATH: \(fp)\nAlways reference this exact absolute path in commands."
                }
                return ""
            }()

            let fileToolDocs: String = {
                guard !toolExts.isEmpty else { return "" }
                let pkgs = TerminalPackageManager.shared.packages
                let docs = toolExts.map { ext -> String in
                    if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                        let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                        var doc = "### \(ext.toolName) [SCRIPT – \(lang.rawValue)]"
                        doc +=
                            "\nInvoke: run_command(\"\(runCmd) \\\"<full user query>\\\"\") — pass entire query as one arg"
                        let cap = ext.effectiveHint.isEmpty ? ext.aiHint : ext.effectiveHint
                        if !cap.isEmpty { doc += "\n" + String(cap.prefix(400)) }
                        return doc
                    }
                    let pkg = pkgs.first(where: { $0.command == ext.toolName })
                    var doc = "### \(ext.toolName) [CLI]"
                    if let helpText = pkg?.helpText, !helpText.isEmpty {
                        doc += "\n" + String(helpText.prefix(600))
                    } else if !ext.aiHint.isEmpty {
                        doc += "\n" + ext.aiHint
                    }
                    return doc
                }.joined(separator: "\n\n")
                return "\n\nAvailable tools (use via run_command):\n\(docs)"
            }()
            // Inject file-type tool registry snippet for file/folder contexts
            let registrySnippet: String = {
                guard isFileContext else { return "" }
                let registry = FileTypeToolRegistry.shared
                var snippet = ""
                if !isFolder, let filePath = ctx.filePath {
                    let ext = (filePath as NSString).pathExtension
                    snippet = registry.systemPromptSnippet(for: ext)
                    // If no installed tool handles this file type, suggest what to install
                    if snippet.isEmpty {
                        let missing = registry.suggestMissingTools(
                            for: _userQuery.isEmpty ? ext : _userQuery, maxCount: 2)
                        if !missing.isEmpty {
                            let suggestions = missing.map { "brew install \($0.toolName)" }.joined(
                                separator: "  or  ")
                            snippet =
                                "\n\nNo installed tool found for .\(ext) files. Tell the user to install one: \(suggestions)"
                        }
                    }
                } else if isFolder, !contextPath.isEmpty {
                    let fm = FileManager.default
                    var seenExts = Set<String>()
                    if let contents = try? fm.contentsOfDirectory(atPath: contextPath) {
                        for name in contents {
                            let e = (name as NSString).pathExtension.lowercased()
                            if !e.isEmpty { seenExts.insert(e) }
                        }
                    }
                    snippet = registry.systemPromptSnippet(forAnyOf: Array(seenExts))
                    // Suggest missing tools based on query intent (e.g. "compress video" → ffmpeg)
                    if snippet.isEmpty {
                        let missing = registry.suggestMissingTools(for: _userQuery, maxCount: 2)
                        if !missing.isEmpty {
                            let suggestions = missing.map {
                                "  brew install \($0.toolName)  — \($0.description)"
                            }.joined(separator: "\n")
                            snippet =
                                "\n\nNo installed tool matches this request. Suggest the user install:\n\(suggestions)"
                        }
                    }
                }
                return snippet
            }()
            systemPrompt = """
                You are a focused macOS assistant inside ILauncher. \
                The user is working with: \(ctx.aiContextDescription).\(pathDirective)
                Answer ONLY questions about this specific item. \
                Use run_command to inspect or act on it. Be concise.\(fileToolDocs)\(registrySnippet)
                \(toolRules)
                """
        } else if activeKey == "homebrew" {
            let brewBin =
                FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
            systemPrompt = """
                You are a Homebrew package manager assistant inside ILauncher.
                Homebrew is installed at: \(brewBin)
                Always run brew commands via run_command. Chain multiple commands when needed.

                PACKAGE MANAGEMENT:
                - Install:      brew install <formula>
                - Install cask: brew install --cask <app>        (GUI apps like Chrome, VS Code)
                - Uninstall:    brew uninstall <formula>
                - Upgrade one:  brew upgrade <formula>
                - Upgrade all:  brew upgrade
                - Update brew:  brew update
                - Search:       brew search <term>
                - Info:         brew info <formula>
                - List all:     brew list
                - Top-level:    brew leaves                      (installed, not as deps)
                - Outdated:     brew outdated

                CASK (GUI APPS):
                - List casks:   brew list --cask
                - Outdated:     brew outdated --cask
                - Info:         brew info --cask <app>

                SERVICES (daemons):
                - List:         brew services list
                - Start:        brew services start <formula>
                - Stop:         brew services stop <formula>
                - Restart:      brew services restart <formula>

                MAINTENANCE:
                - Doctor:       brew doctor                       (diagnose issues)
                - Cleanup:      brew cleanup                      (remove old versions, free disk)
                - Cleanup dry:  brew cleanup -n                   (preview what would be removed)
                - Cache size:   du -sh $(brew --cache)
                - Disk usage:   brew list | xargs brew info --json | jq '.[].installed[].installed_on_request'

                TAPS (third-party repos):
                - Add tap:      brew tap <user/repo>
                - Remove tap:   brew untap <user/repo>
                - List taps:    brew tap

                VERSIONS & PINNING:
                - Pin version:  brew pin <formula>               (stops auto-upgrade)
                - Unpin:        brew unpin <formula>
                - Dependencies: brew deps <formula>
                - What uses it: brew uses --installed <formula>

                BREWFILE (backup/restore):
                - Export:       brew bundle dump --file=~/Brewfile --force
                - Restore:      brew bundle install --file=~/Brewfile
                - List:         brew bundle list --file=~/Brewfile

                WORKFLOW RULES:
                - Always run brew update before major installs/upgrades.
                - Use run_command for each brew step; show output to user.
                - For multi-step tasks (update + upgrade + cleanup), chain with &&.
                - When user asks to "install X", first run brew search X to confirm exact name.
                - When listing packages, use brew list --versions for cleaner output.
                - For disk cleanup suggestions, run brew cleanup -n first so user can approve.
                \(toolRules)
                """
        } else if activeKey == "amphetamine" {
            systemPrompt = """
                You are an Amphetamine assistant inside ILauncher.
                Amphetamine is a macOS app that prevents the Mac from sleeping.
                Control it using osascript (AppleScript) via run_command. Never use caffeinate.

                FULL APPLESCRIPT API (always wrap with: osascript -e '...'):

                START SESSION:
                - Default: osascript -e 'tell application "Amphetamine" to start new session'
                - Timed:   osascript -e 'tell application "Amphetamine" to start new session with options {duration:30, interval:minutes, displaySleepAllowed:false}'
                - Hours:   osascript -e 'tell application "Amphetamine" to start new session with options {duration:2, interval:hours, displaySleepAllowed:true}'
                - interval is either: minutes  OR  hours

                END SESSION:
                - osascript -e 'tell application "Amphetamine" to end session'

                DISPLAY SLEEP:
                - osascript -e 'tell application "Amphetamine" to allow display sleep'
                - osascript -e 'tell application "Amphetamine" to prevent display sleep'

                SCREEN SAVER:
                - osascript -e 'tell application "Amphetamine" to allow screen saver'
                - osascript -e 'tell application "Amphetamine" to prevent screen saver'

                CLOSED DISPLAY MODE:
                - osascript -e 'tell application "Amphetamine" to enable closed display mode'
                - osascript -e 'tell application "Amphetamine" to disable closed display mode'

                QUERY STATUS (run_command, read the output):
                - Is active?:       osascript -e 'tell application "Amphetamine" to return session is active'
                - Time remaining:   osascript -e 'tell application "Amphetamine" to return session time remaining'
                  (returns seconds; 0=infinite, -1=trigger, -2=app/date-based, -3=no session)
                - Display sleep?:   osascript -e 'tell application "Amphetamine" to return display sleep allowed'
                - Is trigger?:      osascript -e 'tell application "Amphetamine" to return session is Trigger'

                RULES:
                - ALWAYS use osascript -e '...' via run_command. Never use caffeinate.
                - To check if Amphetamine is running: run_command(command="pgrep -x Amphetamine")
                - If not running, tell user to open it first (open -a Amphetamine).
                - After "notify when ends": after starting a timed session, also call:
                  run_command(command="osascript -e 'tell application \\"Amphetamine\\" to start new session with options {duration:N, interval:minutes, displaySleepAllowed:false}' && sleep Ns && osascript -e 'display notification \\"Amphetamine session ended\\" with title \\"Amphetamine\\"'")
                - Convert natural language time: "1 hour" → duration:1, interval:hours; "45 minutes" → duration:45, interval:minutes
                - Give a short friendly confirmation after each action.
                \(toolRules)
                """
        } else if !promptExts.isEmpty && toolExts.isEmpty && contextualCliPackages.isEmpty {
            // ── PURE PROMPT EXTENSION — no CLI/script tools, AI answers directly ──
            // Render the first prompt's template; subsequent prompts are appended.
            let rendered = promptExts.map { ext in
                PromptRunner.shared.render(
                    template: ext.promptTemplate, query: query, appLabel: appLabel)
            }.joined(separator: "\n\n---\n\n")
            systemPrompt = rendered

        } else if !toolExts.isEmpty || !contextualCliPackages.isEmpty {
            // USER-SET AI EXTENSIONS — always take priority over built-in hardcoded prompts.
            // Supports CLI tools (binaries on $PATH) AND user scripts (JXA, bash, Python, AppleScript, Lua).
            // If prompt extensions also exist, their rendered template becomes the persona/intro.
            let pkgs = TerminalPackageManager.shared.packages

            let extensionDocs = toolExts.map { ext -> String in
                if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                    // ── SCRIPT EXTENSION ───────────────────────────────────────
                    let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                    var doc = "### \(ext.toolName) [SCRIPT – \(lang.rawValue)]"
                    if ext.profile.isDestructive { doc += " ⚠️ DESTRUCTIVE" }
                    doc +=
                        "\nInvoke with: run_command(\"\(runCmd) \\\"<full user query as one arg>\\\"\")"
                    doc +=
                        "\nPASS THE ENTIRE user query as a single quoted argument — the script handles all parsing internally."
                    // Capability description from aiHint / profile
                    let cap = ext.effectiveHint.isEmpty ? ext.aiHint : ext.effectiveHint
                    if !cap.isEmpty { doc += "\nCapabilities: " + String(cap.prefix(500)) }
                    if !ext.profile.exampleCommands.isEmpty {
                        doc += "\nExamples: " + ext.profile.exampleCommands.joined(separator: " | ")
                    }
                    return doc
                } else {
                    // ── CLI TOOL EXTENSION ─────────────────────────────────────
                    let cmd = ext.effectiveCommand  // "memo notes" or "memo rem" — scoped per app
                    let base = ext.toolName  // "memo" — binary name for package lookup
                    let pkg = pkgs.first(where: { $0.command == base })
                    var doc = "### \(cmd) [CLI]"
                    if cmd != base { doc += "  (binary: \(base))" }
                    if let path = pkg?.installedPath ?? (ext.toolPath.isEmpty ? nil : ext.toolPath)
                    {
                        doc += " at \(path)"
                    }
                    if ext.profile.isDestructive { doc += " ⚠️ DESTRUCTIVE" }
                    doc += "\n"
                    // Prefer scoped subcommand help; fall back to full help or hints
                    let scopedHelp = TerminalPackageManager.shared.helpText(
                        for: cmd, baseCommand: base)
                    let helpSource: String
                    if let sh = scopedHelp, !sh.isEmpty {
                        helpSource = String(sh.prefix(1000))
                    } else if ext.aiHint.contains("--help output:") {
                        helpSource = String(ext.aiHint.prefix(1000))
                    } else if !ext.effectiveHint.isEmpty {
                        helpSource = ext.effectiveHint
                    } else {
                        helpSource = ""
                    }
                    if !helpSource.isEmpty {
                        doc += helpSource
                    } else {
                        doc +=
                            "UNKNOWN: Call run_command(\"\(cmd) --help\") first, read output, then answer."
                    }
                    // Context flag — always append this flag to every command for this app panel
                    if !ext.appContextFlag.isEmpty {
                        doc +=
                            "\n⚑ CONTEXT FLAG: You MUST append `\(ext.appContextFlag)` to EVERY \(base) command for \(appLabel)."
                        doc += "\n  Example: run_command(\"\(cmd) list \(ext.appContextFlag)\")"
                        doc +=
                            "\n  Example: run_command(\"\(cmd) add \(ext.appContextFlag) \\\"Buy milk\\\"\")"
                    }
                    if !ext.profile.exampleCommands.isEmpty {
                        doc += "\nExamples: " + ext.profile.exampleCommands.joined(separator: " | ")
                    }
                    return doc
                }
            }
            let packageDocs = contextualCliPackages.map(appPanelCLIDocumentation(for:))
            let toolDocs = (extensionDocs + packageDocs).joined(separator: "\n\n---\n\n")

            // Intent → invocation hints per tool
            let extensionIntentLines = toolExts.map { ext -> String in
                if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                    let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                    return "• \(ext.toolName): run_command(\"\(runCmd) \\\"<full user query>\\\"\")"
                }
                let cmd = ext.effectiveCommand
                let ctxFlag = ext.appContextFlag.isEmpty ? "" : " \(ext.appContextFlag)"
                if !ext.profile.capabilities.isEmpty {
                    return "• \(cmd): "
                        + ext.profile.capabilities.prefix(4).joined(separator: " | ")
                        + (ctxFlag.isEmpty ? "" : "  [always append \(ext.appContextFlag)]")
                }
                return
                    "• \(cmd): list → \(cmd) list\(ctxFlag)  |  add → \(cmd) add\(ctxFlag) \"<title>\"  |  delete → \(cmd) delete\(ctxFlag) <id>"
            }
            let packageIntentLines = contextualCliPackages.map(appPanelCLIIntentLine(for:))
            let intentLines = (extensionIntentLines + packageIntentLines).joined(separator: "\n")

            let hasDestructiveTool =
                toolExts.contains { $0.profile.isDestructive }
                || contextualCliPackages.contains {
                    let warningWords = ["delete", "remove", "uninstall", "erase", "purge"]
                    let corpus =
                        ($0.taskCategories + $0.subcommands + $0.usageExamples + [$0.description])
                        .joined(separator: " ")
                        .lowercased()
                    return warningWords.contains(where: { corpus.contains($0) })
                }
            let destructiveWarning =
                hasDestructiveTool
                ? "\n- ⚠️ One or more tools are DESTRUCTIVE. Always confirm with the user before running delete/remove/overwrite operations."
                : ""

            // If user has a prompt extension too, its rendered template becomes the persona intro.
            // Strip any "User's question: {{query}}" lines — the query is already the user message.
            let promptPersona: String =
                promptExts.isEmpty
                ? ""
                : {
                    let rendered = promptExts.map { ext in
                        var t = PromptRunner.shared.render(
                            template: ext.promptTemplate, query: query, appLabel: appLabel)
                        // Remove lines that redundantly embed the query — causes AI to answer in text instead of tool-calling
                        t = t.split(separator: "\n", omittingEmptySubsequences: false).filter {
                            line in
                            let l = line.lowercased()
                            return !l.hasPrefix("user's question:")
                                && !l.hasPrefix("user question:")
                                && !l.contains(query.lowercased().prefix(20))
                        }.joined(separator: "\n")
                        return t.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.joined(separator: "\n\n")
                    return rendered.isEmpty ? "" : rendered + "\n\n"
                }()

            systemPrompt = """
                \(promptPersona)You are an AI assistant for \(appLabel) inside ILauncher.
                Only help with tasks related to \(appLabel).
                Use run_command for attached CLI/script tools. The embedded terminal drawer may appear for live output when commands run.
                Their output is returned to you; always summarise it in plain English.

                AVAILABLE TOOLS (user-configured for \(appLabel)):
                \(toolDocs)

                HOW TO INVOKE EACH TOOL:
                \(intentLines)

                RULES:
                - For SCRIPT tools: always pass the user's FULL original query as a single argument in quotes.
                - For CLI tools: use ONLY the exact flags and subcommands documented in AVAILABLE TOOLS above.
                  Never guess flags. If you're unsure of exact syntax, run "<tool> help <subcommand>" first.
                - The AVAILABLE TOOLS section contains the full --help tree (all subcommand levels).
                  Always check the relevant subcommand section before forming a command.
                - For "find/search X": use the search or list subcommand as shown in help.
                - For "create/add X": always check the correct add subcommand syntax before running.
                - Never dump raw output — always give a clean plain-English summary.\(destructiveWarning)
                \(toolRules)
                """
        } else if activeKey == "safari" || isBrowserScope {
            let safariTab = isBrowserScope ? [:] : AppleAppsAPI.shared.getCurrentTab()
            let browserPID =
                AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
            let pageURL: String = {
                if let u = (safariTab["url"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty { return u }
                // Non-Safari browsers: read the live address-bar URL over Accessibility.
                return AXContextReader.shared.liveCurrentURL(
                    pid: browserPID, bundleId: scopedBrowserBundle)
                    ?? AXContextReader.shared.current.currentURL ?? ""
            }()
            let pageTitle =
                (safariTab["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (AppDelegate.shared?.previousFrontmostApp?.localizedName ?? "")
            var pageText = isBrowserScope ? "" : (fetchSafariPageText() ?? "")
            // Fallback / non-Safari: convert the live URL to markdown with MarkItDown so
            // the model has the page content even when there's no Safari bridge text.
            if pageText.isEmpty, let url = URL(string: pageURL),
                MarkItDownService.supports(url),
                let conv = MarkItDownService.convert(url)
            {
                pageText = conv.markdown
            }
            // These read via Safari's JavaScript bridge — skip for other browsers.
            let pageLinks = isBrowserScope ? [] : fetchSafariPageLinks()
            let pageImages = isBrowserScope ? [] : fetchSafariPageImages()
            let lowerQuery = query.lowercased()
            let selectedText =
                AXContextReader.shared.current.selectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let shouldIncludeLinks =
                lowerQuery.contains("link")
                || lowerQuery.contains("url")
                || lowerQuery.contains("href")
            let shouldIncludeImages =
                lowerQuery.contains("image")
                || lowerQuery.contains("photo")
                || lowerQuery.contains("picture")
                || lowerQuery.contains("logo")
            let pageTextSection =
                pageText.isEmpty
                ? "\nPAGE TEXT: (unavailable — Safari page content could not be read)"
                : "\nPAGE TEXT EXCERPT:\n\(String(pageText.prefix(5000)))"
            let selectedTextSection =
                selectedText.isEmpty
                ? ""
                : "\nSELECTED TEXT:\n\(String(selectedText.prefix(1500)))"
            let linksSection =
                shouldIncludeLinks && !pageLinks.isEmpty
                ? "\nPAGE LINKS:\n"
                    + pageLinks.prefix(40).map { "  • \($0)" }.joined(separator: "\n")
                : ""
            let imagesSection =
                shouldIncludeImages && !pageImages.isEmpty
                ? "\nPAGE IMAGE URLS:\n"
                    + pageImages.prefix(40).map { "  • \($0)" }.joined(separator: "\n")
                : ""
            systemPrompt = """
                You are a Safari page assistant inside ILauncher.
                Answer questions about the CURRENT Safari page using the provided page context.
                Do not say you cannot see the page if page context is present below.
                If the user asks what the page is about, summarize the page text.
                If the user asks for images or links, use the provided PAGE IMAGE URLS or PAGE LINKS sections.
                If the requested data is unavailable, say exactly what is missing.

                CURRENT TAB TITLE: \(pageTitle.isEmpty ? "(unknown)" : pageTitle)
                CURRENT TAB URL: \(pageURL.isEmpty ? "(unknown)" : pageURL)\(selectedTextSection)\(pageTextSection)\(linksSection)\(imagesSection)

                RULES:
                - Stay focused on the current Safari page.
                - Prefer the page text and tab metadata over generic guesses.
                - If the user asks for a list of images or links, return the actual URLs you were given.
                - Be concise and directly answer the question.
                """
        } else if activeKey == "finder" {
            let finderDir = ContextDetector.shared.getCurrentFinderDirectory() ?? NSHomeDirectory()
            let selectedFiles = ContextDetector.shared.getFinderSelectedFiles()
            let selectedNote =
                selectedFiles.isEmpty
                ? ""
                : "\nSELECTED FILES:\n"
                    + selectedFiles.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
            let toolContext = FinderToolkit.shared.systemPromptContext()
            systemPrompt = """
                You are a Finder file management assistant inside ILauncher.
                You help users organize, find, rename, and manage files using shell commands and installed scripts.

                CURRENT FINDER DIRECTORY: \(finderDir)\(selectedNote)

                \(toolContext)

                CRITICAL RULES:
                - You are a FILE MANAGER assistant. Do NOT search contacts, photos, or calendars.
                - ALWAYS use run_command to execute operations — never just describe what to do.
                - For destructive operations (sort/organize/rename/delete): ALWAYS run the --dry-run version first,
                  show the output to the user, and ask "Shall I proceed?" before running for real.
                - When user asks "show all PDFs" / "list files": run a find command immediately.
                - When user asks "how do I X": use the Find Cmd script to search for the right command.
                - Summarize command output in plain English — never dump raw terminal output.
                - Home directory is: \(NSHomeDirectory())
                \(toolRules)
                """

        } else if activeKey == "clipboard" {
            let clipboardContext = relevantClipboardHistory().prefix(20).enumerated().map {
                index, entry in
                "\(index + 1). \(entry.preview) — \(clipboardEntrySubtitle(entry))\n\(String(entry.text.prefix(600)))"
            }.joined(separator: "\n\n")
            systemPrompt = """
                You are a Clipboard assistant inside ILauncher.
                The user is asking about their recent clipboard history. Use ONLY the clipboard entries below.
                You can summarize, compare, find, explain, or tell the user which item to paste/open.
                Do not claim to know clipboard items not shown here.

                CLIPBOARD HISTORY:
                \(clipboardContext.isEmpty ? "No clipboard items stored." : clipboardContext)
                \(toolRules)
                """
        } else if activeKey == "reminders" {
            // Fallback: no user extensions set — use built-in rem CLI if installed
            let remPath = ["/opt/homebrew/bin/rem", "/usr/local/bin/rem"]
                .first { FileManager.default.fileExists(atPath: $0) }
            let remNote =
                remPath != nil
                ? "rem is installed at \(remPath!)."
                : "The `rem` CLI is not installed. Tell the user to run: brew install rem"
            systemPrompt = """
                You are a Reminders assistant inside ILauncher.
                \(remNote)
                You manage macOS Reminders using the `rem` CLI via run_command (runs silently, no terminal).

                rem examples:
                - rem add "call mom" --due "tomorrow at 5pm"
                - rem list
                - rem complete "call mom"
                - rem delete "call mom"
                - rem search "mom"

                Natural language dates work: "tomorrow at 3pm", "next friday", "in 2 hours".
                TIP: User can assign a different CLI (e.g. memo) in Settings → App Shortcuts → Reminders → AI Extensions.
                After actions, give a short friendly confirmation. Summarise lists — don't dump raw JSON.
                \(toolRules)
                """
        } else {
            // Generic fallback — no user extensions, no built-in CLI known
            systemPrompt = """
                You are an AI assistant for \(appLabel) inside ILauncher.
                Only help with tasks related to \(appLabel).
                Run shell commands via run_command (runs silently in the background — no terminal shown).
                TIP: Assign CLI tools in Settings → App Shortcuts → \(appLabel) → AI Extensions to unlock more actions.
                \(toolRules)
                """
        }

        // Build history from chat for multi-turn context (exclude .tool command chips — visual only)
        let history: [ChatMessage] = remPanelChatMessages.dropLast()
            .filter { $0.role != .tool }
            .map { ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.content) }

        // Capture folder path for command fixup (folder panel context)
        let contextFolderPath: String? = {
            guard let ctx = ctx, ctx.resultType == .folder else { return nil }
            let p = ctx.filePath ?? ctx.subtitle
            return p.isEmpty ? nil : p
        }()

        // Check prompt extension cache — if we get a hit, skip the full AI round-trip
        if let cacheHit = promptExts.first.flatMap({
            PromptRunner.shared.cachedResponse(for: $0, query: query)
        }) {
            remPanelChatMessages.append(AIChatMessage(role: .assistant, content: cacheHit))
            remPanelIsProcessing = false
            return
        }

        if provider == .onDevice {
            guard let scopedIdentity = scopedWorkspaceIdentity() else {
                remPanelChatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content:
                            "I couldn't resolve a scoped app context for on-device execution. Re-open the app scope and try again.",
                        isError: true
                    ))
                remPanelIsProcessing = false
                return
            }

            let placeholder = AIChatMessage(role: .assistant, content: "")
            remPanelChatMessages.append(placeholder)
            let messageID = placeholder.id

            remPanelAITask = Task { @MainActor in
                await withCheckedContinuation { continuation in
                    #if canImport(FoundationModels)
                        if #available(macOS 26.0, *) {
                            OnDeviceToolSession.shared.stream(
                                to: query,
                                systemPrompt: systemPrompt,
                                bundleId: scopedIdentity.bundleId,
                                axContext: scopedIdentity.axContext,
                                onPartial: { token in
                                    DispatchQueue.main.async {
                                        if let index = self.remPanelChatMessages.firstIndex(where: {
                                            $0.id == messageID
                                        }) {
                                            self.remPanelChatMessages[index] = AIChatMessage(
                                                id: messageID,
                                                role: .assistant,
                                                content: self.remPanelChatMessages[index].content
                                                    + token
                                            )
                                        }
                                    }
                                },
                                onComplete: { response in
                                    DispatchQueue.main.async {
                                        if let index = self.remPanelChatMessages.firstIndex(where: {
                                            $0.id == messageID
                                        }), self.remPanelChatMessages[index].content.isEmpty {
                                            self.remPanelChatMessages[index] = AIChatMessage(
                                                id: messageID,
                                                role: .assistant,
                                                content: response
                                            )
                                        }
                                        self.remPanelIsProcessing = false
                                    }
                                    continuation.resume()
                                },
                                onError: { errorText in
                                    DispatchQueue.main.async {
                                        if let index = self.remPanelChatMessages.firstIndex(where: {
                                            $0.id == messageID
                                        }) {
                                            self.remPanelChatMessages[index] = AIChatMessage(
                                                id: messageID,
                                                role: .assistant,
                                                content: errorText,
                                                isError: true
                                            )
                                        }
                                        self.remPanelIsProcessing = false
                                    }
                                    continuation.resume()
                                }
                            )
                        } else {
                            DispatchQueue.main.async {
                                if let index = self.remPanelChatMessages.firstIndex(where: {
                                    $0.id == messageID
                                }) {
                                    self.remPanelChatMessages[index] = AIChatMessage(
                                        id: messageID,
                                        role: .assistant,
                                        content:
                                            "On-device AI requires macOS 26.0 or later with Apple Silicon.",
                                        isError: true
                                    )
                                }
                                self.remPanelIsProcessing = false
                            }
                            continuation.resume()
                        }
                    #else
                        DispatchQueue.main.async {
                            if let index = self.remPanelChatMessages.firstIndex(where: {
                                $0.id == messageID
                            }) {
                                self.remPanelChatMessages[index] = AIChatMessage(
                                    id: messageID,
                                    role: .assistant,
                                    content: "On-device AI is not available in this build.",
                                    isError: true
                                )
                            }
                            self.remPanelIsProcessing = false
                        }
                        continuation.resume()
                    #endif
                }
            }
            return
        }

        remPanelAITask = Task {
            do {
                let (response, executedCommands) = try await AIProviderService.shared.sendWithTools(
                    query,
                    context: .none,
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: history,
                    commandExecutor: { cmd, purpose in
                        // Fix relative paths: if AI used "find . ..." or "ls" without absolute path
                        // and we're in a folder context, rewrite to use the folder's absolute path
                        let fixedCmd: String = {
                            guard let folderPath = contextFolderPath else { return cmd }
                            var c = cmd
                            // find . → find /absolute/path
                            if c.hasPrefix("find . ") || c == "find ." {
                                c = "find " + folderPath + c.dropFirst(6)
                            } else if c.hasPrefix("find ./ ") {
                                c = "find " + folderPath + "/" + c.dropFirst(8)
                            }
                            // ls (no args or just flags) → ls folderPath
                            if c == "ls"
                                || c.range(of: #"^ls\s+-[a-zA-Z]+$"#, options: .regularExpression)
                                    != nil
                            {
                                c = c + " " + folderPath
                            }
                            // du . → du folderPath
                            if c.hasPrefix("du . ") || c == "du ." {
                                c = "du " + folderPath + c.dropFirst(4)
                            }
                            return c
                        }()
                        // Show command chip in chat + open embedded panel terminal
                        await MainActor.run {
                            self.remPanelChatMessages.append(
                                AIChatMessage(
                                    role: .tool,
                                    content: "$ \(fixedCmd)"
                                ))
                            let ck = self.activeConsoleKey
                            self.panelShowConsoleMap[ck] = true
                            // Ensure panel PTY exists before command fires
                            _ = self.panelTerminal(for: ck)
                        }
                        let result = await TerminalCommandExecutor.shared.run(
                            fixedCmd, purpose: purpose)
                        // Also send approved command to the panel's embedded PTY for live display
                        await MainActor.run {
                            let ck = self.activeConsoleKey
                            self.panelTerminalControllers[ck]?.sendCommand(fixedCmd)
                        }
                        // Post-execution: file detection / live panel (streaming already filled output lines)
                        await MainActor.run {
                            let ck = self.activeConsoleKey
                            // If the command created a file, auto-show its preview
                            if result.success,
                                let createdURL = self.detectCreatedFile(
                                    command: fixedCmd, output: result.output)
                            {
                                self.showLivePanel(.filePreview(url: createdURL))
                            } else if result.success || !result.output.isEmpty {
                                // Parse output → right panel results (files, tasks, processes, events, etc.)
                                let resultEntries = self.parseCommandOutputForPanel(
                                    command: fixedCmd,
                                    output: result.output,
                                    panelKey: activeKey
                                )
                                if !resultEntries.isEmpty {
                                    self.showLivePanel(.results(resultEntries))
                                }
                            }
                        }
                        return result
                    },
                    systemPromptOverride: systemPrompt
                )
                await MainActor.run {
                    // Strip any leaked raw tool-call syntax the AI accidentally included in its text reply
                    let cleanResponse = Self.stripLeakedToolCalls(response)
                    if !cleanResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        remPanelChatMessages.append(
                            AIChatMessage(role: .assistant, content: cleanResponse))
                        // Cache the response for pure-prompt extensions (no commands were run)
                        if executedCommands.isEmpty, let pExt = promptExts.first {
                            PromptRunner.shared.cacheResponse(
                                cleanResponse, for: pExt, query: query)
                        }
                    }
                    remPanelIsProcessing = false
                    searchState.appPanelAllItems = []
                    reloadAppPanelData(for: "reminders")
                    // Auto-switch live panel to terminal if spawn_worker was used
                    let spawnedTUI = executedCommands.contains {
                        $0.command.hasPrefix("spawn_worker")
                    }
                    if spawnedTUI { showLivePanel(.terminal) }
                }
            } catch AIServiceError.unsupportedProvider(_) {
                // Ollama: ask AI to output the rem command as plain text, then run it
                await handleRemPanelQueryLegacy(
                    query: query, systemPrompt: systemPrompt, provider: provider, apiKey: apiKey)
            } catch {
                await MainActor.run {
                    remPanelChatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "⚠️ \(error.localizedDescription)", isError: true))
                    remPanelIsProcessing = false
                }
            }
        }
    }

    func executeScopedMenuIntentIfAvailable(
        query: String,
        activeKey: String,
        contextApp: SearchContextApp?,
        appLabel: String
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        let looksLikeQuestion =
            q.hasSuffix("?")
            || q.hasPrefix("what") || q.hasPrefix("how") || q.hasPrefix("why")
            || q.hasPrefix("tell") || q.hasPrefix("explain") || q.hasPrefix("describe")
            || q.hasPrefix("summarize") || q.hasPrefix("who") || q.hasPrefix("when")
            || q.hasPrefix("where") || q.hasPrefix("is ") || q.hasPrefix("can ")
            || q.hasPrefix("does ") || q.hasPrefix("do ")
        guard !looksLikeQuestion else { return false }

        let target: (bundleId: String, appName: String)? = {
            if let contextApp, contextApp.resultType == .application {
                let bundleIdFromPath =
                    contextApp.appPath.isEmpty
                    ? nil
                    : Bundle(path: contextApp.appPath)?.bundleIdentifier
                let bundleIdFromRunning = NSWorkspace.shared.runningApplications.first(where: {
                    !$0.isTerminated && $0.localizedName == contextApp.name
                })?.bundleIdentifier
                if let bundleId = bundleIdFromPath ?? bundleIdFromRunning, !bundleId.isEmpty {
                    return (bundleId, contextApp.name)
                }
            }
            let meta = smartQueryMeta
            if !meta.appPath.isEmpty,
                let bundleId = Bundle(path: meta.appPath)?.bundleIdentifier,
                !bundleId.isEmpty
            {
                return (bundleId, meta.label)
            }
            if let entry = settings.customAppEntries.first(where: { $0.key == activeKey }),
                let bundleId = Bundle(path: entry.appPath)?.bundleIdentifier,
                !bundleId.isEmpty
            {
                return (bundleId, entry.label)
            }
            return nil
        }()

        guard let target,
            target.bundleId != "scope://clipboard",
            GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: target.bundleId)
        else { return false }

        let matches = GlobalContextEngine.shared.cachedMenuItems(
            bundleIdentifier: target.bundleId,
            appName: target.appName,
            processIdentifier: 0,
            query: query,
            maxResults: 8
        )
        guard let picked = highConfidenceMenuCandidate(from: matches, query: query) else {
            return false
        }

        Task {
            let app = await activateOrLaunchSemanticApp(
                bundleIdentifier: target.bundleId,
                appName: target.appName
            )
            guard let app else {
                await MainActor.run {
                    remPanelChatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "I couldn't open \(target.appName) to run that menu action.",
                            isError: true
                        )
                    )
                    remPanelIsProcessing = false
                }
                return
            }
            AXActionResolver.shared.execute(menuPath: picked.path, in: app)
            await MainActor.run {
                remPanelChatMessages.append(
                    AIChatMessage(role: .assistant, content: "✅ \(picked.pathString)")
                )
                remPanelIsProcessing = false
                searchState.query = ""
            }
        }
        return true
    }

    func highConfidenceMenuCandidate(from items: [AXMenuItem], query: String) -> AXMenuItem?
    {
        let q = AppMenuCapabilityCache.normalize(query)
        let tokens = q.split(separator: " ").map(String.init).filter { $0.count > 2 }
        let scored = items.compactMap { item -> (AXMenuItem, Int)? in
            let title = AppMenuCapabilityCache.normalize(item.title)
            let path = AppMenuCapabilityCache.normalize(item.pathString)
            var score = 0
            if title == q {
                score += 100
            } else if title.hasPrefix(q) {
                score += 75
            } else if title.contains(q) {
                score += 55
            } else if path.contains(q) {
                score += 35
            }
            for token in tokens {
                if title == token {
                    score += 40
                } else if title.hasPrefix(token) {
                    score += 28
                } else if title.contains(token) {
                    score += 18
                } else if path.contains(token) {
                    score += 10
                }
            }
            if !item.isEnabled { score = max(0, score - 20) }
            guard score >= 40 else { return nil }
            return (item, score)
        }.sorted { $0.1 > $1.1 }
        return scored.first?.0
    }

    /// Fallback for Ollama (no tool_use): ask AI to output a rem command, then run it directly.
    func handleRemPanelQueryLegacy(
        query: String, systemPrompt: String, provider: AIProvider, apiKey: String?
    ) async {
        let legacySystemMsg =
            systemPrompt
            + "\n\nIMPORTANT: Respond with ONLY the exact shell command to run (starting with `rem`), nothing else.\nExample: rem add \"buy milk\" --due \"tomorrow at 9am\""
        let historyWithSystem: [ChatMessage] = [
            ChatMessage(role: .system, content: legacySystemMsg)
        ]
        do {
            let response = try await AIProviderService.shared.sendMessage(
                query,
                context: .none,
                provider: provider,
                apiKey: apiKey,
                conversationHistory: historyWithSystem
            )
            // Extract the rem command from the AI response
            let lines = response.components(separatedBy: .newlines)
            let cmd =
                lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rem ") })
                ?? lines.first(where: { $0.contains("rem ") })
                ?? ""
            let remCmd = cmd.trimmingCharacters(in: .init(charactersIn: "`\" "))
            if remCmd.isEmpty {
                await MainActor.run {
                    remPanelChatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content:
                                "I couldn't figure out the right rem command. Try being more specific, e.g. \"add buy milk tomorrow at 9am\""
                        ))
                    remPanelIsProcessing = false
                }
                return
            }
            let (success, output) = await TerminalCommandExecutor.shared.run(
                remCmd, purpose: "rem")
            await MainActor.run {
                let reply =
                    success
                    ? "✅ Done! Ran: `\(remCmd)`\n\(output.isEmpty ? "" : output)"
                    : "❌ Failed: `\(remCmd)`\n\(output)"
                remPanelChatMessages.append(
                    AIChatMessage(role: .assistant, content: reply, isError: !success))
                remPanelIsProcessing = false
                searchState.appPanelAllItems = []
                reloadAppPanelData(for: "reminders")
            }
        } catch {
            await MainActor.run {
                remPanelChatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content: "⚠️ \(error.localizedDescription)", isError: true))
                remPanelIsProcessing = false
            }
        }
    }

    func checkRemInstalled() {
        Task {
            // Check known install paths directly — app doesn't inherit shell PATH
            let home = NSHomeDirectory()
            let knownPaths = [
                "/usr/local/bin/rem",
                "/opt/homebrew/bin/rem",
                "\(home)/.local/bin/rem",
                "\(home)/go/bin/rem",
                "\(home)/.cargo/bin/rem",
                "\(home)/bin/rem",
            ]
            let fm = FileManager.default
            if knownPaths.contains(where: { fm.fileExists(atPath: $0) }) {
                await MainActor.run { remIsInstalled = true }
                return
            }
            // Fallback: login shell which — loads user's full PATH
            let proc = Process()
            proc.launchPath = "/bin/bash"
            proc.arguments = ["-l", "-c", "which rem"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run { remIsInstalled = proc.terminationStatus == 0 }
        }
    }

    func installRem() {
        // Copy install command to clipboard — user runs it in their own terminal
        // (curl|bash is blocked by TerminalAIBridge security policy, correctly so)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "curl -fsSL https://rem.sidv.dev/install | bash", forType: .string)
        remPanelChatMessages.append(
            AIChatMessage(
                role: .assistant,
                content:
                    "📋 Install command copied to clipboard!\n\nPaste it in Terminal:\n```\ncurl -fsSL https://rem.sidv.dev/install | bash\n```\nAnswer **n** when asked about the AI agent skill — ILauncher uses your selected provider (\(AppSettings.shared.selectedAIProvider.shortName)) instead.\n\nAlternatively: open ILauncher terminal → type \"install rem\" → AI will handle it."
            ))
    }

    func isAffirmativeResponse(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let positives = [
            "yes", "y", "ok", "okay", "sure", "do it", "go ahead", "run it", "execute", "confirm",
        ]
        return positives.contains(where: { normalized == $0 })
    }

    func isNegativeResponse(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let negatives = ["no", "n", "stop", "cancel", "don't", "do not", "nah"]
        return negatives.contains(where: { normalized == $0 })
    }

}
