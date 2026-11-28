// Context-Dock
//
// The Settings page behind "Plugin Creator". The Creator itself is a mode of the General
// Chat window (decision 67a1106d), so this page is a door to it, not a second editor: what
// it can do, one button that opens it, and the prompt for anyone who would rather write the
// plugin with another AI and paste the result in.

import AppKit
import SwiftUI

struct PluginCreatorDoor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Describe it, see it, save it.")
                        .font(.system(size: 15, weight: .semibold))
                    Text("""
                        A `.doraxpack` v3 plugin is one manifest plus scripts. Say what you \
                        want — “browse recent screenshots”, “monitor local dev servers” — and \
                        \(settings.selectedAIProvider.displayName) drafts the pack into \
                        the editor, drawn live in every place it will appear. Change the text \
                        or describe the change; Save installs it, and it is searchable by name.
                        """)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        GeneralChatWindowController.shared.showCreator()
                    } label: {
                        Label("Open Plugin Creator", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            PluginAuthoringPrompt.exportable(request: "<describe the plugin here>"),
                            forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy prompt for another AI",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("The same reference the Creator uses. Paste what the AI returns into the editor.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("What a plugin can be")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(Self.shapes, id: \.title) { shape in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: shape.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(shape.title).font(.system(size: 12, weight: .medium))
                                Text(shape.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private static let shapes: [(symbol: String, title: String, detail: String)] = [
        ("bolt", "An instant action", "Runs directly from Global Context — Lock Screen, Toggle Dark Mode."),
        ("menubar.dock.rectangle", "A Dynamic Notch wing",
         "Compact live activity in the Notch — timers, now playing, status."),
        ("app", "An app-scoped companion",
         "Automatically surfaces when its target app or website is frontmost."),
        ("rectangle.on.rectangle", "A 680 × 440 Result Sheet",
         "Lists, thumbnail grids, forms, and inline Actions — unified inside one shell."),
    ]
}
