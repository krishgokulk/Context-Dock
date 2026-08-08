// GeneralChatWindowChrome.swift
// Context-Dock
//
// Titlebar row for the standalone General Chat window, laid out like the Codex
// desktop window: the bar is split by the same vertical line that divides the
// sidebar from the content, so the window reads as one straight edge from
// titlebar to bottom. Sidebar side carries the traffic lights, the sidebar
// toggle and the history arrows; content side carries a Chat/Work pill centred
// on the content column, then temporary-chat, bottom-panel and side-panel toggles.
//
// The window uses `.fullSizeContentView`, so these rows are drawn by SwiftUI
// rather than by an NSToolbar — an NSToolbar would paint its own opaque strip
// across both columns and break the split.

import AppKit
import Combine
import SwiftUI

enum GeneralChatWindowMode: String, CaseIterable, Identifiable {
    case chat
    case work

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .work: return "Work"
        }
    }
}

@MainActor
final class GeneralChatWindowChromeState: ObservableObject {
    static let shared = GeneralChatWindowChromeState()

    @Published var mode: GeneralChatWindowMode = .chat
    @Published var sidebarVisible: Bool = true
    @Published var bottomPanelVisible: Bool = false
    @Published var sidePanelVisible: Bool = false
    /// Temporary chat: nothing from this conversation is written to history.
    @Published var temporaryChat: Bool = false

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.18)) { sidebarVisible.toggle() }
    }

    /// Opens the console without toggling it shut when it is already open — used when a
    /// route produces output the user should see.
    func showBottomPanel() {
        guard !bottomPanelVisible else { return }
        withAnimation(.easeOut(duration: 0.18)) { bottomPanelVisible = true }
    }

    func toggleBottomPanel() {
        withAnimation(.easeOut(duration: 0.18)) { bottomPanelVisible.toggle() }
    }

    /// Reveals the side panel without closing it when already open — used when a tool
    /// starts drawing into the thread's terminal.
    func showSidePanel() {
        guard !sidePanelVisible else { return }
        withAnimation(.easeOut(duration: 0.18)) { sidePanelVisible = true }
    }

    func toggleSidePanel() {
        withAnimation(.easeOut(duration: 0.18)) { sidePanelVisible.toggle() }
    }
}

enum GeneralChatChromeMetrics {
    /// Titlebar height, shared by both columns so the split line stays straight.
    static let barHeight: CGFloat = 52
    /// Runway for the traffic lights, which AppKit still draws.
    static let trafficLightInset: CGFloat = 78
}

// MARK: - Sidebar-side bar

/// The half of the titlebar above the sidebar: traffic lights, sidebar toggle,
/// history arrows. Draws no background of its own — the sidebar's material runs
/// behind it, unbroken from titlebar to the bottom of the window.
struct GeneralChatSidebarBar: View {
    @ObservedObject var chrome: GeneralChatWindowChromeState

    var body: some View {
        ZStack {
            WindowDragSurface()
            HStack(spacing: 2) {
                GeneralChatChromeControls.navigationCluster(chrome: chrome)
                Spacer(minLength: 0)
            }
            .padding(.leading, GeneralChatChromeMetrics.trafficLightInset)
            .padding(.trailing, 8)
        }
        .frame(height: GeneralChatChromeMetrics.barHeight)
    }
}

// MARK: - Content-side bar

struct GeneralChatContentBar: View {
    @ObservedObject var chrome: GeneralChatWindowChromeState
    /// True when the sidebar is hidden — the nav cluster and the traffic-light
    /// runway move over here, since there is no sidebar column to hold them.
    let carriesWindowControls: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            WindowDragSurface()

            HStack(spacing: 2) {
                if carriesWindowControls {
                    GeneralChatChromeControls.navigationCluster(chrome: chrome)
                }
                Spacer(minLength: 12)
                trailingCluster
            }
            .padding(
                .leading,
                carriesWindowControls ? GeneralChatChromeMetrics.trafficLightInset : 12
            )
            .padding(.trailing, 12)

            // Centred on the content column, not the whole window — that is where
            // Codex puts it while the sidebar is open.
            modePill
        }
        .frame(height: GeneralChatChromeMetrics.barHeight)
    }

    private var trailingCluster: some View {
        HStack(spacing: 2) {
            temporaryChatButton
            GeneralChatChromeControls.button(
                systemName: "rectangle.bottomthird.inset.filled",
                help: chrome.bottomPanelVisible ? "Hide Bottom Panel" : "Show Bottom Panel",
                isOn: chrome.bottomPanelVisible
            ) {
                chrome.toggleBottomPanel()
            }
            GeneralChatChromeControls.button(
                systemName: "sidebar.right",
                help: chrome.sidePanelVisible ? "Hide Side Panel" : "Show Side Panel",
                isOn: chrome.sidePanelVisible
            ) {
                chrome.toggleSidePanel()
            }
        }
    }

    /// Dashed ring — the Codex/ChatGPT mark for "this chat is not saved".
    private var temporaryChatButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { chrome.temporaryChat.toggle() }
        } label: {
            Circle()
                .strokeBorder(
                    chrome.temporaryChat ? Color.accentColor : Color.secondary,
                    style: StrokeStyle(lineWidth: 1.4, dash: [3.2, 2.6])
                )
                .frame(width: 15, height: 15)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(chrome.temporaryChat ? Theme.surfaceElevated(dark) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chrome.temporaryChat ? "Temporary chat is on" : "Temporary chat")
    }

    private var modePill: some View {
        HStack(spacing: 2) {
            ForEach(GeneralChatWindowMode.allCases) { mode in
                let selected = chrome.mode == mode
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { chrome.mode = mode }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(width: 74, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(selected ? Theme.surfaceElevated(dark) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface(dark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border(dark), lineWidth: 0.5)
        )
    }
}

// MARK: - Shared controls

enum GeneralChatChromeControls {
    @MainActor
    static func navigationCluster(chrome: GeneralChatWindowChromeState) -> some View {
        HStack(spacing: 2) {
            button(
                systemName: "sidebar.left",
                help: chrome.sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                isOn: chrome.sidebarVisible
            ) {
                chrome.toggleSidebar()
            }
            button(systemName: "chevron.left", help: "Back", enabled: false) {}
            button(systemName: "chevron.right", help: "Forward", enabled: false) {}
        }
    }

    static func button(
        systemName: String,
        help: String,
        isOn: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        ChromeButton(
            systemName: systemName, help: help, isOn: isOn, enabled: enabled, action: action)
    }

    private struct ChromeButton: View {
        let systemName: String
        let help: String
        let isOn: Bool
        let enabled: Bool
        let action: () -> Void
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let dark = colorScheme == .dark
            return Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        enabled
                            ? (isOn ? Color.primary : Color.secondary)
                            : Color.secondary.opacity(0.45)
                    )
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isOn ? Theme.surfaceElevated(dark) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(help)
        }
    }
}

// MARK: - Window dragging

/// `.fullSizeContentView` moves the content under the titlebar, so the strip below
/// the real titlebar height is not draggable by default. This view restores it
/// without `isMovableByWindowBackground`, which would also make text selection in
/// the transcript drag the window.
struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Sidebar material

/// Behind-window blur for the sidebar column, so the wallpaper shows through it
/// while the content column stays opaque — the two-tone split Codex uses.
struct GeneralChatSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
    }
}
