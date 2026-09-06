import SwiftUI

@MainActor
struct CornerGeneralChatSnapshot {
    let draft: String
    let attachmentNames: [String]
    let slashApps: [ChatAppEntry]

    init(model: GeneralChatWindowModel) {
        draft = model.input
        attachmentNames = model.attachments.map(\.lastPathComponent)
        slashApps = ChatSlashAppPicker.matches(for: model.input)
    }

    @discardableResult
    static func pickLeadingSlashApp(in model: GeneralChatWindowModel) -> Bool {
        ChatSlashAppPicker.pickLeadingMatch(text: &model.input) { match in
            model.attachApp(match.name)
        }
    }
}

enum CornerGeneralChatMetrics {
    /// The composer row, matched to App mode's `inputHeight` deliberately. The two modes
    /// are one surface: a General composer that stands taller than the App one makes the
    /// switch between them look like the window changed rather than the scope.
    static var composerRowHeight: CGFloat { AppChatPromptMetrics.inputHeight }
    static var attachmentRowHeight: CGFloat { AppChatPromptMetrics.attachmentRowHeight }
    static let dividerHeight: CGFloat = 1
    /// Nothing typed, nothing said: the row on its own, exactly as App mode rests.
    static var compactHeight: CGFloat { composerRowHeight }
    static let maximumHeight: CGFloat = 620
    /// What one exchange is worth. Named because App mode reads it too: the two modes are
    /// one surface and have to grow at the same rate, or the same conversation gets more
    /// room in one scope than the other.
    static let perMessageHeight: CGFloat = 90
    /// The transcript's own room before any messages are counted.
    static let transcriptBaseHeight: CGFloat = 220
    /// One live step: the row plus the spacing under it. Counted while a turn runs so the
    /// steps have somewhere to appear — a card sized for a single status line shows the
    /// work as a scrollbar instead of as progress.
    static let liveStepHeight: CGFloat = 22
    /// Past this the turn is long enough that the steps scroll rather than grow the card
    /// over the user's work.
    static let maximumCountedLiveSteps = 4

    static func height(
        messageCount: Int,
        isSending: Bool,
        hasAttachments: Bool,
        slashMatchCount: Int,
        showsStarter: Bool = false,
        starterCount: Int = 0,
        starterHasConnections: Bool = false,
        liveStepCount: Int = 0,
        clarificationOptionCount: Int = 0
    ) -> CGFloat {
        if messageCount > 0 || isSending {
            let steps = isSending
                ? CGFloat(min(liveStepCount, maximumCountedLiveSteps)) * liveStepHeight
                : 0
            // A question with options is a control, not text: it needs its own room, or the
            // card asks something the user has to scroll to answer.
            let clarification = clarificationOptionCount > 0
                ? ChatClarificationCard.height(for: clarificationOptionCount)
                : 0
            return min(
                maximumHeight,
                transcriptBaseHeight + CGFloat(min(messageCount, 5)) * perMessageHeight
                    + steps + clarification)
        }
        if showsStarter {
            // Measured from the start screen's own numbers rather than guessed. A flat 350
            // held 234 points of content, and the 116 points of slack read as a card that
            // could not decide what it was for.
            return min(
                maximumHeight,
                compactHeight
                    + GeneralChatStartView.Metrics.compactHeight(
                        starters: starterCount, hasConnections: starterHasConnections))
        }
        // The `/` matches stack above the composer as their own list, so the card has to
        // carry their exact height — one row's worth per match, capped, plus the rule
        // between the list and the field.
        var result = compactHeight
        if slashMatchCount > 0 {
            result += ChatSlashAppList.height(for: slashMatchCount) + dividerHeight
        }
        if hasAttachments { result += attachmentRowHeight }
        return result
    }

    /// The one definition of "nothing has happened in this chat yet", read by the view that
    /// draws the starter and the metrics that size it. Two copies of this condition is a
    /// card sized for one state showing another.
    @MainActor
    static func showsStarter(for model: GeneralChatWindowModel) -> Bool {
        model.activeScope == .general
            && model.messages.isEmpty
            && !model.isSending
            && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.attachments.isEmpty
    }

    /// The options the newest answer is offering, if it is offering any and the user has
    /// not started typing over them.
    @MainActor
    static func clarificationOptionCount(for model: GeneralChatWindowModel) -> Int {
        guard !model.isSending, model.input.isEmpty,
            let last = model.messages.last, last.role == .assistant, !last.isError,
            let clarification = ChatClarification.parse(last.content)
        else { return 0 }
        return clarification.options.count
    }

