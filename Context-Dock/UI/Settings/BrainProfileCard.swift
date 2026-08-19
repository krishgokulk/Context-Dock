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
    @State private var profile = BrainProfile.empty
    @State private var loaded = false
    @State private var savedAt: Date?

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

    private func save() {
        if MarkdownMemoryStore.shared.saveProfile(profile) {
            savedAt = Date()
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
