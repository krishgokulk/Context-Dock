import Combine
import Foundation
import Testing

@testable import Context_Dock

/// The corner prompt: a hotkey opens an input in the shared shell, and it stands down the
/// same way every other corner surface does.
///
/// The pin preference is read from `AppChatPromptModel.pinStore`, which the test script
/// points at a suite of its own. Before that, the host shared the developer's live defaults:
/// a pinned corner on their screen made every model here start pinned, a pinned model
/// ignores `standDown`, and "expected .mini, got .prompt" across three files was filed as
/// an idle-timer flake for weeks.
@MainActor
struct AppChatPromptTests {
    @Test func itShowsNothingUntilTheHotkeyAsksForIt() {
        #expect(AppChatPromptModel().phase == .hidden)
    }

    /// The field opens alone. The app's actions are still there — the arrow keys open them
    /// — but a sheet of 224 rows over a field nobody has typed into was a launch screen,
    /// and the owner asked not to see it (2026-09-16).
    @Test func launchingOpensAsAPlainFieldWithTheSuggestionsBehindTheArrow() {
        let model = AppChatPromptModel()

        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [
                .init(icon: "bolt.fill", title: "New Window", kind: .action),
                .init(icon: "brain", title: "Code", kind: .skill),
            ],
            summary: "5 actions · 2 skills · 1 built-in tools · 3 cli tools")

