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
    /// Apps the answer should be about — the composer's app picker. Several at once
    /// is the point: a chat can be scoped to Reminders and Safari together.
    @Published var attachedAppNames: [String] = []
    /// Which apps were attached when each message was sent, so the transcript keeps
    /// showing what a question was asked *about* after the scope changes. In memory
    /// only — the stored conversation format has no field for it, and a reopened
    /// window showing today's scope on last week's question would be a lie.
    @Published var messageApps: [UUID: [String]] = [:]

    /// The conversation currently shown. The window is a hub: one thread per app or CLI tool,
    /// each kept whether or not that app is running, plus the unscoped one the result sheet
    /// shares. Combined chat is unchanged — it is what attachedAppNames does *within* a
    /// session, so a thread can still span Reminders and Safari.
    @Published private(set) var activeScope: GeneralChatScope = .general
    /// Sidebar contents, most recently used first.
    @Published private(set) var sessions: [GeneralChatSession] = GeneralChatSessionStore.index()

    private var sendTask: Task<Void, Never>?

    var isEmpty: Bool { messages.isEmpty }

    /// Pull in whatever the result sheet has said since this window was last open.
    func reloadFromStore() {
        guard !isSending else { return }
        messages = GeneralChatSessionStore.load(scope: activeScope)
        sessions = GeneralChatSessionStore.index()
    }

    /// Shows the conversation for a scope, creating it on first use.
    ///
    /// Switching persists what is on screen first, so moving between threads cannot lose the
    /// one being left. A send in flight is left alone: cancelling someone's answer because
    /// they clicked another row would be its own bug.
    /// - Parameter seed: the conversation being handed over from the dock. A thread opened
    ///   from a scope must show what the user was already reading — arriving at an empty
    ///   window while the dock still held the transcript is not a handover, it is a second
    ///   conversation. Applied only when the thread is empty, so reopening never overwrites
    ///   history with whatever the dock happens to be showing.
    func openSession(_ scope: GeneralChatScope, title: String, seed: [AIChatMessage] = []) {
        guard !isSending else { return }
        guard scope != activeScope else {
            adoptSeedIfEmpty(seed, scope: scope, title: title)
            sessions = GeneralChatSessionStore.index()
            return
        }
        persist()
        sendTask?.cancel()
        sendTask = nil
        activeScope = scope
        messages = GeneralChatSessionStore.load(scope: scope)
        messageApps = [:]
        input = ""
        attachments = []
        // A scoped session is about its own app; the picker starts empty rather than
        // inheriting whatever the previous thread was attached to.
        attachedAppNames = []
        adoptSeedIfEmpty(seed, scope: scope, title: title)
        GeneralChatSessionStore.upsert(
            scope: scope, title: title, messageCount: messages.count)
        sessions = GeneralChatSessionStore.index()
    }

    private func adoptSeedIfEmpty(
        _ seed: [AIChatMessage], scope: GeneralChatScope, title: String
    ) {
        guard messages.isEmpty, !seed.isEmpty else { return }
        messages = seed
        GeneralChatSessionStore.save(seed, scope: scope, title: title)
    }

    func closeSession(_ scope: GeneralChatScope) {
        GeneralChatSessionStore.remove(scope: scope)
        if scope == activeScope { openGeneralSession() }
        sessions = GeneralChatSessionStore.index()
    }

    func openGeneralSession() {
        activeScope = .general
        messages = GeneralChatSessionStore.load(scope: .general)
        messageApps = [:]
        sessions = GeneralChatSessionStore.index()
    }

    /// Title for the active thread, used when persisting.
    var activeTitle: String {
        switch activeScope {
        case .general: return "General"
        case .cli(let command): return command
        case .app(let bundleId):
            return sessions.first { $0.scope == activeScope }?.title ?? bundleId
        }
    }

    func newChat() {
        sendTask?.cancel()
        sendTask = nil
        messages = []
        messageApps = [:]
        input = ""
        attachments = []
        attachedAppNames = []
        isSending = false
        // Clears the thread being shown, not every thread: with sessions, "New chat" on the
        // Reminders session must not wipe the CLI ones beside it.
        if activeScope == .general {
            GeneralAIChatConversationStore.clear()
        } else {
            GeneralChatSessionStore.save([], scope: activeScope, title: activeTitle)
        }
        sessions = GeneralChatSessionStore.index()
    }

    func cancel() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    /// Same five ways to attach the dock offers — one implementation, in
    /// ChatAttachmentCapture, so the "+" means the same thing on both surfaces.
    func attachFiles(imagesOnly: Bool = false) {
        let picked = ChatAttachmentCapture.pickFiles(imagesOnly: imagesOnly)
        attachments.append(contentsOf: picked.filter { !attachments.contains($0) })
    }

    func captureScreenshot(interactive: Bool, windowFirst: Bool = false) {
        ChatAttachmentCapture.captureScreenshot(
            interactive: interactive, windowFirst: windowFirst
        ) { [weak self] url in
            guard let self, !self.attachments.contains(url) else { return }
            self.attachments.append(url)
        }
    }

    /// OCR'd screen text lands in the composer, where the user can see what was read
    /// before sending it — a capture that silently became context would be worse.
    func captureScreenText() {
        ChatAttachmentCapture.captureScreenText { [weak self] text in
            guard let self else { return }
            let existing = self.input.trimmingCharacters(in: .whitespacesAndNewlines)
            self.input = existing.isEmpty ? text : existing + "\n\n" + text
        }
    }

    func attachApp(_ name: String) {
        guard !attachedAppNames.contains(name) else { return }
        attachedAppNames.append(name)
    }

    func removeApp(_ name: String) {
        attachedAppNames.removeAll { $0 == name }
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
        let userMessage = AIChatMessage(
            role: .user, content: query, attachments: sentAttachments)
        if !attachedAppNames.isEmpty {
            messageApps[userMessage.id] = attachedAppNames
        }
        messages.append(userMessage)
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
        GeneralChatSessionStore.save(messages, scope: activeScope, title: activeTitle)
        sessions = GeneralChatSessionStore.index()
    }
}
