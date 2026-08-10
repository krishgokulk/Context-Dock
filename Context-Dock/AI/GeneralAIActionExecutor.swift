// GeneralAIActionExecutor.swift
// Context-Dock
//
// Executes a DoraXActionCandidate produced by GeneralAIActionResolver, after
// first-run approval. Every route validates before acting and reports honest
// results — General Chat may only claim "done" when an executor returns success.
//
// Route mapping:
//   .adapter          → CapabilityRegistry executor (via AIExecutionEngine) or AdapterAction
//   .shortcutRunner   → ShortcutRunner
//   .keyboardShortcut → launch/activate app + CGEvent shortcut
//   .verifiedMenu     → MenuExecutionCoordinator.executeVerifiedMenuAction (live-verified)
//   .axFallback       → AXActionResolver, only after a live menu verification
//   .automation       → app automation service (Messages compose, …)
//   .appLaunch        → NSWorkspace launch/activate
//   .cli              → terminal.runCommand capability (preview + classifier gated)

import AppKit
import Combine
import Foundation

// MARK: - Approval persistence

/// "Always Allow" store — keys are exact, route-specific permission keys
/// (e.g. generalAI.execute.com.apple.Safari.new-private-window), never app-wide.
enum GeneralAIActionApprovalStore {
    private static let defaultsKey = "generalAI.alwaysAllowedActionKeys"

    static func isAlwaysAllowed(_ permissionKey: String) -> Bool {
        let keys = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return keys.contains(permissionKey)
    }

    static func allowAlways(_ permissionKey: String) {
        var keys = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard !keys.contains(permissionKey) else { return }
        keys.append(permissionKey)
        UserDefaults.standard.set(keys, forKey: defaultsKey)
    }

    static func revoke(_ permissionKey: String) {
        var keys = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        keys.removeAll { $0 == permissionKey }
        UserDefaults.standard.set(keys, forKey: defaultsKey)
    }
}

// MARK: - Approval center (inline chat card, same pattern as AICapabilityApprovalCenter)

@MainActor
final class GeneralAIActionApprovalCenter: ObservableObject {
    static let shared = GeneralAIActionApprovalCenter()

    enum Decision {
        case allowOnce
        case allowAlways
        case cancel
    }

    struct PendingApproval: Identifiable {
        let id = UUID()
        let candidate: DoraXActionCandidate
        let continuation: CheckedContinuation<Decision, Never>
    }

    @Published private(set) var pending: PendingApproval?
    private var expiryTask: Task<Void, Never>?

    private init() {}

    func request(candidate: DoraXActionCandidate) async -> Decision {
        // Only one approval at a time; a newer request cancels the stale one.
        if pending != nil { resolve(.cancel) }
        return await withCheckedContinuation { continuation in
            pending = PendingApproval(candidate: candidate, continuation: continuation)
            expiryTask?.cancel()
            expiryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.resolve(.cancel)
            }
        }
    }

    func resolve(_ decision: Decision) {
        guard let pending else { return }
        expiryTask?.cancel()
        expiryTask = nil
        self.pending = nil
        if decision == .allowAlways {
            GeneralAIActionApprovalStore.allowAlways(pending.candidate.permissionKey)
        }
        pending.continuation.resume(returning: decision)
    }
}

// MARK: - Executor

struct GeneralAIActionResult {
    let success: Bool
    let message: String
}

@MainActor
final class GeneralAIActionExecutor {
    static let shared = GeneralAIActionExecutor()

    private init() {}

    func execute(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        let result: GeneralAIActionResult
        switch candidate.route {
        case .appLaunch:
            result = await executeAppLaunch(candidate)
        case .adapter:
            result = await executeAdapterRoute(candidate)
        case .keyboardShortcut:
            result = await executeKeyboardShortcut(candidate)
        case .verifiedMenu:
            result = await executeVerifiedMenu(candidate)
        case .axFallback:
            result = await executeAXFallback(candidate)
        case .shortcutRunner:
            result = await executeShortcutRunner(candidate)
        case .automation:
            result = await executeAutomation(candidate)
        case .cli:
            result = await executeCLI(candidate)
        case .mcp:
            result = await executeMCP(candidate)
        case .api:
            result = executeAPI(candidate)
        }
        AIAuditHistory.shared.record(
            capabilityID: candidate.permissionKey,
            risk: candidate.riskLevel,
            approved: true,
            success: result.success,
            summary: result.message
        )
        return result
    }

