import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI

struct AICapabilityApprovalView: View {
    let pending: AICapabilityApprovalCenter.PendingApproval

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            Label("AI Action Approval", systemImage: "checkmark.shield")
                .font(.title2.bold())
            Text(pending.capability.title)
                .font(.headline)
            Text(pending.plan.explanation)
                .foregroundStyle(.secondary)
            Text("Risk: \(pending.capability.riskLevel.rawValue.capitalized)")
                .font(.caption.bold())
                .foregroundStyle(pending.capability.riskLevel == .high ? .orange : .secondary)
            if !pending.plan.input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pending.plan.input.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(pending.plan.input[key] ?? "")")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            if pending.capability.id.hasPrefix("finder."), !finderSelectedURLs.isEmpty
            {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected Files").font(.caption.bold())
                    ForEach(finderSelectedURLs.prefix(12), id: \.path) { url in
                        Text(url.path)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if finderSelectedURLs.count > 12 {
                        Text("+ \(finderSelectedURLs.count - 12) more").font(.caption2)
                    }
                    ForEach(finderPreviewRows(urls: finderSelectedURLs), id: \.self) { row in
                        Text(row)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("Undo: not guaranteed").font(.caption).foregroundStyle(.orange)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Approval expires after 60 seconds.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { AICapabilityApprovalCenter.shared.deny() }
                Spacer()
                Button("Approve") { AICapabilityApprovalCenter.shared.approve() }
                    .buttonStyle(.borderedProminent)
            }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var finderSelectedURLs: [URL] {
        if case .filesSelected(let urls) = pending.context { return urls }
        return AXContextReader.shared.current.selectedFilePaths.map(URL.init(fileURLWithPath:))
    }

    private func finderPreviewRows(urls: [URL]) -> [String] {
        switch pending.capability.id {
        case "finder.renameFiles":
            guard let pattern = pending.plan.input["pattern"] else { return [] }
            return urls.prefix(12).enumerated().map { index, url in
                let ext = url.pathExtension
                let base = url.deletingPathExtension().lastPathComponent
                var name = pattern
                    .replacingOccurrences(of: "{name}", with: base)
                    .replacingOccurrences(of: "{ext}", with: ext)
                    .replacingOccurrences(of: "{n}", with: String(index + 1))
                if !ext.isEmpty && !name.hasSuffix(".\(ext)") { name += ".\(ext)" }
                return "\(url.lastPathComponent) -> \(name)"
            }
        case "finder.moveFiles", "finder.copyFiles":
            guard let destination = pending.plan.input["destination"] else { return [] }
            return urls.prefix(12).map {
                "\($0.path) -> \(URL(fileURLWithPath: destination).appendingPathComponent($0.lastPathComponent).path)"
            }
        default:
            return []
        }
    }
}

/// Inline consent card. The same decision as `AIPrivacyApprovalView`, rendered inside the chat
/// instead of a separate floating window — a modal panel over the dock broke the flow and hid
/// the very context the user is being asked about.
struct InlinePrivacyApprovalCard: View {
    let pending: AIPrivacyApprovalCenter.PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Send this context to \(pending.provider.displayName)?")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text(pending.contextDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("Selected text, files or contact data leaves this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.9))
            HStack(spacing: 8) {
                Button("Cancel") { AIPrivacyApprovalCenter.shared.deny() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Button("Send") { AIPrivacyApprovalCenter.shared.approve() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8)
        )
        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
    }
}

/// Capability approval rendered inside the conversation. Same decision as the floating
/// `AICapabilityApprovalView`, but it stays in the chat that asked for it — a separate
/// window lands over the dock and hides the request it is asking about, which is the one
/// thing someone needs to see before approving.
struct InlineCapabilityApprovalCard: View {
    let pending: AICapabilityApprovalCenter.PendingApproval

    private var isHighRisk: Bool {
        pending.capability.riskLevel == .high || pending.capability.riskLevel == .critical
    }

    private var accent: Color { isHighRisk ? .orange : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Text(pending.capability.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                Text(pending.capability.riskLevel.rawValue.capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHighRisk ? .orange : .secondary)
            }
            if !pending.plan.explanation.isEmpty {
                Text(pending.plan.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // The inputs are the approval. A title without them is a request to trust that
            // the right values were filled in somewhere off screen.
            if !pending.plan.input.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pending.plan.input.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(pending.plan.input[key] ?? "")")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            Text("Expires after 60 seconds.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Cancel") { AICapabilityApprovalCenter.shared.deny() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Button("Approve") { AICapabilityApprovalCenter.shared.approve() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(accent, in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.35), lineWidth: 0.8)
        )
        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
    }
}

/// Adapter / menu-command approval rendered inside the conversation. Same decision as the
/// floating `AdapterApprovalPopupView`, but it stays in the chat that asked for it instead of
/// throwing a second window over the dock.
struct InlineAdapterApprovalCard: View {
    let request: AdapterActionRequest

    private var detailLine: String {
        switch request.action.type {
        case .menubar:
            return request.action.menuPath?.joined(separator: " ▸ ") ?? request.action.name
        case .applescript: return "AppleScript"
        case .jxa: return "JXA script"
        case .shell: return "Shell command"
        case .cliTool: return request.action.cliToolCommand ?? "CLI tool"
        case .urlScheme: return request.action.urlScheme ?? "Open URL"
        case .openItem, .scriptFile:
            return request.action.scriptFile ?? request.action.script ?? "Open item"
        case .shortcut: return request.action.shortcutName ?? "Shortcut"
        case .aiPrompt: return "AI prompt"
        case .pageJS: return "Page JavaScript"
        }
    }

