// ChatThreadPreviewPanel.swift
// Context-Dock
//
// The file a thread is working on, shown beside the conversation.
//
// A chat can say "I wrote the summary to ~/Documents/notes.md" and the user has to go and
// open it to find out what it says. The side panel already holds the thread's terminal for
// exactly this reason — some things have to be shown rather than described — and a file is
// the other half of that: the work has an output, and the output should be visible where
// the work happened.
//
// The candidate list is derived from the conversation rather than tracked separately: the
// files the user attached, plus any absolute path in the transcript that exists on disk.
// That is deliberately simple, and it is honest about what it knows — a path the assistant
// only planned to write does not appear, because it is not there.

import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ChatThreadPreviewPanel: View {
    /// Newest last — the file most recently mentioned is the one being worked on.
    let candidates: [URL]

    @State private var selected: URL?
    @State private var text: String = ""
    /// What was on disk when the file was loaded, so an edit can tell whether it is saving
    /// over its own copy or over someone else's change.
    @State private var loadedText: String = ""
    @State private var thumbnail: NSImage?
    @State private var status: String?

    private var current: URL? { selected ?? candidates.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let current {
                content(for: current)
            } else {
                Text("Nothing to preview yet. Files this thread attaches or writes show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
            }
        }
        .onChange(of: current) { _, _ in load() }
        .onAppear { load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            if candidates.count > 1 {
                Menu {
                    ForEach(candidates.reversed(), id: \.self) { url in
                        Button(url.lastPathComponent) { selected = url }
                    }
                } label: {
                    Text(current?.lastPathComponent ?? "Files")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(current?.lastPathComponent ?? "PREVIEW")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let status {
                Text(status)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            if isEditable, text != loadedText {
                Button("Save") { save() }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            }
            if let current {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([current])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for url: URL) -> some View {
        if isEditable {
            // Editable in place. A file the assistant just wrote is usually a draft, and
            // making the user open an editor to change one line is the friction this panel
            // exists to remove.
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 260)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.28)))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        } else if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        } else {
            Text(url.pathExtension.uppercased() + " file")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
    }

    /// Text-shaped files are edited; everything else is looked at.
    private var isEditable: Bool {
        guard let current else { return false }
        guard let type = UTType(filenameExtension: current.pathExtension) else {
            return current.pathExtension.isEmpty
        }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .propertyList) || type.conforms(to: .json)
    }

    // MARK: - Load and save

    private func load() {
        thumbnail = nil
        status = nil
        guard let current else { return }

        if isEditable {
            let contents = (try? String(contentsOf: current, encoding: .utf8)) ?? ""
            // A very large file would make the editor unusable and is not what this panel
            // is for; it is shown truncated and marked so, rather than silently cut.
            if contents.count > 200_000 {
                text = String(contents.prefix(200_000))
                loadedText = text
                status = "showing first 200 KB — not editable"
            } else {
                text = contents
                loadedText = contents
            }
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: current, size: CGSize(width: 640, height: 520),
            scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let representation else { return }
            Task { @MainActor in thumbnail = representation.nsImage }
        }
    }

    private func save() {
        guard let current, isEditable, status == nil else { return }
        // Check the file has not changed underneath since it was loaded. Writing over
        // someone else's edit — the assistant's, an editor's, a build step's — silently is
        // the one failure that cannot be undone from here.
        let onDisk = (try? String(contentsOf: current, encoding: .utf8)) ?? ""
        guard onDisk == loadedText else {
            status = "changed on disk — reopen to merge"
            return
        }
        do {
            try text.write(to: current, atomically: true, encoding: .utf8)
            loadedText = text
            status = "saved"
        } catch {
            status = "couldn't save"
        }
    }
}
