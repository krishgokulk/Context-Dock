// LivePanelResultsView.swift
// Context-Dock
//
// The live panel's result list, and its empty state.
//
// Extracted for #25 as a reachable leaf. It was already self-contained — it draws the entries
// it is handed and nothing else — so it needed no launcher state at all, which is the whole
// interface: a list of entries.
import SwiftUI

struct LivePanelResultsView: View {
    let items: [LauncherView.LivePanelMode.ResultEntry]

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(.secondary.opacity(0.4))
                Text("Ask the AI to show results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("e.g. \"list all PDFs here\" or \"find large files\"")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            if !item.path.isEmpty {
                                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if !item.path.isEmpty {
                                    Menu {
                                        Button("Open") {
                                            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                                        }
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([
                                                URL(fileURLWithPath: item.path)
                                            ])
                                        }
                                        Button("Copy Path") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(
                                                item.path, forType: .string)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .padding(4)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .frame(width: 20)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.0))
                        Divider().padding(.leading, 42).opacity(0.4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
