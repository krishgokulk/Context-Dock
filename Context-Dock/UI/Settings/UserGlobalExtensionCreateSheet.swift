// UserGlobalExtensionCreateSheet.swift
// Context-Dock
//
// Authoring UI for user-made Global Context extensions.
//
// A command runs once; an extension opens a panel and stays. The two scripts here
// mirror that: one prints the rows, one acts on whichever row the user picks.

import SwiftUI

struct UserGlobalExtensionCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (UserGlobalExtension) -> Void

    /// Pre-filled with a working example so the first run shows something real
    /// rather than an empty panel the user has to debug.
    @State private var name = "Recent Downloads"
    @State private var icon = "arrow.down.circle"
    @State private var description = "Latest files in ~/Downloads"
    @State private var keywords = "downloads, recent, files"
    @State private var rowsScriptType = "bash"
    @State private var rowsScript =
        "ls -t ~/Downloads | head -12 | while read f; do echo \"$f | ~/Downloads/$f\"; done"
    @State private var rowActionScriptType = "bash"
    @State private var rowActionScript = "open \"$HOME/Downloads/$(echo \"$CD_ROW\" | cut -d'|' -f1 | xargs)\""
    @State private var aiEnabled = false
    @State private var aiPrompt = ""

    private let scriptTypes = ["bash", "applescript", "jxa"]

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identitySection
                    rowsSection
                    actionSection
                    aiSection
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 680)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon.isEmpty ? "square.grid.2x2" : icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.teal)
                .frame(width: 38, height: 38)
                .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Global Extension")
                    .font(.system(size: 16, weight: .semibold))
                Text("Opens a floating panel — like Quick Note — instead of running once.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Name") {
                TextField("Recent Downloads", text: $name).textFieldStyle(.roundedBorder)
            }
            field("SF Symbol") {
                TextField("square.grid.2x2", text: $icon).textFieldStyle(.roundedBorder)
            }
            field("Description") {
                TextField("What this panel shows", text: $description)
                    .textFieldStyle(.roundedBorder)
            }
            field("Trigger Keywords") {
                TextField("comma-separated", text: $keywords).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var rowsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Rows Script").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $rowsScriptType) {
                    ForEach(scriptTypes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            Text("Prints one row per line. `Title | subtitle` splits into two lines.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            scriptEditor($rowsScript)
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Row Action").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $rowActionScriptType) {
                    ForEach(scriptTypes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            Text("Runs when a row is clicked. The row's text arrives as $CD_ROW. "
                 + "Also available: $CD_URL, $CD_TEXT, $CD_APP.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            scriptEditor($rowActionScript)
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Enable AI in this panel", isOn: $aiEnabled)
                .font(.system(size: 12, weight: .semibold))
            Text("Adds a chat composer to the panel. The Global Context Prompt from AI "
                 + "settings always applies; this adds instructions just for this panel.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if aiEnabled {
                scriptEditor($aiPrompt, minHeight: 70)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Button("Add Extension") {
                onCreate(UserGlobalExtension(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    icon: icon.isEmpty ? "square.grid.2x2" : icon,
                    description: description,
                    keywords: keywords
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty },
                    rowsScriptType: rowsScriptType,
                    rowsScript: rowsScript,
                    rowActionScriptType: rowActionScriptType,
                    rowActionScript: rowActionScript,
                    aiEnabled: aiEnabled,
                    aiPrompt: aiPrompt
                ))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
        }
        .padding(18)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func scriptEditor(_ text: Binding<String>, minHeight: CGFloat = 90) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11, design: .monospaced))
            .frame(minHeight: minHeight)
            .padding(6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}
