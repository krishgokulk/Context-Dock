// CornerSplitShell.swift
// Context-Dock
//
// The shell in two columns while the result board shows a preview (owner 2026-10-07, "Part B"):
// the results on the left with the search field directly under them, the preview on the right
// with the pinned and running apps directly under it — one bottom line, field and apps side by
// side, the way the board above is list and preview side by side.
//
//     ┌──────────────┬──────────────┐
//     │ results      │ preview      │
//     ├──────────────┼──────────────┤
//     │ 🔍 field     │ apps · tools │
//     └──────────────┴──────────────┘
//
// The field's own layout does not move. Its text stack stays laid out at the shell's full
// width; only the glass frame around it narrows to the left column, the same way the
// dock → field morph reveals it. Resizing the layer that holds the TextField is what made
// SwiftUI rebuild the key-view loop every frame and hang the app (see `globalBody`), so this
// changes the frame and nothing inside it.

import AppKit
import SwiftUI

enum CornerSplitShell {
    /// Between the field and the apps, as between every card in the shell.
    static var gap: CGFloat { CornerDockLayout.gap }

    /// Whether the shell splits now. Only while the field is being typed into over a board
    /// that has a right-hand column — the clipboard's, or the results' when a row's preview
    /// is up. A conversation keeps its composer whole, General is its own surface, and with
    /// no preview there is no column for the apps to sit under.
    ///
    /// Global Context's field always stands apart from its apps while it is open (owner
    /// 2026-10-07: "the search bar separation effect while our dock"): the dock opens into the
    /// field and the apps beside it, rather than the apps shrinking into a pill inside it.
    static func splits(
        isVisible: Bool, isGeneral: Bool, phase: AppChatPromptPhase, isGlobalScope: Bool = false,
        clipboardBoard: Bool, resultList: Bool, hasPreview: Bool
    ) -> Bool {
        guard isVisible, !isGeneral, phase == .prompt || phase == .suggesting else { return false }
        return isGlobalScope || clipboardBoard || (resultList && hasPreview)
    }

    /// The bottom line's two widths. Global's apps are as wide as what they hold, so its field
    /// keeps one width whatever the board above shows — the field's text stack is laid out at
    /// that width from the start (`globalInputWidth`), and nothing inside it resizes. An app's
    /// field splits at the board's list column.
    static func widths(shell: CGFloat, isGlobalScope: Bool, apps: Int)
        -> (field: CGFloat, strip: CGFloat)
    {
        if isGlobalScope {
            let strip = restStripWidth(shell: shell, apps: apps)
            return (shell - strip - gap, strip)
        }
        return (fieldWidth(shell: shell), stripWidth(shell: shell))
    }

    /// Global's apps: fitted to their icons and the two tools, never under a minimum that
    /// keeps the tools readable, never over half the shell — past that the icons scroll.
    static func restStripWidth(shell: CGFloat, apps: Int) -> CGFloat {
        let fitted = CornerSplitStrip.contentWidth(apps: apps)
        return min(max(fitted, 160), (shell / 2).rounded())
    }

    /// The field's width: the board's list column, less half the gap so the two bottom
    /// pieces meet the board's divider with the shell's usual spacing.
    static func fieldWidth(shell: CGFloat) -> CGFloat {
        let list = CornerBoardLayout.listWidth(board: shell, preview: .file(URL(fileURLWithPath: "/")))
        return (list - gap / 2).rounded()
    }

    /// The apps' width: what the field and the gap leave.
    static func stripWidth(shell: CGFloat) -> CGFloat {
        shell - fieldWidth(shell: shell) - gap
    }

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

    private static let iconSize: CGFloat = 28
    private static let spacing: CGFloat = 8
    private static let toolSize: CGFloat = 26
    private static let horizontalPadding: CGFloat = 14

    /// The width that holds `apps` icons and the tools without scrolling: the padding, the
    /// icons and their gaps, the hairline, the clipboard and the shelf.
    static func contentWidth(apps: Int) -> CGFloat {
        let icons = CGFloat(max(apps, 0))
        let appsWidth = icons * iconSize + max(icons - 1, 0) * spacing + 4
        let tools = spacing + 1 + spacing + toolSize + spacing + toolSize
        return horizontalPadding * 2 + appsWidth + tools
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
        HStack(spacing: Self.spacing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.spacing) {
                    ForEach(apps) { slot in
                        appButton(slot)
                    }
                }
                .padding(.horizontal, 2)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: Self.iconSize * 0.8)
            toolButton("doc.on.clipboard", title: "Clipboard", tinted: clipboard.isBoardOpen) {
                ClipboardPanelController.shared.toggle()
            }
            DropShelfIcon(presentation: shelf, store: shelfStore, style: .control)
                .frame(width: Self.toolSize, height: Self.toolSize)
        }
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

    /// What a click on the resting strip's icon does, minus the hover previews: a pinned
    /// app's pin runs, a running app scopes the field into it, anything else launches.
    private func open(_ slot: DockAppSlot) {
        if let pin = model.appPin(forIconID: slot.bundleID) {
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