    // MARK: - Verification (Stage 7)

    /// Outcome of a single lightweight read-back after a successful write action.
    enum VerificationOutcome {
        /// Confirmed. Optional refined success message ("I've added reminder …").
        case verified(String?)
        /// Executor succeeded but the result couldn't be confirmed — never report success.
        case unverified(fallback: String)
        /// No verifier for this route — keep the executor's own honest message.
        case skipped
    }

    /// Read the result back exactly once (no polling, no retries, background reads) to
    /// confirm a write actually landed before General Chat claims success. Only verifiers
    /// that are cheap and reliable are implemented; everything else returns `.skipped` so
    /// the honest executor message stands (we never emit a false "couldn't verify").
    func verify(_ candidate: DoraXActionCandidate) async -> VerificationOutcome {
        switch candidate.capabilityID {
        case "reminders.create":
            let title = candidate.inputValues["title"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return .skipped }
            let items = await Task.detached(priority: .utility) {
                AppleAppsAPI.shared.getReminders(limit: 30)
            }.value
            let found = items.contains {
                ($0["title"] as? String)?.localizedCaseInsensitiveContains(title) ?? false
            }
            return found
                ? .verified("I've added reminder “\(title)”.")
                : .unverified(fallback: "I couldn't find it in Reminders just now.")

        case "calendar.create":
            let title = (candidate.inputValues["title"] ?? candidate.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return .skipped }
            let events = await Task.detached(priority: .utility) {
                AppleAppsAPI.shared.getCalendarEvents(limit: 30)
            }.value
            if let match = events.first(where: {
                ($0["title"] as? String)?.localizedCaseInsensitiveContains(title) ?? false
            }) {
                let when = (match["startDate"] as? String).flatMap(Self.friendlyEventDate) ?? ""
                return .verified(
                    "Calendar event “\(title)”\(when.isEmpty ? "" : " for \(when)") was created.")
            }
            return .unverified(fallback: "I couldn't find the event in Calendar just now.")

        case "notes.create":
            let title = candidate.inputValues["title"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return .skipped }
            let matches = await Task.detached(priority: .utility) {
                AppleAppsAPI.shared.searchNotes(query: title)
            }.value
            return matches.isEmpty
                ? .unverified(fallback: "I couldn't find that note in Notes just now.")
                : .verified("I've created the note “\(title)”.")

        // Filesystem writes verify against the filesystem, which is the one read-back with
        // no scripting bridge, no permission prompt and no timing window between it and the
        // thing it is checking.
        case "finder.newFolder":
            let destination = candidate.inputValues["destination"] ?? ""
            let name = candidate.inputValues["name"] ?? ""
            guard !destination.isEmpty, !name.isEmpty else { return .skipped }
            let url = URL(fileURLWithPath: destination, isDirectory: true)
                .appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
                ? .verified("Created the folder “\(name)”.")
                : .unverified(fallback: "I couldn't find that folder afterwards.")

        // Deletion is where an unearned "done" costs the most: the user stops looking for
        // something that is still there, or believes something is gone that is not.
        case "finder.trash":
            let path = candidate.inputValues["path"] ?? ""
            guard !path.isEmpty else { return .skipped }
            return FileManager.default.fileExists(atPath: path)
                ? .unverified(fallback: "It's still at \(path).")
                : .verified(nil)

        case "reminders.delete", "reminders.complete":
            let title = candidate.inputValues["title"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return .skipped }
            let items = await Task.detached(priority: .utility) {
                AppleAppsAPI.shared.getReminders(limit: 50)
            }.value
            // getReminders returns open reminders, so completing one removes it from this
            // list exactly as deleting it does — absence is the confirmation either way.
            let stillOpen = items.contains {
                ($0["title"] as? String)?.localizedCaseInsensitiveContains(title) ?? false
            }
            return stillOpen
                ? .unverified(fallback: "“\(title)” is still in Reminders.")
                : .verified(nil)

        default:
            break
        }

        switch candidate.route {
        case .appLaunch:
            guard let bundleID = candidate.bundleID else { return .skipped }
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .contains { !$0.isTerminated }
            return running
                ? .verified(nil)
                : .unverified(fallback: "\(candidate.appName ?? "The app") isn't running.")
        default:
            return .skipped
        }
    }

