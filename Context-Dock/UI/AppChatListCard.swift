// AppChatListCard.swift
// Context-Dock
//
// What the frontmost app can do, as its own card above the input.
//
// It began inside the prompt pill, sharing one rounded container with the field. Separated
// because the two are different things: the field is where you write, and this is what the
// app offers — the same reason the clip being looked at gets its own card above the
// clipboard rather than growing it. The corner already reads as a stack of cards; this is
// one of them.
//
// Still one shell and one window: the Unified Dock Surface rule is about containers the app
// floats, not about a stack of surfaces inside the one it has.

import AppKit
import SwiftUI

enum AppChatListMetrics {
    static let width = AppChatPromptMetrics.width
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 30
    /// Room above and below the rows.
    static let verticalPadding: CGFloat = 10

    /// A pure function of how many rows there are — the corner draws this frame and
    /// hit-tests the same number, so a measured height would leave the two disagreeing.
    /// A command's output, when the board is carrying one. Enough to read a status without
    /// becoming a terminal — a real PTY flow is a different surface, and this is not it.
    static let outputHeight: CGFloat = 150

    static func size(rows: Int, output: Bool = false) -> CGSize {
        CGSize(
            width: width,
            height: headerHeight + CGFloat(rows) * rowHeight
                + (output ? outputHeight : 0) + verticalPadding * 2)
    }
}

