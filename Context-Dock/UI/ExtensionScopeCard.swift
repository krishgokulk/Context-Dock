// ExtensionScopeCard.swift
// Context-Dock
//
// A Global Extension, running in the corner's board.
//
// The launcher opens these in a window of their own. In the corner that would be a second
// floating container beside the one the user is already in — the thing the Unified Dock
// Surface rule exists to prevent — so the extension's own view is mounted here instead. It
// is the same view the launcher shows, not a corner-shaped copy of it: an extension that
// worked in one place and not the other would be worse than one that only worked in one.

import AppKit
import SwiftUI

enum ExtensionScopeMetrics {
    static let width = CornerDockLayout.cardWidth
    static let headerHeight: CGFloat = 32
    /// Enough for a converter, a note, a short list. Beyond this the extension scrolls
    /// inside its own view rather than pushing the field off the screen.
    static let bodyHeight: CGFloat = 300
    static let verticalPadding: CGFloat = 8

    static var size: CGSize {
        CGSize(width: width, height: headerHeight + bodyHeight + verticalPadding * 2)
    }
}

struct ExtensionScopeCard: View {
    @ObservedObject var model: AppChatPromptModel
    /// One of the two: a Global Extension the user built, or a Global Command from the
    /// registry. They look the same to the user — something global with its own interface —
    /// and so they get one board rather than two that drift.
    var ext: UserGlobalExtension?
    var command: SystemCommand?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            conversation
            content
                .frame(
                    width: ExtensionScopeMetrics.width,
                    height: ExtensionScopeMetrics.bodyHeight)
        }
        .padding(.vertical, ExtensionScopeMetrics.verticalPadding)
        .frame(
            width: ExtensionScopeMetrics.size.width,
            height: ExtensionScopeMetrics.size.height,
            alignment: .topLeading)
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
        .onHover { _ in model.touch() }
    }

    /// What the field has asked this panel, and what it answered. Only while there is
    /// something to show: an empty transcript would take room the panel needs.
    @ViewBuilder
    private var conversation: some View {
        if !model.panelConversation.isEmpty || model.isAskingPanel {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.panelConversation.enumerated()), id: \.offset) {
                        _, message in
                        Text(message.content)
                            .font(.system(size: 11))
                            .foregroundStyle(
                                message.role == .user
                                    ? Color.secondary : Color.primary.opacity(0.9))
                            .frame(
                                maxWidth: .infinity,
                                alignment: message.role == .user ? .trailing : .leading)
                            .textSelection(.enabled)
                    }
                    if model.isAskingPanel {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("Asking \(title)…")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .frame(height: 92)
            Divider().opacity(0.25)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let ext {
            ExtensionPanelContentView(ext: ext, isEmbedded: true)
        } else if let command {
            // The same panel the pinned window shows, so a command that works there works
            // here: one view, two places to put it. Embedded, it leaves the title bar and
            // the assistant to the corner, which already has both.
            ScopedListPanelContent(
                command: command, isEmbedded: true, externalQuery: model.query)
        }
    }

    private var title: String { ext?.name ?? command?.name ?? "" }
    private var symbol: String {
        let icon = ext?.icon ?? command?.icon ?? ""
        return icon.isEmpty ? "puzzlepiece.extension" : icon
    }

    /// The name, and the controls that belong to the board rather than to the field: keep it
    /// open, open it larger, leave it.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)

            Button { model.togglePin() } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.isPinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")

            Button {
                if let ext { ExtensionPanelManager.shared.open(ext) }
                if let command { ScopedListPanelManager.shared.pin(command) }
                // The window *is* the panel now. Leaving the board behind it was the same
                // extension drawn twice, the small copy still holding the corner's field —
                // and closing that copy looked like closing the window it had just opened.
                model.leaveScopeForGlobal()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open in its own window")

            Button { model.leaveScopeForGlobal() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to Global Context")
        }
        .padding(.horizontal, 16)
        .frame(height: ExtensionScopeMetrics.headerHeight)
    }
}