        #expect(model.phase == .prompt)
        #expect(model.isStandDownArmed)
        #expect(model.appName == "Code")
        // Kept, not dropped: the list is a keystroke away.
        #expect(model.suggestions.count == 2)
        #expect(model.capabilitySummary.hasPrefix("5 actions"))
    }

    @Test func anAppWithNothingToSuggestOpensAsAPlainInput() {
        let model = AppChatPromptModel()

        model.summon(app: "Safari")

        #expect(model.phase == .prompt)
        #expect(model.suggestions.isEmpty)
    }

    /// Typing is attention. A prompt must not vanish mid-sentence.
    @Test func typingPutsTheClockBack() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")

        model.query = "why is this slow"
        model.queryChanged()

        #expect(model.phase == .prompt)
        #expect(model.isStandDownArmed)
    }

    /// Idle shrinks to the app's own icon — the surface stays identifiable as being
    /// about that app rather than becoming a generic dot.
    @Test func anIdlePromptShrinksToTheAppIcon() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari", bundleID: "com.apple.Safari")

        model.standDown()

        #expect(model.phase == .mini)
        #expect(model.appBundleID == "com.apple.Safari")
    }

    /// A half-written question survives the shrink; it is the thing worth keeping.
    @Test func shrinkingKeepsAnUnfinishedQuestion() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "half a question"
        model.queryChanged()

        model.standDown()

        #expect(model.phase == .mini)
        #expect(model.query == "half a question")
    }

    @Test func reachingForTheIconGivesTheQuestionBack() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "half a question"
        model.queryChanged()
        model.standDown()

        model.hoverBegan()

        #expect(model.phase == .prompt)
        #expect(model.query == "half a question")
    }

    /// A list the user arrowed open is the first thing to go when they look away — the
    /// field itself stays one step longer.
    @Test func idlingAwayFromAnOpenListClosesToThePlainFieldFirst() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")
        model.rows = [.action(
            AdapterAction(
                id: "new-window", name: "New Window", icon: "bolt.fill",
                description: "", triggers: [], type: .menubar))]
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.phase == .suggesting)

        model.standDown()

        #expect(model.phase == .prompt)
    }

    /// The icon does nothing to a chat with nothing selected — an in-place view of an
    /// empty selection is a promise the button cannot keep.
    @Test func togglingSelectionScopeDoesNothingWithoutASelection() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari", bundleID: "com.apple.Safari")

        model.toggleSelectionScope()

        #expect(!model.isShowingSelectionScope)
    }

    /// Esc backing out of a selection view that was never open is not this key's meaning —
    /// it has to fall through to whatever else Esc does here.
    @Test func leavingSelectionScopeWithNothingToLeaveIsIgnored() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari", bundleID: "com.apple.Safari")

        #expect(model.leaveSelectionScope() == false)
    }

    /// The arrows are the door, the same one the dock's own hidden results sheet has: they open the list from a plain field, and open it again
    /// after idling closed it.
    @Test func arrowingOpensTheListAndReopensItAfterItClosed() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")
        model.rows = [.action(
            AdapterAction(
                id: "new-window", name: "New Window", icon: "bolt.fill",
                description: "", triggers: [], type: .menubar))]
        #expect(model.phase == .prompt)

        #expect(model.moveMenuFocus(by: 1))
        #expect(model.phase == .suggesting)

        model.standDown()
        #expect(model.phase == .prompt)

        #expect(model.moveMenuFocus(by: 1))
        #expect(model.phase == .suggesting)
    }

    /// Coming back to an untouched prompt gives the field back, the same as it opened —
    /// not a sheet the user did not ask for the first time either.
    @Test func reachingForTheIconWithNothingTypedRestoresThePlainField() {
        let model = AppChatPromptModel()
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")
        // The field opens plain now, so one stand-down is the badge.
        model.standDown()
        #expect(model.phase == .mini)

        model.hoverBegan()

        #expect(model.phase == .prompt)
        #expect(model.suggestions.count == 1)
    }

    @Test func theIconEventuallyGoesToo() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.standDown()

        model.standDown()

        #expect(model.phase == .hidden)
    }

    /// Typing is a question, not a browse: the suggestion list gets out of the way.
    @Test func typingCollapsesTheSuggestionsIntoAPlainInput() {
        let model = AppChatPromptModel()
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")

        model.query = "why"
        model.queryChanged()

        #expect(model.phase == .prompt)
    }

    @Test func clearingTheFieldLeavesItAField() {
        let model = AppChatPromptModel()
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")
        model.query = "why"
        model.queryChanged()

        model.query = ""
        model.queryChanged()

        // Deleting what was typed is not a request to browse.
        #expect(model.phase == .prompt)
    }

    /// The turn belongs to the dock's pipeline, so stopping it is a request, not a reach-in.
    @Test func stoppingAsksTheDockToCancelTheRunningTurn() {
        let conversation = AppChatConversation()
        let model = AppChatPromptModel(conversation: conversation)
        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")
        conversation.isLoading = true

        var asked = false
        let observation = NotificationCenter.default
            .publisher(for: .appChatPromptCancel)
            .sink { _ in asked = true }
        defer { observation.cancel() }

        model.cancelTurn()

        #expect(asked)
    }

    /// Nothing running, nothing to stop — and no notification anyone has to guard against.
    @Test func stoppingIdlyAsksForNothing() {
        let conversation = AppChatConversation()
        let model = AppChatPromptModel(conversation: conversation)
        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")

        var asked = false
        let observation = NotificationCenter.default
            .publisher(for: .appChatPromptCancel)
            .sink { _ in asked = true }
        defer { observation.cancel() }

        model.cancelTurn()

        #expect(!asked)
    }

    /// The two modes are one surface. App mode was pinned at 340 while General grew to 620,
    /// so the same conversation got half the room depending on which scope it was in.
    @Test func bothModesGrowAtTheSameRateToTheSameCeiling() {
        func app(_ messages: Int) -> CGFloat {
            AppChatPromptMetrics.size(for: .chat, suggestions: 0, messages: messages).height
        }
        func general(_ messages: Int) -> CGFloat {
            CornerGeneralChatMetrics.height(
                messageCount: messages, isSending: false,
                hasAttachments: false, slashMatchCount: 0)
        }

        #expect(app(2) - app(1) == general(2) - general(1))
        #expect(app(50) == general(50))
        #expect(app(50) == CornerGeneralChatMetrics.maximumHeight)
    }

    /// An empty conversation still opens at a readable size rather than at the composer.
    @Test func aChatWithNoMessagesKeepsItsOpeningHeight() {
        #expect(
            AppChatPromptMetrics.size(for: .chat, suggestions: 0, messages: 0).height
                == AppChatPromptMetrics.chatHeight)
    }

    /// The dock's pipeline writes that transcript, so the corner asks rather than clearing
    /// it behind the dock's back.
    @Test func startingOverAsksTheDockRatherThanClearingItself() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")
        model.query = "half a question"

        var asked = false
        let observation = NotificationCenter.default
            .publisher(for: .appChatPromptNewChat)
            .sink { _ in asked = true }
        defer { observation.cancel() }

        model.newConversation()

        #expect(asked)
        #expect(model.query.isEmpty)
        #expect(model.phase.showsInput)
    }

    @Test func dismissingClearsTheQuestion() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari")
        model.query = "something"

        model.dismiss()

        #expect(model.phase == .hidden)
        #expect(model.query.isEmpty)
    }

    /// The empty card: run a command, switch app, and the corner showed a full-height
    /// conversation with nothing in it.
    ///
    /// Scope changes are posted to the dock and answered later, so at the moment the app
    /// changes the shared conversation still holds the *outgoing* app's messages. The
    /// prompt read those, went to `.chat`, and then the dock emptied the conversation
    /// underneath it.
    @Test func aChatPhaseWithNoConversationFallsBackToTheField() {
        let conversation = AppChatConversation()
        conversation.messages = [AIChatMessage(role: .user, content: "about Safari")]
        let model = AppChatPromptModel(conversation: conversation)
        model.summon(app: "Safari", bundleID: "com.apple.Safari")

        model.frontmostAppDidChange(
            app: "Code", bundleID: "com.microsoft.VSCode", suggestions: [], summary: "")
        #expect(model.phase == .chat)

        // The dock answers the scope change and the conversation empties.
        conversation.messages = []

        #expect(model.phase != .chat)
    }

    /// Attaching a file is composing a question about it — a list the user had arrowed
    /// open is answering something they have stopped asking, so it closes.
    @Test func attachingAFilePutsAnOpenListAway() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(
            app: "Code", bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")
        model.rows = [.action(
            AdapterAction(
                id: "new-window", name: "New Window", icon: "bolt.fill",
                description: "", triggers: [], type: .menubar))]
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.phase == .suggesting)

        model.attach(URL(fileURLWithPath: "/tmp/shot.png"))
        #expect(model.phase == .prompt)

        // Removing it does not reopen the list: nothing opens the list but the arrows.
        model.detach(URL(fileURLWithPath: "/tmp/shot.png"))
        #expect(model.phase == .prompt)
    }

    /// Attachments were never counted, so pasting a file into App mode drew a row the
    /// card had no room for.
    @Test func theCardMakesRoomForWhatSitsOverTheField() {
        let bare = AppChatPromptMetrics.size(for: .prompt, suggestions: 0).height
        let withFile = AppChatPromptMetrics.size(
            for: .prompt, suggestions: 0, attachments: 1).height
        let withApproval = AppChatPromptMetrics.size(
            for: .prompt, suggestions: 0, hasApproval: true).height

        #expect(withFile == bare + AppChatPromptMetrics.attachmentRowHeight)
        #expect(withApproval > bare)
        // A conversation reserves it too — an approval can arrive mid-answer.
        #expect(
            AppChatPromptMetrics.size(for: .chat, suggestions: 0, messages: 2, hasApproval: true)
                .height
                > AppChatPromptMetrics.size(for: .chat, suggestions: 0, messages: 2).height)
    }

    /// Enter means "ask this", until the user says otherwise with the arrow keys.
    ///
    /// With the first row preselected, typing a question and pressing Enter ran a command
    /// instead of asking it — the list is an offer, and taking it should be something the
    /// user does rather than something that happens because they did not avoid it.
    @Test func enterAsksUnlessTheUserArrowedIntoTheList() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")
        model.rows = [.action(
            AdapterAction(
                id: "new-window", name: "New Window", icon: "bolt.fill",
                description: "", triggers: [], type: .menubar))]

        // Nothing chosen: Enter falls through to the question.
        #expect(model.focusedRow == nil)
        #expect(model.runFocusedRow() == false)

        // Arrowing in chooses the first row, and now Enter takes the offer.
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.focusedRow != nil)
    }

    /// Typing again withdraws the choice: a new list is a new offer.
    @Test func aNewListClearsWhateverWasChosen() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")
        model.rows = [.action(
            AdapterAction(
                id: "new-window", name: "New Window", icon: "bolt.fill",
                description: "", triggers: [], type: .menubar))]
        model.moveMenuFocus(by: 1)
        #expect(model.focusedMenuIndex != nil)

        model.query = "something else"
        model.queryChanged()

        #expect(model.focusedMenuIndex == nil)
    }

    @Test func switchingFrontmostAppKeepsThePromptAndUpdatesItsScope() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Safari", bundleID: "com.apple.Safari")
        model.query = "typed but not sent"

        model.frontmostAppDidChange(
            app: "Code",
            bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions")

        #expect(model.phase == .prompt)
        #expect(model.appName == "Code")
        #expect(model.appBundleID == "com.microsoft.VSCode")
        #expect(model.query.isEmpty)
        #expect(model.suggestions.map(\.title) == ["New Window"])
    }

    /// This is the frontmost app chat: the question is asked and answered here.
    @Test func sendingOpensTheConversationHere() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari", bundleID: "com.apple.Safari")
        model.query = "what changed here"

        _ = model.submit()

        #expect(model.phase == .chat)
        // The runtime notification observer owns the shared transcript. This model owns
        // the hand-off and surface transition, which are synchronous and testable here.
        #expect(model.query.isEmpty)
    }

    /// Opening in the dock is still offered for when the corner is too small.
    @Test func openingInTheDockClosesTheCorner() {
        let model = AppChatPromptModel()
        model.summon(app: "Safari", bundleID: "com.apple.Safari")

        model.openInDock()

        #expect(model.phase == .hidden)
    }
}

