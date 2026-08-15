// PreviewTextEditor.swift
// Context-Dock
//
// Text-shaped files are edited in place; everything else is looked at. A file the
// assistant just wrote is usually a draft, and making the user open an editor to
// change one line is the friction this panel exists to remove.
//
// Lifted from ChatThreadPreviewPanel, which had the only version of this in the app.
// Two rules earned the hard way and kept intact: the file is watched, so an agent
// rewriting it never leaves the user reading a stale copy that looks current; and a
// save refuses to overwrite a file that changed underneath, because that is the one
// failure here that cannot be undone.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreviewTextEditor: View {
    let url: URL

    @State private var text = ""
    /// What was on disk when the file was loaded, so an edit can tell whether it is
    /// saving over its own copy or over someone else's change.
    @State private var loadedText = ""
    @State private var status: String?
    @State private var watcher: DispatchSourceFileSystemObject?

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
        }
        .background(Color.black.opacity(0.18))
        .task(id: url) {
            load()
            startWatching()
        }
        .onDisappear { stopWatching() }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let status {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if text != loadedText {
                Text("edited")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if text != loadedText {
                Button("Save") { save() }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    /// Which files this view claims. Anything else belongs to a renderer that shows
    /// rather than edits.
    static func handles(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return url.pathExtension.isEmpty
        }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .propertyList) || type.conforms(to: .json)
    }

    // MARK: - Load, watch, save

    private func load() {
        status = nil
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // A very large file would make the editor unusable and is not what this panel is
        // for; it is shown truncated and marked so, rather than silently cut.
        if contents.count > 200_000 {
            text = String(contents.prefix(200_000))
            loadedText = text
            status = "showing first 200 KB — not editable"
        } else {
            text = contents
            loadedText = contents
        }
    }

    private func startWatching() {
        stopWatching()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            // An editor that writes atomically replaces the file rather than modifying it,
            // so the old descriptor now points at nothing: re-open on the new path.
            Task { @MainActor in
                guard text == loadedText else {
                    // Unsaved edits are not thrown away because something else touched the
                    // file. The save path already refuses to overwrite a changed file.
                    status = "changed on disk"
                    return
                }
                load()
                startWatching()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func save() {
        guard status == nil else { return }
        // Writing over someone else's edit — the assistant's, an editor's, a build
        // step's — silently is not recoverable from here.
        let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard onDisk == loadedText else {
            status = "changed on disk — reopen to merge"
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            loadedText = text
            status = "saved"
        } catch {
            status = "couldn't save"
        }
    }
}