    private var accent: Color { request.action.isDestructive ? .orange : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(
                    systemName: request.action.isDestructive
                        ? "exclamationmark.triangle.fill" : "cursorarrow.click"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                Text(request.action.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(request.adapter.appName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            Text(detailLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if !request.action.description.isEmpty {
                Text(request.action.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Cancel") { request.onDeny() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Button(request.action.isDestructive ? "Allow" : "Run") { request.onApprove() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(accent, in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.35), lineWidth: 0.8)
        )
        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
    }
}

struct AIPrivacyApprovalView: View {
    let pending: AIPrivacyApprovalCenter.PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Send Private Context To Cloud?", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.title2.bold())
            Text("Provider: \(pending.provider.displayName)")
            Text(pending.contextDescription)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Selected text, files, or contact data may leave this Mac.")
                .foregroundStyle(.orange)
            HStack {
                Button("Cancel") { AIPrivacyApprovalCenter.shared.deny() }
                Spacer()
                Button("Send") { AIPrivacyApprovalCenter.shared.approve() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

struct SearchContextApp {
    let name: String
    let icon: NSImage?
    let key: String?  // customAppEntries key (apps with assigned tools)
    let appPath: String  // .app path (empty for non-apps)
    let resultType: SearchResult.ResultType  // type of item (app, file, folder, contact, etc.)
    let filePath: String?  // full path for files/folders
    let subtitle: String  // subtitle from result row (path, email, etc.)
    let contactEmail: String?  // for contacts
    let contactPhone: String?  // for contacts

    /// Human-readable description for the AI system prompt
    var aiContextDescription: String {
        switch resultType {
        case .application: return "the app \(name) (\(appPath))"
        case .file, .document: return "the file \(name) at \(filePath ?? subtitle)"
        case .folder: return "the folder \(name) at \(filePath ?? subtitle)"
        case .contact: return "the contact \(name)\(contactEmail.map { " (\($0))" } ?? "")"
        case .calendarEvent: return "the calendar event \(name)"
        case .reminder: return "the reminder \(name)"
        case .note: return "the note \(name)"
        case .mail: return "the email \(name)"
        case .shortcut: return "the shortcut \(name)"
        case .cliTool: return "the CLI tool '\(name)' installed at \(filePath ?? appPath)"
        default: return "\(name)"
        }
    }
}

/// A tappable "Open in <App>" chip shown under an assistant message that used an Apple
/// app's data (Calendar, Reminders, Contacts, …), so the user can jump straight there.
struct AppLaunchAction: Equatable {
    let label: String
    let systemIcon: String
    let bundleId: String
}

/// A concrete file returned by DoraX's local Recent Items index. Keeping the URL on
/// the message lets the chat render desktop-native actions without asking the model
/// to reproduce a path or issuing another AI request.
struct RecentFileAction: Equatable {
    let url: URL

    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path }
}

/// One grounded Apple Notes search hit. Structured rows keep metadata readable and
/// actionable instead of flattening the entire result set into one chat paragraph.
struct NoteSearchAction: Equatable {
    let id: String
    let title: String
    let folder: String
    let snippet: String
    let modifiedDate: Date?
}

/// A task extracted from a grounded Apple Note. Keeping tasks structured lets the
/// result surface offer direct copy actions without asking an AI provider again.
struct NoteTaskAction: Equatable, Identifiable {
    let id: UUID
    let text: String

    init(text: String) {
        self.id = UUID()
        self.text = text
    }
}

/// A grounded Reminders result. Action receipts and list rows stay structured so the
/// conversation reads like a task manager instead of an MCP debug console.
struct ReminderResultAction: Equatable, Identifiable {
    enum State: Equatable {
        case active
        case overdue
        case created
        case completed
        case deleted
    }

    let id: UUID
    let title: String
    let detail: String?
    let state: State

    init(title: String, detail: String? = nil, state: State) {
        self.id = UUID()
        self.title = title
        self.detail = detail
        self.state = state
    }
}

/// One live Safari tab with enough identity to activate the existing tab rather than
/// opening a duplicate URL.
struct BrowserTabAction: Equatable, Identifiable {
    let title: String
    let url: String
    let windowIndex: Int
    let tabIndex: Int

    var id: String { "\(windowIndex):\(tabIndex):\(url)" }
    var domain: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct PageLinkAction: Equatable, Identifiable {
    let title: String
    let url: String
    let pageTitle: String

    var id: String { url }
    var domain: String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}

struct AIChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let content: String
    let timestamp: Date
    var isError: Bool
    var structuredData: String?  // JSON data from extensions
    var hasInstallButton: Bool  // Show "Add to Extensions" button
    var attachments: [URL]  // Files the user attached to this message (shown as chips)
    var appLaunches: [AppLaunchAction]  // "Open in <App>" buttons (Apple-apps answers)
    var recentFiles: [RecentFileAction]  // Local file rows with Open / Show in Finder
    var noteResults: [NoteSearchAction]  // Structured Apple Notes search results
    var noteTasks: [NoteTaskAction]  // Grounded tasks extracted from one Apple Note
    var reminderResults: [ReminderResultAction]  // Structured Reminders rows and receipts
    var browserTabs: [BrowserTabAction]  // Live browser tabs with direct activation
    var pageLinks: [PageLinkAction]  // Grounded links from the active Safari page
    var mcpToolsRan: [String]  // "tool via server" chips for executed MCP calls
    var enableAppRequest: EnableAppRequest?  // "Enable <app> for this chat" one-tap button
    var actionChoices: [ActionChoice] = []  // pick-one routes, rendered as buttons
    var trace: [String] = []  // routing steps ("Matching 31 actions…"), shown collapsed
    var runOutput: String?  // terminal/script output, collapsed behind a disclosure

    enum ChatRole {
        case user
        case assistant
        case tool  // terminal command chip (shown while running)
        case approval  // inline approve/deny card (replaces popup window)
    }

    init(
        role: ChatRole, content: String, isError: Bool = false, structuredData: String? = nil,
        hasInstallButton: Bool = false, attachments: [URL] = [],
        appLaunches: [AppLaunchAction] = [], recentFiles: [RecentFileAction] = [],
        noteResults: [NoteSearchAction] = [],
        noteTasks: [NoteTaskAction] = [],
        reminderResults: [ReminderResultAction] = [],
        browserTabs: [BrowserTabAction] = [],
        pageLinks: [PageLinkAction] = [],
        mcpToolsRan: [String] = [],
        enableAppRequest: EnableAppRequest? = nil, trace: [String] = [],
        runOutput: String? = nil, actionChoices: [ActionChoice] = []
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isError = isError
        self.structuredData = structuredData
        self.hasInstallButton = hasInstallButton
        self.attachments = attachments
        self.appLaunches = appLaunches
        self.recentFiles = recentFiles
        self.noteResults = noteResults
        self.noteTasks = noteTasks
        self.reminderResults = reminderResults
        self.browserTabs = browserTabs
        self.pageLinks = pageLinks
        self.mcpToolsRan = mcpToolsRan
        self.enableAppRequest = enableAppRequest
        self.trace = trace
        self.runOutput = runOutput
        self.actionChoices = actionChoices
    }

    /// Streaming update — preserves the original UUID so the message can be updated in-place.
    init(
        id: UUID, role: ChatRole, content: String, isError: Bool = false,
        structuredData: String? = nil, hasInstallButton: Bool = false, attachments: [URL] = [],
        appLaunches: [AppLaunchAction] = [], recentFiles: [RecentFileAction] = [],
        noteResults: [NoteSearchAction] = [],
        noteTasks: [NoteTaskAction] = [],
        reminderResults: [ReminderResultAction] = [],
        browserTabs: [BrowserTabAction] = [],
        pageLinks: [PageLinkAction] = [],
        mcpToolsRan: [String] = [],
        enableAppRequest: EnableAppRequest? = nil, trace: [String] = [],
        runOutput: String? = nil, actionChoices: [ActionChoice] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isError = isError
        self.structuredData = structuredData
        self.hasInstallButton = hasInstallButton
        self.attachments = attachments
        self.appLaunches = appLaunches
        self.recentFiles = recentFiles
        self.noteResults = noteResults
        self.noteTasks = noteTasks
        self.reminderResults = reminderResults
        self.browserTabs = browserTabs
        self.pageLinks = pageLinks
        self.mcpToolsRan = mcpToolsRan
        self.enableAppRequest = enableAppRequest
        self.trace = trace
        self.runOutput = runOutput
        self.actionChoices = actionChoices
    }

    static func == (lhs: AIChatMessage, rhs: AIChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Extension Proposal

struct ExtensionProposalData: Codable {
    var type: String
    var name: String
    var description: String
    var scriptType: String  // "applescript" | "bash" | "jxa"
    var script: String
    var layer: String
    var triggers: [TriggerSpec]
    var icon: String?

    struct TriggerSpec: Codable {
        var type: String
        var value: String
    }

    static let markerStart = "<<EXTENSION_PROPOSAL>>"
    static let markerEnd = "<<END_PROPOSAL>>"

    static func parse(from text: String) -> ExtensionProposalData? {
        guard let s = text.range(of: markerStart),
            let e = text.range(of: markerEnd),
            s.upperBound < e.lowerBound
        else { return nil }
        var json = String(text[s.upperBound..<e.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        }
        if json.hasSuffix("```") {
            json = String(json.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtensionProposalData.self, from: data)
    }

    /// Remove the proposal block from the AI response text for display.
    static func cleanResponse(_ text: String) -> String {
        guard let s = text.range(of: markerStart),
            let e = text.range(of: markerEnd),
            s.lowerBound <= e.upperBound
        else { return text }
        var result = text
        // Half-open range: a closed `...e.upperBound` traps when the marker ends at
        // endIndex (no index after endIndex) — the SIGTRAP seen in the wild.
        result.removeSubrange(s.lowerBound..<e.upperBound)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func asJSON() -> String? {
        guard let d = try? JSONEncoder().encode(self) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - AI Chat Message View
struct AIChatMessageView: View {
    let message: AIChatMessage
    var isStreaming: Bool = false
    var onInstallExtension: (() -> Void)? = nil
    var onInstallProposal: ((String) -> Void)? = nil
    var onRunOnceProposal: ((String) -> Void)? = nil
    var onReplaceText: (() -> Void)? = nil
    /// One-tap "Enable <app> for this chat" — adds the app to the focus picker and re-runs.
    var onEnableApp: ((EnableAppRequest) -> Void)? = nil
    /// Show a file in the chat window's Preview panel. Nil on surfaces that already have
    /// one — the window does not need a button that opens the window.
    var onPreviewFile: ((URL) -> Void)? = nil
    var onPickAction: ((ActionChoice) -> Void)? = nil
    var onReminderAction: ((ReminderResultAction, String) -> Void)? = nil
    /// Chat-style avatars (Context Dock scoped chat): the selected AI provider's
    /// symbol beside user messages, the scoped app's icon beside assistant answers.
    /// Both nil (General Chat) → renders exactly as before, no avatars.
    var userAvatarSymbol: String? = nil
    var assistantAvatarImage: NSImage? = nil
    @State private var isTraceExpanded = false
    @State private var isRunOutputExpanded = false
    @ObservedObject private var settings = AppSettings.shared

    private var providerColor: SwiftUI.Color {
        switch settings.selectedAIProvider {
        case .onDevice: return .purple
        case .googleGemini: return .blue
        case .openAI: return .green
        case .anthropic: return .orange
        case .claudeBridge: return .purple
        case .chatGPTBridge: return .green
        case .ollama: return .cyan
        case .openAICompatible: return .mint
        case .shortcuts: return .indigo
        }
    }

    @ViewBuilder
    private var appLaunchButtons: some View {
        HStack(spacing: 6) {
            ForEach(message.appLaunches, id: \.bundleId) { launch in
                Button {
                    if let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: launch.bundleId)
                    {
                        NSWorkspace.shared.openApplication(
                            at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: launch.systemIcon)
                        Text(launch.label).fontWeight(.medium)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(providerColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(providerColor.opacity(0.3)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Concrete local-file actions for a grounded Recent Items answer. Both actions
    /// are direct AppKit calls: they never go back through the provider or automation.
    @ViewBuilder
    private var recentFileRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recent files")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(message.recentFiles, id: \.url) { file in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.folder)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if let onPreviewFile {
                        // Reading a file in the dock costs the conversation, and going back
                        // to the conversation costs the file. The window shows both.
                        Button("Preview") { onPreviewFile(file.url) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(!FileManager.default.fileExists(atPath: file.url.path))
                            .help("Open \(file.name) beside this chat")
                    }
                    Button("Open") {
                        NSWorkspace.shared.open(file.url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!FileManager.default.fileExists(atPath: file.url.path))
                    .help("Open \(file.name)")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!FileManager.default.fileExists(atPath: file.url.path))
                    .help("Show \(file.name) in Finder")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var noteResultRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Matching notes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(message.noteResults, id: \.id) { note in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "note.text")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.yellow)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(note.folder.isEmpty ? "Notes" : note.folder)
                            if let modifiedDate = note.modifiedDate {
                                Text("·")
                                Text(modifiedDate, style: .date)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        if !note.snippet.isEmpty {
                            Text(note.snippet)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 6)
                    Button("Open") {
                        var components = URLComponents()
                        components.scheme = "notes"
                        components.host = "showNote"
                        components.queryItems = [URLQueryItem(name: "identifier", value: note.id)]
                        if let url = components.url { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(9)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private var noteTaskRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Tasks from this note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        message.noteTasks.map { "• \($0.text)" }.joined(separator: "\n"),
                        forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            ForEach(message.noteTasks) { task in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(task.text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(task.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Copy task")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var reminderResultRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            if message.reminderResults.count > 1 {
                HStack {
                    Text(reminderSectionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(message.reminderResults.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            ForEach(message.reminderResults) { reminder in
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(reminderColor(reminder.state).opacity(0.14))
                        Image(systemName: reminderIcon(reminder.state))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(reminderColor(reminder.state))
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(reminder.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                        HStack(spacing: 5) {
                            Text(reminderLabel(reminder.state))
                            if let detail = reminder.detail, !detail.isEmpty {
                                Text("·")
                                Text(detail)
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if reminder.state == .active || reminder.state == .overdue {
                        Button {
                            onReminderAction?(reminder, "complete")
                        } label: {
                            Label("Complete", systemImage: "checkmark")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Menu {
                            Button("Open Reminders", systemImage: "arrow.up.forward.app") {
                                openReminders()
                            }
                            Divider()
                            Button("Delete Reminder", systemImage: "trash", role: .destructive) {
                                onReminderAction?(reminder, "delete")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    } else {
                        Button {
                            openReminders()
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Open Reminders")
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(reminderColor(reminder.state).opacity(0.22), lineWidth: 0.7)
                }
            }

            Label(
                hasReminderReceipt ? "Updated in Reminders" : "Live from Reminders",
                systemImage: hasReminderReceipt ? "checkmark.icloud" : "arrow.triangle.2.circlepath"
            )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 3)
        }
    }

    private var hasReminderReceipt: Bool {
        message.reminderResults.contains {
            $0.state == .created || $0.state == .completed || $0.state == .deleted
        }
    }

    private var reminderSectionTitle: String {
        if message.reminderResults.allSatisfy({ $0.state == .overdue }) { return "Overdue" }
        return "Reminders"
    }

    private func openReminders() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.reminders")
        else { return }
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func reminderColor(_ state: ReminderResultAction.State) -> Color {
        switch state {
        case .overdue: return .red
        case .deleted: return .orange
        case .completed: return .green
        case .created: return .blue
        case .active: return .orange
        }
    }

    private func reminderIcon(_ state: ReminderResultAction.State) -> String {
        switch state {
        case .overdue: return "exclamationmark"
        case .deleted: return "trash"
        case .completed: return "checkmark"
        case .created: return "plus"
        case .active: return "circle"
        }
    }

    private func reminderLabel(_ state: ReminderResultAction.State) -> String {
        switch state {
        case .overdue: return "Overdue"
        case .deleted: return "Deleted"
        case .completed: return "Completed"
        case .created: return "Created"
        case .active: return "Reminder"
        }
    }

    @ViewBuilder
    private var browserTabRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Open tabs")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(message.browserTabs.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            ForEach(message.browserTabs) { tab in
                Button {
                    SafariTabManager.shared.switchTo(
                        SafariTab(
                            title: tab.title, url: tab.url,
                            windowIndex: tab.windowIndex, tabIndex: tab.tabIndex))
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.blue.opacity(0.13))
                            Image(systemName: "safari")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                        .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.title.isEmpty ? tab.domain : tab.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(tab.domain)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("Window \(tab.windowIndex)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Copy Link", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tab.url, forType: .string)
                    }
                    Button("Open in New Tab", systemImage: "plus.square.on.square") {
                        SafariTabManager.shared.openURL(tab.url)
                    }
                }
            }

            Label("Live from Safari", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 3)
        }
    }

    @ViewBuilder
    private var pageLinkRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Links on this page")
                        .font(.system(size: 11, weight: .semibold))
                    if let page = message.pageLinks.first?.pageTitle, !page.isEmpty {
                        Text(page)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("\(message.pageLinks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            ForEach(message.pageLinks.prefix(30)) { link in
                HStack(spacing: 9) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(link.domain)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered).controlSize(.mini).help("Copy link")
                    Button {
                        SafariTabManager.shared.openURL(link.url)
                    } label: {
                        Image(systemName: "arrow.up.forward")
                    }
                    .buttonStyle(.bordered).controlSize(.mini).help("Open in Safari")
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Label("Read locally from Safari Extension", systemImage: "lock.shield")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 3)
        }
    }

    /// Pick-one routes as buttons. The same information the bullet list carried, except a
    /// click runs the route instead of asking the user to retype what they wanted.
    @ViewBuilder
    private var actionChoiceButtons: some View {
        if !message.actionChoices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(message.actionChoices) { choice in
                    Button {
                        onPickAction?(choice)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(
                                    [choice.appName, choice.routeLabel]
                                        .compactMap { $0 }
                                        .joined(separator: " · ")
                                )
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var enableAppButton: some View {
        if let req = message.enableAppRequest {
            Button {
                onEnableApp?(req)
            } label: {
                HStack(spacing: 6) {
                    if let icon = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: req.bundleId).map({
                            NSWorkspace.shared.icon(forFile: $0.path)
                        })
                    {
                        Image(nsImage: icon)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 15, height: 15)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        Image(systemName: "plus.app")
                    }
                    Text("Enable \(req.name) for this chat").fontWeight(.semibold)
                }
                .font(.system(size: 12))
                .foregroundStyle(providerColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(providerColor.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(providerColor.opacity(0.35)))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var mcpToolChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.mcpToolsRan, id: \.self) { label in
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10, weight: .semibold))
                    Text("ran \(label)")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.purple.opacity(0.12), in: Capsule())
            }
        }
    }

    /// Collapsed record of how the answer was routed. Every line is real work the app did
    /// (catalog size, chosen path, executed row) — never model reasoning.
    @ViewBuilder
    /// One line describing what the trace did, instead of a bare step count.
    ///
    /// Categorised by the prefixes this app writes itself — `dockTraceStep`,
    /// `actionTraceStep` and `selectionRouterStep` produce every line here — so this reads
    /// its own vocabulary rather than guessing at arbitrary text. Anything uncategorised
    /// still counts toward the total, and a trace with nothing recognisable falls back to
    /// the plain count, so the label can never overstate what happened.
    static func traceSummary(_ trace: [String]) -> String {
        var commands = 0
        var reads = 0
        for line in trace {
            let lower = line.lowercased()
            // Completions only. Each run also emits a "Running …" line first, so counting
            // both would report one command as two.
            if lower.hasPrefix("ran ") || lower.hasSuffix(" failed") {
                commands += 1
            } else if lower.hasPrefix("reading ") {
                reads += 1
            }
        }
        var parts: [String] = []
        if commands > 0 { parts.append("Ran \(commands) command\(commands == 1 ? "" : "s")") }
        if reads > 0 { parts.append("read \(reads) source\(reads == 1 ? "" : "s")") }
        guard !parts.isEmpty else {
            return "\(trace.count) step\(trace.count == 1 ? "" : "s")"
        }
        let others = trace.count - commands - reads
        if others > 0 { parts.append("\(others) more") }
        return parts.joined(separator: ", ")
    }

    private var routerTraceView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.dockSoft) {
                    isTraceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isTraceExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 9, weight: .semibold))
                    Text(Self.traceSummary(message.trace))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)

            if isTraceExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(message.trace.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(Color.secondary.opacity(0.45))
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(step)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Collapsed script output. Header states the size so the user can judge whether to open it.
    @ViewBuilder
    private func runOutputView(_ output: String) -> some View {
        let lineCount = output.split(separator: "\n", omittingEmptySubsequences: false).count
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.dockSoft) {
                    isRunOutputExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isRunOutputExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "terminal")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Output · \(lineCount) line\(lineCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)

            if isRunOutputExpanded {
                ScrollView {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
                .padding(.top, 5)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var attachmentChips: some View {
        let alignment: HorizontalAlignment = message.role == .user ? .trailing : .leading
        VStack(alignment: alignment, spacing: 4) {
            ForEach(message.attachments, id: \.absoluteString) { url in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role != .user, let avatar = assistantAvatarImage {
                Image(nsImage: avatar)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .padding(.top, 5)
                    .padding(.trailing, 7)
            }
            if message.role == .user { Spacer(minLength: 52) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                // Attachment chips (files the user attached to this message)
                if !message.attachments.isEmpty {
                    attachmentChips
                }
                // Routing trace ("Matching 31 actions…", "Best path: Share · Notes")
                if message.role == .assistant, !message.trace.isEmpty {
                    routerTraceView
                }
                // Script/terminal output — collapsed. A conversion log is hundreds of lines of
                // ffmpeg banner the user did not ask to read; it belongs one tap away, not
                // dumped between two chat bubbles.
                if let runOutput = message.runOutput, !runOutput.isEmpty {
                    runOutputView(runOutput)
                }
                // MCP tool-run chips ("ran <tool> via <server>")
                if !message.mcpToolsRan.isEmpty && message.reminderResults.isEmpty {
                    mcpToolChips
                }
                // Detect extension proposal in structuredData
                if let sd = message.structuredData, message.role == .assistant,
                    let data = sd.data(using: .utf8),
                    let proposal = try? JSONDecoder().decode(
                        ExtensionProposalData.self, from: data),
                    proposal.type == "extension_proposal"
                {
                    ExtensionProposalCard(
                        message: message,
                        proposal: proposal,
                        onRunOnce: onRunOnceProposal.map { cb in { cb(sd) } },
                        onAdd: onInstallProposal.map { cb in { cb(sd) } }
                    )
                } else if let structuredData = message.structuredData, message.role == .assistant {
                    VStack(alignment: .leading, spacing: 8) {
                        if !message.content.isEmpty {
                            MarkdownMessageView(content: message.content, isError: message.isError)
                        }
                        AIResultViewer(jsonString: structuredData)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background { pillBubble(bright: false) }
                } else if !message.content.isEmpty || isStreaming {
                    HStack(alignment: .bottom, spacing: 4) {
                        MarkdownMessageView(
                            content: message.content.isEmpty && isStreaming ? "" : message.content,
                            isError: message.isError
                        )
                        if isStreaming {
                            Rectangle()
                                .fill(providerColor)
                                .frame(width: 2, height: 14)
                                .animation(
                                    .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                    value: isStreaming)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        if message.role == .user {
                            Color.accentColor
                        } else {
                            Color.primary.opacity(message.isError ? 0.04 : 0.08)
                        }
                    }
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if !message.appLaunches.isEmpty {
                    appLaunchButtons
                }

                if !message.recentFiles.isEmpty {
                    recentFileRows
                }

                if !message.noteResults.isEmpty {
                    noteResultRows
                }

                if !message.noteTasks.isEmpty {
                    noteTaskRows
                }

                if !message.reminderResults.isEmpty {
                    reminderResultRows
                }

                if !message.browserTabs.isEmpty {
                    browserTabRows
                }

                if !message.pageLinks.isEmpty {
                    pageLinkRows
                }

                if message.enableAppRequest != nil {
                    enableAppButton
                }
                if !message.actionChoices.isEmpty {
                    actionChoiceButtons
                }

                if message.role == .assistant, let onReplaceText, !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: onReplaceText) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left.arrow.right")
                            Text("Replace text").fontWeight(.medium)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(providerColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(providerColor.opacity(0.28)))
                    }
                    .buttonStyle(.plain)
                    .help("Replace the original selected text with this answer")
                }

                if message.hasInstallButton, message.structuredData == nil,
                    let onInstall = onInstallExtension
                {
                    Button(action: onInstall) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add to Extensions").fontWeight(.medium)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .leading, endPoint: .trailing))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if message.role == .user, let symbol = userAvatarSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(providerColor)
                    .frame(width: 22, height: 22)
                    .background(providerColor.opacity(0.14), in: Circle())
                    .padding(.top, 5)
                    .padding(.leading, 7)
            }
            // Tool/run confirmations belong to the assistant side too. Previously only
            // `.assistant` received this spacer, so `.tool` expanded across the row and its
            // compact success bubble appeared centred.
            if message.role != .user { Spacer(minLength: 52) }
        }
    }

    @ViewBuilder private func pillBubble(bright: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(bright ? 0.28 : 0.12),
                            .white.opacity(bright ? 0.06 : 0.02),
                        ],
                        startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(bright ? 0.65 : 0.32), .white.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: bright ? 1.5 : 0.75)
            if bright {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                    .blur(radius: 3)
            }
        }
    }
}

// MARK: - Extension Proposal Card

struct ExtensionProposalCard: View {
    let message: AIChatMessage
    let proposal: ExtensionProposalData
    var onRunOnce: (() -> Void)? = nil
    var onAdd: (() -> Void)? = nil

    @State private var expanded = false

    private var scriptPreview: String {
        let lines = proposal.script.components(separatedBy: "\n")
        let preview = lines.prefix(12).joined(separator: "\n")
        return lines.count > 12 ? preview + "\n…" : preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Text response (above the card)
            if !message.content.isEmpty {
                MarkdownMessageView(content: message.content, isError: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.bottom, 8)
            }

            // Proposal card
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: proposal.icon ?? "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(proposal.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(proposal.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Script type badge
                    Text(proposal.scriptType.lowercased() == "applescript" ? "AppleScript" : "bash")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    // Expand/collapse chevron
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            expanded.toggle()
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                // Script preview (expandable)
                if expanded {
                    Divider().opacity(0.2)
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(scriptPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 180)
                    .background(Color.black.opacity(0.25))
                }

                Divider().opacity(0.2)

                // Action buttons
                HStack(spacing: 8) {
                    if let run = onRunOnce {
                        Button(action: run) {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                Text("Run Once")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if let add = onAdd {
                        Button(action: add) {
                            HStack(spacing: 5) {
                                Image(systemName: "plus.circle.fill")
                                Text("Save as Extension")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading, endPoint: .trailing))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.blue.opacity(0.5), .purple.opacity(0.3)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.75)
            )
        }
    }
}

// MARK: - Tool Selection Inline View
struct ToolSelectionInlineView: View {
    let pending: L2AITaskExecutor.PendingToolChoice
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a tool")
                .font(.headline)
            Text(pending.stepDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(pending.tools, id: \.self) { tool in
                Button {
                    onSelect(tool)
                } label: {
                    HStack {
                        Text(tool)
                            .font(.body)
                        Spacer()
                        if !L2AITaskExecutor.TerminalTool.isInstalled(tool) {
                            Text("Install")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.08))
                )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - AI Loading View
struct AILoadingView: View {
    var status: String? = nil
    @State private var animationOffset: CGFloat = 0
    @ObservedObject private var settings = AppSettings.shared

    private var providerColor: SwiftUI.Color {
        switch settings.selectedAIProvider {
        case .onDevice: return .purple
        case .googleGemini: return .blue
        case .openAI: return .green
        case .anthropic: return .orange
        case .claudeBridge: return .purple
        case .chatGPTBridge: return .green
        case .ollama: return .cyan
        case .openAICompatible: return .mint
        case .shortcuts: return .indigo
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // AI Avatar - uses provider icon
            AIProviderIcon(provider: settings.selectedAIProvider, size: 16)
                .foregroundStyle(providerColor)
                .frame(width: 28, height: 28)
                .background(providerColor.opacity(0.1))
                .clipShape(Circle())

            HStack(spacing: 9) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(providerColor.opacity(0.6))
                            .frame(width: 8, height: 8)
                            .offset(y: animationOffset)
                            .animation(
                                Animation.easeInOut(duration: 0.5)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.15),
                                value: animationOffset
                            )
                    }
                }
                if let status, !status.isEmpty {
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
            .onAppear {
                animationOffset = -5
            }

            Spacer(minLength: 40)
        }
    }
}

/// MARK: - Adapter Action Approval Popup

struct AdapterApprovalPopupView: View {
    let request: AdapterActionRequest
    @State private var isHoveringAllow = false
    @State private var isHoveringDeny = false
    @State private var isHoveringAlways = false

    private var typeLabel: String {
        switch request.action.type {
        case .menubar: return "Menu Bar: \(request.action.menuPath?.joined(separator: " › ") ?? "")"
        case .applescript: return "AppleScript"
        case .jxa: return "JXA Script"
        case .shell: return "Shell Command"
        case .cliTool: return "CLI Tool: \(request.action.cliToolCommand ?? "")"
        case .urlScheme: return "Open URL: \(request.action.urlScheme ?? "")"
        case .openItem:
            return "Open File / App: \(request.action.scriptFile ?? request.action.script ?? "")"
        case .scriptFile:
            return "Script File: \(request.action.scriptFile ?? request.action.script ?? "")"
        case .shortcut: return "Shortcut: \(request.action.shortcutName ?? "")"
        case .aiPrompt: return "AI Prompt"
        case .pageJS: return "Page JavaScript"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(
                    systemName: request.action.isDestructive
                        ? "exclamationmark.triangle.fill" : "app.connected.to.app.below.fill"
                )
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(request.action.isDestructive ? .red : .accentColor)
                .frame(width: 36, height: 36)
                .background(
                    (request.action.isDestructive ? Color.red : Color.accentColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Context Dock wants to:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(request.action.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 8) {
                approvalDetailRow(icon: "app.badge.fill", text: "App: \(request.adapter.appName)")
                approvalDetailRow(icon: "gearshape", text: typeLabel)
                if !request.action.description.isEmpty {
                    Text(request.action.description)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.88))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.45)

            HStack(spacing: 10) {
                Button {
                    request.onDeny()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            isHoveringDeny
                                ? Color.primary.opacity(0.13) : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringDeny = $0 }

                Button {
                    request.onApprove()
                } label: {
                    Text("Allow")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            request.action.isDestructive
                                ? (isHoveringAllow
                                    ? Color.red.opacity(0.88) : Color.red.opacity(0.78))
                                : (isHoveringAllow
                                    ? Color.accentColor.opacity(0.92)
                                    : Color.accentColor.opacity(0.8)),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringAllow = $0 }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, request.onApproveAlways == nil ? 18 : 10)

            // Standing grant — offered only for non-destructive actions. Browser
            // Extensions are the main beneficiary: without it a userscript re-prompts
            // on every single run.
            if let approveAlways = request.onApproveAlways {
                Button {
                    approveAlways()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                        Text("Always allow \(request.action.name) for \(request.adapter.appName)")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHoveringAlways ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringAlways = $0 }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 460)
        .background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    request.action.isDestructive
                        ? Color.red.opacity(0.38) : Color.white.opacity(0.14),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 12)
        .padding(12)
    }

    private func approvalDetailRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - L2 Extension Chip Button
struct L2ExtensionChipButton: View {
    let extensionResult: ExtensionDiscoveryResult
    let currentContext: UserContext
    let onExecute: (ILExtension, UserContext) async -> Void

    @State private var isHovered = false
    @State private var isExecuting = false

    private var chipColor: SwiftUI.Color {
        switch extensionResult.relevanceScore {
        case 0.5...:
            return .blue
        case 0.3..<0.5:
            return .green
        default:
            return .gray
        }
    }

    var body: some View {
        Button(action: {
            Task {
                isExecuting = true
                await onExecute(extensionResult.ilExtension, currentContext)
                isExecuting = false
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: extensionResult.ilExtension.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(chipColor)

                Text(extensionResult.ilExtension.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHovered ? chipColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(chipColor.opacity(isHovered ? 0.8 : 0.3), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - AI Extension Chip Button
struct AIExtensionChipButton: View {
    let suggestion: SuggestedExtension
    let context: UserContext
    @Binding var chatMessages: [AIChatMessage]

    @State private var isHovered = false
    @State private var isExecuting = false

    private var chipColor: SwiftUI.Color {
        switch suggestion.relevanceScore {
        case 90...:
            return .green
        case 70..<90:
            return .blue
        default:
            return .orange
        }
    }

    var body: some View {
        Button(action: {
            executeExtension()
        }) {
            HStack(spacing: 6) {
                // Icon
                Image(systemName: suggestion.scriptExtension.type.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(chipColor)

                // Title
                Text(suggestion.scriptExtension.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Loading indicator
                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }

                // Star for high relevance
                if suggestion.relevanceScore >= 90 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHovered ? chipColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(chipColor.opacity(isHovered ? 0.8 : 0.3), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(suggestion.reason)
    }

    private func executeExtension() {
        isExecuting = true

        // Add user action message to chat
        let actionMessage = AIChatMessage(
            role: .user,
            content: "Run \(suggestion.scriptExtension.displayName)"
        )
        chatMessages.append(actionMessage)

        Task {
            do {
                let input = getInputFromContext()
                #if DEBUG
                print("🔧 [Extension] Executing: \(suggestion.scriptExtension.displayName)")
                #endif
                #if DEBUG
                print("🔧 [Extension] Input: \(input.prefix(100))...")
                #endif

                let result = try await suggestion.scriptExtension.execute(with: input)

                #if DEBUG
                print("✅ [Extension] Result: \(result.prefix(200))...")
                #endif

                await MainActor.run {
                    isExecuting = false

                    // Add result to chat
                    let resultMessage = AIChatMessage(
                        role: .assistant,
                        content: result.isEmpty ? "✅ Completed successfully" : result,
                        isError: false
                    )
                    chatMessages.append(resultMessage)
                }
            } catch {
                #if DEBUG
                print("❌ [Extension] Error: \(error.localizedDescription)")
                #endif

                await MainActor.run {
                    isExecuting = false

                    // Add error to chat
                    let errorMessage = AIChatMessage(
                        role: .assistant,
                        content: "❌ Error: \(error.localizedDescription)",
                        isError: true
                    )
                    chatMessages.append(errorMessage)
                }
            }
        }
    }

    private func getInputFromContext() -> String {
        switch context {
        case .filesSelected(let urls):
            return urls.map { $0.path }.joined(separator: "\n")
        case .textSelected(let text):
            return text
        case .url(let urlString):
            return urlString
        case .appFocused(let name, _):
            return name
        case .contactSelected(let contact):
            return contact
        case .none:
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
    }
}

// MARK: - Markdown Message View
struct MarkdownMessageView: View {
    let content: String
    let isError: Bool

    @State private var parsedBlocks: [MessageBlock] = []

    struct MessageBlock: Identifiable {
        let id = UUID()
        enum Kind {
            case text(String)
            case codeBlock(code: String, language: String?)
            case table(header: [String], rows: [[String]])
        }
        let kind: Kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parsedBlocks) { block in
                switch block.kind {
                case .text(let text):
                    if #available(macOS 12.0, *) {
                        Text(attributedMarkdown(text))
                            .font(.system(size: 13))
                            .foregroundStyle(isError ? .red : .primary)
                            .textSelection(.enabled)
                            .environment(
                                \.openURL,
                                OpenURLAction { url in
                                    let sourceBundle = AppDelegate.shared?.previousFrontmostApp?
                                        .bundleIdentifier ?? ""
                                    if sourceBundle.hasPrefix("com.apple.Safari") {
                                        SafariTabManager.shared.switchToOpenTabOrOpenURL(
                                            url.absoluteString)
                                    } else {
                                        NSWorkspace.shared.open(url)
                                    }
                                    return .handled
                                })
                    } else {
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(isError ? .red : .primary)
                            .textSelection(.enabled)
                    }

                case .codeBlock(let code, let language):
                    CodeBlockView(code: code, language: language)

                case .table(let header, let rows):
                    MarkdownTableView(header: header, rows: rows)
                }
            }
        }
        .onAppear {
            parsedBlocks = parseContent(content)
        }
        .onChange(of: content) { _, newContent in
            parsedBlocks = parseContent(newContent)
        }
    }

    private func parseContent(_ src: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        let src = normalizeLeakedToolMarkup(src)

        let pattern = "```([a-zA-Z]*)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [MessageBlock(kind: .text(src))]
        }

        let range = NSRange(src.startIndex..., in: src)
        var lastIndex = src.startIndex

        regex.enumerateMatches(in: src, range: range) { match, _, _ in
            guard let match = match,
                let matchRange = Range(match.range, in: src)
            else { return }

            let pre = String(src[lastIndex..<matchRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pre.isEmpty { blocks.append(contentsOf: Self.splitTables(pre)) }

            if match.numberOfRanges >= 3,
                let langRange = Range(match.range(at: 1), in: src),
                let codeRange = Range(match.range(at: 2), in: src)
            {
                let language = String(src[langRange])
                let code = String(src[codeRange])
                blocks.append(
                    MessageBlock(
                        kind: .codeBlock(
                            code: code, language: language.isEmpty ? nil : language)))
            }

            lastIndex = matchRange.upperBound
        }

        let tail = String(src[lastIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { blocks.append(contentsOf: Self.splitTables(tail)) }

        return blocks.isEmpty ? [MessageBlock(kind: .text(src))] : blocks
    }

    /// Pulls Markdown tables out of prose so they can be laid out as a grid.
    ///
    /// The text renderer parses with `.inlineOnlyPreservingWhitespace`, which handles bold,
    /// code and links and drops every *block* construct on the floor. A table therefore
    /// reached the user as the raw pipes that produced it — `| Surface | Job |` over
    /// `|---|---|` — which is not a formatting nit: a comparison is the shape an answer
    /// takes when it has something to compare, and it was arriving unreadable.
    static func splitTables(_ text: String) -> [MessageBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MessageBlock] = []
        var prose: [String] = []
        var index = 0

        func flushProse() {
            let joined = prose.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(MessageBlock(kind: .text(joined))) }
            prose.removeAll()
        }

        func cells(_ line: String) -> [String] {
            var row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("|") { row.removeFirst() }
            if row.hasSuffix("|") { row.removeLast() }
            return row.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        while index < lines.count {
            let line = lines[index]
            // A table is a header row plus a `|---|---|` separator. Requiring the separator
            // is what keeps a sentence that merely contains a pipe from being eaten.
            let isRow = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
            let separator = index + 1 < lines.count
                ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            let isSeparator = separator.range(
                of: "^\\|?[\\s:-]*-[-\\s:|]*\\|?$", options: .regularExpression) != nil
                && separator.contains("-") && separator.contains("|")

            guard isRow, isSeparator else {
                prose.append(line)
                index += 1
                continue
            }

            flushProse()
            let header = cells(line)
            var rows: [[String]] = []
            index += 2
            while index < lines.count,
                lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|")
            {
                rows.append(cells(lines[index]))
                index += 1
            }
            blocks.append(MessageBlock(kind: .table(header: header, rows: rows)))
        }

        flushProse()
        return blocks
    }

    /// Some OpenAI-compatible bridges occasionally return Claude's internal XML-style
    /// tool notation as assistant text. Present those payloads as normal code blocks so
    /// provider implementation details never leak into the conversation UI.
    private func normalizeLeakedToolMarkup(_ source: String) -> String {
        var result = source

        result = replacingToolPayloads(
            in: result,
            pattern: #"<ExecuteBashTool>\s*<command>([\s\S]*?)</command>\s*</ExecuteBashTool>"#
        ) { payload in
            "```bash\n\(decodeXMLText(payload).trimmingCharacters(in: .whitespacesAndNewlines))\n```"
        }

        result = replacingToolPayloads(
            in: result,
            pattern: #"<WriteFilesTool>[\s\S]*?<path>([\s\S]*?)</path>\s*<content>([\s\S]*?)</content>\s*</WriteFilesTool>"#,
            captureCount: 2
        ) { captures in
            let path = decodeXMLText(captures[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = decodeXMLText(captures[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let language = URL(fileURLWithPath: path).pathExtension
            let fenceLanguage = language.isEmpty ? "text" : language
            return "`\(path)`\n\n```\(fenceLanguage)\n\(content)\n```"
        }

        return result
    }

    private func replacingToolPayloads(
        in source: String,
        pattern: String,
        captureCount: Int = 1,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return source }

        var result = source
        let matches = regex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            var captures: [String] = []
            for index in 1...captureCount {
                guard index < match.numberOfRanges,
                    let range = Range(match.range(at: index), in: source)
                else { continue }
                captures.append(String(source[range]))
            }
            guard captures.count == captureCount else { continue }
            result.replaceSubrange(fullRange, with: transform(captures))
        }
        return result
    }

    private func replacingToolPayloads(
        in source: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        replacingToolPayloads(in: source, pattern: pattern) { captures in
            transform(captures[0])
        }
    }

    private func decodeXMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Rewrites the block constructs the inline parser discards into inline ones it keeps.
    ///
    /// `## Heading` loses its hashes and its weight, and `- item` loses its bullet — the
    /// answer arrives as a wall of undifferentiated text. Bold and a real bullet character
    /// survive inline parsing, so the structure the model wrote is still visible.
    private static func inlineFriendlyMarkdown(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: "(?m)^\\s{0,3}#{1,6}\\s+(.+?)\\s*$", with: "**$1**",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: "(?m)^(\\s*)[-*+]\\s+(?!\\s)", with: "$1• ", options: .regularExpression)
        return out
    }

    @available(macOS 12.0, *)
    private func attributedMarkdown(_ text: String) -> AttributedString {
        let text = Self.inlineFriendlyMarkdown(text)
        do {
            var attributed = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )

            return attributed
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Code Block View
/// A Markdown table, laid out as a grid.
///
/// Wide tables scroll inside their own row rather than stretching the bubble: a chat
/// panel is narrow and fixed, and a comparison with four columns would otherwise push the
/// whole conversation sideways.
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        Text(cell(header, column))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { index in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            Text(inline(cell(rows[index], column)))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
        .textSelection(.enabled)
    }

    private func cell(_ row: [String], _ column: Int) -> String {
        column < row.count ? row[column] : ""
    }

    /// Cells carry their own `**bold**` and `` `code` `` — dropping it would make the
    /// table less readable than the raw pipes it replaced.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var copied = false
    @State private var saved = false
    @State private var isRunning = false
    @State private var runSucceeded: Bool?
    @State private var runOutput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language, save, and copy buttons
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Save to Extensions button
                Button(action: saveToExtensions) {
                    HStack(spacing: 4) {
                        Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.system(size: 11))
                        Text(saved ? "Saved" : "Save")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(saved ? .green : .blue)
                }
                .buttonStyle(.plain)
                .help("Save to Extensions folder")

                // Copy button
                Button(action: copyCode) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.05))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color.black.opacity(0.02))

            if executableCommand != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Spacer()
                        Button(action: runCode) {
                            HStack(spacing: 5) {
                                if isRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                Text(isRunning ? "Running…" : "Run")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isRunning)
                        .help("Run this code using the standard command approval flow")
                    }

                    if !runOutput.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: runSucceeded == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(runSucceeded == true ? .green : .red)
                            Text(runOutput)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.05))
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private var executableCommand: String? {
        let normalized = language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "bash", "sh", "shell", "zsh", "terminal":
            return code
        case "applescript", "osascript":
            return "osascript -e \(shellQuote(code))"
        case "python", "python3", "py":
            return "python3 -c \(shellQuote(code))"
        case "javascript", "js", "node":
            return "node -e \(shellQuote(code))"
        default:
            if code.hasPrefix("#!") { return code }
            return nil
        }
    }

    private func runCode() {
        guard let command = executableCommand else { return }
        isRunning = true
        runSucceeded = nil
        runOutput = ""

        Task { @MainActor in
            let result = await TerminalCommandExecutor.shared.run(
                command,
                purpose: "Run code suggested by the AI Assistant"
            )
            runSucceeded = result.success
            runOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if runOutput.isEmpty {
                runOutput = result.success ? "Completed successfully." : "The command failed without output."
            }
            isRunning = false
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func saveToExtensions() {
        Task {
            do {
                // Extract extension metadata from code
                let extensionName = extractExtensionName(from: code)
                let layer = extractExtensionLayer(from: code)
                let activeAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
                await MainActor.run {
                    let scriptType = determineExtensionScriptType(from: code, language: language)
                    let category = inferExtensionCategory(layer: layer, appName: activeAppName)
                    let triggers = buildExtensionTriggers(layer: layer, appName: activeAppName)
                    let ext = ILExtension(
                        name: extensionName,
                        description: "Saved from AI",
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
                    saved = true

                    // Reset after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saved = false
                    }
                }

                #if DEBUG
                print("✅ Saved extension to Application Support/Context-Dock/Extensions")
                #endif

            } catch {
                #if DEBUG
                print("❌ Failed to save extension: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func extractExtensionName(from code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Extension:") {
                return line.replacingOccurrences(of: "# Extension:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "extension_\(Int(Date().timeIntervalSince1970))"
    }

    private func extractExtensionLayer(from code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Layer:") {
                return line.replacingOccurrences(of: "# Layer:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "l2_context"
    }

    private func determineExtensionScriptType(from code: String, language: String? = nil)
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

    private func inferExtensionCategory(layer: String, appName: String) -> String {
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

    private func buildExtensionTriggers(layer: String, appName: String) -> [ExtensionTrigger] {
        if layer.contains("l2"), !appName.isEmpty {
            return [.appContext(appName)]
        }
        return [.always]
    }
}

// MARK: - Notification Dock View
