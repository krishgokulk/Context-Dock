// CornerSplitShell.swift
// Context-Dock
//
// The field and the apps as two pieces of glass (owner 2026-10-07, "Part B"): while the field
// is open — Global Context or an app's Context Dock — the search field stands on the left and
// the pinned and running apps, with the clipboard and the Drop Shelf, stand beside it on the
// right, one bottom line under whatever board is up.
//
//     ┌─────────────────────────────┐
//     │ results  ·  preview         │
//     ├──────────────────┬──────────┤
//     │ 🔍 field         │ apps · 📋 │
//     └──────────────────┴──────────┘
//
// The apps are as wide as what they hold; the field takes the rest, so the two and the gap
// between them are the shell's one width. The field's text stack is laid out at the field's
// width and changes it at once, never over frames: resizing the layer that holds the
// TextField per frame is what made SwiftUI rebuild the key-view loop and hang the app (see
// `globalBody`). Only the glass around it animates.

import AppKit
import SwiftUI

enum CornerSplitShell {
    /// Between the field and the apps, as between every card in the shell.
    static var gap: CGFloat { CornerDockLayout.gap }

    /// Whether the shell splits now: while the field is open (typed into or about to be) in
    /// Global or an app's scope, and only when the apps' piece has something to hold — an
    /// empty capsule beside the field is glass for nothing. A conversation keeps its own
    /// composer (`splitsChat`), General is its own surface.
    static func splits(
        isVisible: Bool, isGeneral: Bool, phase: AppChatPromptPhase, stripHasContent: Bool
    ) -> Bool {
        guard isVisible, !isGeneral, phase == .prompt || phase == .suggesting else { return false }
        return stripHasContent
    }

    /// The bottom line's two widths. The apps fit their icons and tools; the field takes what
    /// they and the gap leave. With nothing to show, the field is the whole shell.
    static func widths(shell: CGFloat, apps: Int, tools: Int) -> (field: CGFloat, strip: CGFloat) {
        guard apps + tools > 0 else { return (shell, 0) }
        let strip = stripWidth(shell: shell, apps: apps, tools: tools)
        return (shell - strip - gap, strip)
    }

    /// Fitted to the icons and tools, never under a capsule's worth, never over half the shell
    /// — past that the icons scroll.
    static func stripWidth(shell: CGFloat, apps: Int, tools: Int) -> CGFloat {
        let fitted = CornerSplitStrip.contentWidth(apps: apps, tools: tools)
        return min(max(fitted, minimumStripWidth), (shell / 2).rounded())
    }

    static let minimumStripWidth: CGFloat = 64

    /// In a conversation the composer is inset in the chat card, under the transcript and the
    /// app's panel (`CornerLivePanel`). The apps take the panel's column, inset by the
    /// composer's own 10-point margin so they line up with the panel above them.
    static let chatInset: CGFloat = 10

    static func chatStripWidth(card: CGFloat) -> CGFloat {
        CornerLivePanelLayout.panelWidth(card: card) - chatInset
    }

    /// Whether a conversation's composer splits: only with the app's panel open above, so the
    /// apps have a column to stand under, and only with apps to show (owner 2026-10-07:
    /// "show same for chat as well, if user pinned something").
    static func splitsChat(phase: AppChatPromptPhase, showsLivePanel: Bool, hasApps: Bool) -> Bool {
        phase == .chat && showsLivePanel && hasApps
    }
}

/// The right column's foot: pinned apps first, then whatever else is running, then the
/// clipboard and the Drop Shelf — the same apps, in the same order, as the resting strip.
struct CornerSplitStrip: View {
    @ObservedObject var model: AppChatPromptModel
    let width: CGFloat
    /// Inside the chat card, beside the composer: drawn the way the composer is — an inset
    /// rounded field — rather than as a glass capsule of its own floating in the shell.
    var inset: Bool = false
    @ObservedObject private var pins = DockPinStore.shared
    @ObservedObject private var clipboard = ClipboardPanelController.shared.model
    @ObservedObject private var shelf = DropShelfController.shared.presentation
    @ObservedObject private var shelfStore = DropShelfController.shared.store

    static let iconSize: CGFloat = 28
    static let spacing: CGFloat = 8
    static let toolSize: CGFloat = 26
    static let horizontalPadding: CGFloat = 14