// MARK: - Controls

@MainActor
struct AppChatControlsTests {
    private func opened() -> AppChatPromptModel {
        let model = AppChatPromptModel()
        model.summon(app: "Code", bundleID: "com.microsoft.VSCode")
        return model
    }

    /// Pinning writes a real UserDefaults key so the preference survives a relaunch — one
    /// process, one shared domain, so a value left over from an earlier test (or an earlier
    /// run of the app itself on this machine) would otherwise leak into the next model
    /// constructed. Started at a known value and put back exactly as found, the same way
    /// DoraXTurnLogTests isolates its own real default.
    private func resetPinDefault() -> Bool {
        let previous = AppChatPromptModel.pinStore.bool(forKey: AppChatPromptModel.pinnedDefaultsKey)
        AppChatPromptModel.pinStore.set(false, forKey: AppChatPromptModel.pinnedDefaultsKey)
        return previous
    }

    /// Pinning is the user saying "stay". Nothing times it out after that.
    @Test func pinningStopsTheStandDown() {
        let previous = resetPinDefault()
        defer { AppChatPromptModel.pinStore.set(previous, forKey: AppChatPromptModel.pinnedDefaultsKey) }
        let model = opened()

        model.togglePin()

        #expect(model.isPinned)
        #expect(!model.isStandDownArmed)
    }

