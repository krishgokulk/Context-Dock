// ClipboardPreviewCard.swift
// Context-Dock
//
// The clip you are standing on, above the list you are walking through.
//
// Arrowing a history of "Image, Image, Image" tells the user nothing, and the answer is not
// a bigger row: it is the clip itself, shown while the list stays where it is.
//
// It is a preview and nothing else. A composer lived here briefly and was wrong: a question
// asked from a card this size has nowhere to put the answer, and asking about a clip is what
// the expanded preview is for. The controls here are the ones that act on the file — open
// it, share it, open it properly, keep it on screen.

import AppKit
import SwiftUI

enum ClipboardPreviewMetrics {
    static let headerHeight: CGFloat = 38

    static var size: CGSize {
        CGSize(width: CornerDockLayout.cardWidth, height: CornerDockLayout.previewHeight)
    }
}

struct ClipboardPreviewCard: View {
    @ObservedObject var model: ClipboardPanelModel
    let entry: LauncherView.ClipboardEntry
    var isPinned: Bool
    var onTogglePin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.18)
            body(for: entry)
        }
        .frame(width: ClipboardPreviewMetrics.size.width,
               height: ClipboardPreviewMetrics.size.height)
        .background(GlassBackground(cornerRadius: 22, isDark: true))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
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

            openWithMenu
            shareControl

            Button {
                // Expanding is where a conversation about this clip happens: that window
                // has the room for a transcript, and this card does not.
                ClipboardPanelController.shared.preview()
            } label: {
                glyph("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open the full preview")

            Button(action: onTogglePin) {
                glyph(isPinned ? "pin.fill" : "pin", tinted: isPinned)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin preview (⌘P)" : "Pin preview (⌘P)")
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPreviewMetrics.headerHeight)
    }

    /// The apps that can open this clip, which is only a question worth asking once there
    /// is a file to open.
    @ViewBuilder
    private var openWithMenu: some View {
        if let url = fileURL {
            Menu {
                ForEach(openers(for: url), id: \.self) { app in
                    Button(appName(app)) {
                        NSWorkspace.shared.open(
                            [url], withApplicationAt: app,
                            configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                glyph("arrow.up.forward.app")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .help("Open with")
        }
    }

    @ViewBuilder
    private var shareControl: some View {
        if let url = fileURL {
            ShareLink(item: url) {
                glyph("square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("Share")
        }
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
        } else if let url = fileURL {
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

    /// A clip is only openable and shareable when it has a file of its own. Text clips have
    /// none, and inventing a scratch file for a control the user has not pressed would
    /// write to disk on every arrow key.
    private var fileURL: URL? {
        guard let first = entry.filePaths.first else { return nil }
        let url = URL(fileURLWithPath: first)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func openers(for url: URL) -> [URL] {
        Array(NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(5))
    }

    private func appName(_ appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
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
