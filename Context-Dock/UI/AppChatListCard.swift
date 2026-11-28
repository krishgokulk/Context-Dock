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
    /// The board stands exactly as wide as the field below it: the shell's one width (#189).
    static var width: CGFloat { DockShellWidth.current }
    static let rowHeight: CGFloat = 52
    static let iconSize: CGFloat = 36
    static let headerHeight: CGFloat = 22
    /// Room above and below the rows.
    static let verticalPadding: CGFloat = 6

    /// A pure function of how many rows there are — the corner draws this frame and
    /// hit-tests the same number, so a measured height would leave the two disagreeing.
    /// A command's output, when the board is carrying one. Enough to read a status without
    /// becoming a terminal — a real PTY flow is a different surface, and this is not it.
    static let outputHeight: CGFloat = 150

    /// The board's foot: what Return does, ⌘P and ⌘, (owner 2026-10-07), as the clipboard's
    /// board ends.
    static var footerHeight: CGFloat { BoardFooter.height }

    /// `header`: the count line above the rows. Global's sections draw their headers as
    /// slots in the list instead (#258), so every slot is a row tall and none shows cut.
    static func size(
        rows: Int, output: Bool = false, width: CGFloat = width, header: Bool = true
    ) -> CGSize {
        CGSize(
            width: width,
            height: (header ? headerHeight : 0) + CGFloat(rows) * rowHeight
                + (output ? outputHeight : 0) + verticalPadding * 2 + footerHeight)
    }
}

/// Apple Spotlight / Siri-style dark glass squircle badge for commands, menus, and actions,
/// optionally carrying a small owning-app icon badge at the bottom-trailing corner.
struct SpotlightCommandBadgeIcon: View {
    let symbol: String
    var customImage: NSImage? = nil
    var appBadgeImage: NSImage? = nil
    var tint: Color? = nil
    var size: CGFloat = 32

