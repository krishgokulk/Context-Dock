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
    static func splits(
        isVisible: Bool, isGeneral: Bool, phase: AppChatPromptPhase,
        clipboardBoard: Bool, resultList: Bool, hasPreview: Bool
    ) -> Bool {
        guard isVisible, !isGeneral, phase == .prompt || phase == .suggesting else { return false }
        return clipboardBoard || (resultList && hasPreview)
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
}

/// The right column's foot: pinned apps first, then whatever else is running, then the
/// clipboard and the Drop Shelf — the same apps, in the same order, as the resting strip.
struct CornerSplitStrip: View {
    @ObservedObject var model: AppChatPromptModel
    let width: CGFloat
    @ObservedObject private var pins = DockPinStore.shared
    @ObservedObject private var clipboard = ClipboardPanelController.shared.model
    @ObservedObject private var shelf = DropShelfController.shared.presentation
    @ObservedObject private var shelfStore = DropShelfController.shared.store

    private static let iconSize: CGFloat = 28

    /// The resting strip's own composition, so an app is in the same place in both.
    private var apps: [DockAppSlot] {
        DockStripPlan.make(
            running: model.stripIcons, pins: model.stripPins, tools: 0,
            fieldIcons: 0
        ).composition.apps
    }

    var body: some View {
        let height = AppChatPromptMetrics.fieldHeight(global: true)
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
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
