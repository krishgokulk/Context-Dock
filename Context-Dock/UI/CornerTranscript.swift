// CornerTranscript.swift
// Context-Dock
//
// A conversation as the corner draws it — the App Chat card's transcript, and since the
// Selection card answers in place (2026-09-25), the Selection card's too. One view, so an
// answer looks and behaves the same wherever the corner shows it: the shared
// `AIChatMessageView` (markdown, tables, links, files, images, result cards), the live step
// list while a turn runs, and the Install card for a proposed app action.

import AppKit
import SwiftUI

struct CornerTranscript: View {
    let messages: [AIChatMessage]
    let isAnswering: Bool
    let liveSteps: [String]
    let appName: String
    let appBundleID: String
    let appIcon: NSImage?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        AIChatMessageView(
                            message: message,
                            isStreaming: isAnswering && index == messages.count - 1,
                            // The dock passed this and the corner did not, so a proposed app
                            // action reached this transcript with its Install card drawn
                            // nowhere. Same message, same flag, same installer — the corner
                            // only supplies its own scope.
                            onInstallProposal: { json in install(json) },
                            assistantAvatarImage: appIcon,
                            liveSteps: isAnswering && index == messages.count - 1 ? liveSteps : []
                        )
                        .id(message.id)
                    }
                    // The dock draws its activity timeline over exactly this data; the
                    // corner drew a bare spinner over it. A spinner is the app declining
                    // to say what it is doing while it holds the user's question.
                    if isAnswering && (messages.last?.role == .user || messages.isEmpty) {
                        LiveAgentProgressView(steps: waitingSteps)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            // Drawn again (the Selection card coming back from its actions or Share): open on
            // the latest reply, not the top of the thread.
            .onAppear {
                guard let last = messages.last else { return }
                DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What to show between sending and the first token.
    ///
    /// The steps are the truth when there are any. Before the first one arrives there is
    /// still something honest to say — which app the question went to — and saying it beats
    /// a spinner, which tells the user only that the app is busy with something.
    private var waitingSteps: [String] {
        let steps = liveSteps.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard steps.isEmpty else { return steps }
        return ["Reading \(appName.isEmpty ? "this app" : appName)…"]
    }

    private func install(_ json: String) {
        guard let data = json.data(using: .utf8),
            let proposal = try? JSONDecoder().decode(ExtensionProposalData.self, from: data)
        else { return }
        Task { @MainActor in
            // The corner is a frontmost-app surface, so its proposals are app actions. A
            // selection-scope or rule proposal has its own installer, still on the dock (#12);
            // filing one as an adapter action would be worse than saying so.
            guard proposal.layer.lowercased() == "contextdock" else {
                AppChatConversation.shared.messages.append(
                    AIChatMessage(
                        role: .assistant,
                        content: "That kind of extension is saved from "
                            + "the dock's chat for now — open the same "
                            + "conversation there and press Install."))
                return
            }
            await AdapterActionProposalInstaller.install(
                proposal, bundleId: appBundleID, appName: appName)
        }
    }
}
