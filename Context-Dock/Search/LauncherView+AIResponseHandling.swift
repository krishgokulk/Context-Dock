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

    func copySuggestedExtension() {
        guard let code = suggestedExtensionCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        // Show confirmation
        let confirmMessage = AIChatMessage(
            role: .assistant,
            content:
                "✅ Extension code copied to clipboard! Save it to ExtensionLibrary/ and make it executable."
        )
        l2.chatMessages.append(confirmMessage)
    }

    func installSuggestedExtension() {
        guard let code = suggestedExtensionCode else { return }

        Task {
            do {
                // Extract extension metadata from code comments
                let extensionName = extractExtensionName(from: code)
                let description = extractExtensionDescription(from: code)
                let layer = extractExtensionLayer(from: code)
                await MainActor.run {
                    let scriptType = determineExtensionScriptType(from: code)
                    let category = inferExtensionCategory(layer: layer, appName: frontmost.name)
                    let triggers = buildExtensionTriggers(layer: layer, appName: frontmost.name)
                    let ext = ILExtension(
                        name: extensionName,
                        description: description,
                        icon: "sparkles",
                        layer: layer.contains("l1")
                            ? .l1_search : (layer.contains("l3") ? .l3_browser : .l2_context),
                        tags: [.automation],
                        category: category,
                        triggers: triggers,
                        scriptPath: "",
                        scriptContent: code,
                        scriptType: scriptType,
                        isBuiltIn: false
                    )

                    LayeredExtensionManager.shared.addExtension(ext)
                    updateL2ContextExtensions()

                    let successMessage = """
                        ✅ Extension installed successfully!

                        📦 **\(extensionName)**
                        📝 \(description)
                        📂 Saved to: Application Support/Context-Dock/Extensions

                        The extension has been added and is now available in your Extensions library!
                        """

                    let confirmMessage = AIChatMessage(role: .assistant, content: successMessage)
                    l2.chatMessages.append(confirmMessage)
                }

            } catch {
                await MainActor.run {
                    let errorMessage = AIChatMessage(
                        role: .assistant,
                        content: "❌ Failed to install extension: \(error.localizedDescription)",
                        isError: true
                    )
                    l2.chatMessages.append(errorMessage)
                }
            }
        }
    }

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
              "icon": "<SF Symbol name>"
            }
            <<END_PROPOSAL>>

            RULES:
            - Prefer AppleScript for macOS app automation (\(appName), Finder, System Events, Notes).
            - Prefer bash for file ops, network calls, or multi-step shell workflows.
            - Use $CD_URL for the current page URL; $CD_TEXT for selected text; $CD_FILE for selected file path.
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
        return AIChatMessage(
            id: msg.id, role: msg.role, content: cleaned,
            structuredData: json, hasInstallButton: true
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
        requestWindowSizeUpdate(reason: .chatChanged)
    }

    func runOnceFromProposal(_ json: String) {
        guard let data = json.data(using: .utf8),
            let proposal = try? JSONDecoder().decode(ExtensionProposalData.self, from: data)
        else { return }
        // Selection Scope freezes its payload, and the dock is frontmost by the time this runs —
        // so the live AX read is the wrong source for the file being acted on.
        let ctx = effectiveShareAXContext()
        let selectionFiles = effectiveSelectedFileURLsForConversation().map(\.path)
        let contextFiles = selectionFiles.isEmpty ? ctx.selectedFilePaths : selectionFiles
        let envVars: [String: String] = [
            "CD_URL": ctx.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
            "CD_TEXT": ctx.selectedText ?? "",
            "CD_FILE": contextFiles.first ?? "",
            "CD_FILES": contextFiles.joined(separator: "\n"),
            "CD_APP": ctx.appName,
            "CD_TITLE": ctx.windowTitle ?? "",
        ]
        let script = expandSelectionPlaceholders(in: proposal.script)
        AppToast.show(
            "Running \(proposal.name)…", icon: "bolt.fill", tint: .blue.opacity(0.9), duration: 2.0,
            centered: true)
        switch proposal.scriptType.lowercased() {
        case "applescript":
            // Run directly so failures surface. AXTriggerRuleEngine's AppleScript path
            // discards the error (executeAndReturnError(nil)), which is why "Add reminder"
            // reported success but nothing appeared — a permission denial or bad script
            // was swallowed. Capture the error and tell the user what actually happened.
            let outcome = runProposalAppleScript(script)
            if outcome.ok {
                AppToast.show(
                    "\(proposal.name) ran", icon: "checkmark.circle.fill",
                    tint: .green, duration: 2.0, centered: true)
                let detail = outcome.message.isEmpty ? "" : " \(outcome.message)"
                l2.chatMessages.append(
                    AIChatMessage(role: .tool, content: "✅ \(proposal.name) ran.\(detail)"))
            } else {
                AppToast.show(
                    "\(proposal.name) failed", icon: "exclamationmark.triangle.fill",
                    tint: .orange, duration: 3.5, centered: true)
                l2.chatMessages.append(
                    AIChatMessage(
                        role: .assistant,
                        content: "⚠️ \(proposal.name) didn't run:\n\n\(outcome.message)",
                        isError: true))
            }
        default:
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("proposal_\(UUID().uuidString).sh")
            try? script.write(to: tmp, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            // Run in the VISIBLE dock terminal — the user watches the clone/build/
            // install live instead of a silent background process. Context vars are
            // exported first so $CD_URL etc. resolve inside the script.
            let consoleKey = prepareScopedWorkspaceTerminal()
            let term = panelTerminal(for: consoleKey)
            showLivePanel(.terminal)
            // The terminal is a live PTY with no output API, so the run leaves its own trail:
            // stdout+stderr tee'd to a log, the exit code written to a marker file. Swift polls
            // the marker and reports the real outcome — otherwise a failing script just scrolls
            // past and the chat implies it worked.
            let runID = UUID().uuidString
            let logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("proposal_\(runID).log")
            let statusURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("proposal_\(runID).status")
            let exports = envVars.map { key, value in
                let safe = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                return "export \(key)=\"\(safe)\""
            }.joined(separator: "; ")
            term.sendCommand(
                "\(exports); bash \"\(tmp.path)\" > >(tee \"\(logURL.path)\") 2>&1; "
                + "echo $? > \"\(statusURL.path)\"")
            setScriptRunStatus("Running \(proposal.name)…")
            awaitProposalRunOutcome(
                name: proposal.name, logURL: logURL, statusURL: statusURL)
        }
    }

    /// Polls for the exit-code marker the terminal run writes, then reports the outcome once.
    /// Gives up quietly after 10 minutes so a long-running or abandoned job never reports a
    /// result it doesn't have.
    private func awaitProposalRunOutcome(name: String, logURL: URL, statusURL: URL) {
        let deadline = Date().addingTimeInterval(600)
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let fm = FileManager.default
                guard let raw = try? String(contentsOf: statusURL, encoding: .utf8) else {
                    // Still running: mirror the script's own last line of output as the status,
                    // so the user sees the real work ("[download] 62% of 4MiB") rather than dots.
                    self.setScriptRunStatus(
                        Self.liveRunStatus(name: name, logURL: logURL))
                    if Date() < deadline { poll() }
                    return
                }
                let exitCode =
                    Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
                let log =
                    (try? String(contentsOf: logURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.reportExtensionRun(
                    name: name, succeeded: exitCode == 0, detail: log, exitCode: exitCode)
                try? fm.removeItem(at: statusURL)
                try? fm.removeItem(at: logURL)
            }
        }
        poll()
    }

    /// Last meaningful line of a running script's log, shortened for the status strip.
    private static func liveRunStatus(name: String, logURL: URL) -> String {
        let fallback = "Running \(name)…"
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return fallback }
        let lines = log.split(whereSeparator: \.isNewline)
        guard var last = lines.last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty
        else { return fallback }
        if last.count > 70 { last = String(last.prefix(70)) + "…" }
        return "\(name): \(last)"
    }

    /// Run a proposal's AppleScript synchronously and return whether it succeeded plus a
    /// human message. Unlike the trigger engine it does NOT discard the error dictionary,
    /// so permission denials and script bugs are reported instead of failing silently.
    func runProposalAppleScript(_ source: String) -> (ok: Bool, message: String) {
        guard let script = NSAppleScript(source: source) else {
            return (false, "The AppleScript couldn't be compiled.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error."
            let code = error[NSAppleScript.errorNumber] as? Int
            // -1743 = errAEEventNotPermitted: the target app's Automation permission isn't granted.
            if code == -1743 || message.lowercased().contains("not allowed to send apple events") {
                return (
                    false,
                    "\(message)\n\nGrant it in System Settings → Privacy & Security → Automation → "
                    + "Context-Dock, enable the target app, then run it again."
                )
            }
            return (false, message)
        }
        return (true, result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Save a proposal — as a Selection Scope extension when it was proposed for that layer,
    /// otherwise as a persistent Context Trigger rule.
    func installFromProposal(_ json: String) {
        guard let data = json.data(using: .utf8),
            let proposal = try? JSONDecoder().decode(ExtensionProposalData.self, from: data)
        else { return }
        // A selection-layer proposal has to land in the extension store the Selection Scope
        // sheet and Settings both read (`layer == .l2_context`, `category == "shortcutSheet"`).
        // Saving it as a trigger rule — as every proposal used to — meant the user pressed
        // "Save as Extension" and it appeared in neither place.
        if proposal.layer.lowercased() == "selection" {
            installSelectionScopeExtension(proposal)
            return
        }
        let lang: AppScriptLanguage = {
            switch proposal.scriptType.lowercased() {
            case "applescript": return .applescript
            case "jxa": return .jxa
            default: return .bash
            }
        }()
        let savedPath =
            AppSettings.shared.saveScript(
                appKey: "context-dock", name: proposal.name, language: lang, code: proposal.script
            ) ?? ""
        let actionType: AppShortcut.ActionType = savedPath.isEmpty ? .appleScript : .scriptFile
        let actionValue = savedPath.isEmpty ? proposal.script : savedPath
        let conditions: [AXTriggerCondition] = proposal.triggers.compactMap { t in
            switch t.type {
            case "appContext":
                return AXTriggerCondition(field: .appName, op: .contains, value: t.value)
            case "urlPattern":
                return AXTriggerCondition(field: .currentURL, op: .contains, value: t.value)
            case "fileType":
                return AXTriggerCondition(field: .filePath, op: .endsWith, value: ".\(t.value)")
            default: return nil
            }
        }
        let pill = AXRulePill(
            label: proposal.name,
            icon: proposal.icon ?? "sparkles",
            accentColor: "blue",
            actionType: actionType,
            actionValue: actionValue
        )
        // Rules with no conditions are always-on global — use a non-empty conditions list.
        let finalConditions: [AXTriggerCondition] =
            conditions.isEmpty
            ? [AXTriggerCondition(field: .appName, op: .isNotEmpty, value: "")]
            : conditions
        let rule = AXTriggerRule(
            name: proposal.name, isEnabled: true,
            conditions: finalConditions, conditionLogic: .any, pills: [pill], priority: 10
        )
        AppSettings.shared.addAXRule(rule)
        let confirmation = AIChatMessage(
            role: .assistant,
            content:
                "**\(proposal.name)** saved as an extension. It runs automatically when its "
                + "selection/context matches, or type \"\(proposal.name.lowercased())\" to run it.")
        // Route the confirmation to whichever chat raised the proposal.
        if aiMode.isActive {
            aiMode.messages.append(confirmation)
        } else {
            l2.chatMessages.append(confirmation)
        }
    }

    /// Installs a proposed Selection Scope action as a real extension: it then shows up as a
    /// row in the selection sheet, is listed and editable in Settings, and survives relaunch.
    private func installSelectionScopeExtension(_ proposal: ExtensionProposalData) {
        let scriptType: ILExtension.ScriptType = {
            switch proposal.scriptType.lowercased() {
            case "applescript": return .applescript
            case "jxa", "javascript": return .javascript
            case "python": return .python
            case "swift": return .swift
            default: return .bash
            }
        }()
        let ext = ILExtension(
            name: proposal.name,
            description: proposal.description,
            icon: proposal.icon ?? "sparkles",
            layer: .l2_context,
            category: "shortcutSheet",
            enabled: true,
            scriptContent: proposal.script,
            scriptType: scriptType,
            author: "DoraX AI"
        )
        LayeredExtensionManager.shared.addExtension(ext)
        let confirmation = AIChatMessage(
            role: .assistant,
            content:
                "**\(proposal.name)** saved as a Selection Scope extension. It appears as a row "
                + "whenever a matching selection is active, and in Settings → Extensions."
        )
        if aiMode.isActive {
            aiMode.messages.append(confirmation)
        } else {
            l2.chatMessages.append(confirmation)
        }
    }

    func extractExtensionName(from code: String) -> String {
        // Look for "# Extension: Name" in comments
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Extension:") {
                return line.replacingOccurrences(of: "# Extension:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "Custom Extension"
    }

    func extractExtensionDescription(from code: String) -> String {
        // Look for "# Description: ..." in comments
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Description:") {
                return line.replacingOccurrences(of: "# Description:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "No description provided"
    }

    func extractExtensionLayer(from code: String) -> String {
        // Look for "# Layer: ..." in comments
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Layer:") {
                return line.replacingOccurrences(of: "# Layer:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "l2_context"  // Default to L2
    }

    func determineExtensionScriptType(from code: String, language: String? = nil)
        -> ILExtension.ScriptType
    {
        if code.hasPrefix("#!/bin/bash") || code.hasPrefix("#!/usr/bin/env bash")
            || code.hasPrefix("#!/bin/sh") || language == "bash" || language == "sh"
        {
            return .bash
        }
        if code.hasPrefix("#!/usr/bin/env python") || code.hasPrefix("#!/usr/bin/python")
            || language == "python"
        {
            return .python
        }
        if code.hasPrefix("#!/usr/bin/osascript") || language == "applescript" {
            return .applescript
        }
        return .bash
    }

    func inferExtensionCategory(layer: String, appName: String) -> String {
        let normalized = appName.lowercased()
        if layer.contains("l2") {
            if normalized.contains("safari") || normalized.contains("chrome")
                || normalized.contains("arc")
            {
                return "browser"
            }
            if normalized.contains("finder") {
                return "finder"
            }
            if normalized.contains("mail") {
                return "mail"
            }
            if normalized.contains("notes") || normalized.contains("textedit") {
                return "text-editor"
            }
            if normalized.contains("xcode") || normalized.contains("vscode") {
                return "code-editor"
            }
        }
        if layer.contains("l3") {
            return "page-enhancers"
        }
        return "custom"
    }

    func buildExtensionTriggers(layer: String, appName: String) -> [ExtensionTrigger] {
        if layer.contains("l2"), !appName.isEmpty {
            return [.appContext(appName)]
        }
        return [.always]
    }

    func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            #if DEBUG
            print("❌ Failed to create AppleScript")
            #endif
            return nil
        }

        let output = scriptObject.executeAndReturnError(&error)

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

    func parseAIAction(_ response: String) -> AIAction? {
        // Legacy - keeping for compatibility
        return nil
    }

    func executeAIAction(_ action: AIAction) async {
        // Legacy - keeping for compatibility
    }

    enum AIAction {
        case findFiles(path: String, criteria: String)
        case listDirectory(path: String)
        case getFileInfo(path: String)
        case openFile(path: String)
    }

    // MARK: - Extension Catalog for AI

    struct ExtensionInfo {
        let name: String
        let description: String
        let keywords: [String]
        let capabilities: String
        let category: String
    }

    func getAvailableExtensionsForContext(frontmostApp: String?, context: UserContext)
        -> [ExtensionInfo]
    {
        #if DEBUG
        print("📚 [L2] Building extension catalog for AI")
        #endif

        // Get all context-relevant extensions
        let selectedFiles: [URL] = {
            if case .filesSelected(let urls) = context {
                return urls
            }
            return []
        }()

        let allExtensions = LayeredExtensionManager.shared.discoverExtensions(
            for: "",
            selectedFiles: selectedFiles,
            frontmostApp: frontmostApp,
            layer: .l2_context
        )

        #if DEBUG
        print("📚 [L2] Found \(allExtensions.count) total extensions")
        #endif

        // Filter context-relevant extensions
        let relevantExtensions = allExtensions.filter { ext in
            ext.ilExtension.triggers.contains { trigger in
                switch trigger {
                case .appContext:
                    return true
                case .fileType:
                    if case .filesSelected = context {
                        return true
                    }
                    return false
                case .keyword:
                    return true
                default:
                    return false
                }
            }
        }

        #if DEBUG
        print("📚 [L2] Filtered to \(relevantExtensions.count) relevant extensions")
        #endif

        // Convert to simplified info for AI
        let catalog = relevantExtensions.map { ext -> ExtensionInfo in
            let keywords = extractKeywordsFromExtension(ext.ilExtension)
            let capabilities = ext.ilExtension.intents.map { $0.action }.joined(separator: ", ")

            return ExtensionInfo(
                name: ext.ilExtension.name,
                description: ext.ilExtension.description,
                keywords: keywords,
                capabilities: capabilities.isEmpty ? "General actions" : capabilities,
                category: ext.ilExtension.category
            )
        }

        // Log catalog
        for ext in catalog.prefix(5) {
            #if DEBUG
            print("  📦 \(ext.name): \(ext.description)")
            #endif
        }
        if catalog.count > 5 {
            #if DEBUG
            print("  ... and \(catalog.count - 5) more")
            #endif
        }

        return catalog
    }

    func extractKeywordsFromExtension(_ ext: ILExtension) -> [String] {
        var keywords: [String] = []

        for trigger in ext.triggers {
            if case .keyword(let kws) = trigger {
                keywords.append(contentsOf: kws)
            }
        }

        // Also extract from intents
        keywords.append(contentsOf: ext.intents.map { $0.action })
        if let target = ext.intents.first?.target {
            keywords.append(target)
        }

        return Array(Set(keywords))  // Remove duplicates
    }

    func findExtension(named name: String) -> ILExtension? {
        let allExtensions = LayeredExtensionManager.shared.discoverExtensions(
            for: "",
            selectedFiles: [],
            frontmostApp: frontmost.name,
            layer: .l2_context
        )

        return allExtensions.first { ext in
            ext.ilExtension.name.lowercased() == name.lowercased()
                || ext.ilExtension.name.lowercased().contains(name.lowercased())
        }?.ilExtension
    }

    func executeShortcutWithContext(_ result: SearchResult) {
        let shortcutName = result.title

        #if DEBUG
        print("🎯 [Shortcut Execution] Executing '\(shortcutName)' with context: \(currentContext)")
        #endif

        // Use Universal Runner v2 system
        Task {
            do {
                let frontmostApp = NSWorkspace.shared.frontmostApplication

                var files: [URL] = []
                var text: String? = nil
                var url: String? = nil

                // Extract context data
                switch currentContext {
                case .filesSelected(let urls):
                    files = urls
                    #if DEBUG
                    print("📁 Context: \(urls.count) file(s)")
                    #endif
                    for fileURL in urls {
                        #if DEBUG
                        print("   📄 \(fileURL.lastPathComponent)")
                        #endif
                    }

                case .textSelected(let textContent):
                    text = textContent
                    let preview = textContent.prefix(100)
                    #if DEBUG
                    print("📝 Context: Text - \"\(preview)\(textContent.count > 100 ? "..." : "")\"")
                    #endif

                    // Check if it's a URL
                    if let urlFromText = URL(string: textContent), urlFromText.scheme != nil {
                        url = textContent
                        #if DEBUG
                        print("🌐 Detected as URL: \(textContent)")
                        #endif
                    }

                case .url(let urlString):
                    url = urlString
                    text = urlString
                    #if DEBUG
                    print("🌐 Context: URL - \(urlString)")
                    #endif

                case .appFocused(let appName, _):
                    #if DEBUG
                    print("🖥️ Context: App focused - \(appName)")
                    #endif

                case .contactSelected:
                    #if DEBUG
                    print("👤 Context: Contact selected")
                    #endif

                case .none:
                    #if DEBUG
                    print("❌ No context")
                    #endif
                }

                // Execute DIRECTLY with input (no Runner v2 needed!)
                let output: String

                if !files.isEmpty {
                    // Files context - send files directly
                    print(
                        "🎯 [Direct Execution] Sending \(files.count) file(s) directly to '\(shortcutName)'"
                    )
                    output = try await ShortcutRunner.shared.runDirectly(
                        shortcutName,
                        with: .files(files)
                    )
                } else if let text = text {
                    // Text context - send text directly
                    #if DEBUG
                    print("🎯 [Direct Execution] Sending text directly to '\(shortcutName)'")
                    #endif
                    output = try await ShortcutRunner.shared.runDirectly(
                        shortcutName,
                        with: .text(text)
                    )
                } else if let url = url {
                    // URL context - send URL as text directly
                    #if DEBUG
                    print("🎯 [Direct Execution] Sending URL directly to '\(shortcutName)'")
                    #endif
                    output = try await ShortcutRunner.shared.runDirectly(
                        shortcutName,
                        with: .url(url)
                    )
                } else {
                    // No context - run shortcut without input
                    #if DEBUG
                    print("🎯 [Direct Execution] Running '\(shortcutName)' without input")
                    #endif
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                    process.arguments = ["run", shortcutName]

                    let outputPipe = Pipe()
                    process.standardOutput = outputPipe

                    try process.run()
                    process.waitUntilExit()

                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    output =
                        String(data: data, encoding: .utf8)?.trimmingCharacters(
                            in: .whitespacesAndNewlines) ?? ""
                }

                await MainActor.run {
                    #if DEBUG
                    print("✅ [ShortcutRunner] Output: \(output)")
                    #endif

                    // Handle output (could be file path, text, or status)
                    if output.starts(with: "/") {
                        // It's a file path - reveal in Finder
                        let fileURL = URL(fileURLWithPath: output)
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } else if !output.isEmpty && output != "OK" {
                        // Show as notification or toast
                        #if DEBUG
                        print("📋 Result: \(output)")
                        #endif
                    }

                    // Close launcher
                    onClose()
                }

            } catch ShortcutRunner.RunnerError.runnerNotInstalled {
                await MainActor.run {
                    #if DEBUG
                    print("⚠️ ILauncher Runner v2 not installed - falling back to direct execution")
                    #endif
                    // Fallback to old method
                    executeShortcutLegacy(result)
                }

            } catch {
                await MainActor.run {
                    #if DEBUG
                    print("❌ Shortcut execution failed: \(error)")
                    #endif
                    onClose()
                }
            }
        }
    }

    // Legacy execution method (fallback)
    func executeShortcutLegacy(_ result: SearchResult) {
        switch currentContext {
        case .filesSelected(let urls):
            let filePaths = urls.map { $0.path }
            runShortcutWithInputLegacy(name: result.title, input: filePaths)

        case .textSelected(let text):
            runShortcutWithInputLegacy(name: result.title, input: text)

        case .url(let urlString):
            runShortcutWithInputLegacy(name: result.title, input: urlString)

        case .none, .appFocused, .contactSelected:
            result.action()
        }
    }

    func runShortcutWithInputLegacy(name: String, input: Any) {
        Task {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

            // Convert input to JSON string
            let inputString: String
            if let textInput = input as? String {
                inputString = textInput
            } else if let arrayInput = input as? [String] {
                // For file arrays, pass as newline-separated list
                inputString = arrayInput.joined(separator: "\n")
            } else {
                #if DEBUG
                print("⚠️ Unsupported input type")
                #endif
                return
            }

            // Run shortcut with input via stdin
            process.arguments = ["run", name, "--input-path", "-"]

            let inputPipe = Pipe()
            let outputPipe = Pipe()

            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()

                // Write input to stdin
                if let inputData = inputString.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(inputData)
                }
                inputPipe.fileHandleForWriting.closeFile()

                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    #if DEBUG
                    print("✅ Shortcut '\(name)' completed successfully")
                    #endif
                } else {
                    let errorData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if let errorOutput = String(data: errorData, encoding: .utf8) {
                        #if DEBUG
                        print("❌ Shortcut '\(name)' failed: \(errorOutput)")
                        #endif
                    }
                }
            } catch {
                #if DEBUG
                print("❌ Failed to run shortcut '\(name)': \(error)")
                #endif
            }
        }
    }

    func handleDirectInput() {
        let trimmed = searchState.query.trimmingCharacters(in: .whitespaces)

        // Check if it's a URL
        if let url = URL(string: trimmed), url.scheme != nil {
            NSWorkspace.shared.open(url)
            searchState.query = ""
            hideLauncherAfterResultExecution()
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            // Try as a URL with https://
            if let url = URL(string: "https://\(trimmed)") {
                NSWorkspace.shared.open(url)
                searchState.query = ""
                hideLauncherAfterResultExecution()
            } else {
                // Not a valid URL, perform web search
                performWebSearch(query: trimmed)
            }
        } else {
            // Perform inline web search
            performWebSearch(query: trimmed)
        }
    }

    func performWebSearch(query: String) {
        let encodedQuery =
            query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://www.google.com/search?q=\(encodedQuery)"
        if let url = URL(string: urlString) {
            settings.addRecentWebSearch(query)
            NSWorkspace.shared.open(url)
        }
        searchState.query = ""
        hideLauncherAfterResultExecution()
    }

    func fetchWebSearchResults(query: String) async throws -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            #if DEBUG
            print("❌ Failed to encode query")
            #endif
            return []
        }

        // Use DuckDuckGo Instant Answer API (no API key required)
        let urlString =
            "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1"
        #if DEBUG
        print("🌐 Fetching from: \(urlString)")
        #endif
        guard let url = URL(string: urlString) else {
            #if DEBUG
            print("❌ Invalid URL")
            #endif
            return []
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        #if DEBUG
        print("🌐 Received \(data.count) bytes of data")
        #endif

        struct DDGResponse: Codable {
            let Abstract: String?
            let AbstractText: String?
            let AbstractSource: String?
            let AbstractURL: String?
            let Heading: String?
            let RelatedTopics: [RelatedTopic]?

            struct RelatedTopic: Codable {
                let Text: String?
                let FirstURL: String?
                let Icon: IconInfo?

                struct IconInfo: Codable {
                    let URL: String?
                }
            }
        }

        let response = try JSONDecoder().decode(DDGResponse.self, from: data)
        var results: [SearchResult] = []

        print(
            "🌐 DDG Response - Abstract: \(response.AbstractText ?? "none"), Topics: \(response.RelatedTopics?.count ?? 0)"
        )

        // Add main abstract result if available
        if let abstractText = response.AbstractText, !abstractText.isEmpty,
            let abstractURL = response.AbstractURL, let url = URL(string: abstractURL)
        {
            let heading = response.Heading ?? query
            #if DEBUG
            print("🌐 Adding abstract result: \(heading)")
            #endif
            results.append(
                SearchResult(
                    title: heading,
                    subtitle: abstractText,
                    icon: NSImage(
                        systemSymbolName: "info.circle.fill", accessibilityDescription: nil),
                    action: { NSWorkspace.shared.open(url) },
                    score: 100.0,
                    type: .webSearch,
                    filePath: nil,
                    contactData: nil
                ))
        }

        // Add related topics as results
        if let topics = response.RelatedTopics {
            for topic in topics.prefix(5) {
                guard let text = topic.Text, !text.isEmpty,
                    let urlString = topic.FirstURL,
                    let url = URL(string: urlString)
                else {
                    continue
                }

                // Split text into title and description
                let parts = text.components(separatedBy: " - ")
                let title = parts.first ?? text
                let subtitle = parts.count > 1 ? parts[1...].joined(separator: " - ") : urlString

                results.append(
                    SearchResult(
                        title: title,
                        subtitle: subtitle,
                        icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil),
                        action: { NSWorkspace.shared.open(url) },
                        score: 90.0,
                        type: .webSearch,
                        filePath: nil,
                        contactData: nil
                    ))
            }
        }

        // Always add "Search on Google" as fallback
        let googleQuery =
            query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let googleURL = URL(string: "https://www.google.com/search?q=\(googleQuery)") {
            #if DEBUG
            print("🌐 Adding Google search fallback")
            #endif
            results.append(
                SearchResult(
                    title: "Search \"\(query)\" on Google",
                    subtitle: "Open Google search in browser",
                    icon: NSImage(
                        systemSymbolName: "magnifyingglass", accessibilityDescription: nil),
                    action: {
                        NSWorkspace.shared.open(googleURL)
                    },
                    score: 50.0,
                    type: .webSearch,
                    filePath: nil,
                    contactData: nil
                ))
        }

        #if DEBUG
        print("🌐 Returning \(results.count) total results")
        #endif
        return results
    }

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
                            script.executeAndReturnError(nil)
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