/// A command's icon: the menu's own image when macOS gives one, otherwise the symbol the
/// dock resolves for that command, badged with the app it belongs to. `SFSymbolResolver` is
/// already a shared service, so this is the dock's choice of glyph rather than a second one.
private struct MenuRowIcon: View {
    let item: AXMenuItem
    let bundleID: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 26, height: 26)
                .overlay {
                    if let image = item.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 15, height: 15)
                    } else {
                        Image(systemName: symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }

            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var symbolName: String {
        SFSymbolResolver.menuSymbol(
            title: item.title, path: item.path, isAppleMenu: item.isAppleMenu)
    }

    private var appIcon: NSImage? {
        guard !bundleID.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// The commands matching what is typed, or — before anything is typed — what the app can do.
struct AppChatListCard: View {
    @ObservedObject var model: AppChatPromptModel

    private var size: CGSize {
        AppChatListMetrics.size(rows: model.listRowCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: AppChatListMetrics.headerHeight, alignment: .leading)

            // A command's result belongs with what asked for it, above the rows that offered
            // it — the same board, the way a turn shows its own reasoning. A second card is
            // for a terminal that needs one, and nothing here needs one yet.
            if model.isRunningCommand || model.cliOutput != nil {
                commandOutput
            }

            if model.rows.isEmpty, !model.returnsToGlobalScope {
                ForEach(model.suggestions.prefix(AppChatPromptModel.menuRowLimit)) { suggestion in
                    suggestionRow(suggestion)
                }
            } else {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    switch row {
                    case .command(let item):
                        commandRow(item, isFocused: index == model.focusedMenuIndex)
                    case .action(let action):
                        actionRow(action, isFocused: index == model.focusedMenuIndex)
                    case .global(let doc):
                        globalRow(doc, isFocused: index == model.focusedMenuIndex)
                    case .file(let url):
                        fileRow(url, isFocused: index == model.focusedMenuIndex)
                    case .cliSuggestion(let word):
                        cliSuggestionRow(word, isFocused: index == model.focusedMenuIndex)
                    }
                }
            }
        }
        .padding(.vertical, AppChatListMetrics.verticalPadding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        .onHover { _ in model.touch() }
    }

    /// Names what the list is: what the app can do at rest, what matched once typing starts.
    private var headerText: String {
        let app = model.appName.isEmpty ? "App" : model.appName
        let typed = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if typed { return "\(app) · \(model.rows.count) match\(model.rows.count == 1 ? "" : "es")" }
        return model.capabilitySummary.isEmpty ? "\(app) can" : model.capabilitySummary
    }

    /// What the field says before anything is typed, per scope.
    static func placeholder(for model: AppChatPromptModel) -> String {
        if model.isGlobalScope { return "Search apps, tools and menus…" }
        // Scoped into an app from Global, the field is a filter over that app — so it says
        // what the dock says there, rather than offering to chat.
        if model.returnsToGlobalScope {
            return AppScopeHint.placeholder(
                bundleId: model.appBundleID, appName: model.appName,
                hasActions: !model.adapterActions.isEmpty)
        }
        return "Ask \(model.appName.isEmpty ? "this app" : model.appName)"
    }

    /// A command the app really has: its name, the menu it lives under, and its shortcut —
    /// the three things that say this is the app's own command and not a paraphrase of one.
    private func commandRow(_ item: AXMenuItem, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            MenuRowIcon(item: item, bundleID: model.appBundleID)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                // Where the command actually lives, said the way the dock says it:
                // "Code > File". The trail is what tells the user this is the app's real
                // menu command and not a paraphrase of one.
                Text(trail(for: item))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let shortcut = item.shortcutDisplay {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isFocused ? 0.10 : 0))
                .padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onTapGesture { model.runMenuItem(item) }
    }

    /// "Code > File" — the app, then the menu the row sits in.
    private func trail(for item: AXMenuItem) -> String {
        let menu = item.path.dropLast().last ?? item.path.first ?? ""
        let app = model.appName
        if app.isEmpty { return menu }
        return menu.isEmpty ? app : "\(app) > \(menu)"
    }
    /// What the last command printed, with what it returned.
    private var commandOutput: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if model.isRunningCommand {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                } else if let output = model.cliOutput {
                    Image(
                        systemName: output.failed
                            ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(output.failed ? Color.orange : Color.green.opacity(0.8))
                }
                Text(model.cliOutput?.command ?? "\(model.cliCommand)…")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let output = model.cliOutput, output.exitCode != 0 {
                    // Said plainly: a tool can exit non-zero while printing something that
                    // reads like success, and the reverse.
                    Text("exit \(output.exitCode)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                if model.cliOutput != nil {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            model.cliOutput?.text ?? "", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy output")
                }
            }

            ScrollView {
                Text(model.isRunningCommand ? "Running…" : (model.cliOutput?.text ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: AppChatListMetrics.outputHeight - 22)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// A subcommand the scoped tool takes. Choosing it fills the field rather than running
    /// it, because most subcommands still want an argument.
    private func cliSuggestionRow(_ word: String, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(word)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(model.cliCommand) \(word)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isFocused ? 0.10 : 0))
                .padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onTapGesture { model.run(.cliSuggestion(word)) }
    }

    /// A file or folder from the Finder scope, with the path it lives at — two files called
    /// "Downloads" are told apart by where they are, not by their name.
    private func fileRow(_ url: URL, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(
                    url.deletingLastPathComponent().path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isFocused ? 0.10 : 0))
                .padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onTapGesture { model.run(.file(url)) }
    }

    /// A Global Context result: whatever the machine offers for this query, with its own
    /// icon where the index has one.
    private func globalRow(_ doc: GlobalSearchService.SearchDocument, isFocused: Bool)
        -> some View
    {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 26, height: 26)
                if let icon = doc.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: GlobalContextRow.symbol(for: doc))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(doc.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(GlobalContextRow.subtitle(for: doc))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isFocused ? 0.10 : 0))
                .padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onTapGesture { model.run(.global(doc)) }
    }

    /// The opening offer for an app with no adapter and nothing cached yet.
    private func suggestionRow(_ suggestion: AppChatSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(suggestion.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
    }

    /// An action the app's adapter declares: curated, so it says what it does rather than
    /// where it lives.
    private func actionRow(_ action: AdapterAction, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 26, height: 26)
                Image(systemName: action.icon.isEmpty ? "bolt.fill" : action.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(action.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(action.description.isEmpty ? model.appName : action.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isFocused ? 0.10 : 0))
                .padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onTapGesture { model.runAdapterAction(action) }
    }
}
