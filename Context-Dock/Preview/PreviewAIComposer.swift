// PreviewAIComposer.swift
// Context-Dock
//
// The preview's assistant, with hands.
//
// It used to be the scope panels' composer, which calls sendMessage — one shot, a
// prompt string, no tools. So the panel that knows exactly which file the user means
// could only describe it: asked to organise a folder, it replied that it could not see
// inside one. Everything needed to actually do the work already existed one layer
// down, behind sendWithTools.
//
// Commands run through TerminalCommandExecutor with the previewed item's folder as
// their scope, so they land in the right directory and anything that writes goes
// through the same approval the rest of the app uses.

import AppKit
import SwiftUI

struct PreviewAIComposer: View {
    @ObservedObject var session: PreviewSession
    /// Already pulled by the surface for the file on screen — PDF text, OCR, source.
    let extractedText: String?

    @ObservedObject private var settings = AppSettings.shared
    /// Approvals raised by this panel's own tools. Answered here, over the file the
    /// question is about, instead of in a window thrown on top of it.
    @ObservedObject private var capabilityApprovals = AICapabilityApprovalCenter.shared
    @ObservedObject private var terminalBridge = TerminalAIBridge.shared
    @State private var history: [ChatMessage] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorText: String?
    /// What the model actually ran this turn, shown under its answer. A tool loop that
    /// works invisibly is indistinguishable from one that made its answer up.
    @State private var lastCommands: [RanCommand] = []
    struct RanCommand: Identifiable {
        let id = UUID()
        let command: String
        let output: String
        let success: Bool
    }

    /// Files the user pinned onto the conversation on top of what is being previewed.
    @State private var attachedFiles: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            transcript
            approvalCard
            AIComposerBar(
                text: $draft,
                isSending: isSending,
                attachedAppNames: [],
                onAttachFile: pickFiles,
                onAttachApp: { _ in },
                onSubmit: send
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var approvalCard: some View {
        if let pending = capabilityApprovals.pending {
            InlineCapabilityApprovalCard(pending: pending)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        if let pending = terminalBridge.pendingApproval, pending.origin == .preview {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("Run command?")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(pending.classification.riskLevel.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                if !pending.purpose.isEmpty {
                    Text(pending.purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(pending.command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 8) {
                    Button("Deny") { terminalBridge.denyCommand() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Approve & Run") { terminalBridge.approveCommand(pending.command) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .overlay(alignment: .top) { Divider().opacity(0.4) }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if history.isEmpty && errorText == nil {
                        Text(emptyHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(history) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.role == .user ? "You" : "AI")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(message.content)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(message.id)
                    }

                    if !lastCommands.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(lastCommands) { ran in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Image(systemName: ran.success
                                            ? "checkmark.circle" : "exclamationmark.circle")
                                            .font(.system(size: 9))
                                            .foregroundStyle(ran.success ? .green : .orange)
                                        Text(ran.command)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                    }
                                    // The reason it failed, verbatim. The model paraphrased
                                    // "Command denied by user" as "access issues", which sent
                                    // the user looking for a permissions problem that was not
                                    // there.
                                    if !ran.success, !ran.output.isEmpty {
                                        Text(ran.output)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.orange.opacity(0.9))
                                            .textSelection(.enabled)
                                            .lineLimit(4)
                                            .padding(.leading, 13)
                                    }
                                }
                            }
                        }
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
            }
            .onChange(of: history.count) { _, _ in
                if let last = history.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyHint: String {
        guard let item = session.current else { return "Ask about this preview" }
        switch item.kind {
        case .folder:
            return "Ask about this folder — what is in it, what is duplicated, "
                + "how to organise it."
        case .image:
            return "Ask about this image — what it shows, the text in it, converting it."
        case .web:
            return "Ask about this page."
        case .text, .document:
            return "Ask about \(item.title) — summarise it, pull something out of it, "
                + "rewrite it."
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !attachedFiles.contains(url) {
            attachedFiles.append(url)
        }
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending, let item = session.current else { return }

        draft = ""
        errorText = nil
        lastCommands = []
        isSending = true
        history.append(ChatMessage(role: .user, content: question))

        let provider = settings.selectedAIProvider
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey
        let priorHistory = Array(history.dropLast())
        let scope = PreviewAIContext.scope(for: item)
        let contextPrompt = PreviewAIContext.prompt(
            for: item,
            siblings: session.items,
            currentIndex: session.index,
            extractedText: extractedText
        )
        // Vision only for the image being shown: attaching a whole folder of pictures
        // would cost a fortune to answer a question about one of them.
        let images = item.kind == .image ? [item.url] : []

        Task { @MainActor in
            defer { isSending = false }
            do {
                let (reply, executed) = try await AIProviderService.shared.sendWithTools(
                    question,
                    context: .filesSelected(session.items.map(\.url) + attachedFiles),
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: priorHistory,
                    commandExecutor: { command, purpose, modelRequiresApproval in
                        await TerminalCommandExecutor.shared.run(
                            command,
                            purpose: purpose,
                            modelRequiresApproval: modelRequiresApproval,
                            consoleScope: scope
                        )
                    },
                    additionalSystemPrompt: contextPrompt,
                    imageAttachments: images,
                    chatScope: scope
                )
                history.append(ChatMessage(role: .assistant, content: reply))
                lastCommands = executed.map {
                    RanCommand(command: "$ " + $0.command, output: $0.output, success: $0.success)
                }
                // A command that wrote something usually wrote it here. Re-read the
                // folder so the new file is on screen instead of behind a manual reopen.
                if !executed.isEmpty { session.reload() }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
