// PreviewRenderer.swift
// Context-Dock
//
// Kind → view. Documents, images and text all go through QLPreviewView, which is the
// same renderer the system panel uses — the difference is that this one is a subview
// we own, so a header, a pin and an assistant can sit around it.

import AppKit
import QuickLookUI
import SwiftUI
import WebKit

struct PreviewRenderer: View {
    let item: PreviewItem

    var body: some View {
        switch item.kind {
        case .document, .image, .text:
            InlineQLPreview(url: item.url)
        case .folder:
            PreviewFolderList(url: item.url)
        case .web:
            PreviewWebView(url: item.url)
        }
    }
}

// MARK: - Folder

/// QLPreviewView renders a folder as one big folder icon, which tells the user nothing
/// they didn't already know. A listing is the useful preview of a directory.
private struct PreviewFolderList: View {
    let url: URL

    @State private var entries: [Entry] = []
    /// Folders walked into from here, so the panel can go back without reopening. The
    /// preview is a peek — it browses, it does not become a file manager.
    @State private var stack: [URL] = []
    @State private var selection: String?

    private var currentURL: URL { stack.last ?? url }

    private struct Entry: Identifiable {
        let id: String
        let url: URL
        let icon: NSImage
        let name: String
        let detail: String
        let isDirectory: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            if !stack.isEmpty { breadcrumb }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry)
                    }

                    if entries.isEmpty {
                        Text("Empty folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 18)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .task(id: currentURL) { load() }
        .onChange(of: url) { _, _ in stack = [] }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button { stack.removeLast() } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Back")

            Text(currentURL.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: entry.icon)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(entry.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            selection == entry.id ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { selection = entry.id }
        .onTapGesture(count: 2) { activate(entry) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(entry.url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
        }
    }

    /// Folders open in place; files take over the same window, so a peek into a folder
    /// never sprays panels across the screen.
    private func activate(_ entry: Entry) {
        if entry.isDirectory {
            stack.append(entry.url)
        } else {
            PreviewController.shared.present(url: entry.url, toggleIfSame: false)
        }
    }

    private func load() {
        let url = currentURL
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        entries = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { child in
                let values = try? child.resourceValues(
                    forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
                let isDirectory = values?.isDirectory ?? false
                let size = values?.fileSize ?? 0
                let modified = values?.contentModificationDate
                var detail = isDirectory
                    ? "Folder"
                    : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                if let modified {
                    detail += " · " + modified.formatted(date: .abbreviated, time: .omitted)
                }
                return Entry(
                    id: child.path,
                    url: child,
                    icon: NSWorkspace.shared.icon(forFile: child.path),
                    name: child.lastPathComponent,
                    detail: detail,
                    isDirectory: isDirectory
                )
            }
    }
}

// MARK: - Web

private struct PreviewWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url))
    }
}
