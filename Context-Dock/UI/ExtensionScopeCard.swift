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

    @ViewBuilder
    private var content: some View {
        if let ext {
            ExtensionPanelContentView(ext: ext)
        } else if let command {
            // The same panel the pinned window shows, so a command that works there works
            // here: one view, two places to put it.
            ScopedListPanelContent(command: command)
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
