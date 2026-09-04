// ClipboardPreviewCard.swift
// Context-Dock
//
// The clip you are standing on, above the list you are walking through, with a field to ask
// about it.
//
// Arrowing a history of "Image, Image, Image" tells the user nothing, and the answer is not
// a bigger row: it is the clip itself, shown while the list stays where it is. The composer
// is here because looking at a clip and wanting something done with it are the same moment —
// the question goes to General chat with the clip attached, so there is no second pipeline.

import AppKit
import SwiftUI

enum ClipboardPreviewMetrics {
    static let composerHeight: CGFloat = 44
    static let headerHeight: CGFloat = 38
    /// Room for the reply, once one has been asked for. The card grows rather than sending
    /// the user somewhere else to read it.
    static let answerHeight: CGFloat = 148

    static func size(showsAnswer: Bool) -> CGSize {
        CGSize(
            width: CornerDockLayout.cardWidth,
            height: CornerDockLayout.previewHeight + (showsAnswer ? answerHeight : 0))
    }

    static var size: CGSize { size(showsAnswer: false) }
}

struct ClipboardPreviewCard: View {
    @ObservedObject var model: ClipboardPanelModel
    let entry: LauncherView.ClipboardEntry
    var isPinned: Bool
    var onTogglePin: () -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    @ObservedObject private var general = GeneralChatWindowModel.shared

    private var showsAnswer: Bool { model.previewConversationActive }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.18)
            body(for: entry)
            if showsAnswer {
                Divider().opacity(0.18)
                answer
            }
            Divider().opacity(0.18)
            composer
        }
        .frame(
            width: ClipboardPreviewMetrics.size(showsAnswer: showsAnswer).width,
            height: ClipboardPreviewMetrics.size(showsAnswer: showsAnswer).height)
        .background(GlassBackground(cornerRadius: 22, isDark: true))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !entry.sourceBundleId.isEmpty, let icon = appIcon(entry.sourceBundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(entry.sourceAppName.isEmpty ? "Clip" : entry.sourceAppName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text(entry.timestamp.formatted(.relative(presentation: .named)))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 6)

            Button {
                ClipboardPanelController.shared.preview()
            } label: {
                glyph("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open in the preview window")

            Button(action: onTogglePin) {
                glyph(isPinned ? "pin.fill" : "pin", tinted: isPinned)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin preview (⌘P)" : "Pin preview (⌘P)")
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPreviewMetrics.headerHeight)
    }

    /// The clip at a size worth calling a preview: the picture for an image, the text for
    /// text, the file's own icon and name for anything else.
    @ViewBuilder
    private func body(for entry: LauncherView.ClipboardEntry) -> some View {
        if let data = ClipboardScopeService.imageData(for: entry),
            let image = NSImage(data: data)
        {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
        } else if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                Text(entry.text)
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let path = entry.filePaths.first {
            let url = URL(fileURLWithPath: path)
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 34, height: 34)
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text("Nothing to preview")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What came back, in the card that asked.
    ///
    /// The question already ran on General's thread and pipeline — nothing here is a second
    /// engine — but sending the user off to another surface to read the answer made the
    /// field look like a dead end. Steps while it works, the reply when it arrives, and a
    /// way through to the full thread.
    private var answer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if general.isSending {
                LiveAgentProgressView(
                    steps: general.activeProgress.isEmpty
                        ? [general.activeStatus ?? "Thinking…"] : general.activeProgress)
            } else if let reply = latestReply {
                ScrollView {
                    Text(reply)
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No answer yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Open in General Chat") {
                    CornerDockController.shared.chatPresentation.showGeneralFromPreview()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)

                Spacer(minLength: 4)

                if general.isSending {
                    Button("Stop") { general.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Done") { model.endPreviewConversation() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: ClipboardPreviewMetrics.answerHeight)
    }

    private var latestReply: String? {
        general.messages.last { $0.role == .assistant }?.content
    }

    /// Asking about the clip in front of you. It goes to General chat with the clip
    /// attached — the same thread and the same pipeline, not a third one.
    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text("Ask about this clip…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onSubmit(send)
                    // Typing here is attention. Without this the clipboard's own idle
                    // clock kept running and took the card away mid-question.
                    .onChange(of: draft) { _, _ in model.keepAlive() }
                    .onChange(of: fieldFocused) { _, focused in
                        model.setPreviewComposerFocused(focused)
                    }
            }

            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Ask")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPreviewMetrics.composerHeight)
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let general = GeneralChatWindowModel.shared
        // The clip travels as its file where it has one, so the model sees the image
        // rather than the word "Image".
        if let path = entry.filePaths.first {
            let url = URL(fileURLWithPath: path)
            if !general.attachments.contains(url) { general.attachments.append(url) }
            general.input = question
        } else if let data = ClipboardScopeService.imageData(for: entry),
            let url = ClipboardScopeService.temporaryDragFile(data: data, fileExtension: "png")
        {
            if !general.attachments.contains(url) { general.attachments.append(url) }
            general.input = question
        } else {
            general.input = "\(question)\n\n\(ClipboardScopeService.contextText(from: [entry]))"
        }
        general.send()
        draft = ""
        // The answer lands here, in the card that asked. General still owns the thread —
        // "Open in General Chat" is one control away for the rest of it.
        model.beginPreviewConversation()
    }

    private func glyph(_ symbol: String, tinted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tinted ? Color.accentColor : .secondary)
            .frame(width: 24, height: 24)
            .background(tinted ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
            .contentShape(Circle())
    }

    private func appIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
