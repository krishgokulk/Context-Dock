// GeneralChatWindowModel.swift
// Context-Dock
//
// Conversation state for the standalone General Chat window.
//
// It is the SAME conversation the result sheet shows: both sides store to
// `GeneralAIChatConversationStore`, and both use `AIChatMessage`, so a chat
// started in the sheet continues in the window and vice versa. The window has its
// own object only because the sheet's copy lives on LauncherView's @State, which
// cannot be reached from another window.

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class GeneralChatWindowModel: ObservableObject {
    static let shared = GeneralChatWindowModel()

    @Published var messages: [AIChatMessage] = []
    @Published var input: String = ""
    @Published var isSending: Bool = false
    /// Files on the next message, shown as chips once it is sent.
    @Published var attachments: [URL] = []
    /// Apps the answer should be about — the composer's app picker.
    @Published var attachedAppNames: [String] = []

    private var sendTask: Task<Void, Never>?

    var isEmpty: Bool { messages.isEmpty }

    /// Pull in whatever the result sheet has said since this window was last open.
    func reloadFromStore() {
        guard !isSending else { return }
        messages = GeneralAIChatConversationStore.load()
    }

    func newChat() {
        sendTask?.cancel()
        sendTask = nil
        messages = []
        input = ""
        attachments = []
        attachedAppNames = []
        isSending = false
        GeneralAIChatConversationStore.clear()
    }

    func cancel() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        attachments.append(contentsOf: panel.urls)
    }

    func attachApp(_ name: String) {
        guard !attachedAppNames.contains(name) else { return }
        attachedAppNames.append(name)
    }

    func send() {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSending else { return }

        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider

        let history: [ChatMessage] = messages.compactMap { message in
            switch message.role {
            case .user: return ChatMessage(role: .user, content: message.content)
            case .assistant: return ChatMessage(role: .assistant, content: message.content)
            case .tool, .approval: return nil
            }
        }

        let sentAttachments = attachments
        messages.append(
            AIChatMessage(role: .user, content: query, attachments: sentAttachments))
        input = ""
        attachments = []
        persist()

        if provider.requiresAPIKey && !settings.isProviderConfigured(provider) {
            messages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "\(provider.shortName) has no API key yet. Add one in Settings → AI Provider, "
                        + "or switch to On-Device Intelligence.",
                    isError: true))
            persist()
            return
        }

        let rawKey = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : ""
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey
        // An attached app makes this an app question, so the provider gets the same
        // app-focused context the sheet builds for one.
        let context: UserContext = {
            guard let name = attachedAppNames.first else { return .none }
            let bundleID =
                NSWorkspace.shared.runningApplications
                .first { $0.localizedName == name }?.bundleIdentifier ?? ""
            return .appFocused(name: name, bundleID: bundleID)
        }()
        let providerAttachments = sentAttachments.map(AIAttachment.inferred(from:))

        isSending = true
        sendTask = Task { [weak self] in
            do {
                let response = try await AIProviderService.shared.sendMessage(
                    query,
                    context: context,
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: history,
                    attachments: providerAttachments
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.messages.append(AIChatMessage(role: .assistant, content: response))
                    self.isSending = false
                    self.sendTask = nil
                    self.persist()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.messages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "Error: \(error.localizedDescription)",
                            isError: true))
                    self.isSending = false
                    self.sendTask = nil
                    self.persist()
                }
            }
        }
    }

    private func persist() {
        GeneralAIChatConversationStore.save(messages)
    }
}