    @MainActor
    static func size(for model: GeneralChatWindowModel) -> CGSize {
        let slashMatches = ChatSlashAppPicker.matches(for: model.input)
        let connected = AppAdapterManager.shared.adapters.filter(\.isEnabled)
        return CGSize(
            width: CornerDockLayout.cardWidth,
            height: height(
                messageCount: model.messages.count,
                isSending: model.isSending,
                hasAttachments: !model.attachments.isEmpty,
                slashMatchCount: slashMatches.count,
                showsStarter: showsStarter(for: model),
                starterCount: connected.count,
                starterHasConnections: !connected.isEmpty,
                liveStepCount: model.activeProgress.count,
                clarificationOptionCount: clarificationOptionCount(for: model)))
    }
}

struct CornerGeneralChatView: View {
    @ObservedObject var model: GeneralChatWindowModel
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var keyboardState = CornerDockController.shared.keyboardState
    @FocusState private var composerFocused: Bool
    /// Which `/` match ↑/↓ has landed on. Reset whenever the filter changes, because the
    /// third row of one list is not the third row of the next.
    @State private var slashSelection = 0
    /// Which option ↑/↓ has landed on in a clarifying question. Separate from the slash
    /// selection: the two lists never show at once, but sharing one index would make the
    /// highlight jump when the user typed after being asked something.
    @State private var clarificationSelection = 0

    private var size: CGSize { CornerGeneralChatMetrics.size(for: model) }
    private var showsTranscript: Bool { !model.messages.isEmpty || model.isSending }
    private var showsStarter: Bool { CornerGeneralChatMetrics.showsStarter(for: model) }

    var body: some View {
        VStack(spacing: 0) {
            if showsTranscript {
                header
                Divider().opacity(0.18)
                transcript
                // `.chatWindow` is non-nil only while the General Chat *window* is frontmost,
                // so in the corner this card never appeared and a question raised by a
                // corner turn had nowhere to be answered.
                if let request = approvals.pending(for: .corner) {
                    ApprovalCard(request: request)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            } else if showsStarter {
                GeneralChatStartView(
                    onPick: { prompt in
                        model.input = prompt
                        model.send()
                    },
                    compact: true
                )
                // Fades only. The card's own height is already animating underneath it, and
                // a slide inside a resize is two motions describing one change.
                .transition(.opacity)
            }
            composer
        }
        .frame(width: size.width, height: size.height)
        .background(GlassBackground(cornerRadius: 22, isDark: true))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        .onChange(of: keyboardState.focusRequestToken) { _, _ in composerFocused = true }
        .onChange(of: model.input) { _, _ in
            CornerDockController.shared.chatPresentation.composerInteracted()
            // The filter narrows as you type, so the row under the highlight is a
            // different app from one keystroke to the next. Start from the top again.
            slashSelection = 0
        }
        // One animation for the whole card. Two — a spring on the height and an ease on the
        // starter — ran against each other every time the starter appeared, which is the
        // stutter the resize looked like it had.
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: size.height)
    }

    /// Who the chat is with, and what to do with the chat itself.
    ///
    /// Scope leads: once the thread is about Messages, the Messages icon is the truer
    /// answer to "what am I looking at" than the provider mark, and it was being stated
    /// twice — as a chip down in the composer and nowhere the eye starts.
    private var header: some View {
        HStack(spacing: 8) {
            let members = membershipAppNames
            if !members.isEmpty {
                // Every member gets its icon: a combined chat is one conversation with two
                // apps in it, and which two is the first thing worth knowing about it.
                HStack(spacing: -5) {
                    ForEach(members.prefix(3), id: \.self) { name in
                        if let icon = AppContextPicker.icon(forAppNamed: name) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1))
                        }
                    }
                }
                .help(
                    members.count == 1
                        ? "This chat is scoped to \(members[0])"
                        : "This chat is with \(members.joined(separator: " + "))")

