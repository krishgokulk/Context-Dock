// LauncherView+GeneralAIActions.swift
// Context-Dock
//
// DoraX Action Chat — General AI Chat integration for executable requests.
//
// Runs before the normal provider answer path in sendToAIProvider. When the user's
// message is an executable request ("open safari new private window"), this resolves
// real routes through GeneralAIActionResolver, shows route lookup status in the
// existing chat loading row, asks first-run approval (Allow Once / Always Allow /
// Cancel) inline, executes through GeneralAIActionExecutor, and returns an honest
// result message. Returns nil for non-executable queries so normal Q&A continues.

import SwiftUI

extension LauncherView {

    /// Executable-action interception for General AI Chat. Returns the final chat
    /// answer when the query was handled as a DoraX action, or nil to fall through
    /// to the normal provider pipeline.
    func generalAIExecutableActionAnswer(query: String) async -> String? {
        await MainActor.run { aiMode.loadingStatus = "Checking DoraX action routes…" }
        let resolution = await GeneralAIActionResolver.shared.resolve(query: query)

        switch resolution {
        case .none:
            // No deterministic route. If the user enabled a dedicated AppleScript model
            // (e.g. Osaurus AppleScript-8B) and this is an automation-shaped request,
            // let the specialist generate a script and run it with approval.
            if let scripted = await appleScriptModelFallbackAnswer(query: query) {
                return scripted
            }
            await MainActor.run { aiMode.loadingStatus = nil }
            return nil

        case .explain(let message):
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = ["DoraX route lookup"]
            }
            return message

        case .clarify(let question, let options):
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.pendingToolChips = ["DoraX route lookup"]
            }
            guard !options.isEmpty else { return question }
            let list = options.map { "• \($0)" }.joined(separator: "\n")
            return question + "\n" + list