    private static func friendlyEventDate(_ iso: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let cal = Calendar.current
        let dayWord: String
        if cal.isDateInToday(date) { dayWord = "today" }
        else if cal.isDateInTomorrow(date) { dayWord = "tomorrow" }
        else {
            let df = DateFormatter()
            df.dateFormat = "EEE MMM d"
            dayWord = df.string(from: date)
        }
        let tf = DateFormatter()
        tf.timeStyle = .short
        return "\(dayWord) at \(tf.string(from: date))"
    }

    // MARK: - App launch

    private func executeAppLaunch(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        guard let bundleID = candidate.bundleID,
              let app = await launchAndActivate(bundleID: bundleID)
        else {
            return .init(success: false, message: "Couldn't launch \(candidate.appName ?? "the app").")
        }
        let name = candidate.appName ?? app.localizedName ?? bundleID
        var message = "Opened \(name)."
        if let caveat = candidate.caveat { message += " \(caveat)" }
        return .init(success: true, message: message)
    }

    // MARK: - Registered capability / adapter action

    private func executeAdapterRoute(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        // Registered capability (reminders.create, calendar.create, …) — validated and
        // run through the existing engine. Approval already happened in General Chat,
        // so pass approved: true; .critical is still blocked inside execute().
        if let capabilityID = candidate.capabilityID {
            guard CapabilityRegistry.shared.capability(id: capabilityID) != nil else {
                return .init(success: false, message: "Capability \(capabilityID) is not registered.")
            }
            var capabilityInput = candidate.inputValues
            if capabilityID.hasPrefix("notes."),
                candidate.requiredInputs.contains("noteID"),
                capabilityInput["noteID", default: ""].isEmpty
            {
                do {
                    capabilityInput["noteID"] = try await AppleNotesMCPServer.shared.selectedNoteID()
                } catch {
                    return .init(
                        success: false,
                        message: "I couldn't identify the current note. Select a note in Notes and try again. \(error.localizedDescription)")
                }
            }
            let plan = AIActionPlan(
                capability: capabilityID,
                input: capabilityInput,
                explanation: "DoraX Action Chat: \(candidate.title)")
            do {
                let result = try await AIExecutionEngine.shared.execute(
                    plan, context: .none, approved: true)
                return .init(success: result.success, message: result.output)
            } catch {
                return .init(success: false, message: error.localizedDescription)
            }
        }
        // App adapter action.
        if let actionID = candidate.adapterActionID, let bundleID = candidate.bundleID {
            guard let adapter = AppAdapterManager.shared.adapter(for: bundleID),
                  var action = adapter.actions.first(where: { $0.id == actionID })
            else {
                return .init(success: false, message: "Adapter action is no longer available.")
            }
            // General Chat already showed its own route-specific approval.
            action.requiresApproval = false
            let context = AXContextReader.shared.current
            let (success, output) = await AppAdapterManager.shared.execute(
                action, context: context, targetBundleId: bundleID)
            let fallbackMessage = success ? "Ran \(candidate.title)." : "\(candidate.title) failed."
            return .init(success: success, message: output.isEmpty ? fallbackMessage : output)
        }
        return .init(success: false, message: "Adapter route is missing its execution payload.")
    }

    // MARK: - Keyboard shortcut

