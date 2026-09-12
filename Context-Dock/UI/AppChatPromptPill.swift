// AppChatPromptPill.swift
// Context-Dock
//
// The corner input for asking the frontmost app something, in the same shell and shape as
// the clipboard pill.
//
// It opens the way Siri does — showing what this app can actually do — because a blank
// field asks the user to guess. Typing puts the list away, idling shrinks the whole thing
// to the app's own icon, and the controls in the field only appear under the pointer so
// the resting state stays a single quiet line.

import AppKit
import SwiftUI

enum AppChatPromptMetrics {
    static let width: CGFloat = 372
    static let inputHeight: CGFloat = 56
    static let suggestionRowHeight: CGFloat = 34
    static let summaryHeight: CGFloat = 30
    /// Just the app's icon.
    static let miniSize = CGSize(width: 52, height: 44)
    /// Attached files, as chips with a thumbnail — taller than the old bare capsules, and
    /// shared with General so one attachment is the same object in both modes.
    static let attachmentRowHeight: CGFloat = 46
    /// The conversation, with nothing in it yet: header, one exchange's worth of room, and
    /// the composer.
    static let chatHeight: CGFloat = 340

    /// How much a card grows per message, and how far it may grow.
    ///
    /// Both read from General's numbers rather than copying them. App mode was pinned at
    /// 340 while General grew to 620, so the same conversation was given half the room
    /// depending on which scope it was in — and the switch between the two modes looked
    /// like the window had changed rather than the subject.
    static var perMessageHeight: CGFloat { CornerGeneralChatMetrics.perMessageHeight }
    static var maximumChatHeight: CGFloat { CornerGeneralChatMetrics.maximumHeight }

    /// A pure function of model state, deliberately: the corner draws this frame and
    /// hit-tests the same number, so a height measured from content would leave the two
    /// disagreeing. Message count is state; message height is not.
    static func chatHeight(messages: Int) -> CGFloat {
        min(maximumChatHeight, chatHeight + CGFloat(min(messages, 5)) * perMessageHeight)
    }

    /// What sits over the field — an approval waiting on a yes, attached files — is part
    /// of the card's height in every phase. Attachments were not counted at all before, so
    /// pasting a file into App mode drew a row the card had no room for.
    static func sheetHeight(hasApproval: Bool, attachments: Int) -> CGFloat {
        var result: CGFloat = 0
        if hasApproval { result += ApprovalCard.height + 1 }
        if attachments > 0 { result += attachmentRowHeight }
        return result
    }

    static func size(
        for phase: AppChatPromptPhase,
        suggestions: Int,
        messages: Int = 0,
        hasApproval: Bool = false,
        attachments: Int = 0
    ) -> CGSize {
        let sheet = sheetHeight(hasApproval: hasApproval, attachments: attachments)
        switch phase {
        case .hidden, .mini:
            return miniSize
        case .prompt, .suggesting:
            // The list is its own card above this one, so the field stays a field.
            return CGSize(width: width, height: inputHeight + sheet)
        case .chat:
            return CGSize(width: width, height: chatHeight(messages: messages) + sheet)
        }
    }
}

