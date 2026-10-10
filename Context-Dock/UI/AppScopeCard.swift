// AppScopeCard.swift
// Context-Dock
//
// The app's settings card: what DoraX can do in the app in front, what the next question
// will carry from it, and what it is allowed to do there. Opened from the app chip in the
// Corner's field (owner 2026-09-28: layout C, a narrow card anchored to the chip, in the
// glass-menu style of the iOS references).
//
// Nothing here is a second inventory. "Can do" is `ScopeInventory.app`, the list the Dock's
// app panel shows; "Allowed" reads the same stores Settings writes.

import AppKit
import SwiftUI

// MARK: - In the board

enum AppScopeBoardMetrics {
    static let height: CGFloat = 360

    /// A compact card over the right half of the shell — the result sheet's own right half,
    /// where it stands beside the list when there is one (owner 2026-10-08: "expand only on
    /// the right side"). Pure: the corner draws this frame and hit-tests the same number.
    static func size(shell: CGFloat) -> CGSize {
        CGSize(width: CornerBoardLayout.panelWidth(board: shell), height: height)
    }

    /// Where the card's centre sits from the field's leading edge: its trailing edge on the
    /// shell's, over the right half.
    static func anchorOffset(shell: CGFloat) -> CGFloat {
        shell - size(shell: shell).width / 2
    }
}

/// The app's card in the result board over the field, in the board's own glass — where the
/// chip opens it (owner 2026-10-07), rather than as a popover hanging off the chip.
struct AppScopeBoard: View {
    @ObservedObject var model: AppChatPromptModel

    private var size: CGSize {
        AppScopeBoardMetrics.size(shell: AppChatPromptMetrics.boardWidth(for: model))
    }

    private var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: model.appBundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        AppScopeCard(
            model: model, appIcon: appIcon, close: { model.isShowingScopeCard = false },
            width: size.width, maxScrollHeight: size.height - 70)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.clear)
                    .background(GlassBackground(cornerRadius: 22, isDark: true))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
            }
            .onHover { _ in model.touch() }
    }
}

// MARK: - Sees now (pure)

/// One line of what the next turn will carry from the app.
struct AppScopeContextLine: Identifiable, Equatable {
    var id: String { symbol + title }
    let symbol: String
    let title: String
    let detail: String
    /// DoraX will not read this (a bank page, a password page): shown, and why.
    var isRefused = false
}

enum AppScopeContext {
    /// What the next question in this app would carry: the open page (or why it will not be
    /// read), the selection, the attached files. Empty means it carries only the question.
    static func lines(
        isBrowser: Bool, page: BrowserPageSnapshot?, selection: AppChatSelectionScope?,
        attachments: [URL]
    ) -> [AppScopeContextLine] {
        var lines: [AppScopeContextLine] = []
        if isBrowser {
            if let page {
                let title = page.title.isEmpty ? (URL(string: page.url)?.host ?? "This page") : page.title
                if let reason = page.refusal?.message {
                    lines.append(AppScopeContextLine(
                        symbol: "lock.fill", title: title, detail: reason, isRefused: true))
                } else {
                    lines.append(AppScopeContextLine(
                        symbol: "doc.richtext", title: title,
                        detail: "This page, when a question is about it"))
                }
            } else {
                lines.append(AppScopeContextLine(
                    symbol: "doc.richtext", title: "No readable page",
                    detail: "Turn on the Context Dock Safari extension to read pages"))
            }
        }
        if let selection {
            let detail: String
            switch selection.kind {
            case .text(let characters): detail = "\(characters) characters of selected text"
            case .files(let count): detail = count == 1 ? "1 selected file" : "\(count) selected files"
            }
            lines.append(AppScopeContextLine(symbol: selection.icon, title: "Selection", detail: detail))
        }
        if !attachments.isEmpty {
            let names = attachments.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
            let more = attachments.count > 2 ? " +\(attachments.count - 2)" : ""
            lines.append(AppScopeContextLine(
                symbol: "paperclip", title: "Attached", detail: names + more))
        }
        return lines
    }
}

// MARK: - The card

struct AppScopeCard: View {
    @ObservedObject var model: AppChatPromptModel
    let appIcon: NSImage?
    let close: () -> Void
    /// The card's width: the board's, now that it opens in the result board.
    var width: CGFloat = 300
    var maxScrollHeight: CGFloat = 420

    @State private var expanded: Set<String> = []

    private var bundleID: String { model.appBundleID }

    private var inventory: ScopeInventory {
        ScopeInventory.app(bundleId: bundleID, appName: model.appName)
    }

    var body: some View {
        let inventory = inventory
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    canDo(inventory)
                    if !inventory.knowsGroups.isEmpty {
                        AppScopeSection("Knows") {
                            AppScopeInventoryGroups(groups: inventory.knowsGroups, expanded: $expanded)
                        }
                    }
                    AppScopeSection("Sees now") { AppScopeSeesNowList(lines: seesNowLines) }
                    AppScopeSection("Allowed") { AppScopeAllowedList(bundleID: bundleID) }
                }
            }
            .frame(maxHeight: maxScrollHeight)
        }
        .padding(14)
        .frame(width: width)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let appIcon {
                Image(nsImage: appIcon).resizable().frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.appName).font(.system(size: 13, weight: .semibold))
                Text("What DoraX can do here").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Can do

    private func canDo(_ inventory: ScopeInventory) -> some View {
        AppScopeSection("Can do") {
            if model.adapterActions.isEmpty && inventory.canDoGroups.isEmpty {
                Text("Nothing for \(model.appName) yet — its menus are searchable from the field.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if !model.adapterActions.isEmpty {
                AppScopeDisclosure(
                    id: "actions", symbol: "bolt.fill", title: "Actions",
                    count: model.adapterActions.count, expanded: $expanded
                ) {
                    ForEach(model.adapterActions) { action in
                        actionRow(action)
                    }
                }
            }
            // Everything else the Dock's panel lists, but actions (drawn above, runnable).
            AppScopeInventoryGroups(
                groups: inventory.canDoGroups.filter { $0.title != "Actions" }, expanded: $expanded)
        }
    }

    private func actionRow(_ action: AdapterAction) -> some View {
        let row = AppChatRow.action(action)
        let pinned = model.isPinnedToApp(row)
        return HStack(spacing: 8) {
            Button {
                close()
                model.runAdapterAction(action)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: action.icon).frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(action.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(action.description)
            Button { model.toggleAppPin(row) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(pinned ? "Unpin from \(model.appName)" : "Pin to \(model.appName)")
        }
        .font(.system(size: 12))
        .padding(.leading, 24)
        .padding(.vertical, 2)
    }

    // MARK: Sees now

    private var seesNowLines: [AppScopeContextLine] {
        let isBrowser = ScopedAppPromptBuilder.isBrowserBundle(bundleID)
        return AppScopeContext.lines(
            isBrowser: isBrowser,
            page: isBrowser ? BrowserPageReader.current(bundleId: bundleID) : nil,
            selection: model.selection, attachments: model.attachments)
    }
}
