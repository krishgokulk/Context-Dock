// DoraXDiagnosticReport.swift
// Context-Dock
//
// One artefact that says what went wrong, in enough detail to fix it without asking.
//
// The evidence needed to diagnose a failure already exists at the moment it happens — the
// question, the provider and model, the scope, what actually ran, the quota state, the
// build. It is spread across five surfaces and none of it survives the turn, so a report
// reaching the developer is "it didn't work", and the next hour goes into rebuilding
// context that the app had all along and discarded.
//
// This gathers it. It does not fix anything: the app cannot rewrite and rebuild itself
// while it is the thing running. What it can do is make the fix a five-minute job instead
// of a re-investigation, and hand a real reproduction to Claude Code, which can.
//
// Nothing here reaches the network. It is assembled on demand and goes where the user sends
// it — clipboard, a file, or a prompt they choose to send.

import AppKit
import Foundation

struct DoraXDiagnosticReport: Identifiable {

    let id = UUID()

    /// What the user was doing. Everything else is machine state at that moment.
    let symptom: String
    let query: String?
    let scope: GeneralChatScope?
    let capturedAt: Date

    init(
        symptom: String,
        query: String? = nil,
        scope: GeneralChatScope? = nil,
        capturedAt: Date = Date()
    ) {
        self.symptom = symptom
        self.query = query
        self.scope = scope
        self.capturedAt = capturedAt
    }

    // MARK: - Rendering

    /// Markdown, because both destinations read it: a human in an issue, and Claude Code as
    /// a prompt.
    @MainActor
    func markdown() -> String {
        var out = ["# DoraX diagnostic report", ""]
        out.append("**Symptom:** \(symptom)")
        out.append("**Captured:** \(Self.timestamp(capturedAt))")
        if let query, !query.isEmpty { out.append("**Query:** `\(query)`") }
        if let scope { out.append("**Scope:** `\(scope.storageKey)`") }
        out.append("")

        out.append(contentsOf: section("Build", buildLines()))
        out.append(contentsOf: section("Provider", providerLines()))
        out.append(contentsOf: section("Usage", usageLines()))
        if let scope {
            out.append(contentsOf: section("What ran in this thread", consoleLines(scope)))
        }
        out.append(contentsOf: section("CLI scopes", cliLines()))
        out.append(contentsOf: section("Permissions", permissionLines()))
        return out.joined(separator: "\n")
    }

    private func section(_ title: String, _ lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        return ["## \(title)", ""] + lines.map { "- \($0)" } + [""]
    }

    // MARK: - Sources

    private func buildLines() -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "Version \(info["CFBundleShortVersionString"] as? String ?? "?") "
                + "(build \(info["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Bundle \(Bundle.main.bundlePath)",
        ]
    }

    @MainActor
    private func providerLines() -> [String] {
        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider
        var lines = [
            "Selected: \(provider.displayName) (`\(provider.rawValue)`)",
            "Configured: \(settings.isProviderConfigured(provider))",
            "Native tools: \(provider.supportsNativeTools)",
        ]
        switch provider {
        case .claudeCode:
            lines.append("CLI: \(ClaudeCodeCLIService.binaryPath() ?? "NOT FOUND")")
            lines.append(
                "Model alias: \(settings.claudeCodeModel.isEmpty ? "(plan default)" : settings.claudeCodeModel)")
        case .claudeBridge:
            lines.append("Endpoint: \(settings.claudeBridgeEndpoint)")
            lines.append("Model: \(settings.claudeBridgeModelID)")
        case .chatGPTBridge:
            lines.append("Endpoint: \(settings.chatGPTBridgeEndpoint)")
            lines.append("Model: \(settings.chatGPTBridgeModelID)")
        case .ollama:
            lines.append("Endpoint: \(settings.ollamaEndpoint)")
            lines.append("Model: \(settings.selectedOllamaModel)")
        default:
            break
        }
        return lines
    }

    @MainActor
    private func usageLines() -> [String] {
        let store = AIProviderUsageStore.shared
        var lines: [String] = []
        for quota in store.subscriptionQuotas where quota.isExhausted {
            lines.append(
                "QUOTA SPENT — \(quota.providerName)"
                    + (quota.planType.map { " (\($0))" } ?? "")
                    + " until \(Self.timestamp(quota.resetsAt))")
        }
        let ledger = AITokenLedger.shared.today
        if ledger.isEmpty {
            lines.append("No requests recorded today.")
        } else {
            for entry in ledger.prefix(5) {
                lines.append(
                    "\(entry.providerName) · \(entry.model): \(entry.requests) req, "
                        + "\(entry.totalTokens) tokens")
            }
        }
        return lines
    }

    /// The receipts. A claim in the transcript can be checked against this; a summary of it
    /// cannot, which is why the output is included whole rather than trimmed to a status.
    @MainActor
    private func consoleLines(_ scope: GeneralChatScope) -> [String] {
        let entries = ChatConsoleLog.shared.entries(for: scope)
        guard !entries.isEmpty else { return ["Console empty — nothing executed."] }
        return entries.suffix(12).map { entry in
            let status = entry.isRunning ? "RUNNING" : (entry.success ? "ok" : "FAILED")
            let output = entry.output
                .replacingOccurrences(of: "\n", with: " ⏎ ")
                .prefix(300)
            return "`\(entry.title)` → \(status)\(output.isEmpty ? "" : ": \(output)")"
        }
    }

    @MainActor
    private func cliLines() -> [String] {
        let packages = TerminalPackageManager.shared.packages.filter {
            $0.isEnabled && TerminalPackageManager.shared.isUserAddedGlobalScope($0)
        }
        guard !packages.isEmpty else { return [] }
        return packages.prefix(8).map { package in
            "\(package.command) → \(package.installedPath ?? "path unknown")"
                + (package.isInteractive ? " [needs terminal]" : "")
        }
    }

    private func permissionLines() -> [String] {
        [
            "Accessibility: \(AXIsProcessTrusted())",
            "Automation prompts are per-app; see Settings → Permissions for the live state.",
        ]
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - Destinations

    @MainActor
    @discardableResult
    func copyToPasteboard() -> String {
        let text = markdown()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    /// The prompt handed to a real Claude Code session — the one thing in this app that can
    /// actually change the code that produced the fault.
    @MainActor
    func repairPrompt() -> String {
        """
        A DoraX user hit the failure below. Find the cause in this repository and fix it.

        \(markdown())

        Work from the evidence above rather than from a guess at what it might be, and say
        which file and line produced it before changing anything.
        """
    }
}
