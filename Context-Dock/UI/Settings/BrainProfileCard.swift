//
//  BrainProfileCard.swift
//  Context-Dock
//
//  The editor for who the user is.
//
//  Deliberately a form rather than a chat interview. An interview reads better in a demo,
//  but it produces whatever the model decided to write down, and the user cannot see the
//  file it wrote until it is wrong. These are five fields going into five headings, and
//  what is on screen is what ends up in profile.md — which matters because this text is
//  put in front of the model on every single turn.
//

import AppKit
import SwiftUI

struct BrainProfileCard: View {
    /// Lets the page rebuild its file list: profile.md is new the first time it is saved,
    /// and the list around it is read once on appear.
    var onSaved: () -> Void = {}

    @State private var profile = BrainProfile.empty
    @State private var loaded = false
    @State private var savedAt: Date?
    @State private var vaultPath = MarkdownMemoryStore.shared.folderURL.path
    @State private var vaultNote: String?

    var body: some View {
        CardSection(title: "Profile", systemImage: "person.text.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("What DoraX knows about you")
                            .font(.system(size: 13, weight: .medium))
                        Text("Included in every conversation, so you never have to explain yourself twice. Stored as profile.md next to your other memory files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if let savedAt {
                        Text("Saved \(Self.clock.string(from: savedAt))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                ForEach(Array(BrainProfile.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.heading)
                            .font(.system(size: 12, weight: .medium))
                        Text(field.prompt)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        TextEditor(text: binding(for: field.key))
                            .font(.system(size: 12))
                            .frame(height: 54)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05)))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Vault location")
                        .font(.system(size: 12, weight: .medium))
                    Text("Your memory is plain markdown. Keep it somewhere you can open, back up, or point Obsidian at.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(vaultPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Move…") { chooseVault() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if let vaultNote {
                        Text(vaultNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Button {
                        NSWorkspace.shared.open(MarkdownMemoryStore.shared.folderURL)
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button("Save Profile") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            // Load once. Re-reading on every appearance would throw away edits the user
            // made and had not saved yet.
            guard !loaded else { return }
            profile = MarkdownMemoryStore.shared.loadProfile()
            loaded = true
        }
    }

    private func binding(for key: WritableKeyPath<BrainProfile, String>) -> Binding<String> {
        Binding(
            get: { profile[keyPath: key] },
            set: { profile[keyPath: key] = $0 })
    }

    /// The panel picks a container, and DoraX makes its own folder inside it — choosing
    /// "Documents" should not scatter memory files across Documents.
    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Vault Here"
        panel.message = "Pick a folder to keep DoraX's memory in. A “DoraX Brain” folder is created inside it."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        let destination = chosen.lastPathComponent == "DoraX Brain"
            ? chosen
            : chosen.appendingPathComponent("DoraX Brain", isDirectory: true)
        vaultNote = MarkdownMemoryStore.shared.relocate(to: destination)
        vaultPath = MarkdownMemoryStore.shared.folderURL.path
        profile = MarkdownMemoryStore.shared.loadProfile()
        onSaved()
    }

    private func save() {
        if MarkdownMemoryStore.shared.saveProfile(profile) {
            savedAt = Date()
            onSaved()
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