    private func executeKeyboardShortcut(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        guard MenuExecutionCoordinator.ensureAccessibilityTrustOrPrompt() else {
            return .init(success: false, message: "Accessibility permission is required to send shortcuts.")
        }
        // Cached shortcuts belong to a cached menu record. Live-verify that menu first,
        // then let the coordinator send its shortcut or click the menu item as fallback.
        if candidate.menuPath?.isEmpty == false {
            return await executeVerifiedMenu(candidate)
        }
        guard let bundleID = candidate.bundleID,
              let char = candidate.shortcutChar, !char.isEmpty,
              let app = await launchAndActivate(bundleID: bundleID)
        else {
            return .init(success: false, message: "Couldn't activate the target app for the shortcut.")
        }
        // Let the app settle after activation before posting the HID event.
        try? await Task.sleep(nanoseconds: 180_000_000)
        let sent = AXMenuReader.shared.executeShortcut(
            char: char,
            modifiers: candidate.shortcutModifiers,
            in: app.processIdentifier)
        guard sent else {
            // Unsupported key code — degrade to the live-verified menu path if we have one.
            if candidate.menuPath?.isEmpty == false {
                return await executeVerifiedMenu(candidate)
            }
            return .init(success: false, message: "The shortcut key couldn't be posted.")
        }
        // Verify what we can: the target app must still be frontmost to have received it.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        guard frontmost else {
            return .init(
                success: false,
                message: "\(candidate.appName ?? "The app") lost focus before the shortcut landed — nothing was executed.")
        }
        let display = MenuShortcutFormatter.display(
            char: candidate.shortcutChar, modifiers: candidate.shortcutModifiers) ?? "shortcut"
        return .init(success: true, message: "Ran \(candidate.title) (\(display)).")
    }

    // MARK: - Verified menu

    private func executeVerifiedMenu(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        guard let bundleID = candidate.bundleID, let path = candidate.menuPath, !path.isEmpty else {
            return .init(success: false, message: "Menu route is missing its path.")
        }
        guard await launchAndActivate(bundleID: bundleID) != nil else {
            return .init(success: false, message: "Couldn't activate \(candidate.appName ?? bundleID).")
        }
        let (success, message) = await MenuExecutionCoordinator.shared.executeVerifiedMenuAction(
            bundleIdentifier: bundleID,
            path: path,
            cachedShortcutChar: candidate.shortcutChar,
            cachedShortcutModifiers: candidate.shortcutModifiers)
        return .init(success: success, message: message)
    }

    // MARK: - AX fallback (last resort, only after live verification)

    private func executeAXFallback(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        guard MenuExecutionCoordinator.ensureAccessibilityTrustOrPrompt() else {
            return .init(success: false, message: "Accessibility permission is required.")
        }
        guard let bundleID = candidate.bundleID, let path = candidate.menuPath, !path.isEmpty,
              let app = await launchAndActivate(bundleID: bundleID)
        else {
            return .init(success: false, message: "Couldn't activate the target app.")
        }
        // Live verification before clicking — never blind-click.
        let liveItems = AXMenuReader.shared.refreshAllMenuItems(
            for: app.processIdentifier, maxDepth: 6)
        let normalizedTarget = path.map { $0.lowercased() }
        let verified = liveItems.contains { item in
            item.isEnabled && item.path.map({ $0.lowercased() }).suffix(normalizedTarget.count)
                .elementsEqual(normalizedTarget)
        }
        guard verified else {
            return .init(
                success: false,
                message: "\(path.joined(separator: " → ")) isn't available in \(candidate.appName ?? "the app") right now.")
        }
        AXActionResolver.shared.execute(menuPath: path, in: app)
        return .init(success: true, message: "Ran \(candidate.title) via accessibility.")
    }

    // MARK: - Shortcuts app

    private func executeShortcutRunner(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        guard let name = candidate.shortcutName, !name.isEmpty else {
            return .init(success: false, message: "No shortcut name on this route.")
        }
        do {
            let output = try await ShortcutRunner.shared.runDirectly(name, with: .text(""))
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                success: true,
                message: trimmed.isEmpty ? "Ran shortcut “\(name)”." : "Ran shortcut “\(name)”: \(trimmed)")
        } catch {
            return .init(success: false, message: "Shortcut “\(name)” failed: \(error.localizedDescription)")
        }
    }

    // MARK: - MCP tool route

    /// Execute a registered MCP tool through the SAME ranked-candidate/executor path as
    /// every other route (not only the provider tool-loop). The resolver puts the target
    /// in `inputValues`: mcpServer, mcpTool, mcpArguments (JSON object).
    private func executeMCP(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        guard let bundleID = candidate.bundleID,
            let tool = candidate.inputValues["mcpTool"], !tool.isEmpty
        else {
            return .init(success: false, message: "MCP route is missing its server/tool payload.")
        }
        let server = candidate.inputValues["mcpServer"] ?? ""
        var arguments: [String: Any] = [:]
        if let json = candidate.inputValues["mcpArguments"],
            let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = parsed
        }
        do {
            let output = try await MCPRuntime.shared.callTool(
                bundleId: bundleID, server: server, tool: tool, arguments: arguments)
            return .init(success: true, message: output)
        } catch {
            return .init(success: false, message: "MCP tool \(tool) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - API route

    /// Execute a DoraX API command through APICommandHandler. Args live in
    /// `inputValues["apiArgs"]` as a whitespace-separated command line.
    private func executeAPI(_ candidate: DoraXActionCandidate) -> GeneralAIActionResult {
        let raw = candidate.inputValues["apiArgs"] ?? ""
        let args = raw.split(separator: " ").map(String.init)
        guard !args.isEmpty else {
            return .init(success: false, message: "API route is missing its command payload.")
        }
        let output = APICommandHandler.shared.handleCommand(args)
        let failed = output.lowercased().hasPrefix("error") || output.lowercased().contains("unknown")
        return .init(success: !failed, message: output)
    }

    // MARK: - App automation services

    private func executeAutomation(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        switch candidate.id {
        case "automation.messages.compose":
            let recipient = candidate.inputValues["recipient"] ?? ""
            let body = candidate.inputValues["body"] ?? ""
            guard !recipient.isEmpty else {
                return .init(success: false, message: "Missing recipient.")
            }
            let output = await MessagesAutomation.composeMessage(to: recipient, body: body)
            let success = !output.hasPrefix("❌")
            return .init(success: success, message: output)

        case "automation.appleScriptModel":
            return executeGeneratedAppleScript(candidate)

        case "automation.nativeShare":
            return await executeNativeShare(candidate)

        case "automation.media.pause", "automation.media.play", "automation.media.next-track",
             "automation.media.previous-track":
            return executeMediaTransport(candidate)

        case "safari.bridge.summarize":
            return await summarizeSafariBridgePage(candidate)

        default:
            // Safari history / URL open — always the cached URL, never an AX menu click.
            if candidate.inputValues["automation"] == "safari.openURL",
               let url = candidate.inputValues["url"], !url.isEmpty {
                SafariTabManager.shared.openURL(url)
                return .init(success: true, message: "Opened \(url) in Safari.")
            }
            return .init(success: false, message: "Unknown automation route \(candidate.id).")
        }
    }

    /// Run AppleScript produced by the dedicated automation model. The script text lives
    /// in `inputValues["appleScript"]` — approval already happened before we get here.
    private func executeGeneratedAppleScript(_ candidate: DoraXActionCandidate) -> GeneralAIActionResult {
        let script = candidate.inputValues["appleScript"] ?? ""
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(success: false, message: "The automation model returned no script.")
        }
        guard let object = NSAppleScript(source: script) else {
            return .init(success: false, message: "Couldn't compile the generated AppleScript.")
        }
        var error: NSDictionary?
        let output = object.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed."
            return .init(success: false, message: "AppleScript error: \(msg)")
        }
        let value = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var message = value.isEmpty ? "Done." : value
        if let caveat = candidate.caveat { message += " \(caveat)" }
        return .init(success: true, message: message)
    }

    private func executeNativeShare(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        let raw = candidate.inputValues["rawQuery"] ?? ""
        guard let intent = ShareIntentRouter.shared.parse(raw) else {
            return .init(success: false, message: "Couldn't understand the share destination.")
        }
        let axContext = AXContextReader.shared.current
        guard !ShareIntentRouter.shared.shareItems(for: axContext).isEmpty else {
            return .init(success: false, message: "Nothing to share right now.")
        }
        let resolution = await ShareIntentRouter.shared.resolve(intent)
        let message = await ShareIntentRouter.shared.execute(resolution, axContext: axContext)
        return .init(success: !message.hasPrefix("❌"), message: message)
    }

    private func executeMediaTransport(_ candidate: DoraXActionCandidate) -> GeneralAIActionResult {
        let commandName = candidate.inputValues["verb"] ?? candidate.title
        let command: MRCommand
        switch candidate.id {
        case "automation.media.pause": command = .pause
        case "automation.media.play": command = .play
        case "automation.media.next-track": command = .nextTrack
        case "automation.media.previous-track": command = .previousTrack
        default:
            return .init(success: false, message: "Unknown media command.")
        }

        let sent = MediaRemoteBridge.shared.sendCommand(command)
        if !sent {
            let fallbackCommand: String
            switch command {
            case .pause: fallbackCommand = "pause"
            case .play: fallbackCommand = "play"
            case .nextTrack: fallbackCommand = "next"
            case .previousTrack: fallbackCommand = "previous"
            default: fallbackCommand = "toggle"
            }
            _ = MediaInfoProvider.shared.handleMediaCommand([fallbackCommand])
        }

        let target = candidate.inputValues["title"]?.isEmpty == false
            ? candidate.inputValues["title"]!
            : (candidate.inputValues["appName"] ?? "media")
        return .init(success: true, message: "\(commandName) sent to \(target).")
    }

    /// "Summarize this page": Safari extension context (URL/title/visible text) grounded
    /// through AIProviderRouter. The provider only summarizes — it never claims execution.
    private func summarizeSafariBridgePage(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        guard let context = SafariBrowserBridge.shared.currentContext(),
              !context.pageText.isEmpty
        else {
            return .init(
                success: false,
                message: "The Safari extension context went stale — reload the page and try again.")
        }
        do {
            let response = try await AIProviderRouter.shared.send(
                AIRequest(
                    text: "Summarize this page concisely.",
                    context: .url(context.url),
                    source: .aiChat,
                    liveContext: nil,
                    additionalContextPrompt: """
                    Page: \(context.title)
                    URL: \(context.url)

                    Page content (from the DoraX Safari extension):
                    \(context.pageTextForAI)
                    """
                )
            )
            return .init(success: true, message: response)
        } catch {
            return .init(success: false, message: "Summarize failed: \(error.localizedDescription)")
        }
    }

    // MARK: - CLI

    private func executeCLI(_ candidate: DoraXActionCandidate) async -> GeneralAIActionResult {
        guard let command = candidate.inputValues["command"], !command.isEmpty else {
            return .init(success: false, message: "CLI route is missing its command.")
        }
        let plan = AIActionPlan(
            capability: "terminal.runCommand",
            input: ["command": command, "purpose": candidate.title],
            explanation: candidate.debugReason)
        do {
            let result = try await AIExecutionEngine.shared.execute(
                plan, context: .none, approved: true)
            return .init(success: result.success, message: result.output)
        } catch {
            return .init(success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Launch/activate helper

    private func launchAndActivate(bundleID: String) async -> NSRunningApplication? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }) {
            if running.isHidden { running.unhide() }
            running.activate(options: [.activateIgnoringOtherApps])
            await AXActionResolver.waitForActivation(of: running)
            return await confirmActive(running, bundleID: bundleID) ? running : nil
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let launched: NSRunningApplication? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                continuation.resume(returning: app)
            }
        }
        guard let launched else { return nil }
        // Freshly launched apps need a moment before their menu bar / key window exists.
        for _ in 0..<20 {
            if launched.isFinishedLaunching { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        await AXActionResolver.waitForActivation(of: launched)
        return await confirmActive(launched, bundleID: bundleID) ? launched : nil
    }

    /// Confirm both launch completion and foreground activation before sending input.
    private func confirmActive(_ app: NSRunningApplication, bundleID: String) async -> Bool {
        for _ in 0..<12 {
            let isRunning = !app.isTerminated
                && NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .contains { !$0.isTerminated }
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
            if isRunning && isFrontmost { return true }
            app.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
