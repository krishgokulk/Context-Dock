// LivePanelFilePreviewView.swift
// Context-Dock
//
// The live panel's Quick Look preview, with the right-click menu that belongs to it.
//
// Extracted for #25 as a reachable leaf. The right-click position is written here — that is
// where the click happens — so it comes across as a binding rather than a value.
import SwiftUI

struct LivePanelFilePreviewView: View {
    let url: URL

    /// Where the pointer was when the menu was asked for. Written here, read by whoever
    /// positions the menu.
    @Binding var rightClickPosition: CGPoint?

    let contextMenuItems: (URL) -> [PillContextMenuAction]

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    InlineQLPreview(
                        url: url,
                        onRightClick: { pos in
                            withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                                rightClickPosition = pos
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let pos = rightClickPosition {
                        PillContextMenuPopup(
                            items: contextMenuItems(url),
                            position: pos,
                            containerSize: geo.size,
                            onDismiss: {
                                withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                                    rightClickPosition = nil
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.90)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom action bar
            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy path")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }
}
