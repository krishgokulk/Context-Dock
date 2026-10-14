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
    // MARK: - AI Response Parsing & Execution

    enum L2Action {
        case useExtension(String)
        case executeCommand(String)
        case terminalCommand(command: String, purpose: String)  // AI terminal automation
        case suggestExtension(code: String, explanation: String)
        case createAndExecuteExtension(name: String, description: String, app: String, code: String)
        case safariCommand(SafariCommand)
        case directAnswer(String)
    }

    func parseL2AIResponse(_ response: String) -> L2Action {
        #if DEBUG
        print("🔍 [L2] Parsing AI response...")
        #endif

        // Check for Safari browser control tags
        if let safariCmd = SafariCommandBridge.shared.parseTag(from: response) {
            #if DEBUG
            print("🌐 [L2] Safari command tag detected")
            #endif
            return .safariCommand(safariCmd)
        }

        // Check if AI wants to use an extension
        if let range = response.range(
            of: #"\[USE_EXTENSION:\s*([^\]]+)\]"#, options: .regularExpression)
        {
            let matched = String(response[range])
            // Extract extension name between brackets
            let extensionName =
                matched
                .replacingOccurrences(of: "[USE_EXTENSION:", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            #if DEBUG
            print("✅ [L2] AI wants to use extension: \(extensionName)")
            #endif
            return .useExtension(extensionName)
        }

        // Check if AI is suggesting extension creation (explicit tag)
        if response.contains("[SUGGEST_EXTENSION]") {
            #if DEBUG
            print("💡 [L2] AI is suggesting an extension (explicit tag)")
            #endif

            // Try to parse JSON format first
            if let jsonStart = response.range(of: "\\{[\\s\\S]*?\\}", options: .regularExpression) {
                let jsonString = String(response[jsonStart])
                if let jsonData = jsonString.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: jsonData)
                        as? [String: String],
                    let name = json["name"],
                    let description = json["description"],
                    let app = json["app"],
                    let code = json["code"]
                {
                    #if DEBUG
                    print("✅ [L2] Parsed JSON extension suggestion")
                    #endif
                    return .createAndExecuteExtension(
                        name: name, description: description, app: app, code: code)
                }
            }

            // Fallback to old code block parsing
            let codePattern = "```(?:bash|python|javascript|applescript)?\\n([\\s\\S]*?)```"
            if let codeRange = response.range(of: codePattern, options: .regularExpression) {
                let codeBlock = String(response[codeRange])
                // Remove markdown code fence
                let code =
                    codeBlock
                    .replacingOccurrences(of: "```bash\n", with: "")
                    .replacingOccurrences(of: "```python\n", with: "")
                    .replacingOccurrences(of: "```javascript\n", with: "")
                    .replacingOccurrences(of: "```applescript\n", with: "")
                    .replacingOccurrences(of: "```sh\n", with: "")
                    .replacingOccurrences(of: "```\n", with: "")
                    .replacingOccurrences(of: "\n```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Extract explanation (everything before code block)
                let explanation = response.components(separatedBy: "```").first ?? response

                return .suggestExtension(code: code, explanation: explanation)
            }
        }

        // Check if AI wants to run a terminal command (new format with purpose)
        if let commandRange = response.range(
            of: #"\[TERMINAL_COMMAND:\s*([^\]]+)\]"#, options: .regularExpression)
        {
            let commandMatched = String(response[commandRange])
            let command =
                commandMatched
                .replacingOccurrences(of: "[TERMINAL_COMMAND:", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract purpose if available
            var purpose = "Execute terminal command"
            if let purposeRange = response.range(
                of: #"\[COMMAND_PURPOSE:\s*([^\]]+)\]"#, options: .regularExpression)
            {
                let purposeMatched = String(response[purposeRange])
                purpose =
                    purposeMatched
                    .replacingOccurrences(of: "[COMMAND_PURPOSE:", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            #if DEBUG
            print("✅ [L2] AI wants to run terminal command: \(command)")
            #endif
            #if DEBUG
            print("   Purpose: \(purpose)")
            #endif
            return .terminalCommand(command: command, purpose: purpose)
        }

        // Check if AI wants to execute a command (legacy format)
        if let range = response.range(
            of: #"\[EXECUTE_COMMAND:\s*([^\]]+)\]"#, options: .regularExpression)
        {
            let matched = String(response[range])
            let command =
                matched
                .replacingOccurrences(of: "[EXECUTE_COMMAND:", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            #if DEBUG
            print("✅ [L2] AI wants to execute command: \(command)")
            #endif
            return .executeCommand(command)
        }

        // Otherwise, it's a direct answer
        #if DEBUG
        print("💬 [L2] Direct answer from AI")
        #endif
        return .directAnswer(response)
    }

    // Store suggested extension code for easy copying
    // Generated extension proposal state lives in AIChatViewModel.



    // MARK: - Extension Proposal Helpers

    /// Build the system-prompt appendix that asks the AI to emit an extension proposal block
    /// when it can automate the user's action with AppleScript or bash.
    func extensionProposalPromptAppendix(appName: String, query: String) -> String {
        let q = query.lowercased()
        let isQuestion =
            q.hasSuffix("?") || q.hasPrefix("what") || q.hasPrefix("how")
            || q.hasPrefix("why") || q.hasPrefix("explain") || q.hasPrefix("tell")
            || q.hasPrefix("describe") || q.hasPrefix("who") || q.hasPrefix("when")
        guard !isQuestion else { return "" }
        return """

            ══ AUTOMATION ASSISTANT MODE ══
            LAST RESORT ONLY. If an adapter action, a verified menu command (menu_call), or a
            linked tool (MCP/Shortcut/CLI/API) can do what the user asked, use THAT — do not
            propose a script. Only when NONE of those fit — including cross-app actions this
            app has no route for (e.g. "add selected text to Reminders" from a code editor) —
            do NOT just narrate options. Instead, write the automation and propose it as a
            saveable extension:
            1. Answer in one plain-English sentence.
            2. Immediately follow with a working script wrapped in these exact markers:

            <<EXTENSION_PROPOSAL>>
            {
              "type": "extension_proposal",
              "name": "<short verb-noun name, e.g. Save Page as PDF>",
              "description": "<one-line description>",
              "scriptType": "<applescript or bash>",
              "script": "<complete, runnable script — NO placeholders, NO TODOs>",
              "layer": "contextDock",
              "triggers": [{"type": "appContext", "value": "\(appName)"}],
              "icon": "<SF Symbol name>",
              "value": {"label": "<unit>", "default": "<the number in this request>"}
            }
            <<END_PROPOSAL>>

            RULES:
            - Prefer AppleScript for macOS app automation (\(appName), Finder, System Events, Notes).
            - Prefer bash for file ops, network calls, or multi-step shell workflows.
            - Use $CD_URL for the current page URL; $CD_TEXT for selected text; $CD_FILE for selected file path.
            - Design recurring actions for reuse. Use $CD_QUERY for the new request and read live
              state at run time (for example `git log -1`) instead of hardcoding today's content.
              A fixed destination such as a person/email may stay fixed when that is the workflow's
              purpose; changing content, files, branch, selection, and URL must stay dynamic.
            - If the request names a quantity that will change next time — a delay, a count, a
              percentage, a size — do not bake it in. Put {{value}} where it goes (works in bash
              and AppleScript) and declare it in "value": "label" is the unit the script needs
              there ("seconds", "minutes", "percent", "count"); "default" is the number from this
              request in that unit. "minimise after 5 min" → `sleep {{value}}` with
              {"label": "seconds", "default": "300"}, so "after 10 min" runs the SAME saved
              action with 600 instead of a new script. One value per action. Omit "value" when
              nothing varies.
            - For reusable email actions, extract an email address from $CD_QUERY when one is
              present and use the address from the original request only as the fallback. This
              lets one saved action draft to different people without generating another script.
            - For tasks needing user input, use `osascript -e 'display dialog...'` or `choose from list`.
            - The script must be 100% complete and run as-is — no stubs, no comments asking to fill in.
            - If you cannot write a fully working script, omit the proposal block entirely.
            """
    }

    /// Deterministic file-operation routing for selected files. Injected so the model stops
    /// asking "which tool?" and just uses the built-in macOS tool that always exists — sips for
    /// image conversion/resize, markitdown/qlmanage for documents, ditto for archives — running
    /// once per selected file. Only falls back to a linked CLI when no built-in can do it.
    func selectionFileOperationGuidance() -> String {
        let files = aiMode.selectionFiles
        guard !files.isEmpty else { return "" }
        let exts = Set(files.map { $0.pathExtension.lowercased() })
        let imageExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp",
            "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "raw",
        ]
        let hasImages = !exts.isDisjoint(with: imageExts)
        var lines: [String] = [
            "",
            "══ FILE ACTIONS (selected files: \(files.count)) ══",
            "Use the built-in macOS tool — do NOT ask the user which tool, and do NOT reach for",
            "ImageMagick/other installs when a built-in can do it. Run once PER selected file and",
            "write the output next to the source. Report each file done.",
        ]
        if hasImages {
            lines.append(
                "- Image format convert/resize → `sips`. Convert to JPEG: "
                + "`sips -s format jpeg \"<file>\" --out \"<file-without-ext>.jpg\"` "
                + "(png→`format png`, heic→`format heic`). sips reads RAW (dng/cr2/nef/arw) too, "
                + "so RAW→JPEG is just sips — never ImageMagick. Resize: `sips -Z <maxpx> \"<file>\"`.")
        }
        lines.append(
            "- Documents (pdf/docx/pptx/xlsx) → `markitdown \"<file>\"`; text/preview → `qlmanage -p`.")
        lines.append("- Archive/zip → `ditto -c -k --keepParent \"<file>\" \"<file>.zip\".")
        lines.append(
            "For multiple files, convert EACH one (loop or repeat the command); never emit one "
            + "command that only handles the first file.")
        return lines.joined(separator: "\n")
    }

    /// Selection-Scope variant of the automation appendix. Prefers an existing Selection Scope
    /// extension, and only when none fit does it write the automation and propose it as a
    /// saveable extension keyed on the selected content ({file}/{selectedText}), so it reappears
    /// for that file type / selection next time.
    func selectionScopeExtensionProposalAppendix(query: String) -> String {
        let q = query.lowercased()
        let isQuestion =
            q.hasSuffix("?") || q.hasPrefix("what") || q.hasPrefix("how")
            || q.hasPrefix("why") || q.hasPrefix("explain") || q.hasPrefix("tell")
            || q.hasPrefix("describe") || q.hasPrefix("who") || q.hasPrefix("when")
        guard !isQuestion else { return "" }
        return """

            ══ SELECTION-SCOPE AUTOMATION ══
            LAST RESORT ONLY. First use an existing Selection Scope extension or a built-in macOS
            tool (sips for image conversion/resize, markitdown for documents, Vision OCR, ditto/zip
            for archives). Only when NONE fit — and the request is an ACTION on the selection — do
            NOT just narrate steps. Write the automation and propose it as a saveable extension:
            1. Answer in one plain-English sentence.
            2. Immediately follow with a working script wrapped in these exact markers:

            <<EXTENSION_PROPOSAL>>
            {
              "type": "extension_proposal",
              "name": "<short verb-noun name, e.g. Convert DNG to JPEG>",
              "description": "<one-line description>",
              "scriptType": "bash",
              "script": "<complete, runnable script — NO placeholders, NO TODOs>",
              "layer": "selection",
              "triggers": [{"type": "fileType", "value": "<selected file extension, e.g. dng>"}],
              "icon": "<SF Symbol name>"
            }
            <<END_PROPOSAL>>

            RULES:
            - Operate on the selected content: use {file} for the selected file/folder path,
              {selectedText} for selected text, {url} for a link. Never hardcode a path.
            - Prefer a built-in tool (sips, markitdown, ditto, qlmanage) over installing anything.
            - If it needs a CLI that may be missing, START the script by checking it:
              `command -v <tool> >/dev/null 2>&1 || { echo "<tool> not installed — run: brew install <formula>"; exit 1; }`.
            - The script must be 100% complete and run as-is. If you can't write a working script,
              omit the proposal block entirely and say what IS possible.
            """
    }

    /// After an AI response arrives, extract any embedded proposal, strip the markers from the
    /// displayed text, and return an updated message tagged for the extension card UI.
    func tagMessageWithProposal(_ msg: AIChatMessage) -> AIChatMessage {
        guard let proposal = ExtensionProposalData.parse(from: msg.content),
            let json = proposal.asJSON()
        else { return msg }
        let cleaned = ExtensionProposalData.cleanResponse(msg.content)
        // Carry the fields the caller already filled in. Rebuilding with only the proposal
        // silently dropped the route trace and the tool chips, so a proposed extension lost
        // the record of the search that led to it — the case where that record matters most.
        return AIChatMessage(
            id: msg.id, role: msg.role, content: cleaned,
            structuredData: json, hasInstallButton: true,
            attachments: msg.attachments, appLaunches: msg.appLaunches,
            mcpToolsRan: msg.mcpToolsRan, trace: msg.trace, runOutput: msg.runOutput
        )
    }

    /// Execute a proposal's script immediately without saving.
    /// Substitutes the `{file}` / `{selectedText}` / `{url}` placeholders the app documents
    /// everywhere (Automation settings, trigger rules, the extension-proposal prompt) into a
    /// script before it runs. Without this a proposal script runs with the literal text
    /// `{file}` in it: `ffmpeg -i "{file}"` fails, `set -e` exits, and nothing is produced —
    /// which reads as "it said converted but there's no file".
    ///
    /// Values are shell-escaped because they land inside double quotes in the script.
    func expandSelectionPlaceholders(in script: String) -> String {
        let ctx = effectiveShareAXContext()
        let selectionFiles = effectiveSelectedFileURLsForConversation().map(\.path)
        let files = selectionFiles.isEmpty ? ctx.selectedFilePaths : selectionFiles
        let text =
            (effectiveSelectionForScope.flatMap { selection -> String? in
                if case .text(let value) = selection { return value }
                return nil
            }) ?? ctx.selectedText ?? ""

        func escaped(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        return script
            .replacingOccurrences(of: "{file}", with: escaped(files.first ?? ""))
            .replacingOccurrences(
                of: "{files}", with: escaped(files.joined(separator: "\" \"")))
            .replacingOccurrences(of: "{selectedText}", with: escaped(text))
            .replacingOccurrences(of: "{text}", with: escaped(text))
            .replacingOccurrences(of: "{url}", with: escaped(ctx.currentURL ?? ""))
            .replacingOccurrences(
                of: "{clipboard}",
                with: escaped(NSPasteboard.general.string(forType: .string) ?? ""))
            .replacingOccurrences(of: "{appName}", with: escaped(ctx.appName))
    }

    /// Single truthful report for anything script-shaped that runs on a selection: the chat says
    /// what the exit code says, with the real output attached. Silence used to read as success.
    /// Live, truthful run status shown in place of the thinking dots ("Running ffmpeg…").
    /// Passing nil ends it. Targets whichever chat surface is on screen.
    func setScriptRunStatus(_ status: String?) {
        if aiMode.isActive {
            aiMode.loadingStatus = status
            aiMode.isLoading = status != nil
        } else {
            l2.loadingStatus = status
            l2.isLoading = status != nil
        }
    }

    func reportExtensionRun(name: String, succeeded: Bool, detail: String, exitCode: Int32) {
        setScriptRunStatus(nil)
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the log out of the bubble — it goes behind the collapsed "Output" disclosure.
        let tail = trimmed.count > 4000 ? "…" + String(trimmed.suffix(4000)) : trimmed
        let content =
            succeeded
            ? "✅ \(name) ran."
            : "⚠️ \(name) failed (exit \(exitCode))."
                + (tail.isEmpty ? " No output — check the script." : "")
        let message = AIChatMessage(
            role: .assistant, content: content, isError: !succeeded, runOutput: tail)
        if aiMode.isActive {
            aiMode.messages.append(message)
            persistGeneralAIConversation()
        } else {
            l2.chatMessages.append(message)
            persistActiveL2DockSession()
        }
    }














    func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            #if DEBUG
            print("❌ Failed to create AppleScript")
            #endif
            return nil
        }

        let output = scriptObject.executeSerialized(error: &error)

        if let error = error {
            #if DEBUG
            print("❌ AppleScript error: \(error)")
            #endif
            return nil
        }

        return output.stringValue
    }

    // NOTE: executeShellCommandSafely was removed (P0 security fix). It ran an arbitrary
    // string through `bash -c` with ZERO classification — a loaded gun whose name implied
    // safety. It had no callers (dead code). Any AI-reachable command execution must go
    // through TerminalAIBridge.processAICommand, which classifies and gates on approval.




    // MARK: - Extension Catalog for AI











    // performSearch(), SmartQueryType, detectSmartQuery(), findExactApplicationMatch()
    // → moved to LauncherView+Search.swift

    // handleSmartQueryResult() → moved to LauncherView+Search.swift

    /// Converts user-defined AppShortcuts into SearchResult rows and prepends them
    /// to the pinned results so they appear at the top of the smart-query view.
    func injectAppShortcuts(for appKey: String) {
        let shortcuts = settings.shortcuts(for: appKey)
        guard !shortcuts.isEmpty else { return }

        let shortcutResults: [SearchResult] = shortcuts.map { sc in
            SearchResult(
                title: sc.name,
                subtitle: sc.actionValue,
                icon: NSImage(systemSymbolName: sc.iconName, accessibilityDescription: sc.name),
                action: { [sc] in
                    switch sc.actionType {
                    case .openURL:
                        if let url = URL(string: sc.actionValue) { NSWorkspace.shared.open(url) }
                    case .openFile:
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: sc.actionValue),
                            configuration: NSWorkspace.OpenConfiguration())
                    case .shellCommand:
                        let proc = Process()
                        proc.launchPath = "/bin/zsh"
                        proc.arguments = ["-c", sc.actionValue]
                        try? proc.run()
                    case .appleScript:
                        if let script = NSAppleScript(source: sc.actionValue) {
                            script.executeSerialized(error: nil)
                        }
                    case .jxa:
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent("ilauncher_jxa_\(UUID().uuidString).js")
                        try? sc.actionValue.write(to: tmp, atomically: true, encoding: .utf8)
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        p.arguments = ["-l", "JavaScript", tmp.path]
                        try? p.run()
                    case .scriptFile:
                        AXTriggerRuleEngine.shared.run(type: .scriptFile, value: sc.actionValue)
                    case .menuItem:
                        AXTriggerRuleEngine.shared.run(type: .menuItem, value: sc.actionValue)
                    case .shortcut:
                        AXTriggerRuleEngine.shared.run(type: .shortcut, value: sc.actionValue)
                    }
                },
                type: .shortcut,
                filePath: nil,
                contactData: nil
            )
        }
        // Prepend as pinned "Quick Actions" section; content follows below
        setPinnedResults(shortcutResults, title: "Quick Actions", excludeTypes: [])
    }

    func loadApplicationSpecificContent(appPath: String) {
        let expectedQuery = searchState.query.trimmingCharacters(in: .whitespaces)
        Task {
            await MainActor.run {
                let currentQuery = searchState.query.trimmingCharacters(in: .whitespaces)
                guard currentQuery == expectedQuery else { return }
                var appResults: [SearchResult] = []

                // Add the app itself as first result
                let appName = URL(fileURLWithPath: appPath).deletingPathExtension()
                    .lastPathComponent
                let appIcon = NSWorkspace.shared.icon(forFile: appPath)

                appResults.append(
                    SearchResult(
                        title: appName,
                        subtitle: appPath,
                        icon: appIcon,
                        action: {
                            NSWorkspace.shared.openApplication(
                                at: URL(fileURLWithPath: appPath),
                                configuration: NSWorkspace.OpenConfiguration())
                        },
                        type: .application,
                        filePath: appPath,
                        contactData: nil
                    ))

                // TODO: Add recent documents opened by this app
                // TODO: Add app settings/preferences
                // For now, just show the app itself

                setPinnedResults(appResults, title: "Application", excludeTypes: [])
                #if DEBUG
                print("✅ Loaded app-specific content for \(appName)")
                #endif
            }
        }
    }

    // performSearchWithoutSpotlight() → moved to LauncherView+Search.swift

    // findApplications() → moved to LauncherView+Search.swift

    func launchPinnedApp(_ app: PinnedApp) {
        if app.type == .application {
            let resolvedBundleId = bundleIdentifier(for: app)
            _ = launchApplication(
                bundleIdentifier: resolvedBundleId,
                appName: app.name,
                path: app.path
            )
            if isGlobalContextActive {
                scheduleContextDockTransition(bundleId: resolvedBundleId, appName: app.name)
            }
            return
        }

        // For files and shortcuts - open normally
        let url = URL(fileURLWithPath: app.path)
        NSWorkspace.shared.open(url)
        onClose()
    }

}
