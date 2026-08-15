// PreviewSurfaceView.swift
// Context-Dock
//
// The shell around the preview: our header, our glass, our assistant. The system
// Quick Look panel could not carry any of this — its chrome belongs to macOS — which
// is the whole reason this surface exists.
//
// Same shell whether the window is following the dock or pinned. Only the pin glyph
// and the close behaviour differ, so a pinned preview never looks like a second app.

import AppKit
import SwiftUI

/// Where the surface is living. Same shell either way — a preview embedded in the chat
/// window must not look like a different feature from the one Space opens — but a panel
/// inside another window has no traffic lights of its own to draw, and no assistant to
/// offer, because the window it sits in already is one.
enum PreviewHost {
    case window
    case embedded
}

struct PreviewSurfaceView: View {
    @ObservedObject var session: PreviewSession
    var host: PreviewHost = .window
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("previewPanelAIWidth") private var aiWidth = 320.0

    @State private var preZoomFrame: NSRect?
    /// Text pulled out of the previewed file for the assistant. Loaded only once the
    /// panel is actually open — OCR and MarkItDown are too expensive to run for every
    /// row a user arrows past.
    @State private var extractedText: String?
    @State private var isExtracting = false

    private let dividerWidth: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)

            GeometryReader { geo in
                let maxAI = max(240, geo.size.width - 320)
                let paneAI = min(max(aiWidth, 240), maxAI)

                HStack(spacing: 0) {
                    if let item = session.current {
                        PreviewRenderer(item: item)
                            .id(item.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Nothing to preview")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if session.showsAI, host == .window {
                        StickySplitDivider(width: $aiWidth, maximumWidth: maxAI,
                                           minimumWidth: 240)
                            .frame(width: dividerWidth)
                        ExtensionPanelAIComposer(
                            title: session.current?.title ?? "this file",
                            subtitle: session.current?.url.deletingLastPathComponent().path ?? "",
                            extraPrompt: aiContext
                        )
                        .frame(width: paneAI)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel is transparent so Liquid Glass can show the desktop; the material
        // has to come from the content, exactly as the sticky note and scoped panels do.
        .background(chrome)
        .onChange(of: session.index) { _, _ in
            session.window?.title = session.current?.title ?? "Preview"
        }
        .task(id: extractionKey) { await loadExtractedText() }
    }

    /// Re-extract when the file changes, or when the assistant is opened on a file that
    /// was never read because the pane was closed.
    private var extractionKey: String {
        "\(session.current?.id ?? "none")|\(session.showsAI)"
    }

    private func loadExtractedText() async {
        guard session.showsAI, let item = session.current else { return }
        isExtracting = true
        defer { isExtracting = false }
        extractedText = await PreviewTextExtractor.text(for: item)
    }

    /// A window draws its own glass; embedded, the surrounding window already did.
    @ViewBuilder
    private var chrome: some View {
        if host == .window {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.10 + 0.45 * settings.glassDarkness))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        } else {
            Color.clear
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if host == .window {
                // Close / minimise / zoom at the leading edge, where macOS puts them — the
                // panel hides the real traffic lights to keep the glass unbroken.
                circleButton("xmark", size: 9, help: "Close") { session.window?.close() }
                circleButton("minus", size: 9, help: "Minimise") {
                    session.window?.miniaturize(nil)
                }
                circleButton("arrow.up.left.and.arrow.down.right", size: 8, help: "Zoom") {
                    toggleZoom()
                }
            }

            if let item = session.current {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 15, height: 15)
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if session.items.count > 1 {
                stepper
            }

            Spacer(minLength: 8)

            if let item = session.current, item.url.isFileURL {
                openWithMenu(for: item)
                iconButton("square.and.arrow.up", help: "Share…") { share(item) }
            }

            if isExtracting {
                ProgressView()
                    .controlSize(.mini)
                    .help("Reading the file for the assistant…")
            }

            if host == .window {
                iconButton(
                    "sidebar.right",
                    help: session.showsAI ? "Hide assistant" : "Ask about this",
                    active: session.showsAI
                ) {
                    session.showsAI.toggle()
                }
            }

            iconButton(session.isPinned ? "pin.fill" : "pin",
                       help: session.isPinned
                           ? "Pinned — stays open while you work"
                           : "Pin — open this preview in its own window",
                       active: session.isPinned) {
                if host == .embedded {
                    // Nothing to detach from: an embedded panel belongs to the window
                    // around it, so pinning copies its content into a real window and
                    // leaves the chat's own panel where it was.
                    PreviewController.shared.presentDetached(
                        items: session.items, focus: session.index)
                } else {
                    PreviewController.shared.togglePin(session)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Walks the rest of what was on screen when the preview opened, so a peek at one
    /// file in a list doesn't strand the user on that file.
    private var stepper: some View {
        HStack(spacing: 4) {
            Button { session.step(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Text("\(session.index + 1)/\(session.items.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Button { session.step(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private func openWithMenu(for item: PreviewItem) -> some View {
        Menu {
            // Default app first — LSCopyApplicationURLsForURL is already sorted that way.
            ForEach(DefaultAppResolver.shared.getAllApps(for: item.url)) { app in
                Button {
                    NSWorkspace.shared.open([item.url], withApplicationAt: app.path,
                                            configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    // Label + .original, not a bare Image: a menu renders an icon only in
                    // the label slot, and without .original AppKit tints the app icon flat.
                    Label {
                        Text(app.name)
                    } icon: {
                        Image(nsImage: menuIcon(app.icon ?? NSWorkspace.shared.icon(forFile: app.path.path)))
                            .renderingMode(.original)
                    }
                }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            // Escape hatch: a few formats only render through a QL plugin the system
            // panel loads out of process and QLPreviewView here does not.
            Button("Open in System Quick Look") {
                PreviewController.shared.openInSystemQuickLook(item.url)
            }
        } label: {
            Text("Open With")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// App icons arrive at 32pt or larger and a menu does not resize them, so a raw
    /// icon makes every row in the list twice as tall as it should be.
    private func menuIcon(_ icon: NSImage) -> NSImage {
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }

    // MARK: - Pieces

    private func circleButton(_ symbol: String, size: CGFloat, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Color.primary.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Actions

    private func share(_ item: PreviewItem) {
        let picker = NSSharingServicePicker(items: [item.url])
        guard let view = session.window?.contentView else { return }
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    private func toggleZoom() {
        guard let window = session.window, let screen = window.screen ?? NSScreen.main else {
            return
        }
        let target = screen.visibleFrame
        if window.frame.equalTo(target) {
            window.setFrame(preZoomFrame ?? target.insetBy(dx: 120, dy: 80), display: true,
                            animate: true)
        } else {
            preZoomFrame = window.frame
            window.setFrame(target, display: true, animate: true)
        }
    }

    /// What the assistant can see. The panel shows the file, so the model is given the
    /// same thing: its details plus whatever text could be pulled out of it.
    private var aiContext: String {
        guard let item = session.current else { return "" }
        var prompt = """
        You are looking at one file the user is previewing in Context Dock.

        \(item.metadataForAI)
        """
        if let text = extractedText, !text.isEmpty {
            prompt += "\n\nContents:\n\(text)"
        } else {
            prompt += """


            You cannot read this file's contents — only the details above. Answer about \
            what you can see, and say plainly when something is not visible to you rather \
            than guessing at what is inside.
            """
        }
        prompt += """


        You cannot open, move, rename or delete anything — the panel does that. Say what \
        you would do and let the user act. Never invent details that are not shown here.
        """
        return prompt
    }
}
