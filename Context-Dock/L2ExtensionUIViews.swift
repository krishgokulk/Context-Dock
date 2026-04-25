// L2ExtensionUIViews.swift
// Context-Dock
//
// UI components for the L2 (AI tool) extension settings panel.

import SwiftUI

// MARK: - L2ExampleExtension

struct L2ExampleExtension: Identifiable {
    let id: UUID
    let displayName: String
    let description: String
    let icon: String
    let toolName: String

    static let all: [L2ExampleExtension] = [
        L2ExampleExtension(id: UUID(), displayName: "Compress Images",
                           description: "Batch compress PNG/JPEG files",
                           icon: "photo.stack", toolName: "compress_images"),
        L2ExampleExtension(id: UUID(), displayName: "Convert PDF",
                           description: "Convert documents to PDF format",
                           icon: "doc.richtext", toolName: "convert_pdf"),
        L2ExampleExtension(id: UUID(), displayName: "Resize Video",
                           description: "Resize and transcode video files",
                           icon: "film.stack", toolName: "resize_video"),
    ]
}

// MARK: - L2ExampleCard

struct L2ExampleCard: View {
    let example: L2ExampleExtension
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: example.icon)
                    .foregroundStyle(.purple)
                Spacer()
                Button("Install") { onInstall() }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.mini)
            }
            Text(example.displayName)
                .font(.caption).fontWeight(.semibold)
            Text(example.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 160)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.purple.opacity(0.2)))
    }
}

// MARK: - L2ExtensionCard

struct L2ExtensionCard: View {
    let ext: L2Extension
    @State private var showEditor = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ext.icon)
                .frame(width: 28, height: 28)
                .background(.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(ext.displayName).font(.subheadline)
                Text(ext.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !ext.isEnabled {
                Text("Disabled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                showEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .sheet(isPresented: $showEditor) {
            L2ExtensionEditorSheet(onSave: {})
        }
    }
}

// MARK: - L2ExtensionEditorSheet

struct L2ExtensionEditorSheet: View {
    var initialJSON: String?
    var initialScript: String?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var jsonText   = ""
    @State private var scriptText = ""

    init(initialJSON: String? = nil, initialScript: String? = nil, onSave: @escaping () -> Void) {
        self.initialJSON   = initialJSON
        self.initialScript = initialScript
        self.onSave        = onSave
        _jsonText   = State(initialValue: initialJSON   ?? "")
        _scriptText = State(initialValue: initialScript ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Tool Editor").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("Save") { onSave(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
            .padding()
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("extension.json").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    TextEditor(text: $jsonText)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Script").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    TextEditor(text: $scriptText)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .padding(8)
        }
        .frame(width: 700, height: 500)
    }
}