    @Test func aPinnedPromptIgnoresTheClockEntirely() {
        let previous = resetPinDefault()
        defer { AppChatPromptModel.pinStore.set(previous, forKey: AppChatPromptModel.pinnedDefaultsKey) }
        let model = opened()
        model.togglePin()

        model.standDown()

        #expect(model.phase != .hidden)
        #expect(model.phase != .mini)
    }

    @Test func unpinningPutsTheClockBack() {
        let previous = resetPinDefault()
        defer { AppChatPromptModel.pinStore.set(previous, forKey: AppChatPromptModel.pinnedDefaultsKey) }
        let model = opened()
        model.togglePin()

        model.togglePin()

        #expect(!model.isPinned)
        #expect(model.isStandDownArmed)
    }

    /// Sending is a real hand-off now, so it reports true — unlike before, when nothing
    /// was sent and the prompt had to say so.
    @Test func sendingReportsThatItWentSomewhere() {
        let model = opened()
        model.query = "why is this slow"

        #expect(model.submit())
    }

    /// A second Enter while the first is still running must not start a second turn.
    @Test func askingAgainMidAnswerIsIgnored() {
        let model = opened()
        AppChatConversation.shared.isLoading = true
        defer { AppChatConversation.shared.isLoading = false }
        model.query = "second"

        #expect(!model.submit())
    }

    /// The corner is another view of the dock conversation. A dock-side update must
    /// invalidate this model so SwiftUI redraws the transcript and live activity.
    @Test func sharedConversationUpdatesRefreshTheCorner() {
        let model = opened()
        var didRefresh = false
        let observation = model.objectWillChange.sink { didRefresh = true }
        defer { observation.cancel() }

        AppChatConversation.shared.liveSteps = ["Checking capabilities"]
        defer { AppChatConversation.shared.liveSteps = [] }

        #expect(didRefresh)
        #expect(model.liveSteps == ["Checking capabilities"])
    }

