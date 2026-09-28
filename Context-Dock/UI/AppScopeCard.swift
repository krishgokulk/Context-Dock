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
                if let reason = SensitivePageGuard.refusal(for: page.url)?.message {
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
    @ObservedObject private var computerUse = ComputerUseConsentStore.shared
    let appIcon: NSImage?
    let close: () -> Void

    @State private var expanded: Set<String> = []
    @State private var allowedCommands: [String] = []

    private var bundleID: String { model.appBundleID }

    private var inventory: ScopeInventory {
        ScopeInventory.app(bundleId: bundleID, appName: model.appName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    canDo
                    seesNow
                    allowed
                }
            }
            .frame(maxHeight: 420)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { allowedCommands = AppMenuConsentStore.shared.allowedCommands(bundleId: bundleID) }
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

    private var canDo: some View {
        section("Can do") {
            if model.adapterActions.isEmpty && inventory.groups.isEmpty {
                Text("Nothing for \(model.appName) yet — its menus are searchable from the field.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if !model.adapterActions.isEmpty {
                disclosure(
                    id: "actions", symbol: "bolt.fill", title: "Actions",
                    count: model.adapterActions.count
                ) {
                    ForEach(model.adapterActions) { action in
                        actionRow(action)
                    }
                }
            }
            // Everything else the Dock's panel lists, but actions (drawn above, runnable).
            ForEach(inventory.groups.filter { $0.title != "Actions" }) { group in
                disclosure(
                    id: group.title, symbol: group.symbol, title: group.title,
                    count: group.items.count
                ) {
                    ForEach(Array(group.items.prefix(12).enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(group.isMonospaced
                                ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 24)
                    }
                    if group.items.count > 12 {
                        Text("+\(group.items.count - 12) more")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .padding(.leading, 24)
                    }
                }
            }
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

    private var seesNow: some View {
        let lines = AppScopeContext.lines(
            isBrowser: ScopedAppPromptBuilder.isBrowserBundle(bundleID),
            page: ScopedAppPromptBuilder.isBrowserBundle(bundleID)
                ? BrowserPageReader.current(bundleId: bundleID) : nil,
            selection: model.selection, attachments: model.attachments)
        return section("Sees now") {
            if lines.isEmpty {
                Text("Only what you type.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: line.symbol).frame(width: 16)
                        .foregroundStyle(line.isRefused ? Color.orange : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.title).font(.system(size: 12)).lineLimit(1)
                        Text(line.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Allowed

    private var allowed: some View {
        section("Allowed") {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2").frame(width: 16).foregroundStyle(.secondary)
                Text("Computer Use").font(.system(size: 12))
                Spacer(minLength: 0)
                Menu {
                    ForEach(ComputerUseMode.allCases, id: \.self) { mode in
                        Button {
                            computerUse.setMode(mode, for: bundleID)
                        } label: {
                            if computerUse.mode(for: bundleID) == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Text(computerUse.mode(for: bundleID).title).font(.system(size: 11.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .help(computerUse.isMasterEnabled
                ? computerUse.mode(for: bundleID).explanation
                : "Computer Use is off for every app in Settings")
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield").frame(width: 16).foregroundStyle(.secondary)
                Text(allowedCommands.isEmpty
                    ? "No commands run without asking"
                    : "\(allowedCommands.count) command\(allowedCommands.count == 1 ? "" : "s") run without asking")
                    .font(.system(size: 12))
                    .help(allowedCommands.joined(separator: "\n"))
                Spacer(minLength: 0)
                if !allowedCommands.isEmpty {
                    Button("Forget") {
                        AppMenuConsentStore.shared.forget(bundleId: bundleID)
                        allowedCommands = []
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
                }
            }
            HStack(spacing: 8) {
                AIProviderIcon(provider: AppSettings.shared.selectedAIProvider, size: 14)
                    .frame(width: 16)
                Text(AppSettings.shared.selectedAIProvider.displayName).font(.system(size: 12))
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Pieces

    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func disclosure<Content: View>(
        id: String, symbol: String, title: String, count: Int,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let open = expanded.contains(id)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if open { expanded.remove(id) } else { expanded.insert(id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 12))
                    Spacer(minLength: 0)
                    Text("\(count)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content() }
        }
    }
}