    private var cornerRadius: CGFloat { max(7, size * 0.25) }
    private var resolvedSymbol: String {
        SFSymbolResolver.validSymbol(symbol, fallback: "menubar.rectangle")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            (tint ?? Color.primary).opacity(tint != nil ? 0.22 : 0.12),
                            (tint ?? Color.primary).opacity(tint != nil ? 0.10 : 0.05),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            (tint ?? Color.white).opacity(tint != nil ? 0.28 : 0.16),
                            lineWidth: 0.75
                        )
                )
                .overlay {
                    if let customImage {
                        Image(nsImage: customImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size * 0.54, height: size * 0.54)
                    } else {
                        Image(systemName: resolvedSymbol)
                            .font(.system(size: size * 0.45, weight: .medium))
                            .foregroundStyle(tint ?? .primary.opacity(0.92))
                    }
                }

            if let appBadgeImage {
                let badgeSize = max(12, size * 0.41)
                Image(nsImage: appBadgeImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: badgeSize, height: badgeSize)
                    .clipShape(RoundedRectangle(cornerRadius: badgeSize * 0.27, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: badgeSize * 0.27, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.65), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A command's icon: the menu's own image when macOS gives one, otherwise the symbol the
/// dock resolves for that command, badged with the app it belongs to. `SFSymbolResolver` is
/// already a shared service, so this is the dock's choice of glyph rather than a second one.
private struct MenuRowIcon: View {
    let item: AXMenuItem
    let bundleID: String

    var body: some View {
        SpotlightCommandBadgeIcon(
            symbol: symbolName,
            customImage: item.image,
            appBadgeImage: appIcon,
            size: 30
        )
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
    @ObservedObject private var selectionModel = CornerDockController.shared.selection
    @Environment(\.sharesOneCard) private var sharesOneCard
    /// The item at the top of the list as it scrolls, and when the arrows last moved the
    /// highlight — so a hand scroll can keep the highlight in view without fighting the keys.
    @State private var topItemID: String?
    @State private var lastKeyMove = Date.distantPast
    @State private var mouseGate = MouseGate()
    @Namespace private var selectionSpace

    /// The board: the list, and the highlighted row's preview beside it in the same card
    /// (#191) — the same number the window reserves.
    private var size: CGSize { model.boardSize }

    private var effectiveFocus: Int? {
        model.skipsTopRowOnBareReturn
            ? model.focusedMenuIndex : (model.focusedMenuIndex ?? 0)
    }

    /// The right half: the app's card when the chip opened it (owner 2026-10-08: "in the
    /// right half of the result sheet"), the highlighted row's preview otherwise.
    @ViewBuilder
    private func previewPanel(_ preview: CornerBoardPreview) -> some View {
        if let card = preview.appCard {
            let panelHeight = size.height - 2 * AppChatListMetrics.verticalPadding
                - AppChatListMetrics.footerHeight
            // The field's app (its chip), or an app row's own app (Global, "/").
            AppScopeCard(
                model: model,
                appIcon: NSWorkspace.shared.urlForApplication(withBundleIdentifier: card.bundleID)
                    .map { NSWorkspace.shared.icon(forFile: $0.path) },
                close: { model.isShowingScopeCard = false },
                width: CornerBoardLayout.panelWidth(board: size.width) - 10,
                maxScrollHeight: max(panelHeight - 70, 120),
                subject: card.isOwnScope ? nil : (card.bundleID, card.name))
                .boardPanelCard()
        } else if case .file(let url) = preview, !AppChatPromptModel.isFolder(url),
            selectionModel.isEmbeddedInSidePanel, selectionModel.phase.isVisible
        {
            SelectionScopeCard(model: selectionModel, embeddedInPanel: true)
                .onChange(of: url) { _, newURL in
                    if !AppChatPromptModel.isFolder(newURL),
                        selectionModel.files.first?.standardizedFileURL.path != newURL.standardizedFileURL.path
                    {
                        _ = CornerDockController.shared.showSelection(forFile: newURL)
                    }
                }
        } else {
            CornerBoardPreviewPanel(preview: preview)
        }
    }

    var body: some View {
        let preview = model.boardPreview
        // Global's sections (#258 G1): the first one's header stands where the count did.
        let sectionHeaders = model.globalSectionHeaders
        // One card, two columns, as Raycast and Claude lay a list beside its detail (#191):
        // the list on the left, what the highlighted row is on the right — and one foot
        // under both.
        VStack(spacing: 0) {
        if let submode = model.fileSubmode {
            FileSheetSubmodeView(
                model: model,
                selectionModel: selectionModel,
                submode: submode,
                height: size.height - AppChatListMetrics.footerHeight
            )
            .frame(
                width: size.width,
                height: size.height - AppChatListMetrics.footerHeight,
                alignment: .topLeading
            )
            fileSubmodeFooter(submode)
        } else {
        HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
            if sectionHeaders.isEmpty, !headerText.isEmpty {
                Text(headerText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(height: AppChatListMetrics.headerHeight, alignment: .leading)
            }

            // A command's result belongs with what asked for it, above the rows that offered
            // it — the same board, the way a turn shows its own reasoning. A second card is
            // for a terminal that needs one, and nothing here needs one yet.

            if model.isFinderFileSearch, model.rows.isEmpty {
                let folderName = model.finderBrowseStack.last?.lastPathComponent ?? "Folder"
                let filtered = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                VStack(spacing: 6) {
                    Image(systemName: filtered ? "magnifyingglass" : "folder")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(filtered ? "No matching items in \(folderName)" : "\(folderName) is empty")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Press ← or Backspace to go back")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.65))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else if model.rows.isEmpty, !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 0) {
                    fallbackAskAIRow(isFocused: (effectiveFocus ?? 0) == 0)
                        .onHover { hovering in
                            if hovering, mouseGate.moved() {
                                withAnimation(FluidMotion.selectionGlide) {
                                    model.focusedMenuIndex = 0
                                }
                            }
                        }
                    fallbackWebRow(isFocused: effectiveFocus == 1)
                        .onHover { hovering in
                            if hovering, mouseGate.moved() {
                                withAnimation(FluidMotion.selectionGlide) {
                                    model.focusedMenuIndex = 1
                                }
                            }
                        }
                    fallbackFinderRow(isFocused: effectiveFocus == 2)
                        .onHover { hovering in
                            if hovering, mouseGate.moved() {
                                withAnimation(FluidMotion.selectionGlide) {
                                    model.focusedMenuIndex = 2
                                }
                            }
                        }
                }
                .animation(FluidMotion.selectionGlide, value: effectiveFocus)
            } else if model.rows.isEmpty, !model.returnsToGlobalScope {
                ForEach(model.suggestions.prefix(AppChatPromptModel.menuRowLimit)) { suggestion in
                    suggestionRow(suggestion)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Return already runs the top row when nothing has been arrowed
                            // to — `rows.first`, the same fallback the field's own icon
                            // reads — so a list showing none of them chosen was a list
                            // disagreeing with what its own Return key was about to do.
                            // Under Finder's Ask AI row, nothing chosen is that row.
                            if model.showsAskAIRow {
                                askAIRow(isFocused: model.focusedMenuIndex == nil)
                                    .id("ask-ai")
                                    .onHover { hovering in
                                        if hovering, mouseGate.moved() {
                                            withAnimation(FluidMotion.selectionGlide) {
                                                model.focusedMenuIndex = nil
                                            }
                                        }
                                    }
                            }
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                // A section's header and its first row are one item, scrolled to
                                // as one: aimed at the row alone, a scroll to an item not yet
                                // laid out stopped a slot short, the header showing and the
                                // highlighted row under it hidden.
                                VStack(spacing: 0) {
                                if let title = sectionHeaders[index] {
                                    sectionHeader(title)
                                }
                                Group {
                                    switch row {
                                    case .dock(let pill):
                                        dockRow(pill, isFocused: index == effectiveFocus)
                                    case .command(let item):
                                        commandRow(item, isFocused: index == effectiveFocus)
                                    case .action(let action):
                                        actionRow(action, isFocused: index == effectiveFocus)
                                    case .global(let doc):
                                        globalRow(doc, isFocused: index == effectiveFocus)
                                    case .file(let url):
                                        fileRow(url, isFocused: index == effectiveFocus)
                                    case .cliSuggestion(let word):
                                        cliSuggestionRow(word, isFocused: index == effectiveFocus)
                                    case .app(let entry):
                                        appRow(entry, isFocused: index == effectiveFocus)
                                    }
                                }
                                .contextMenu { pinMenu(for: row) }
                                .onHover { hovering in
                                    if hovering, mouseGate.moved() {
                                        withAnimation(FluidMotion.selectionGlide) {
                                            model.focusedMenuIndex = index
                                        }
                                    }
                                }
                                }
                                .id(row.id)
                            }
                        }
                        .padding(.bottom, 6)
                        // Fluid gliding selection capsule travels smoothly between rows
                        .animation(FluidMotion.selectionGlide, value: effectiveFocus)
                        .scrollTargetLayout()
                    }
                    // A hand scroll settles on whole rows, as the arrows do — never half a
                    // row at an edge (owner 2026-10-17).
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $topItemID, anchor: .top)
                    // And the highlight comes with it: scrolled out of view, it moves to the
                    // nearest row in view, so the foot never names a row nobody can see.
                    .onChange(of: topItemID) { _, top in
                        guard Date().timeIntervalSince(lastKeyMove) > 0.4 else { return }
                        model.keepFocusInView(topItemID: top, slots: visibleSlots)
                    }
                    // ↑ opens the list already on its last row: no change to follow then,
                    // so the list goes to it as it appears.
                    .onAppear {
                        guard let row = model.focusedRow else { return }
                        // After the scroll position settles on the list's top, or it wins.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(row.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: model.focusedMenuIndex) { _, _ in
                        lastKeyMove = Date()
                        // Synchronized scrolling in step with selectionGlide animation
                        if model.focusedMenuIndex == 0, let first = model.rows.first {
                            withAnimation(FluidMotion.selectionGlide) {
                                proxy.scrollTo(first.id, anchor: .top)
                            }
                        } else if let row = model.focusedRow {
                            withAnimation(FluidMotion.selectionGlide) {
                                proxy.scrollTo(row.id)
                            }
                        } else if model.showsAskAIRow {
                            withAnimation(FluidMotion.selectionGlide) {
                                proxy.scrollTo("ask-ai", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: model.query) { _, _ in
                        if model.showsAskAIRow {
                            proxy.scrollTo("ask-ai", anchor: .top)
                        } else if let row = model.rows.first {
                            proxy.scrollTo(row.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(
            width: CornerBoardLayout.listWidth(board: size.width, preview: preview),
            alignment: .topLeading)
        if let preview {
            // The preview's own inset card draws the edge between the halves.
            Color.clear.frame(width: CornerBoardLayout.dividerWidth)
            previewPanel(preview)
                .frame(
                    width: CornerBoardLayout.panelWidth(board: size.width),
                    height: size.height - 2 * AppChatListMetrics.verticalPadding
                        - AppChatListMetrics.footerHeight,
                    alignment: .topLeading)
                .transition(.opacity)
        }
        }
        .animation(.smooth(duration: 0.18), value: preview)
        .padding(.vertical, AppChatListMetrics.verticalPadding)
        .frame(
            width: size.width, height: size.height - AppChatListMetrics.footerHeight,
            alignment: .topLeading)
        footer
        }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            // Inside the centred card the card is the glass; a hairline marks the sheet.
            if sharesOneCard {
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                .background(GlassBackground(cornerRadius: 22, isDark: nil))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            }
        }
        .onHover { _ in model.touch() }
        .onChange(of: model.isSidePanelExpanded) { _, expanded in
            if !expanded, selectionModel.isEmbeddedInSidePanel, selectionModel.phase.isVisible {
                selectionModel.dismiss()
            }
        }
    }

    /// The board's foot, as Raycast's (owner 2026-10-14): on the left what Return is about to
    /// act on, on the right one bar of what Return does and the row's other keys, then pin
    /// and Settings as icons. Both sides follow the arrows (`boardFoot`). A folder walk keeps
    /// its path pills on the left instead.
    private var footer: some View {
        let foot = model.boardFoot
        return VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            HStack(spacing: 8) {
                if model.finderPathTrail.isEmpty {
                    contextPill(foot)
                } else {
                    finderPathPills
                }

                Spacer(minLength: 8)

                BoardFooter.pill {
                    Button {
                        if !model.runReturnRow(runsTopRow: true) {
                            model.submit()
                        }
                    } label: {
                        BoardFooter.action(foot.verb, keys: ["↩"])
                    }
                    .buttonStyle(.plain)

                    if tabStepsIn {
                        BoardFooter.divider
                        Button {
                            _ = model.stepIntoFocusedRow()
                        } label: {
                            BoardFooter.action("Step in", keys: ["⇥"])
                        }
                        .buttonStyle(.plain)
                    }
                    // A running app's row: quit it (owner 2026-10-11).
                    if let app = model.focusedAppRow, AppResultActions.runningApp(app.bundleID) != nil {
                        BoardFooter.divider
                        Button { _ = model.quitFocusedApp() } label: {
                            BoardFooter.action("Quit app", keys: ["⌘", "⌫"])
                        }
                        .buttonStyle(.plain)
                        .help("Quit \(app.name) (⌘⌫)")
                    }
                }
                .animation(.smooth(duration: 0.15), value: foot)

                actionsMenu(foot: foot)

                BoardFooter.pill {
                    Button {
                        withAnimation(FluidMotion.selectionGlide) {
                            model.isSidePanelExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: model.isSidePanelExpanded ? "sidebar.trailing" : "sidebar.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(model.isSidePanelExpanded ? Color.accentColor : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.isSidePanelExpanded ? "Collapse preview panel (⌘B)" : "Expand preview panel (⌘B)")
                }

                pinPill
            }
            .padding(.horizontal, 12)
            .frame(height: AppChatListMetrics.footerHeight - 1)
        }
        .frame(height: AppChatListMetrics.footerHeight)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
    }

    /// Contextual Raycast-style footer while viewing a file in Preview, Selection Scope,
    /// Search Inside File, or User Actions mode.
    private func fileSubmodeFooter(_ submode: FileSheetSubmodeState) -> some View {
        let primaryVerb: String = {
            switch submode.kind {
            case .preview:
                let hasText = !submode.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return hasText ? "Ask AI" : (submode.isFolder ? "Open Folder" : "Open")
            case .selectionScope:
                return selectionModel.isShowingAnswer ? "Ask" : "Run"
            case .extractedText:
                return "Copy All"
            case .userActions:
                return "Run"
            case .searchInFile:
                return "Show in Preview"
            }
        }()
        return VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            HStack(spacing: 8) {
                BoardFooter.pill {
                    Button {
                        if submode.kind == .extractedText && submode.returnToSelectionOnBack {
                            model.switchFileSubmode(.selectionScope)
                        } else {
                            _ = model.leaveFileSubmode()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            LiveFileIconView(url: submode.url, size: 14)
                            Text(submode.kind.shortLabel)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                BoardFooter.pill {
                    Button {
                        _ = model.submitFileSubmode()
                    } label: {
                        BoardFooter.action(primaryVerb, keys: ["↩"])
                    }
                    .buttonStyle(.plain)

                    BoardFooter.divider

                    if submode.kind == .preview {
                        Button {
                            model.switchFileSubmode(.selectionScope)
                        } label: {
                            BoardFooter.action("Selection Scope", keys: ["→"])
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            model.switchFileSubmode(.preview)
                        } label: {
                            BoardFooter.action("Preview", keys: ["␣"])
                        }
                        .buttonStyle(.plain)
                    }
                }

                pinPill
            }
            .padding(.horizontal, 12)
            .frame(height: AppChatListMetrics.footerHeight - 1)
        }
        .frame(height: AppChatListMetrics.footerHeight)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
    }

    /// Standalone pin pill at the far right end, highlighted in accent when active.
    private var pinPill: some View {
        Button {
            if !model.pinChosenRow() { model.togglePin() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isPinned ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                model.isPinned ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    model.isPinned ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.12),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.focusedRow != nil
            ? "Pin chosen row (⌘P)"
            : (model.isPinned ? "Unpin (⌘P)" : "Keep launcher open (⌘P)"))
    }

    /// Raycast-style Actions menu (⌘K) exposing contextual item actions, view controls, and settings.
    private func actionsMenu(foot: BoardFoot) -> some View {
        Menu {
            Section("Item") {
                Button(foot.verb.isEmpty ? "Open" : foot.verb) {
                    if !model.runReturnRow(runsTopRow: true) {
                        model.submit()
                    }
                }

                if tabStepsIn {
                    Button("Step into") {
                        _ = model.stepIntoFocusedRow()
                    }
                }

                if let row = model.focusedRow ?? model.rows.first {
                    switch row {
                    case .file(let url):
                        Button("Quick Look") {
                            _ = model.toggleSidePanelPreview(force: true)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
                        }
                        Button("Copy File Name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.lastPathComponent, forType: .string)
                        }
                    case .global(let doc):
                        if let path = doc.filePath, !path.isEmpty {
                            let url = URL(fileURLWithPath: path)
                            Button("Quick Look") {
                                _ = model.toggleSidePanelPreview(force: true)
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                            }
                        } else if case .browserURL(let url, _, _, _, _) = doc.action {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                        }
                    case .command(let item):
                        Button("Copy Menu Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.title, forType: .string)
                        }
                    default:
                        EmptyView()
                    }
                }

                if let app = model.focusedAppRow, AppResultActions.runningApp(app.bundleID) != nil {
                    Button("Quit \(app.name)") {
                        _ = model.quitFocusedApp()
                    }
                }

                Button("Pin to Quick Bar") {
                    _ = model.pinChosenRow()
                }
            }

            Section("View") {
                Button(model.isSidePanelExpanded ? "Collapse Preview Panel" : "Expand Preview Panel") {
                    withAnimation(FluidMotion.selectionGlide) {
                        model.isSidePanelExpanded.toggle()
                    }
                }
            }

            Section("Launcher") {
                Button("Create Extension or Plugin with AI…") {
                    model.openExtensionStudio(
                        target: model.targetFileSubmodeURL() != nil ? .selectionExtension : .globalCommand,
                        contextFile: model.targetFileSubmodeURL()
                    )
                }

                Button("Keyboard Shortcuts...") {
                    CornerDockController.shared.chatPresentation.toggleKeysOverlay()
                }

                Button("Settings...") {
                    AppDelegate.shared?.showSettings()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("Actions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary)
                BoardFooter.keycaps(["⌘", "K"])
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .keyboardShortcut("k", modifiers: .command)
        .help("Actions (⌘K)")
    }

    /// What Return is about to act on: its icon and its kind, dimmed, as Raycast's foot names
    /// the highlighted row's section.
    private func contextPill(_ foot: BoardFoot) -> some View {
        BoardFooter.pill {
            Group {
                if let icon = foot.icon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                } else {
                    Image(systemName: foot.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
            }
            Text(foot.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .id(foot.title + foot.bundleID)
        .transition(.opacity)
        .animation(.smooth(duration: 0.15), value: foot)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(foot.title). Return: \(foot.verb)")
    }

    /// The folder being walked, as Finder's path bar shows it: one clickable pill per folder
    /// from the disk down, the current one last and in bold (owner 2026-10-09).
    private var finderPathPills: some View {
        let trail = model.finderPathTrail
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(trail.enumerated()), id: \.element) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button { model.openFinderPathPill(url) } label: {
                        BoardFooter.pill {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 14, height: 14)
                            Text(FileManager.default.displayName(atPath: url.path))
                                .font(.system(
                                    size: 11.5,
                                    weight: index == trail.count - 1 ? .semibold : .medium))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                }
            }
        }
        .defaultScrollAnchor(.trailing)
    }

    /// Tab steps into the highlighted row — the top one when none is — when it is a scope:
    /// a CLI tool, a Global Command, an extension.
    private var tabStepsIn: Bool {
        guard let row = model.focusedRow ?? model.rows.first else { return false }
        switch row {
        case .global(let doc): return AppChatPromptModel.rightArrowStepsInto(doc.action)
        case .cliSuggestion: return true
        default: return false
        }
    }

    /// Names what the list is: what the app can do at rest, what matched once typing starts.
    /// A section's title over its first row, set as the count line was.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary.opacity(0.8))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A row's height: the list keeps one grid, so scrolling never leaves half a row.
            .frame(height: AppChatListMetrics.rowHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }

    /// How many row-high slots the list shows: the card less its padding, foot and the count
    /// line when there are no sections.
    private var visibleSlots: Int {
        let height = size.height - 2 * AppChatListMetrics.verticalPadding
            - AppChatListMetrics.footerHeight
            - (model.globalSectionHeaders.isEmpty && !headerText.isEmpty ? AppChatListMetrics.headerHeight : 0)
        return max(Int(height / AppChatListMetrics.rowHeight), 1)
    }

    private var headerText: String {
        if model.isGlobalScope { return "" }
        if model.isFinderFileSearch, let folder = model.finderBrowseStack.last {
            return "\(folder.lastPathComponent) · \(model.rows.count) item\(model.rows.count == 1 ? "" : "s")"
        }
        if model.slashAppFilter != nil { return "Jump to an app, tool or command · ↩ steps in" }
        let typed = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let app = model.appName.isEmpty ? "App" : model.appName
        if typed { return "\(app) · \(model.rows.count) match\(model.rows.count == 1 ? "" : "es")" }
        return model.capabilitySummary.isEmpty ? "\(app) can" : model.capabilitySummary
    }

    /// What the field says before anything is typed, per scope.
    static func placeholder(for model: AppChatPromptModel) -> String {
        if model.isGlobalScope { return "Search anything…" }
        if model.showsExtensionPanel {
            let ph = ExtensionHeaderBarState.shared.placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
            return ph.isEmpty ? "Filter…" : ph
        }
        if model.isFinderFileSearch, let folder = model.finderBrowseStack.last {
            return "Search \(folder.lastPathComponent)…"
        }
        // Scoped into a tool or command from Global, the field is a filter over that scope;
        // an App Pet selected in the Dock is a composer ("Ask <App>", #338).
        if model.returnsToGlobalScope, !model.isAppStepIn {
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
                .fluidIconZoom(isFocused: isFocused)
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
            } else if isFocused {
                // No real shortcut to show in its place, so this row — focused, about to
                // run on Return — said nothing at all about what Return would do to it.
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
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
    /// A subcommand the scoped tool takes. Choosing it fills the field rather than running
    /// it, because most subcommands still want an argument.
    private func cliSuggestionRow(_ word: String, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .fluidIconZoom(isFocused: isFocused)
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
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture { model.run(.cliSuggestion(word)) }
    }

    /// An app "/" can jump to: its icon and name, and whether it is open. One that is not
    /// still works — its scope runs on its adapters, CLI tools and skills, unlaunched.
    private func appRow(_ entry: ChatAppEntry, isFocused: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: AppChatListMetrics.iconSize - 6, height: AppChatListMetrics.iconSize - 6)
            .frame(width: AppChatListMetrics.iconSize, height: AppChatListMetrics.iconSize)
            .fluidIconZoom(isFocused: isFocused)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(entry.isRunning ? "Running" : "Not open · works without launching")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isFocused {
                Text("↩")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture { model.run(.app(entry)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Finder's first row: what is typed, as a question to the AI. Return takes it until the
    /// arrows choose a file or command (owner 2026-10-09).
    private func askAIRow(isFocused: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: AppChatListMetrics.iconSize, height: AppChatListMetrics.iconSize)
                .fluidIconZoom(isFocused: isFocused)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask AI")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(model.query.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if isFocused {
                Text("↩")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isGlobalScope {
                model.askFromGlobal(model.query)
            } else {
                model.submit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Ask AI: \(model.query)")
    }

    /// Siri Fallback 1: Ask AI with typed prompt
    private func fallbackAskAIRow(isFocused: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: AppChatListMetrics.iconSize, height: AppChatListMetrics.iconSize)
                .fluidIconZoom(isFocused: isFocused)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask AI")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(model.query.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isFocused {
                Text("↩")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isGlobalScope {
                model.askFromGlobal(model.query)
            } else {
                model.submit()
            }
        }
    }

    /// Siri Fallback 2: Search web via default browser
    private func fallbackWebRow(isFocused: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.blue)
                .frame(width: AppChatListMetrics.iconSize, height: AppChatListMetrics.iconSize)
                .fluidIconZoom(isFocused: isFocused)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search The Web")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text("Search default browser for “\(model.query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isFocused {
                Text("↩")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture { model.openWebSearch() }
    }

    /// Siri Fallback 3: Search Finder for files on Mac
    private func fallbackFinderRow(isFocused: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: AppChatListMetrics.iconSize, height: AppChatListMetrics.iconSize)
                .fluidIconZoom(isFocused: isFocused)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search in Finder")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text("Find files matching “\(model.query.trimmingCharacters(in: .whitespacesAndNewlines))” on Mac")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isFocused {
                Text("↩")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture { model.openFinderSearch() }
    }

    /// A file or folder from the Finder scope, with the path it lives at — two files called
    /// "Downloads" are told apart by where they are, not by their name.
    private func fileRow(_ url: URL, isFocused: Bool) -> some View {
        let isFolder = AppChatPromptModel.isFolder(url)
        let isBookmark = url.pathExtension == "inetloc" || url.pathExtension == "webloc"
        let displayName: String = {
            if isBookmark {
                let base = url.deletingPathExtension().lastPathComponent
                if base.hasPrefix("com.apple.") {
                    let cleaned = base.replacingOccurrences(of: "com.apple.", with: "")
                    return "\(cleaned) Bookmark"
                }
                return base
            }
            return url.lastPathComponent
        }()
        let displayPath: String = {
            let parent = url.deletingLastPathComponent().path
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return isBookmark ? "\(parent) · Web Bookmark" : parent
        }()
        return HStack(spacing: 10) {
            LiveFileIconView(url: url, size: 26)
                .frame(width: 28, height: 28)
                .fluidIconZoom(isFocused: isFocused)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(displayPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if isFocused {
                HStack(spacing: 5) {
                    Text(isFolder ? "Browse" : "Actions")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.75))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else if isFolder {
                HStack(spacing: 3) {
                    Text("Folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.45))
                }
            } else {
                Text(isBookmark ? "Bookmark" : "File")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if isFolder {
                _ = model.enterFolder(url)
            } else {
                model.run(.file(url))
            }
        }
    }

    /// A Global Context result: whatever the machine offers for this query, with its own
    /// icon where the index has one.
    /// "Pin to dock" on any row that stands for something pinnable; nothing on the rest.
    /// One rule (`DockPinKind(row:)`) decides, the same one the strip's drop uses.
    @ViewBuilder
    private func pinMenu(for row: AppChatRow) -> some View {
        // In an app's Context Dock a row pins for that app: to its bar, not Global's.
        if model.canPinToApp(row) {
            Button(model.isPinnedToApp(row) ? "Unpin from \(model.appName)" : "Pin to \(model.appName)") {
                model.toggleAppPin(row)
            }
        } else if let kind = DockPinKind(row: row) {
            Button(DockPinStore.shared.isPinned(kind) ? "Unpin from Dock" : "Pin to Dock") {
                model.toggleDockPin(row)
            }
        }
    }

    private func globalRow(_ doc: GlobalSearchService.SearchDocument, isFocused: Bool)
        -> some View
    {
        let foot = model.foot(for: .global(doc))
        return HStack(spacing: 12) {
            globalLeadingIcon(for: doc)
                .overlay(alignment: .bottomTrailing) {
                    if foot.isRunningApp {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor).opacity(0.85), lineWidth: 1))
                    }
                }
                .frame(width: AppChatListMetrics.iconSize, height: AppChatListMetrics.iconSize)
                .fluidIconZoom(isFocused: isFocused)

            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                // Said once, on the right (#258 G2): "Application" under the name repeated it.
                let subtitle = GlobalContextRow.subtitle(for: doc)
                // Highlighted, the right says ↩, so the line under the name stays.
                if isFocused || (subtitle != foot.kind && !(foot.isRunningApp && subtitle == "Running")) {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // The dock hints "press Return" at whichever row the arrow keys land on; this
            // list showed the same rows without ever saying what Return does to one.
            if isFocused {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                RowStatus(foot: model.foot(for: .global(doc)), shortcut: menuShortcut(doc))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture { model.run(.global(doc)) }
    }

    /// A menu command's own shortcut, as its app's menu shows it.
    private func menuShortcut(_ doc: GlobalSearchService.SearchDocument) -> String? {
        guard case .cachedMenu(_, _, _, let char, let modifiers) = doc.action else { return nil }
        return MenuShortcutFormatter.display(char: char, modifiers: modifiers)
    }

    private func pageURL(_ doc: GlobalSearchService.SearchDocument) -> URL? {
        if case .browserURL(let url, _, _, _, _) = doc.action { return url }
        if let path = doc.filePath, !path.isEmpty, !path.hasSuffix(".app") {
            return URL(fileURLWithPath: path)
        }
        if case .launchPath(let path) = doc.action, !path.isEmpty, !path.hasSuffix(".app") {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    @ViewBuilder
    private func globalLeadingIcon(for doc: GlobalSearchService.SearchDocument) -> some View {
        switch doc.action {
        case .activatePID, .launchPath, .launchBundleId:
            CornerResultIcon(
                url: pageURL(doc),
                fallback: doc.icon,
                symbol: GlobalContextRow.symbol(for: doc)
            )
        case .browserURL(let url, let browserBundleId, _, _, _):
            CornerResultIcon(
                url: url,
                fallback: doc.icon ?? appIconImage(for: browserBundleId),
                symbol: GlobalContextRow.symbol(for: doc)
            )
        case .cachedMenu(let bundleId, _, _, _, _):
            SpotlightCommandBadgeIcon(
                symbol: GlobalContextRow.symbol(for: doc),
                customImage: doc.icon,
                appBadgeImage: appIconImage(for: bundleId),
                size: 32
            )
        case .adapterAction(let bundleId, _, _):
            SpotlightCommandBadgeIcon(
                symbol: GlobalContextRow.symbol(for: doc),
                appBadgeImage: appIconImage(for: bundleId),
                tint: .accentColor,
                size: 32
            )
        case .cliScope, .systemCommandScope, .userExtension, .plugin:
            SpotlightCommandBadgeIcon(
                symbol: GlobalContextRow.symbol(for: doc),
                customImage: doc.icon,
                appBadgeImage: doc.bundleId.isEmpty ? nil : appIconImage(for: doc.bundleId),
                size: 32
            )
        }
    }

    private func appIconImage(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func dockRow(_ pill: DockPill, isFocused: Bool) -> some View {
        // "Show N more" is a control, not a result: a small chevron, quieter text, no status
        // (owner 2026-10-17).
        let isShowMore = pill.rankingKind == GlobalResultSection.showMoreKind
        let rawSubtitle = pill.menuContext ?? pill.badge ?? pill.sourceAppName
        let subtitle: String = {
            if rawSubtitle.hasPrefix("syscmd://") { return "System command" }
            if rawSubtitle.hasPrefix("cli://") { return "Command-line tool" }
            return rawSubtitle
        }()
        let foot = model.foot(for: .dock(pill))
        let rowURL = pill.resolvedURL
            ?? pill.previewPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let isNativeAppOrFile = ["application", "appLaunch", "appSwitch"].contains(pill.rankingKind)
            || (rowURL?.isFileURL == true)
        let isAppScopedCommand = ["menu", "submenuChild", "finderMenu", "safariCommand", "adapterAction"].contains(pill.rankingKind)
        return HStack(spacing: 12) {
            Group {
                if isShowMore {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if isNativeAppOrFile {
                    CornerResultIcon(url: rowURL, fallback: pill.menuItemImage, symbol: pill.icon)
                        .overlay(alignment: .bottomTrailing) {
                            if foot.isRunningApp {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor).opacity(0.85), lineWidth: 1))
                            }
                        }
                } else if let rowURL, !rowURL.isFileURL {
                    CornerResultIcon(url: rowURL, fallback: pill.menuItemImage, symbol: pill.icon)
                } else {
                    let badgeImage: NSImage? = {
                        if !pill.sourceBundleId.isEmpty,
                           isAppScopedCommand || pill.rankingKind == "doraxPackV3Contextual" || pill.rankingKind == "globalCommand"
                        {
                            return appIconImage(for: pill.sourceBundleId)
                        }
                        return nil
                    }()
                    let tintColor: Color? = {
                        if pill.rankingKind == "nativeWindow" { return .blue }
                        if pill.rankingKind == "doraxPackStudio" { return .purple }
                        if pill.rankingKind == "adapterAction" { return .accentColor }
                        return nil
                    }()
                    let resolvedSymbol: String = {
                        let raw = pill.icon.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !raw.isEmpty && raw != "app" && raw != "command" {
                            return raw
                        }
                        return SFSymbolResolver.menuSymbol(
                            title: pill.name,
                            path: pill.menuPath.isEmpty ? [pill.sourceAppName, pill.name] : pill.menuPath,
                            isAppleMenu: pill.menuPath.first?.lowercased() == "apple"
                        )
                    }()
                    SpotlightCommandBadgeIcon(
                        symbol: resolvedSymbol,
                        customImage: isAppScopedCommand ? pill.menuItemImage : nil,
                        appBadgeImage: badgeImage,
                        tint: tintColor,
                        size: 32
                    )
                }
            }
            .frame(width: AppChatListMetrics.iconSize, height: AppChatListMetrics.iconSize)
            .fluidIconZoom(isFocused: isFocused)
            VStack(alignment: .leading, spacing: 2) {
                Text(pill.name)
                    .font(.system(size: isShowMore ? 13 : 15, weight: .medium))
                    .foregroundStyle(isShowMore ? .secondary : .primary)
                    .lineLimit(1)
                // A row with no second line sits centred, not over an empty one.
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isShowMore {
                EmptyView()
            } else if isFocused {
                Text(pill.sourceAppName).font(.system(size: 10)).foregroundStyle(.secondary)
                Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if model.isGlobalScope {
                RowStatus(foot: model.foot(for: .dock(pill)), shortcut: pill.keyboardShortcutLabel)
            } else if let shortcut = pill.keyboardShortcutLabel {
                Text(shortcut).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .opacity(pill.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { model.run(.dock(pill)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The opening offer for an app with no adapter and nothing cached yet.
    private func suggestionRow(_ suggestion: AppChatSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: AppChatListMetrics.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // A proactive Pet suggestion (#343) is never stuck on screen: dismiss it, or mute
            // the Pet until tomorrow.
            if let id = suggestion.proactiveID {
                Button("Mute for a day", systemImage: "bell.slash") {
                    AppPetSuggestionCoordinator.shared.dismissSuggestion(id: id, mutePetFor: 86_400)
                }
                .help("Mute this Pet's suggestions for a day")
                Button("Dismiss", systemImage: "xmark") {
                    AppPetSuggestionCoordinator.shared.dismissSuggestion(id: id)
                }
                .help("Dismiss this suggestion")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
    }

    /// An action the app's adapter declares: curated, so it says what it does rather than
    /// where it lives.
    private func actionRow(_ action: AdapterAction, isFocused: Bool) -> some View {
        let resolvedSymbol = action.icon.isEmpty
            ? SFSymbolResolver.menuSymbol(title: action.name, path: [model.appName, action.name], isAppleMenu: false)
            : action.icon
        return HStack(spacing: 12) {
            SpotlightCommandBadgeIcon(
                symbol: resolvedSymbol,
                appBadgeImage: appIconImage(for: model.appBundleID),
                tint: .accentColor,
                size: 32
            )
            .frame(width: AppChatListMetrics.iconSize, height: AppChatListMetrics.iconSize)
            .fluidIconZoom(isFocused: isFocused)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(action.description.isEmpty ? model.appName : action.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isFocused {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: selectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture { model.runAdapterAction(action) }
    }
}

/// Observing the cache redraws a page icon as soon as it arrives, without another keypress.
/// Local `file://` URLs resolve directly to their macOS file/folder icon instead of `"globe"`.
struct CornerResultIcon: View {
    @ObservedObject private var favicons = FaviconStore.shared
    let url: URL?
    let fallback: NSImage?
    let symbol: String

    static func resolvedImage(
        url: URL?, fallback: NSImage?, favicons: FaviconStore = .shared
    ) -> NSImage? {
        if let url {
            if url.isFileURL {
                return FileThumbnailCache.shared.cachedThumbnail(for: url.path)
                    ?? fallback
                    ?? NSWorkspace.shared.icon(forFile: url.path)
            }
            return favicons.icon(for: url) ?? fallback
        }
        return fallback
    }

    static func fallbackSymbol(url: URL?, symbol: String) -> String {
        if let url, !url.isFileURL { return "globe" }
        return symbol
    }

    var body: some View {
        if let url, url.isFileURL {
            LiveFileIconView(url: url, size: 26, fallback: fallback)
        } else {
            let image = Self.resolvedImage(url: url, fallback: fallback, favicons: favicons)
            let side: CGFloat = image != nil ? 26 : 20
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: Self.fallbackSymbol(url: url, symbol: symbol))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .task(id: url) {
                if let url, !url.isFileURL {
                    favicons.fetchIfNeeded(for: url)
                }
            }
        }
    }
}

/// The highlight behind a focused row in the corner's lists — one drawing for every card
/// that lists rows (App Chat, Selection), so the two cannot drift apart.
/// A Global row's right side when it is not highlighted (#258 G2): its kind, or ● Running
/// for an open app — the foot's own words, so the row and the foot never disagree.
struct RowStatus: View {
    let foot: BoardFoot
    /// A menu command's shortcut, after its kind: "Menu · ⌘Q".
    var shortcut: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if foot.isRunningApp {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Running")
            } else {
                Text(foot.kind)
            }
            if let shortcut {
                Text("·")
                Text(shortcut)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

struct CornerListRowBackground: View {
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.primary.opacity(isFocused ? 0.10 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.primary.opacity(isFocused ? 0.2 : 0), lineWidth: 1)
            }
            .padding(.horizontal, 8)
    }
}
