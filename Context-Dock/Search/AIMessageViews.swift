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
    var mcpToolsRan: [String]  // "tool via server" chips for executed MCP calls

    enum ChatRole {
        case user
        case assistant
        case tool  // terminal command chip (shown while running)
        case approval  // inline approve/deny card (replaces popup window)
    }

    init(
        role: ChatRole, content: String, isError: Bool = false, structuredData: String? = nil,
        hasInstallButton: Bool = false, attachments: [URL] = [],
        appLaunches: [AppLaunchAction] = [], mcpToolsRan: [String] = []
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
        self.mcpToolsRan = mcpToolsRan
    }

    /// Streaming update — preserves the original UUID so the message can be updated in-place.
    init(
        id: UUID, role: ChatRole, content: String, isError: Bool = false,
        structuredData: String? = nil, hasInstallButton: Bool = false, attachments: [URL] = [],
        appLaunches: [AppLaunchAction] = [], mcpToolsRan: [String] = []
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
        self.mcpToolsRan = mcpToolsRan
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
            e.upperBound <= text.endIndex
        else { return text }
        var result = text
        result.removeSubrange(s.lowerBound...e.upperBound)
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
            if message.role == .user { Spacer(minLength: 52) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                // Attachment chips (files the user attached to this message)
                if !message.attachments.isEmpty {
                    attachmentChips
                }
                // MCP tool-run chips ("ran <tool> via <server>")
                if !message.mcpToolsRan.isEmpty {
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
                } else {
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

            if message.role == .assistant { Spacer(minLength: 52) }
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
            Image(systemName: settings.selectedAIProvider.iconName)
                .font(.system(size: 16))
                .foregroundStyle(providerColor)
                .frame(width: 28, height: 28)
                .background(providerColor.opacity(0.1))
                .clipShape(Circle())

            // Loading indicator
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
                    Text("ILauncher wants to:")
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
            .padding(.bottom, 18)
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
                                    NSWorkspace.shared.open(url)
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
            if !pre.isEmpty { blocks.append(MessageBlock(kind: .text(pre))) }

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
        if !tail.isEmpty { blocks.append(MessageBlock(kind: .text(tail))) }

        return blocks.isEmpty ? [MessageBlock(kind: .text(src))] : blocks
    }

    @available(macOS 12.0, *)
    private func attributedMarkdown(_ text: String) -> AttributedString {
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
struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var copied = false
    @State private var saved = false

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
                print("✅ Saved extension to Documents/ILauncher/Extensions")
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