struct AppChatPromptPill: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var keyboardState = CornerDockController.shared.keyboardState
    @ObservedObject private var approvals = ApprovalCenter.shared
    /// Watched, not asked once: the clipboard can arm while this field is already up, and
    /// the caret has to leave when it does.
    @ObservedObject private var clipboard = ClipboardPanelController.shared.model
    @ObservedObject private var selection = CornerDockController.shared.selection
    @FocusState private var fieldFocused: Bool
    @State private var pointerInside = false

    private var size: CGSize {
        AppChatPromptMetrics.size(
            for: model.phase,
            suggestions: model.listRowCount,  // list rows live in AppChatListCard now
            messages: model.messages.count,
            hasApproval: approvals.pending(for: .corner) != nil,
            attachments: model.attachments.count)
    }

    var body: some View {
        // Both layers stay mounted and cross-fade. Swapping them with a transition looked
        // right in isolation and wrong in the shell: the 372-point input stack is still
        // laid out at full width while the frame shrinks to the 52-point badge, and the
        // clip outside this frame cuts it off mid-word — the badge showed an app icon and
        // the first letter of its name, over the outgoing card's glass.
        //
        // The wide layer is also faded out faster than the frame collapses, so it is
        // already invisible by the time the pill is narrow enough to slice it.
        ZStack(alignment: .bottomLeading) {
            inputStack
                .frame(width: AppChatPromptMetrics.width, alignment: .bottomLeading)
                .opacity(model.phase.showsInput ? 1 : 0)
                .allowsHitTesting(model.phase.showsInput)
                .animation(.easeOut(duration: 0.11), value: model.phase)

            miniContent
                .opacity(model.phase == .mini ? 1 : 0)
                .allowsHitTesting(model.phase == .mini)
                .animation(.easeIn(duration: 0.16).delay(0.06), value: model.phase)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
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
        .onHover { pointerInside = $0 }
        // One rule decides who holds the caret, and this field asks it rather than
        // asserting. Before, every phase change and focus token pulled focus back here —
        // so arming the clipboard armed a card that never got the keys.
        // Claimed when named, and on appear too: a board that mounts after the owner was
        // decided has no change to react to, which is exactly how the clipboard ended up
        // armed and keyless.
        .onAppear { syncFocus() }
        .onChange(of: keyboardState.owner) { _, _ in syncFocus() }
        .onChange(of: keyboardState.focusRequestToken) { _, _ in syncFocus() }
        // A panel minimised or restored changes the pills without anything being typed, so
        // the row has to be asked again rather than waiting for the next keystroke.
        .onReceive(NotificationCenter.default.publisher(for: .minimizedPanelsChanged)) { _ in
            model.updateGlobalTyping(for: model.query)
        }
    }

    private func syncFocus() {
        fieldFocused = keyboardState.owner == .chat
    }

    // MARK: - Input

    /// Every state reads upward from one stable composer at the bottom. Suggestions are
    /// simply the empty transcript: they occupy the same space answers will use later.
    private var inputStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.phase == .chat {
                header
                Divider().opacity(0.18)
                transcript
                Divider().opacity(0.18)
            }
            // A turn asked from here can need a yes, and that question belongs directly
            // over the field — the same place the `/` picker and the command list appear —
            // rather than inside a transcript the user can scroll away from.
            if let request = approvals.pending(for: .corner) {
                ApprovalCard(request: request)
                    .frame(height: ApprovalCard.height)
                Divider().opacity(0.18)
            }
            if !model.pendingChoices.isEmpty {
                choiceCard
                Divider().opacity(0.18)
            }
            if !model.attachments.isEmpty { attachmentRow }
            inputRow
        }
        .frame(width: AppChatPromptMetrics.width, alignment: .topLeading)
    }

    /// What the answer is waiting on, above the composer.
    ///
    /// The buttons exist inside the message too, and inside a scrolling transcript in a
    /// 372-point card that is somewhere the user has to go back to. A turn that has stopped to
    /// ask belongs at the point of reply, which is where the clipboard panel already puts its
    /// preview.
    private var choiceCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.pendingChoices) { choice in
                Button { model.pick(choice) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(choice.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(choice.routeLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Who the chat is with, and what to do with the chat itself — the same shape General
    /// mode uses, so switching scope changes the subject rather than the furniture.
    private var header: some View {
        HStack(spacing: 8) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text(model.appName.isEmpty ? "This app" : model.appName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text("App Chat")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 6)

            // Stop lives in the composer, which is drawn in every phase this header is —
            // one job, one button, rather than two of them 300 points apart.
            Button { model.openInDock() } label: {
                headerGlyph("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open this conversation in the dock")

            Button { model.newConversation() } label: {
                headerGlyph("trash")
            }
            .buttonStyle(.plain)
            .help("Clear this conversation")

            Button { model.togglePin() } label: {
                headerGlyph(model.isPinned ? "pin.fill" : "pin", tinted: model.isPinned)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
    }

    private func headerGlyph(_ symbol: String, tinted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tinted ? Color.accentColor : .secondary)
            .frame(width: 26, height: 26)
            .background(tinted ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
            .contentShape(Rectangle())
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            if model.appBundleID.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            } else if model.isGlobalScope {
                globalLeadingChip
            } else if model.returnsToGlobalScope {
                scopeChipWithExit
            } else {
                appChip
            }

            // What the question will carry besides the words. Next to the scope chip
            // because the two together are the subject: this app, this selection.
            if let selection = model.selection {
                selectionChip(selection)
            }

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    placeholder
                }
                // What Tab would complete to, greyed behind the caret. Drawn in the field's
                // own metrics with the typed part transparent, so the ghost lines up with
                // the text instead of floating near it.
                if !model.globalGhostCompletion.isEmpty {
                    HStack(spacing: 0) {
                        Text(model.query).foregroundStyle(.clear)
                        Text(model.globalGhostCompletion)
                            .foregroundStyle(.secondary.opacity(0.45))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($fieldFocused)
                    .onChange(of: model.query) { _, _ in model.queryChanged() }
                    .onSubmit {
                        // A chosen row runs — a command or an adapter action. On a window
                        // snapshot with nothing typed, Return switches to that app, because
                        // that is what the switcher is for. Anything else is a question.
                        if model.runFocusedRow() { return }
                        if model.activateSnapshotApp() { return }
                        // A panel on screen is what the field is talking to.
                        if model.showsExtensionPanel {
                            model.askPanelAssistant()
                            return
                        }
                        // Inside a CLI scope, Return runs the line against that tool rather
                        // than asking the model about it.
                        if model.isCLIScope {
                            model.runCLICommand()
                            return
                        }
                        if model.isSearchField {
                            if let first = model.rows.first { model.run(first) }
                            return
                        }
                        model.submit()
                    }
                    .onKeyPress(.space) {
                        // Only once the user has arrowed into the list; with the caret in
                        // the field, a space is a space.
                        model.previewFocusedRow() ? .handled : .ignored
                    }
                    .onKeyPress(.tab) {
                        // The row the arrows landed on first; the top match only when the
                        // user has not chosen one.
                        if model.enterFocusedRow() { return .handled }
                        return model.acceptGlobalTopMatch() ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow) {
                        model.moveMenuFocus(by: 1) ? .handled : .ignored
                    }
                    .onKeyPress(.upArrow) {
                        model.moveMenuFocus(by: -1) ? .handled : .ignored
                    }
                    .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                        // Backspace on an empty field leaves the scope — the dock's way out,
                        // and the one most people reach for before they find the "−". Both
                        // delete keys, because `.delete` alone did not match the backspace
                        // this field actually receives.
                        if model.query.isEmpty, model.leaveScopeForGlobal() { return .handled }
                        return .ignored
                    }
                    .onKeyPress(.escape) {
                        // Unwind, then leave. Dismissing mid-answer threw away a turn the
                        // user was waiting on and a question they had half-written, for
                        // one press of the key that usually means "step back".
                        if !model.query.isEmpty {
                            model.query = ""
                            model.queryChanged()
                            return .handled
                        }
                        if model.isAnswering {
                            model.cancelTurn()
                            return .handled
                        }
                        model.dismiss()
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        // Left out of a scope entered from Global goes back to Global,
                        // before the walk between scopes is considered at all.
                        if model.query.isEmpty, model.leaveScopeForGlobal() { return .handled }
                        return CornerDockController.shared.chatPresentation
                            .handleLeftArrow(draft: model.query) ? .handled : .ignored
                    }
                    .onKeyPress(.rightArrow) {
                        // A chosen row is what the user is pointing at, so → steps into it
                        // before anything else. Otherwise it takes the ghost completion, and
                        // on an empty field it steps into an app; failing all of that it
                        // walks back through the scopes.
                        if model.enterFocusedRow() { return .handled }
                        if model.acceptGhostCompletion() { return .handled }
                        if model.scopeIntoFirstRunningApp() { return .handled }
                        return CornerDockController.shared.chatPresentation
                            .handleRightArrow(draft: model.query) ? .handled : .ignored
                    }
                    .onKeyPress(keys: ["p"]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        model.togglePin()
                        return .handled
                    }
                    .onKeyPress(keys: ["k"]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        model.newConversation()
                        return .handled
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        CornerDockController.shared.requestComposerFocus()
                    })
            }

            // The dock's own match pills, mounted rather than imitated: the apps that
            // answer what is typed, with "+N" for the rest. Same view, same icons, same
            // running dot as the dock's global bar.
            // Hidden once the user has typed and the board is answering: the rows say what
            // matched, and two answers to one question is the clutter the dock avoids. An
            // untyped field is not that case — there the pills are the only thing offering
            // anywhere to go, so they stay through a scope change.
            if model.isGlobalScope || model.returnsToGlobalScope,
                model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !model.globalMatchIcons.isEmpty || model.globalOverflowCount > 0
            {
                ContextMatchDock(
                    phase: .idle,
                    icons: model.globalMatchIcons,
                    overflowCount: model.globalOverflowCount,
                    isSearching: false,
                    onSelect: { icon in model.openGlobalMatchIcon(icon) })
                    .transition(.opacity)
            }

            // Attaching and sending live in the field, always drawn, the way the dock's own
            // composer keeps its "+" on screen. Hiding them until the pointer arrived meant
            // the two things you do most here were invisible until found by accident, and
            // gone entirely once a conversation started.
            //
            // Global Context and the scopes entered from it are search fields rather than
            // composers, and the dock carries none of this there — so neither does this.
            if !model.isSearchField {
                attachMenu
                // Only when there is something to open: an icon that does nothing on a
                // blank selection is a button shaped like a promise it cannot keep.
                if model.selection != nil {
                    selectionScopeButton
                }
            }

            if model.isAnswering {
                Button { model.cancelTurn() } label: {
                    controlGlyph("stop.fill", tinted: true)
                }
                .buttonStyle(.plain)
                .help("Stop")
                .transition(.opacity)
            } else if model.isCLIScope,
                !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Asking the tool, through the pipeline — which decides what to run and
                // asks before running it.
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Ask \(model.cliCommand)")
                .transition(.opacity)
            } else if !model.isSearchField,
                !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Send")
                .transition(.opacity)
            }

            // Expand and pin stay with the pointer while this row is the whole surface;
            // once a conversation exists the header carries them, and drawing them twice
            // six points apart is two buttons for one job.
            if pointerInside, model.phase != .chat, !model.isGlobalScope {
                surfaceControls
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: AppChatPromptMetrics.inputHeight)
        .animation(.easeOut(duration: 0.14), value: pointerInside)
        .animation(.easeOut(duration: 0.12), value: model.isAnswering)
        .animation(.easeOut(duration: 0.12), value: model.query.isEmpty)
    }

    /// Opens the frontmost app's selection as its own corner card — the same surface the
    /// Selection Scope hotkey opens, reached here without leaving the keyboard to find it in
    /// Settings. Sits beside "+" because both add something to work with; this one reads it
    /// off the screen instead of picking a file.
    private var selectionScopeButton: some View {
        Button {
            AppDelegate.shared?.activateSelectionScope()
        } label: {
            controlGlyph("text.cursor")
        }
        .buttonStyle(.plain)
        .help("Open the current selection")
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    private var attachMenu: some View {
        Menu {
            Button("Upload File") { pickFiles(imagesOnly: false) }
            Button("Upload Photo") { pickFiles(imagesOnly: true) }
            Divider()
            Button("Take Screenshot") { capture(interactive: false) }
            Button("Capture Area") { capture(interactive: true) }
            Button("Capture Text") { captureText() }
        } label: {
            controlGlyph("plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .help("Add context")
    }

    /// The app the question is about, named rather than implied.
    /// In Global Context the leading chip is the top match, not the scope — the same thing
    /// the dock's global bar shows, so three letters and a glance tell the user what Tab
    /// would take.
    private var globalLeadingChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .frame(width: 26, height: 26)
            // The thing the field is pointing at, so the icon answers "what happens if I
            // press Return" without the user reading a row.
            if let icon = model.leadingResultIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .help(model.globalTopMatch.map { "Tab to open \($0.title)" } ?? "Search everything")
    }

    /// The app's current selection, shown because the turn carries it. Read from the same
    /// snapshot the turn is built from, so it cannot promise something the turn will not
    /// send.
    private func selectionChip(_ selection: AppChatSelectionScope) -> some View {
        HStack(spacing: 4) {
            Image(systemName: selection.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(selection.label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
        .transition(.opacity)
        .help("This question will carry the app's current selection")
    }

    /// The scope chip with a way out of it — the "−" the dock's scope chip carries. Only
    /// for a scope entered from Global: the frontmost app's own scope is not something the
    /// user stepped into, so there is nothing to step back from.
    private var scopeChipWithExit: some View {
        HStack(spacing: 6) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(model.appName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Button { model.leaveScopeForGlobal() } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Back to Global Context")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.09), in: Capsule())
        // The scope's name is the subject of everything else in this row, so it keeps its
        // width and the placeholder gives way — truncating it to "F" said nothing at all.
        .layoutPriority(1)
    }

    private var appChip: some View {
        HStack(spacing: 6) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(model.appName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.phase == .suggesting {
            HStack(spacing: 6) {
                Text(AppChatListCard.placeholder(for: model))
                    .foregroundStyle(.secondary.opacity(0.85))
                Text("— press Enter to send…")
                    .foregroundStyle(.secondary.opacity(0.45))
            }
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
        } else {
            Text("\(AppChatListCard.placeholder(for: model))…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    /// What acts on the surface rather than on the question: where it opens, and whether it
    /// stays. Attach and send are in the field itself, because they are part of asking.
    private var surfaceControls: some View {
        HStack(spacing: 8) {
            Button {
                model.openInDock()
            } label: {
                controlGlyph("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open this conversation in the dock")

            Button {
                model.togglePin()
            } label: {
                controlGlyph(model.isPinned ? "pin.fill" : "pin", tinted: model.isPinned)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")
        }
    }

    private func controlGlyph(_ symbol: String, tinted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tinted ? Color.accentColor : .secondary)
            .frame(width: 26, height: 26)
            .background(
                tinted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                in: Circle())
    }

    // MARK: - Attachments

    private func pickFiles(imagesOnly: Bool) {
        for url in ChatAttachmentCapture.pickFiles(imagesOnly: imagesOnly) {
            model.attach(url)
        }
    }

    private func capture(interactive: Bool) {
        ChatAttachmentCapture.captureScreenshot(interactive: interactive) { url in
            model.attach(url)
        }
    }

    private func captureText() {
        ChatAttachmentCapture.captureScreenText { text in
            model.query += model.query.isEmpty ? text : "\n" + text
            model.queryChanged()
        }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments, id: \.self) { url in
                    ChatAttachmentChip(url: url) { model.detach(url) }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: AppChatPromptMetrics.attachmentRowHeight)
    }

    // MARK: - Suggestions

    // MARK: - Conversation

    /// The dock's own message view, so steps, tool chips, receipts and route choices
    /// render here exactly as they do in the dock. Reimplementing it would have been the
    /// same drift this surface was built to avoid.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) {
                        index, message in
                        AIChatMessageView(
                            message: message,
                            isStreaming: model.isAnswering && index == model.messages.count - 1,
                            assistantAvatarImage: appIcon,
                            liveSteps: model.isAnswering && index == model.messages.count - 1
                                ? model.liveSteps : []
                        )
                        .id(message.id)
                    }
                    // The dock draws its activity timeline over exactly this data; the
                    // corner drew a bare spinner over it. A spinner is the app declining
                    // to say what it is doing while it holds the user's question.
                    if model.isAnswering && model.messages.last?.role == .user {
                        LiveAgentProgressView(steps: waitingSteps)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: model.messages.count) { _, _ in
                guard let last = model.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What to show between sending and the first token.
    ///
    /// The steps are the truth when there are any. Before the first one arrives there is
    /// still something honest to say — which app the question went to — and saying it beats
    /// a spinner, which tells the user only that the app is busy with something.
    private var waitingSteps: [String] {
        let steps = model.liveSteps.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard steps.isEmpty else { return steps }
        return ["Reading \(model.appName.isEmpty ? "this app" : model.appName)…"]
    }

    // MARK: - Shrunken

    /// The app's own icon: the corner still says which app this was about.
    private var miniContent: some View {
        Group {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            width: AppChatPromptMetrics.miniSize.width,
            height: AppChatPromptMetrics.miniSize.height)
    }

    private var appIcon: NSImage? {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: model.appBundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