    @Test func dockRouteTraceFeedsTheSharedCornerActivity() {
        var state = L2State()

        state.routerTrace = ["Planning the minimum evidence route"]
        defer { state.routerTrace = [] }

        #expect(
            AppChatConversation.shared.liveSteps
                == ["Planning the minimum evidence route"])
    }

    @Test func sendingAnEmptyQuestionDoesNothing() {
        let model = opened()

        let sent = model.submit()

        #expect(!sent)
        #expect(model.phase != .hidden)
    }

    /// Conversation history does not make the corner immortal. Leaving it lets the same
    /// idle lifecycle as the launch suggestions shrink it back to the app icon.
    @Test func aConversationShrinksAfterThePointerLeaves() {
        let model = opened()
        model.query = "a question"
        _ = model.submit()

        model.hoverEnded()
        model.standDown()

        #expect(model.phase == .mini)
    }

    @Test func aConversationStaysOpenWhileThePointerIsInside() {
        let model = opened()
        model.query = "a question"
        _ = model.submit()
        model.hoverBegan()

        model.standDown()

        #expect(model.phase == .chat)
    }

    @Test func comingBackToAConversationReopensIt() {
        let model = opened()
        model.query = "a question"
        _ = model.submit()
        model.standDown()

        model.hoverBegan()

        #expect(model.phase == .chat)
    }

    @Test func attachmentsAreListedAndRemovable() {
        let model = opened()
        let file = URL(fileURLWithPath: "/tmp/shot.png")

        model.attach(file)
        #expect(model.attachments == [file])

        model.detach(file)
        #expect(model.attachments.isEmpty)
    }

    @Test func attachingTheSameFileTwiceKeepsOneCopy() {
        let model = opened()
        let file = URL(fileURLWithPath: "/tmp/shot.png")

        model.attach(file)
        model.attach(file)

        #expect(model.attachments.count == 1)
    }

    @Test func dismissingDropsTheAttachmentsAndThePin() {
        let previous = resetPinDefault()
        defer { AppChatPromptModel.pinStore.set(previous, forKey: AppChatPromptModel.pinnedDefaultsKey) }
        let model = opened()
        model.attach(URL(fileURLWithPath: "/tmp/shot.png"))
        model.togglePin()

        model.dismiss()

        #expect(model.attachments.isEmpty)
        #expect(!model.isPinned)
    }

    // MARK: - Pin persists across a relaunch

    /// A relaunch constructs a brand new model with nothing carried over except what was
    /// explicitly written down — this is the only thing that should be.
    @Test func aFreshModelStartsPinnedIfThatWasLastSetTrue() {
        let previous = resetPinDefault()
        defer { AppChatPromptModel.pinStore.set(previous, forKey: AppChatPromptModel.pinnedDefaultsKey) }
        AppChatPromptModel.pinStore.set(true, forKey: AppChatPromptModel.pinnedDefaultsKey)

        let model = AppChatPromptModel()

        #expect(model.isPinned)
    }

    @Test func aFreshModelStartsUnpinnedIfThatWasLastSetFalse() {
        let previous = resetPinDefault()
        defer { AppChatPromptModel.pinStore.set(previous, forKey: AppChatPromptModel.pinnedDefaultsKey) }

        let model = AppChatPromptModel()

        #expect(!model.isPinned)
    }

    /// The toggle is what writes the preference down — not standing down, not dismissing,
    /// both of which change the in-memory flag for reasons that have nothing to do with the
    /// user changing their mind about whether this should always start pinned.
    @Test func togglingIsWhatPersistsNotIdlingOrDismissing() {
        let previous = resetPinDefault()
        defer { AppChatPromptModel.pinStore.set(previous, forKey: AppChatPromptModel.pinnedDefaultsKey) }
        let model = opened()

        model.togglePin()
        #expect(AppChatPromptModel.pinStore.bool(forKey: AppChatPromptModel.pinnedDefaultsKey))

        model.dismiss()
        // dismiss() clears the in-memory flag for this appearance — a fact about this
        // session, not the user rescinding the preference they just stated.
        #expect(AppChatPromptModel.pinStore.bool(forKey: AppChatPromptModel.pinnedDefaultsKey))
    }
}
