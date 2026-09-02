import SwiftUI

@MainActor
struct CornerGeneralChatSnapshot {
    let draft: String
    let attachmentNames: [String]
    let slashApps: [ChatAppEntry]

    init(model: GeneralChatWindowModel) {
        draft = model.input
        attachmentNames = model.attachments.map(\.lastPathComponent)
        slashApps = ChatSlashAppPicker.matches(for: model.input)
    }

    @discardableResult
    static func pickLeadingSlashApp(in model: GeneralChatWindowModel) -> Bool {
        ChatSlashAppPicker.pickLeadingMatch(text: &model.input) { match in
            model.attachApp(match.name)
        }
    }
}

enum CornerGeneralChatMetrics {
    static let compactHeight: CGFloat = 72
    static let maximumHeight: CGFloat = 620

    static func height(
        messageCount: Int,
        isSending: Bool,
        hasAttachments: Bool,
        slashMatchCount: Int,
        showsStarter: Bool = false
    ) -> CGFloat {
        if messageCount > 0 || isSending {
            return min(maximumHeight, 220 + CGFloat(min(messageCount, 5)) * 90)
        }
        if showsStarter { return 350 }
        var result = compactHeight
        if slashMatchCount > 0 { result += 46 }
        if hasAttachments { result += 34 }
        return result
    }

    @MainActor
    static func size(for model: GeneralChatWindowModel) -> CGSize {
        let slashMatches = ChatSlashAppPicker.matches(for: model.input)
        let showsStarter = model.activeScope == .general
            && model.messages.isEmpty
            && !model.isSending
            && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.attachments.isEmpty
        return CGSize(
            width: CornerDockLayout.cardWidth,
            height: height(
                messageCount: model.messages.count,
                isSending: model.isSending,
                hasAttachments: !model.attachments.isEmpty,
                slashMatchCount: slashMatches.count,
                showsStarter: showsStarter))
    }
}

struct CornerGeneralChatView: View {
    @ObservedObject var model: GeneralChatWindowModel
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var keyboardState = CornerDockController.shared.keyboardState
    @FocusState private var composerFocused: Bool

    private var size: CGSize { CornerGeneralChatMetrics.size(for: model) }
    private var showsTranscript: Bool { !model.messages.isEmpty || model.isSending }
    private var showsStarter: Bool {
        model.activeScope == .general
            && model.messages.isEmpty
            && !model.isSending
            && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsTranscript {
                header
                Divider().opacity(0.18)
                transcript
                if let request = approvals.pending(for: .chatWindow) {
                    ApprovalCard(request: request)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            } else if showsStarter {
                GeneralChatStartView { prompt in
                    model.input = prompt
                    model.send()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composer
        }
        .frame(width: size.width, height: size.height)
        .background(GlassBackground(cornerRadius: 22, isDark: true))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        .onChange(of: keyboardState.focusRequestToken) { _, _ in composerFocused = true }
        .onChange(of: model.input) { _, _ in
            CornerDockController.shared.chatPresentation.composerInteracted()
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: size.height)
        .animation(.easeOut(duration: 0.18), value: showsStarter)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AIProviderIcon(provider: AppSettings.shared.selectedAIProvider, size: 18)
            Text(AppSettings.shared.selectedAIProvider.shortName)
                .font(.system(size: 14, weight: .semibold))
            Text("General Chat")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button { GeneralChatWindowController.shared.show() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open in General Chat")
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        AIChatMessageView(
                            message: message,
                            onEnableApp: { model.enableApp($0) },
                            onPickAction: { model.pickRoute($0) },
                            liveSteps: message.id == model.messages.last?.id
                                ? model.activeProgress : [])
                            .id(message.id)
                    }
                    if model.isSending, let status = model.activeStatus {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(15)
            }
            .onChange(of: model.messages.count) { _, _ in
                guard let last = model.messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.attachments, id: \.self) { url in
                            Text(url.lastPathComponent)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                }
            }
            AIComposerBar(
                text: $model.input,
                isSending: model.isSending,
                attachedAppNames: model.scopeAppNames,
                onAttachFile: { model.attachFiles() },
                onAttachApp: { model.attachApp($0) },
                onSubmit: {
                    if !CornerGeneralChatSnapshot.pickLeadingSlashApp(in: model) {
                        model.send()
                    }
                },
                extraAttachMenu: {
                    AnyView(Group {
                        Button("Upload Photo") { model.attachFiles(imagesOnly: true) }
                        Button("Chat with a Folder…") { model.attachFolder() }
                        Divider()
                        Button("Take Screenshot") { model.captureScreenshot(interactive: false) }
                        Button("Capture Area") {
                            model.captureScreenshot(interactive: true, windowFirst: true)
                        }
                        Button("Capture Text") { model.captureScreenText() }
                    })
                },
                showsProviderName: true,
                onClear: model.isEmpty ? nil : { model.clearActiveThread() },
                onRemoveApp: { model.removeApp($0) },
                onPasteImages: { urls in
                    model.attachments.append(contentsOf: urls.filter {
                        !model.attachments.contains($0)
                    })
                },
                onEmptyLeftArrow: { false },
                usesInlineAppPicker: true,
                isPinned: CornerDockController.shared.chatPresentation.isGeneralPinned,
                onTogglePin: {
                    CornerDockController.shared.chatPresentation.toggleGeneralPin()
                })
                .focused($composerFocused)
                .simultaneousGesture(TapGesture().onEnded {
                    CornerDockController.shared.requestComposerFocus()
                })
        }
        .padding(12)
        .onChange(of: composerFocused) { _, focused in
            CornerDockController.shared.chatPresentation.setGeneralComposerFocused(focused)
        }
    }
}

struct CornerGeneralChatMini: View {
    var body: some View {
        HStack(spacing: 7) {
            AIProviderIcon(provider: AppSettings.shared.selectedAIProvider, size: 20)
            Text("AI")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(
            width: AppChatPromptMetrics.miniSize.width,
            height: AppChatPromptMetrics.miniSize.height)
        .background(GlassBackground(cornerRadius: 22, isDark: true))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
    }
}