        case .candidates(let candidates):
            guard let best = candidates.first else {
                await MainActor.run { aiMode.loadingStatus = nil }
                return nil
            }
            // Medium confidence with meaningfully different alternatives → ask, don't guess.
            if best.confidence < 0.7 {
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.pendingToolChips = ["DoraX route lookup"]
                }
                let list = candidates.prefix(3)
                    .map { "• \($0.title) — \($0.routeLabel)" }
                    .joined(separator: "\n")
                return "I found these possible actions — which one should I run?\n" + list
            }
            return await runGeneralAIAction(best, alternatives: Array(candidates.dropFirst()))
        }
    }

    private func runGeneralAIAction(
        _ candidate: DoraXActionCandidate,
        alternatives: [DoraXActionCandidate]
    ) async -> String {
        let appLabel = candidate.appName ?? "app"
        await MainActor.run {
            aiMode.loadingStatus = "Found route: \(candidate.title) (\(candidate.routeLabel))"
        }
        // Route-specific first-run approval. "Always Allow" is scoped to this exact
        // permission key, never to the whole app.
        if !GeneralAIActionApprovalStore.isAlwaysAllowed(candidate.permissionKey) {
            await MainActor.run { aiMode.loadingStatus = "Approval required…" }
            let decision = await GeneralAIActionApprovalCenter.shared.request(candidate: candidate)
            if decision == .cancel {
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.pendingToolChips = ["Cancelled: \(candidate.routeLabel)"]
                }
                return "Cancelled — nothing was executed."
            }
        }

        await MainActor.run { aiMode.loadingStatus = "Running \(appLabel) action…" }
        let result = await GeneralAIActionExecutor.shared.execute(candidate)
        await MainActor.run {
            aiMode.loadingStatus = nil
            aiMode.pendingToolChips = ["\(candidate.title) · \(candidate.routeLabel)"]
        }

        if result.success {
            return result.message
        }
        var answer = "That didn't work: \(result.message)"
        if let fallback = alternatives.first {
            answer += "\n\nI also found a fallback route — \(fallback.title) "
                + "(\(fallback.routeLabel)). Say “try the fallback” and I'll run it."
        }
        return answer
    }

    /// Dedicated-automation-backend fallback: when no deterministic route matched, ask the
    /// specialist AppleScript model to generate a script, show it for approval, then run it.
    /// Returns nil (→ normal chat) when the model is off, unconfigured, or the query isn't
    /// an automation-shaped request.
    private func appleScriptModelFallbackAnswer(query: String) async -> String? {
        guard AppleScriptModelService.shared.isEnabledAndConfigured,
            GeneralAIActionResolver.shared.looksExecutable(query)
        else { return nil }

        let appHint = GeneralAIActionResolver.shared.namedInstalledApp(in: query)?.name
        await MainActor.run { aiMode.loadingStatus = "Generating AppleScript…" }
        let generated: AppleScriptModelService.GeneratedScript
        do {
            generated = try await AppleScriptModelService.shared.generateAppleScript(
                instruction: query, appHint: appHint)
        } catch {
            await MainActor.run { aiMode.loadingStatus = nil }
            // Model enabled but failed → tell the user honestly rather than falling back
            // silently to a chat guess.
            return "Couldn't generate AppleScript: "
                + (error.localizedDescription)
        }

        let preview = generated.script
        let firstLine = preview.split(separator: "\n").first.map(String.init) ?? "AppleScript"
        var candidate = DoraXActionCandidate(
            id: "automation.appleScriptModel",
            title: appHint.map { "Run AppleScript on \($0)" } ?? "Run generated AppleScript",
            appName: appHint,
            bundleID: nil,
            source: .automation,
            route: .automation,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .high,
            confidence: 0.9,
            permissionKey: "generalAI.execute.appleScriptModel",
            debugReason: "AppleScript model fallback: \(firstLine)"
        )
        candidate.inputValues = ["appleScript": preview]

        await MainActor.run { aiMode.loadingStatus = "Approval required…" }
        if !GeneralAIActionApprovalStore.isAlwaysAllowed(candidate.permissionKey) {
            let decision = await GeneralAIActionApprovalCenter.shared.request(candidate: candidate)
            if decision == .cancel {
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.pendingToolChips = ["Cancelled: AppleScript"]
                }
                return "Cancelled — nothing was executed.\n\nGenerated script was:\n```applescript\n"
                    + preview + "\n```"
            }
        }

        await MainActor.run { aiMode.loadingStatus = "Running AppleScript…" }
        let result = await GeneralAIActionExecutor.shared.execute(candidate)
        await MainActor.run {
            aiMode.loadingStatus = nil
            aiMode.pendingToolChips = ["AppleScript · automation model"]
        }
        if result.success {
            return result.message
        }
        return "That didn't work: \(result.message)\n\nGenerated script:\n```applescript\n"
            + preview + "\n```"
    }
}

// MARK: - Named-app runtime grounding

extension LauncherView {

    /// Live app-state context for General Chat questions about a named app
    /// ("what's going on with vs code?"). Pulls the SAME powers frontmost-app chat
    /// already uses — adapter context readers, runtime CLI snapshots (code --status,
    /// imsg, tailscale), the menu capability cache, MCP/adapter inventory — so the
    /// provider answers from real state instead of "unable to access application status".
    /// Returns "" when the query names no installed app or isn't status-shaped.
    func generalAppRuntimeContextBlock(for query: String) async -> String {
        let lowered = query.lowercased()
        guard let app = GeneralAIActionResolver.shared.namedInstalledApp(in: query) else {
            return ""
        }
        // Only status/state questions pay for live reads.
        let statusWords = [
            "what", "doing", "going on", "status", "open", "current", "working",
            "why", "running", "which", "how many", "show", "recent", "state",
            "explore", "inspect", "pause", "play", "song", "track", "music",
        ]
        guard statusWords.contains(where: lowered.contains) else { return "" }

        await MainActor.run { aiMode.loadingStatus = "Reading \(app.name) state…" }
        var lines: [String] = [
            "## Live \(app.name) state (read by DoraX just now — factual)",
        ]

        // Running / frontmost state.
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: app.bundleId).first
        if let running {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleId
            lines.append("- \(app.name) is running\(frontmost ? " and frontmost" : "")"
                + (running.isHidden ? " (hidden)" : ""))
        } else {
            lines.append("- \(app.name) is NOT running right now")
        }