    /// The width that holds `apps` icons and `tools` tools without scrolling: the padding,
    /// the icons and their gaps, the hairline between the two kinds, and the tools.
    static func contentWidth(apps: Int, tools: Int) -> CGFloat {
        let icons = CGFloat(max(apps, 0))
        let toolCount = CGFloat(max(tools, 0))
        var width = horizontalPadding * 2
        if apps > 0 { width += icons * iconSize + (icons - 1) * spacing + 4 }
        if tools > 0 { width += toolCount * toolSize + (toolCount - 1) * spacing }
        if apps > 0, tools > 0 { width += spacing + 1 + spacing }
        return width
    }

    /// Which tools close the strip, by the resting dock's own rules: the clipboard for a few
    /// seconds after a copy or while its board is open (`showsDockIcon`), the Drop Shelf only
    /// while it holds something or a drag is in flight (`DropShelfVisibility`).
    static func tools(for model: AppChatPromptModel) -> (clipboard: Bool, shelf: Bool) {
        (ClipboardPanelController.shared.model.showsDockIcon, model.showsShelf)
    }

    static func toolCount(for model: AppChatPromptModel) -> Int {
        let tools = tools(for: model)
        return (tools.clipboard ? 1 : 0) + (tools.shelf ? 1 : 0)
    }

    /// The resting strip's own composition, so an app is in the same place in both.
    private var apps: [DockAppSlot] { Self.apps(for: model) }

    static func apps(for model: AppChatPromptModel) -> [DockAppSlot] {
        DockStripPlan.make(
            running: model.stripIcons, pins: model.stripPins, tools: 0,
            fieldIcons: 0
        ).composition.apps
    }

    var body: some View {
        // Its own height as a capsule in the shell; the composer's, beside it in the chat card.
        let height: CGFloat? = inset ? nil : AppChatPromptMetrics.fieldHeight(global: true)
        let tools = Self.tools(for: model)
        HStack(spacing: Self.spacing) {
            if !apps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(apps) { slot in
                            appButton(slot)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                if tools.clipboard || tools.shelf {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: Self.iconSize * 0.8)
                }
            }
            if tools.clipboard {
                toolButton("doc.on.clipboard", title: "Clipboard", tinted: clipboard.isBoardOpen) {
                    ClipboardPanelController.shared.toggle()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            if tools.shelf {
                DropShelfIcon(presentation: shelf, store: shelfStore, style: .control)
                    .frame(width: Self.toolSize, height: Self.toolSize)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.smooth(duration: 0.2), value: tools.clipboard)
        .animation(.smooth(duration: 0.2), value: tools.shelf)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(width: width, height: height)
        .frame(maxHeight: inset ? .infinity : nil)
        .modifier(StripChrome(inset: inset))
    }

    private func appButton(_ slot: DockAppSlot) -> some View {
        Button {
            open(slot)
        } label: {
            VStack(spacing: 2) {
                Group {
                    if let image = slot.running?.icon ?? slot.pin?.kind.icon {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: Self.iconSize, height: Self.iconSize)
                .opacity((slot.pin.map { $0.kind.isAvailable } ?? true) ? 1 : 0.4)
                Circle()
                    .fill(Color.primary.opacity(slot.isRunning ? 0.55 : 0))
                    .frame(width: 3, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(slot.title)
        .accessibilityLabel(slot.title)
    }

    /// What a click on the resting strip's icon does, minus the hover previews: an app bar's
    /// pin or tab runs, a pinned app's pin runs, a running app scopes the field into it,
    /// anything else launches.
    private func open(_ slot: DockAppSlot) {
        // An app's bar (its pins and tabs) opens them the way the bar inside the field did.
        if model.showsTabBar, let icon = slot.running {
            model.openBarIcon(icon)
        } else if let pin = model.appPin(forIconID: slot.bundleID) {
            model.openAppPin(pin)
        } else if let icon = slot.running {
            model.openGlobalMatchIcon(icon)
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: slot.bundleID)
        {
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func toolButton(
        _ symbol: String, title: String, tinted: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tinted ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    tinted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                    in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The strip's container: a glass capsule of its own in the shell, or the composer's inset
/// rounded field inside the chat card.
private struct StripChrome: ViewModifier {
    let inset: Bool

    func body(content: Content) -> some View {
        if inset {
            content
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
        } else {
            content
                .clipShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
    }
}
