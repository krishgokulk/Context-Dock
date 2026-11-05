// SideThreadChildView.swift
// Context-Dock
//
// Child view presenting an active Side Thread branched off a conversation turn (#333).
//
// Operates within the same shell and storage layer, never creating a new floating window.
// Provides explicit controls to fold-back a summary into the main conversation or discard the tangent.

import AppKit
import SwiftUI

struct SideThreadChildView: View {
    let sideThread: SideThreadState
    var scopeTitle: String = "Chat"
    var scopeIcon: NSImage? = nil
    let onSend: (String) -> Void
    let onFoldBack: () -> Void
    let onDiscard: () -> Void
    let onBack: () -> Void

    @State private var input: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.18)

            if !sideThread.parentTurnSnippet.isEmpty {
                groundingSnippetBanner
                Divider().opacity(0.12)
            }

            transcriptArea

            Divider().opacity(0.18)
            composerArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFieldFocused = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Main")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Return to main conversation (leaves side thread intact)")

            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)

            Text("Side Thread")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 4) {
                if let icon = scopeIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(scopeTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1), in: Capsule())

            Spacer(minLength: 6)

            Button(action: onFoldBack) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.up.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Fold Back")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("Fold summary of this side thread into the main conversation")

            Button(action: onDiscard) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Discard this side thread without updating the main conversation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Grounding Snippet Banner

    private var groundingSnippetBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, 1)

            Text(sideThread.parentTurnSnippet)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.025))
    }

    // MARK: - Transcript Area

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if sideThread.isEmpty && !sideThread.isSending {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text("Branch a temporary side question")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Ask tangents or verify details without polluting the main conversation or Pet memory.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(Array(sideThread.messages.enumerated()), id: \.element.id) { index, msg in
                            AIChatMessageView(
                                message: msg,
                                isStreaming: sideThread.isSending && index == sideThread.messages.count - 1
                            )
                            .id(msg.id)
                        }

                        if sideThread.isSending && (sideThread.messages.last?.role == .user || sideThread.messages.isEmpty) {
                            LiveAgentProgressView(
                                steps: sideThread.liveSteps.isEmpty ? ["Thinking…"] : sideThread.liveSteps
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: sideThread.messages.count) { _, _ in
                guard let last = sideThread.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: - Composer Area

    private var composerArea: some View {
        HStack(spacing: 8) {
            TextField("Ask a side question…", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isFieldFocused)
                .onSubmit {
                    submit()
                }

            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(sideThread.isSending)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sideThread.isSending else { return }
        input = ""
        onSend(trimmed)
    }
}