        let mediaInfo = await MediaRemoteBridge.shared.infoAsync()
        let media = MediaRemoteBridge.parse(mediaInfo)
        let mediaClient = await MediaRemoteBridge.shared.clientAsync()
        let observerMediaApp = MediaPlayerObserver.shared.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mediaClient.bundleID == app.bundleId
            || mediaClient.displayName?.localizedCaseInsensitiveContains(app.name) == true
            || (!observerMediaApp.isEmpty
                && app.name.localizedCaseInsensitiveContains(observerMediaApp)) {
            let title = media.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let artist = media.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(
                    "- \(app.name) now playing: \(title)"
                    + (artist.isEmpty ? "" : " by \(artist)")
                    + (media.isPlaying ? " (playing)" : " (paused)")
                )
            }
        }

        // Adapter context readers — the same live readers frontmost-app chat runs
        // (current file, git branch, workspace, …).
        if AppAdapterManager.shared.adapter(for: app.bundleId) != nil, running != nil {
            let readerData = await AppAdapterManager.shared.runContextReaders(
                for: app.bundleId, axContext: AXContextReader.shared.current)
            for (_, value) in readerData.sorted(by: { $0.key < $1.key })
            where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(String(value.prefix(600)))
            }
        }

        // Runtime CLI snapshots: VS Code `code --status`, Messages imsg, Tailscale CLI.
        let cliSnapshot = await runtimeAppCLIContextPrompt(
            bundleId: app.bundleId, appName: app.name, query: query)
        if !cliSnapshot.isEmpty {
            lines.append("")
            lines.append(cliSnapshot)
        }

        // Compact capability inventory so the model knows what DoraX can DO with
        // this app (and offers real next actions instead of "check their website").
        var inventory: [String] = []
        let adapterActions = AppAdapterManager.shared.actions(for: app.bundleId)
        if !adapterActions.isEmpty {
            inventory.append(
                "\(adapterActions.count) adapter actions ("
                + adapterActions.prefix(6).map(\.name).joined(separator: ", ") + "…)")
        }
        let mcpServers = MCPServerManager.shared.servers(forBundleId: app.bundleId)
        if !mcpServers.isEmpty {
            inventory.append("\(mcpServers.count) linked MCP server(s)")
        }
        if let summary = AppMenuCapabilityCache.shared.summary(bundleIdentifier: app.bundleId) {
            inventory.append("\(summary.recordCount) cached menu commands")
        }
        if !inventory.isEmpty {
            lines.append("")
            lines.append("DoraX capabilities registered for \(app.name): "
                + inventory.joined(separator: "; ") + ".")
        }

        lines.append("")
        lines.append(
            "Answer the user's question about \(app.name) from the data above. "
            + "If something isn't in the data, say DoraX couldn't read that specific detail — "
            + "NEVER reply \"unable to access application status\" and never answer from "
            + "generic product knowledge when live state is shown here.")
        await MainActor.run {
            aiMode.pendingToolChips.append("\(app.name) live state")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Inline approval card

/// First-run approval card shown inside the General Chat surface (no new floating
/// window). Observes the approval center directly so the huge LauncherView struct
/// doesn't need a new @State/@ObservedObject property.
struct GeneralAIActionApprovalCard: View {
    @ObservedObject private var center = GeneralAIActionApprovalCenter.shared

    var body: some View {
        if let pending = center.pending {
            let candidate = pending.candidate
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.orange)
                    Text("Run \(candidate.title)?")
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                }
                Text("Route: \(candidate.routeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = candidate.menuPath, !path.isEmpty {
                    Text(path.joined(separator: " → "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Generated AppleScript gets a full, scrollable preview so the user sees
                // exactly what will run before approving arbitrary automation.
                if let script = candidate.inputValues["appleScript"],
                    !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("This script will run:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(script)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                HStack(spacing: 8) {
                    Button("Allow Once") {
                        GeneralAIActionApprovalCenter.shared.resolve(.allowOnce)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Always Allow") {
                        GeneralAIActionApprovalCenter.shared.resolve(.allowAlways)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Cancel", role: .cancel) {
                        GeneralAIActionApprovalCenter.shared.resolve(.cancel)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
                    )
            )
        }
    }
}
