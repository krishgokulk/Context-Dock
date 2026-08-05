//
//  AppKnowledgeService.swift
//  Context-Dock
//
//  What Context Dock knows about one app, right now, as text an assistant can use.
//
//  Attaching an app to a chat used to pass its name and a list of adapter action
//  names — enough for the model to say what it *could* do, never enough to answer
//  "what tabs are open" or "summarise this page". Every source needed for that
//  already existed and was wired to a different surface: the Safari extension
//  bridge, the tab manager, each adapter's context-reader scripts, the AX reader.
//  This gathers them behind one call so any AI panel can ask the same question.
//

import AppKit

enum AppKnowledgeService {

    /// Live context for `appName`, or an empty string when nothing is knowable.
    /// Runs off the main thread where it shells out; safe to await from a view.
    static func context(forAppNamed appName: String) async -> String {
        let adapter = await MainActor.run {
            AppAdapterManager.shared.adapters.first {
                $0.appName == appName && $0.isEnabled
            }
        }
        let bundleId = adapter?.bundleId
            ?? NSWorkspace.shared.runningApplications
                .first { $0.localizedName == appName }?.bundleIdentifier

        var sections: [String] = ["## \(appName)"]

        if let adapter {
            let actions = adapter.actions.prefix(30).map(\.name)
            if !actions.isEmpty {
                sections.append("Actions Context Dock can run here: "
                                + actions.joined(separator: ", "))
            }
        }

        if let browser = await browserContext(bundleId: bundleId) {
            sections.append(browser)
        }
        if let live = await liveContext(appName: appName) {
            sections.append(live)
        }
        if let adapter, let readers = await runContextReaders(adapter) {
            sections.append(readers)
        }
        if let channels = await channels(bundleId: bundleId) {
            sections.append(channels)
        }

        // Only the heading means nothing was actually knowable — say nothing rather
        // than hand the model a bare app name it will treat as evidence.
        return sections.count > 1 ? sections.joined(separator: "\n\n") : ""
    }

    /// CLI tools, MCP servers and API connections the user has linked to this app.
    ///
    /// These are the answer to "the app isn't frontmost": accessibility can only read
    /// the front window, but a CLI or an MCP server responds whatever has focus. The
    /// model is told what channels exist and how to reach them, so it can propose a
    /// concrete command instead of guessing that one might exist.
    private static func channels(bundleId: String?) async -> String? {
        guard let bundleId else { return nil }

        var parts: [String] = []

        let packages = await MainActor.run {
            TerminalPackageManager.shared.packages(
                forContextBundleId: bundleId, maxResults: 8)
        }
        if !packages.isEmpty {
            let lines = packages.map { pkg -> String in
                // The cached --help is the difference between naming a tool and being
                // able to use it correctly.
                if let help = pkg.helpTextForPrompt, !help.isEmpty {
                    return "- \(pkg.name) (`\(pkg.command)`)\n\(help.prefix(1200))"
                }
                return "- \(pkg.name) (`\(pkg.command)`)"
            }
            parts.append("CLI tools linked to this app:\n" + lines.joined(separator: "\n"))
        }

        let servers = await MainActor.run {
            MCPServerManager.shared.servers.filter { $0.bundleIds.contains(bundleId) }
        }
        if !servers.isEmpty {
            let lines = servers.map { "- \($0.name) (\($0.transport): \($0.command) \($0.argsDisplay))" }
            parts.append("MCP servers linked to this app:\n" + lines.joined(separator: "\n"))
        }

        let apis = await MainActor.run {
            APIConnectionStore.shared.connections.filter { $0.adapterBundleId == bundleId }
        }
        if !apis.isEmpty {
            let lines = apis.map { conn -> String in
                let scope = conn.permissions.isEmpty ? "" : " — \(conn.permissions)"
                return "- \(conn.name) at \(conn.baseURL) [\(conn.status.rawValue)]\(scope)"
            }
            parts.append("API connections linked to this app:\n" + lines.joined(separator: "\n"))
        }

        guard !parts.isEmpty else { return nil }
        return (["These reach the app whether or not it is frontmost. Name the exact "
                 + "command or endpoint you would use; Context Dock runs it, you do not."]
                + parts).joined(separator: "\n\n")
    }

    // MARK: - Sources

    /// Safari and Safari Web Apps: the page the user is on, its links, and every
    /// open tab. Comes from the extension bridge, so it needs no Apple Events.
    private static func browserContext(bundleId: String?) async -> String? {
        guard let bundleId,
              bundleId == "com.apple.Safari" || bundleId.hasPrefix("com.apple.Safari.WebApp.")
        else { return nil }

        var parts: [String] = []

        if let page = await MainActor.run(body: { SafariBrowserBridge.shared.currentContext() }) {
            parts.append("Current page: \(page.title)\n\(page.url)")
            if !page.description.isEmpty {
                parts.append("Description: \(page.description)")
            }
            if !page.pageTextForAI.isEmpty {
                parts.append("Page content:\n\(page.pageTextForAI)")
            }
            if !page.links.isEmpty {
                let links = page.links.prefix(40)
                    .map { "- \($0.text) → \($0.url)" }
                    .joined(separator: "\n")
                parts.append("Links on the page:\n\(links)")
            }
        }

        let tabs = await MainActor.run { SafariTabManager.shared.cachedTabs(maxAge: 30) }
        if !tabs.isEmpty {
            let list = tabs.prefix(40)
                .map { "- \($0.title) — \($0.url)" }
                .joined(separator: "\n")
            parts.append("Open tabs:\n\(list)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Window title, URL and selection — only meaningful for the frontmost app,
    /// since that is all the accessibility reader observes.
    private static func liveContext(appName: String) async -> String? {
        let ctx = await MainActor.run { AXContextReader.shared.current }
        guard ctx.appName == appName else { return nil }

        var parts: [String] = []
        if let title = ctx.windowTitle, !title.isEmpty { parts.append("Front window: \(title)") }
        if let url = ctx.currentURL, !url.isEmpty { parts.append("Current URL: \(url)") }
        if let sel = ctx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sel.isEmpty {
            parts.append("Selected text:\n\(sel.prefix(2000))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// An adapter's own context-reader scripts. This is the extensible half: a user
    /// who wants their app to expose something specific writes a reader for it and
    /// every AI panel gains that knowledge without any Swift.
    private static func runContextReaders(_ adapter: AppAdapter) async -> String? {
        guard !adapter.contextReaders.isEmpty else { return nil }

        var parts: [String] = []
        for reader in adapter.contextReaders.prefix(6) {
            let output = await runScript(type: reader.type, script: reader.script)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            parts.append("\(reader.name):\n\(trimmed.prefix(2000))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func runScript(type: String, script: String) async -> String {
        let (exe, args): (String, [String]) = {
            switch type.lowercased() {
            case "applescript": return ("/usr/bin/osascript", ["-e", script])
            case "jxa":         return ("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
            default:            return ("/bin/zsh", ["-lc", script])
            }
        }()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do { try process.run() } catch {
                    continuation.resume(returning: ""); return
                }
                // A context reader sits between the user pressing Send and the model
                // being called, so it gets a short leash.
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
