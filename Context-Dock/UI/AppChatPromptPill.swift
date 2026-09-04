// AppChatPromptPill.swift
// Context-Dock
//
// The corner input for asking the frontmost app something, in the same shell and shape as
// the clipboard pill.
//
// It opens the way Siri does — showing what this app can actually do — because a blank
// field asks the user to guess. Typing puts the list away, idling shrinks the whole thing
// to the app's own icon, and the controls in the field only appear under the pointer so
// the resting state stays a single quiet line.

import AppKit
import SwiftUI

enum AppChatPromptMetrics {
    static let width: CGFloat = 372
    static let inputHeight: CGFloat = 56
    /// The one control row under the composer. Attach, new chat, expand and pin used to
    /// appear inside the input line under the pointer, which made them invisible until
    /// found by accident and crowded the field when they were.
    static let controlRowHeight: CGFloat = 36
    static let suggestionRowHeight: CGFloat = 34
    static let summaryHeight: CGFloat = 30
    /// Just the app's icon.
    static let miniSize = CGSize(width: 52, height: 44)
    /// The conversation. Fixed, because the shell never resizes — the transcript scrolls.
    static let chatHeight: CGFloat = 340
    /// How much of the corner a waiting decision may take. Past this the card scrolls:
    /// a long command must not push the composer out of the shell.
    static let resultCardMaxHeight: CGFloat = 168

    /// General mode composes in the app's one shared `AIComposerBar` — the same capsule,
    /// provider chip and app picker the chat window uses — so its composer is that bar's
    /// height plus the room around the capsule, not the App-mode input line.
    static let generalBarHeight: CGFloat = 44
    static let generalBarInset: CGFloat = 8

    /// Composer plus its controls — the height the surface never goes below, and the
    /// bottom every other state grows upward from.
    static var composerBlockHeight: CGFloat { inputHeight + controlRowHeight }
    static var generalComposerBlockHeight: CGFloat {
        generalBarHeight + generalBarInset * 2 + controlRowHeight
    }

    static func composerBlockHeight(for scope: AppChatPromptScope) -> CGFloat {
        scope == .general ? generalComposerBlockHeight : composerBlockHeight
    }

    static func size(
        for phase: AppChatPromptPhase, suggestions: Int, scope: AppChatPromptScope = .app
    ) -> CGSize {
        let composer = composerBlockHeight(for: scope)
        switch phase {
        case .hidden, .mini:
            return miniSize
        case .prompt:
            return CGSize(width: width, height: composer)
        case .chat:
            return CGSize(width: width, height: chatHeight)
        case .suggesting:
            let rows = CGFloat(min(suggestions, 5))
            return CGSize(
                width: width,
                height: composer + summaryHeight + rows * suggestionRowHeight + 12)
        }
    }
}