                Text(headerTitle(for: members))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                AIProviderIcon(provider: AppSettings.shared.selectedAIProvider, size: 18)
                Text(AppSettings.shared.selectedAIProvider.shortName)
                    .font(.system(size: 14, weight: .semibold))
            }

            Text("General Chat")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 6)

            Button { GeneralChatWindowController.shared.show() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in General Chat")

            // Beside expand, because both are about this card rather than this question.
            Button {
                CornerDockController.shared.chatPresentation.toggleGeneralPin()
            } label: {
                let pinned = CornerDockController.shared.chatPresentation.isGeneralPinned
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        pinned ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle()
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                CornerDockController.shared.chatPresentation.isGeneralPinned
                    ? "Unpin" : "Keep this open")
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
    }

    /// The app this thread is about, if it is about one.
    private var scopedAppName: String? {
        model.activeScopeAppName ?? model.scopeAppNames.first
    }

    /// Names for the header: both when two fit, a count past that.
    private func headerTitle(for members: [String]) -> String {
        switch members.count {
        case 0: return ""
        case 1: return members[0]
        case 2: return members.joined(separator: " + ")
        default: return "\(members[0]) + \(members.count - 1) more"
        }
    }

    /// Every app this conversation is with.
    ///
    /// A combined chat is the cross-app power of this surface, and the header used to name
    /// only the first member — so Messages + Code read as a chat with Messages, and the
    /// second app the user deliberately attached was invisible at the place the eye starts.
    private var membershipAppNames: [String] {
        let names = model.currentMembership
        guard names.isEmpty else { return names }
        return scopedAppName.map { [$0] } ?? []
    }

    /// The steps are the truth when there are any. Before the first one arrives there is
    /// still something honest to say — who the question went to — and saying it beats a
    /// spinner, which reports only that the app is busy.
    private var waitingSteps: [String] {
        let steps = model.activeProgress.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard steps.isEmpty else { return steps }
        if let status = model.activeStatus, !status.isEmpty { return [status] }
        let members = membershipAppNames
        return members.isEmpty
            ? ["Thinking…"]
            : ["Reading \(members.joined(separator: " and "))…"]
    }

    /// The question the last answer asked, if it asked one.
    ///
    /// Only the newest message, and only when the turn has finished: an older question has
    /// already been answered, and one still being written is not a question yet.
    private var clarification: ChatClarification? {
        guard !model.isSending,
            let last = model.messages.last,
            last.role == .assistant,
            !last.isError
        else { return nil }
        return ChatClarification.parse(last.content)
    }

    /// Answering by pointing sends what the option says, so the next turn reads a request
    /// rather than a number whose list it can no longer see.
    private func answer(_ option: ChatClarification.Option) {
        guard let clarification else { return }
        model.input = clarification.reply(for: option)
        clarificationSelection = 0
        model.send()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        AIChatMessageView(
                            message: message,
                            onEnableApp: { model.enableApp($0) },
                            onPickAction: { model.pickRoute($0) },
                            liveSteps: message.id == model.messages.last?.id
                                ? model.activeProgress : [])
                            .id(message.id)
                    }
                    // The same step list App mode shows, in the same card.
                    //
                    // General drew one status line here while the frontmost-app chat, two
                    // inches away in the same corner, showed every step it had taken. Both
                    // read the same published progress; only this one was throwing it away,
                    // so the surface that could explain itself least was the one asked the
                    // broadest questions.
                    if model.isSending {
                        LiveAgentProgressView(steps: waitingSteps)
                            .id("live-progress")
                    }
                }
                .padding(15)
            }
            .onChange(of: model.messages.count) { _, _ in
                guard let last = model.messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// The same single row App mode shows, in the same card, at the same height.
    ///
    /// It used to be the shared capsule inside a 12-point inset inside the pill — a border
    /// within a border, and 16 points taller than the App composer for a row holding the
    /// same things. The bar is the row now; the pill is the only chrome.
    private var slashMatches: [ChatAppEntry] {
        ChatSlashAppPicker.matches(for: model.input)
    }

    private func pick(_ app: ChatAppEntry) {
        model.attachApp(app.name)
        model.input = ""
        slashSelection = 0
    }

    /// ↑/↓ move the highlight, and only while there is a list to move it through — the key
    /// has to go back to the field otherwise, or the cursor stops working in a text box.
    private func moveSlashSelection(_ delta: Int) -> Bool {
        if let next = ChatSlashAppPicker.movedSelection(
            from: slashSelection, by: delta, count: slashMatches.count)
        {
            slashSelection = next
            return true
        }
        // The same rule for a clarifying question, and only while the field is empty —
        // once the user is typing their own answer the arrows belong to the cursor.
        guard model.input.isEmpty, let clarification,
            let next = ChatSlashAppPicker.movedSelection(
                from: clarificationSelection, by: delta, count: clarification.options.count)
        else { return false }
        clarificationSelection = next
        return true
    }

    /// Escape unwinds what the user built, one layer per press, and only closes the corner
    /// once there is nothing left to undo. Before this there was no key handling here at
    /// all: an open General chat could not be escaped, only clicked or hotkeyed away.
    private func handleEscape() -> Bool {
        if !slashMatches.isEmpty {
            model.input = ""
            slashSelection = 0
            return true
        }
        if !model.input.isEmpty {
            model.input = ""
            return true
        }
        if model.isSending {
            model.cancel()
            return true
        }
        CornerDockController.shared.chatPresentation.dismiss()
        return true
    }

    private func commitSlashSelection() -> Bool {
        let matches = slashMatches
        if !matches.isEmpty {
            pick(matches[min(max(slashSelection, 0), matches.count - 1)])
            return true
        }
        guard model.input.isEmpty, let clarification, !clarification.options.isEmpty
        else { return false }
        let index = min(max(clarificationSelection, 0), clarification.options.count - 1)
        answer(clarification.options[index])
        return true
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The picker is a sheet over the field, not a control inside it: the same
            // shape the clipboard panel uses, list above and input below.
            if !slashMatches.isEmpty {
                ChatSlashAppList(matches: slashMatches, selection: slashSelection) { app in
                    pick(app)
                }
                Divider().opacity(0.18)
            } else if let clarification, model.input.isEmpty {
                // Typing replaces the card: the composer is the answer the model did not
                // think of, and a list of its own guesses on top of that reads as a wall.
                ChatClarificationCard(
                    clarification: clarification,
                    selection: clarificationSelection,
                    onChoose: { answer($0) },
                    onSomethingElse: { composerFocused = true })
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }

            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments, id: \.self) { url in
                            ChatAttachmentChip(url: url) {
                                model.attachments.removeAll { $0 == url }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: CornerGeneralChatMetrics.attachmentRowHeight)
            }
            AIComposerBar(
                text: $model.input,
                isSending: model.isSending,
                // Said once. With a header up, the scope is named there; the chip down
                // here was the same fact in a second place.
                attachedAppNames: showsTranscript ? [] : model.scopeAppNames,
                onAttachFile: { model.attachFiles() },
                onAttachApp: { model.attachApp($0) },
                onSubmit: {
                    if !CornerGeneralChatSnapshot.pickLeadingSlashApp(in: model) {
                        model.send()
                    }
                },
                extraAttachMenu: {
                    AnyView(Group {
                        Button("Upload Photo") { model.attachFiles(imagesOnly: true) }
                        Button("Chat with a Folder…") { model.attachFolder() }
                        Divider()
                        Button("Take Screenshot") { model.captureScreenshot(interactive: false) }
                        Button("Capture Area") {
                            model.captureScreenshot(interactive: true, windowFirst: true)
                        }
                        Button("Capture Text") { model.captureScreenText() }
                    })
                },
                showsProviderName: true,
                onClear: model.isEmpty ? nil : { model.clearActiveThread() },
                onRemoveApp: { model.removeApp($0) },
                onPasteImages: { urls in
                    model.attachments.append(contentsOf: urls.filter {
                        !model.attachments.contains($0)
                    })
                },
                onEmptyLeftArrow: { false },
                // App Chat arrows into General; General has to arrow back, or the keyboard
                // is a one-way door and only the mouse can undo the trip.
                onEmptyRightArrow: {
                    CornerDockController.shared.chatPresentation.handleRightArrow(
                        draft: model.input)
                },
                onEscape: { handleEscape() },
                onStop: model.isSending ? { model.cancel() } : nil,
                onMoveSelection: { moveSlashSelection($0) },
                onCommitSelection: { commitSlashSelection() },
                usesInlineAppPicker: true,
                // Pin lives in the header once there is one; the bare composer has no
                // header, so it keeps its own.
                isPinned: showsTranscript
                    ? false : CornerDockController.shared.chatPresentation.isGeneralPinned,
                onTogglePin: showsTranscript
                    ? nil
                    : { CornerDockController.shared.chatPresentation.toggleGeneralPin() },
                rendersSlashMatches: false,
                drawsChrome: false)
                .frame(height: CornerGeneralChatMetrics.composerRowHeight)
                .focused($composerFocused)
                .simultaneousGesture(TapGesture().onEnded {
                    CornerDockController.shared.requestComposerFocus()
                })
        }
        .onChange(of: composerFocused) { _, focused in
            CornerDockController.shared.chatPresentation.setGeneralComposerFocused(focused)
        }
    }
}

struct CornerGeneralChatMini: View {
    var body: some View {
        HStack(spacing: 7) {
            AIProviderIcon(provider: AppSettings.shared.selectedAIProvider, size: 20)
            Text("AI")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(
            width: AppChatPromptMetrics.miniSize.width,
            height: AppChatPromptMetrics.miniSize.height)
        .background(GlassBackground(cornerRadius: 22, isDark: true))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
    }
}
