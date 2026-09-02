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
    static let suggestionRowHeight: CGFloat = 34
    static let summaryHeight: CGFloat = 30
    /// Just the app's icon.
    static let miniSize = CGSize(width: 52, height: 44)
    /// The conversation. Fixed, because the shell never resizes — the transcript scrolls.
    static let chatHeight: CGFloat = 340

    static func size(for phase: AppChatPromptPhase, suggestions: Int) -> CGSize {
        switch phase {
        case .hidden, .mini:
            return miniSize
        case .prompt:
            return CGSize(width: width, height: inputHeight)
        case .chat:
            return CGSize(width: width, height: chatHeight)
        case .suggesting:
            let rows = CGFloat(min(suggestions, 5))
            return CGSize(
                width: width,
                height: inputHeight + summaryHeight + rows * suggestionRowHeight + 12)
        }
    }
}

struct AppChatPromptPill: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var keyboardState = CornerDockController.shared.keyboardState
    @FocusState private var fieldFocused: Bool
    @State private var pointerInside = false

    private var size: CGSize {
        AppChatPromptMetrics.size(for: model.phase, suggestions: model.suggestions.count)
    }

    var body: some View {
        Group {
            if model.phase == .mini {
                miniContent
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            } else {
                inputStack
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
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
        .onHover { pointerInside = $0 }
        .onChange(of: model.phase) { _, phase in
            fieldFocused = phase.showsInput
        }
        .onChange(of: keyboardState.focusRequestToken) { _, _ in
            fieldFocused = true
        }
    }

    // MARK: - Input

    /// Every state reads upward from one stable composer at the bottom. Suggestions are
    /// simply the empty transcript: they occupy the same space answers will use later.
    private var inputStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.phase == .chat {
                transcript
                Divider().opacity(0.18)
            } else if model.phase == .suggesting {
                suggestionList
                Divider().opacity(0.18)
            }
            if !model.attachments.isEmpty { attachmentRow }
            inputRow
        }
        .frame(width: AppChatPromptMetrics.width, alignment: .topLeading)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            if model.appBundleID.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            } else {
                appChip
            }

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
                    .onKeyPress(.leftArrow) {
                        CornerDockController.shared.chatPresentation
                            .handleLeftArrow(draft: model.query) ? .handled : .ignored
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        CornerDockController.shared.requestComposerFocus()
                    })
            }

            // Controls belong to the pointer: at rest this row is one quiet line.
            if pointerInside {
                trailingControls
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if !model.appBundleID.isEmpty, model.phase == .prompt, let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: AppChatPromptMetrics.inputHeight)
        .animation(.easeOut(duration: 0.14), value: pointerInside)
    }

    /// The app the question is about, named rather than implied.
    private var appChip: some View {
        HStack(spacing: 6) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(model.appName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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
        } else {
            Text("Ask \(model.appName.isEmpty ? "this app" : model.appName)…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 8) {
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
                model.openInDock()
            } label: {
                controlGlyph("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open this conversation in the dock")

            Button {
                model.togglePin()
            } label: {
                controlGlyph(model.isPinned ? "pin.fill" : "pin", tinted: model.isPinned)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")
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

    /// The app's own icon: the corner still says which app this was about.
    private var miniContent: some View {
        Group {
            if let icon = appIcon {
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