struct AppChatPromptPill: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var keyboard = CornerDockController.shared.keyboard
    @ObservedObject private var general = GeneralChatWindowModel.shared
    @FocusState private var fieldFocused: Bool

    private var isGeneral: Bool { model.scope == .general }

    /// The decision this surface is waiting on, if it is this surface's to answer.
    private var approval: ApprovalRequest? { approvals.pending(for: .corner) }

    private var size: CGSize {
        AppChatPromptMetrics.size(
            for: model.phase, suggestions: model.suggestions.count, scope: model.scope)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            miniContent.opacity(model.phase == .mini ? 1 : 0)
            inputStack.opacity(model.phase.showsInput ? 1 : 0)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        // Anywhere on the pill, not just the field: the click that reaches SwiftUI at all
        // is the one that has to arm the window, and simultaneous so the buttons in the
        // control row still get theirs.
        .simultaneousGesture(
            TapGesture().onEnded { CornerDockController.shared.requestComposerFocus() }
        )
        .onChange(of: model.phase) { _, phase in
            fieldFocused = phase.showsInput
        }
        // A ticket, not a flag: clicking back after focus went to another app is a new
        // number to react to, where a boolean would already read true and do nothing.
        .onChange(of: keyboard.focusRequestToken) { _, _ in
            fieldFocused = model.phase.showsInput
        }
        // The steps are a passthrough onto whichever conversation owns the turn, so the
        // count has to be taken as they arrive — once the turn ends they are gone.
        .onChange(of: model.liveSteps.count) { _, _ in model.noteActivity() }
        .onChange(of: model.isAnswering) { _, _ in model.noteActivity() }
    }

    // MARK: - Input

    /// Every state reads upward from one stable composer at the bottom. Suggestions are
    /// simply the empty transcript: they occupy the same space answers will use later.
    private var inputStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.phase == .chat {
                conversationBody
                Divider().opacity(0.18)
            } else if model.phase == .suggesting {
                suggestionList
                Divider().opacity(0.18)
            }
            if !model.attachments.isEmpty { attachmentRow }
            if isGeneral { generalComposer } else { inputRow }
            controlRow
        }
        .frame(width: AppChatPromptMetrics.width, alignment: .topLeading)
    }

    /// Transcript, then what the turn is doing, then the one thing it is waiting on.
    ///
    /// The order is fixed and so is the ranking: a decision sits closest to the composer
    /// and the transcript gives up its space for it, because a card the user has to answer
    /// scrolled off the top is a turn that quietly stalls.
    private var conversationBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcript
                .opacity(approval == nil ? 1 : 0.45)
            if model.isAnswering || model.lastStepCount > 0 {
                activityStream
            }
            if let approval {
                resultCard(approval)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: approval?.id)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            leadingGlyph

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    placeholder
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($fieldFocused)
                    .onChange(of: model.query) { _, _ in model.queryChanged() }
                    .onSubmit { model.submit() }
                    .onKeyPress(.escape) {
                        model.dismiss()
                        return .handled
                    }
                    // An empty field has nothing to move a cursor through, so left and
                    // right mean the other chat. The moment there is text they mean what
                    // they always meant — a switch that ate a cursor key would be worse
                    // than no switch at all.
                    .onKeyPress(.leftArrow) { switchModeOnEmptyField() }
                    .onKeyPress(.rightArrow) { switchModeOnEmptyField() }
            }

            // The only control in the field is the one that sends it. Everything else
            // moved to the row below, where it stays legible instead of appearing under
            // the pointer.
            if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .help("Send")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: AppChatPromptMetrics.inputHeight)
        .animation(.easeOut(duration: 0.14), value: model.query.isEmpty)
    }

    private func switchModeOnEmptyField() -> KeyPress.Result {
        guard model.query.isEmpty else { return .ignored }
        model.toggleScope()
        return .handled
    }

    // MARK: - General composer

    /// General mode composes in the app's one AI input, not a corner copy of it.
    ///
    /// `AIComposerBar` is the same capsule Quick Note, the panels and the chat window use:
    /// provider chip with the name spelled out, `/app` matching straight from
    /// `ChatAppDirectory`, the app picker, attachments, paste-images, clear. Rebuilding a
    /// narrower version here is exactly the drift this surface was built to avoid — the
    /// bar gains a `lineLimit` so it can hold one line in a shell whose height was decided
    /// before it drew, and nothing else about it changes.
    private var generalComposer: some View {
        AIComposerBar(
            text: Binding(
                get: { model.query },
                set: { model.query = $0; model.queryChanged() }),
            isSending: model.isAnswering,
            attachedAppNames: general.scopeAppNames,
            onAttachFile: { pickFiles(imagesOnly: false) },
            onAttachApp: { general.attachApp($0) },
            onSubmit: { model.submit() },
            extraAttachMenu: {
                AnyView(
                    Group {
                        Button { pickFiles(imagesOnly: true) } label: {
                            Label("Upload Photo", systemImage: "photo")
                        }
                        Divider()
                        Button { capture(interactive: false) } label: {
                            Label("Take Screenshot", systemImage: "camera.viewfinder")
                        }
                        Button { capture(interactive: true) } label: {
                            Label("Capture Area", systemImage: "crop")
                        }
                        Button { captureText() } label: {
                            Label("Capture Text", systemImage: "text.viewfinder")
                        }
                    }
                )
            },
            showsProviderName: true,
            onClear: general.messages.isEmpty ? nil : { model.newConversation() },
            // A thread's own app is not detachable: removing it would mean closing the
            // thread, which is the sidebar's job in the window and nobody's here.
            onRemoveApp: { name in
                guard name != general.activeScopeAppName else { return }
                general.removeApp(name)
            },
            onPasteImages: { urls in urls.forEach { model.attach($0) } },
            lineLimit: 1...1
        )
        .frame(height: AppChatPromptMetrics.generalBarHeight)
        .padding(.horizontal, 10)
        .padding(.vertical, AppChatPromptMetrics.generalBarInset)
    }

    /// What the question is about, in the field itself: the app's own icon, or the mark
    /// General chat answers under.
    @ViewBuilder
    private var leadingGlyph: some View {
        if isGeneral {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
        } else if let icon = appIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .frame(width: 22)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
    }

    // MARK: - Controls

    /// One quiet row under the composer: what the question is scoped to on the left, the
    /// things you can do to the conversation on the right. It is always drawn, in every
    /// phase, so the surface has one control surface rather than a set that appears and
    /// disappears with the pointer.
    private var controlRow: some View {
        HStack(spacing: 8) {
            // The chip is the switch you can see. The arrow keys and the swipe are for
            // people who already know; this is how anyone finds out there is another mode.
            Button { model.toggleScope() } label: {
                if isGeneral { generalChip } else { appChip }
            }
            .buttonStyle(.plain)
            .help(isGeneral ? "Switch to the frontmost app's chat" : "Switch to General chat")
            Spacer(minLength: 6)

            // General mode's composer already carries attach and clear, so the row keeps
            // only what the bar has no place for. Repeating them would be two buttons for
            // one job, six points apart.
            if !isGeneral {
                Menu {
                    Button("Upload File") { pickFiles(imagesOnly: false) }
                    Button("Upload Photo") { pickFiles(imagesOnly: true) }
                    Divider()
                    Button("Take Screenshot") { capture(interactive: false) }
                    Button("Capture Area") { capture(interactive: true) }
                    Button("Capture Text") { captureText() }
                } label: {
                    controlGlyph("plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
                .help("Add context")

                Button {
                    model.newConversation()
                } label: {
                    controlGlyph("square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New chat")
            }

            Button {
                model.openInDock()
            } label: {
                controlGlyph("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help(
                isGeneral ? "Open in the General Chat window" : "Open this conversation in the dock"
            )

            Button {
                model.togglePin()
            } label: {
                controlGlyph(model.isPinned ? "pin.fill" : "pin", tinted: model.isPinned)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")
        }
        .padding(.horizontal, 12)
        .frame(height: AppChatPromptMetrics.controlRowHeight)
        .overlay(alignment: .top) { Divider().opacity(0.12) }
    }

    /// The app the question is about, named rather than implied.
    private var appChip: some View {
        HStack(spacing: 6) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(model.appName.isEmpty ? "This app" : model.appName)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.09), in: Capsule())
    }

    /// General chat has no app to name, so the scope itself gets the chip — same shape,
    /// same place, so the one stable composer reads identically in both scopes.
    private var generalChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("General")
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.phase == .suggesting {
            HStack(spacing: 6) {
                Text("Ask \(model.appName.isEmpty ? "this app" : model.appName)")
                    .foregroundStyle(.secondary.opacity(0.85))
                Text("— press Enter to send…")
                    .foregroundStyle(.secondary.opacity(0.45))
            }
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
        } else if isGeneral {
            Text("Ask anything…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        } else {
            Text("Ask \(model.appName.isEmpty ? "this app" : model.appName)…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func controlGlyph(_ symbol: String, tinted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tinted ? Color.accentColor : .secondary)
            .frame(width: 26, height: 26)
            .background(
                tinted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                in: Circle())
    }

    // MARK: - Attachments

    private func pickFiles(imagesOnly: Bool) {
        for url in ChatAttachmentCapture.pickFiles(imagesOnly: imagesOnly) {
            model.attach(url)
        }
    }

    private func capture(interactive: Bool) {
        ChatAttachmentCapture.captureScreenshot(interactive: interactive) { url in
            model.attach(url)
        }
    }

    private func captureText() {
        ChatAttachmentCapture.captureScreenText { text in
            model.query += model.query.isEmpty ? text : "\n" + text
            model.queryChanged()
        }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments, id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 13, height: 13)
                        Text(url.lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Button {
                            model.detach(url)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 34)
    }

    // MARK: - Suggestions

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.capabilitySummary.isEmpty {
                Text(model.capabilitySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(height: AppChatPromptMetrics.summaryHeight, alignment: .leading)
            }
            ForEach(model.suggestions.prefix(5)) { suggestion in
                HStack(spacing: 10) {
                    Image(systemName: suggestion.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 16)
                .frame(height: AppChatPromptMetrics.suggestionRowHeight)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Activity

    /// What the turn is doing, as a vertical stream directly above the composer.
    ///
    /// Only the tail is shown: three lines say what is happening now, and a longer run
    /// would eat the transcript to report its own middle. When the turn ends the stream
    /// collapses to its count, so the finished work is still stated but the result gets
    /// the room.
    @ViewBuilder
    private var activityStream: some View {
        if model.isAnswering {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(model.liveSteps.suffix(3).enumerated()), id: \.offset) {
                    index, step in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(
                                index == min(model.liveSteps.count, 3) - 1
                                    ? Color.accentColor : Color.secondary.opacity(0.45)
                            )
                            .frame(width: 5, height: 5)
                        Text(step)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .transition(.opacity)
        } else if model.lastStepCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
                Text("\(model.lastStepCount) step\(model.lastStepCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Result

    /// The one thing the turn is waiting on, drawn as the dock draws it. It scrolls rather
    /// than growing: the composer keeps its place whatever the request contains.
    private func resultCard(_ request: ApprovalRequest) -> some View {
        ScrollView {
            ApprovalCard(request: request)
        }
        .frame(maxHeight: AppChatPromptMetrics.resultCardMaxHeight)
    }

    // MARK: - Conversation

    /// The dock's own message view, so steps, tool chips, receipts and route choices
    /// render here exactly as they do in the dock. Reimplementing it would have been the
    /// same drift this surface was built to avoid.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) {
                        index, message in
                        AIChatMessageView(
                            message: message,
                            isStreaming: model.isAnswering && index == model.messages.count - 1,
                            assistantAvatarImage: appIcon,
                            liveSteps: model.isAnswering && index == model.messages.count - 1
                                ? model.liveSteps : []
                        )
                        .id(message.id)
                    }
                    if model.isAnswering && model.messages.last?.role == .user {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: model.messages.count) { _, _ in
                guard let last = model.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Shrunken

    /// The app's own icon: the corner still says which app this was about. General chat
    /// has no app, so its own mark stands in.
    private var miniContent: some View {
        Group {
            if isGeneral {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            width: AppChatPromptMetrics.miniSize.width,
            height: AppChatPromptMetrics.miniSize.height)
    }

    private var appIcon: NSImage? {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: model.appBundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
