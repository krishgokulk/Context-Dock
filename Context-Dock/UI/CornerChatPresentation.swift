// CornerChatPresentation.swift
// Context-Dock
//
// Presentation state for the one corner chat shell. The two chat modes keep their own
// models and pipelines; this object only decides which one the shell is showing.

import Combine
import Foundation

enum CornerChatMode: Equatable {
    case frontmostApp
    /// Everything running, not one app: the machine's menus and actions, ranked together.
    /// Between the two chats deliberately — it is the frontmost app's scope widened, not a
    /// different conversation.
    case globalContext
    case general

    /// The order the scopes are walked in, left to right.
    static let walk: [CornerChatMode] = [.general, .globalContext, .frontmostApp]

    /// The scope `delta` steps away, or nil at either end. The walk does not wrap: running
    /// off the end and reappearing on the other side reads as the surface losing its place.
    static func step(from current: CornerChatMode, by delta: Int) -> CornerChatMode? {
        guard let index = walk.firstIndex(of: current) else { return nil }
        let next = index + delta
        guard walk.indices.contains(next) else { return nil }
        return walk[next]
    }
}

enum CornerGeneralPhase: Equatable {
    case expanded
    case mini
}

struct CornerChatTarget: Equatable {
    let name: String
    let bundleID: String
    let suggestions: [AppChatSuggestion]
    let summary: String

    init(
        name: String,
        bundleID: String,
        suggestions: [AppChatSuggestion] = [],
        summary: String = ""
    ) {
        self.name = name
        self.bundleID = bundleID
        self.suggestions = suggestions
        self.summary = summary
    }
}

@MainActor
final class CornerChatPresentation: ObservableObject {
    static let shared = CornerChatPresentation()

    @Published private(set) var mode: CornerChatMode = .frontmostApp
    @Published private(set) var isVisible = false
    @Published private(set) var generalPhase: CornerGeneralPhase = .expanded
    @Published private(set) var isGeneralPinned = false
    private var latestTarget: CornerChatTarget?
    private var generalStandDownTask: Task<Void, Never>?
    private var isGeneralPointerInside = false
    private var isGeneralComposerFocused = false
    private var sinks: Set<AnyCancellable> = []

    let appChat: AppChatPromptModel
    let generalChat: GeneralChatWindowModel

    init(
        appChat: AppChatPromptModel? = nil,
        generalChat: GeneralChatWindowModel? = nil
    ) {
        self.appChat = appChat ?? AppChatPromptModel()
        self.generalChat = generalChat ?? .shared

        // App mode runs its own clock: the pill shrinks to the badge and then hides itself.
        // This object was never told, so `isVisible` stayed true for a pill that had gone —
        // and the shell kept drawing an empty card in the corner, sized for a badge that
        // was no longer in it, still answering the mouse. Follow the pill out.
        self.appChat.$phase
            .sink { [weak self] phase in
                guard let self, self.mode == .frontmostApp, phase == .hidden else { return }
                self.isVisible = false
            }
            .store(in: &sinks)
    }

    /// The corner hotkey, pressed again.
    ///
    /// It only ever summoned, so the key that opened the corner could not close it and the
    /// only way out was to wait for the idle clock. Pressing it while the chat is up puts
    /// it away; pressing it while the chat has already shrunk to its badge brings it back,
    /// because a badge is the surface on its way out rather than the surface.
    func cycle(target: CornerChatTarget) {
        latestTarget = target
        if isVisible, isShowingSomethingToDismiss {
            dismiss()
            return
        }
        showFrontmostApp(target: target)
    }

    /// A conversation is on screen in the corner — not a resting composer, not a badge.
    /// What decides whether an approval raised by a corner turn is drawn here.
    var isShowingConversation: Bool {
        guard isVisible else { return false }
        switch mode {
        case .general:
            return generalPhase == .expanded
                && (!generalChat.messages.isEmpty || generalChat.isSending)
        case .frontmostApp, .globalContext:
            return appChat.phase == .chat
        }
    }

    private var isShowingSomethingToDismiss: Bool {
        switch mode {
        case .general: return generalPhase == .expanded
        case .frontmostApp, .globalContext: return appChat.phase.showsInput
        }
    }

    func showFrontmostApp(target: CornerChatTarget) {
        latestTarget = target
        cancelGeneralStandDown()
        mode = .frontmostApp
        isVisible = true
        appChat.summon(
            app: target.name,
            bundleID: target.bundleID,
            suggestions: target.suggestions,
            summary: target.summary)
        // Tell the dock what this corner session is about the moment it opens, not when the
        // first question is asked. The dock is what tracks the target app's live selection
        // and folder, and it only does so for a scope it has been given — so a corner
        // session that announced itself late asked its first Finder question blind.
        NotificationCenter.default.post(
            name: .appChatPromptScopeChanged,
            object: nil,
            userInfo: ["appName": target.name, "bundleId": target.bundleID])
    }

    /// Open the app chat so an answer asked from another corner surface has somewhere to
    /// appear, and tell it one is coming.
    ///
    /// Selection Scope asks its question through the same pipeline the app chat renders. It
    /// used to post the question and hide itself, leaving the answer to land in a surface
    /// that was not on screen — from the user's side, Return did nothing at all.
    func presentAnswer(forSelectionIn appName: String, bundleID: String) {
        showFrontmostApp(
            target: CornerChatTarget(
                name: appName, bundleID: bundleID, suggestions: [], summary: ""))
        appChat.expectAnswer()
    }

    @discardableResult
    func handleLeftArrow(draft: String) -> Bool {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let next = CornerChatMode.step(from: mode, by: -1)
        else { return false }
        show(next)
        return true
    }

    /// General → the frontmost app's chat, the way `handleLeftArrow` goes the other way.
    /// It returns to the app that is in front now, not the one the trip started from.
    @discardableResult
    func handleRightArrow(draft: String) -> Bool {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let next = CornerChatMode.step(from: mode, by: 1)
        else { return false }
        show(next)
        return true
    }

    /// Show a scope by name, from an arrow walk or a hotkey.
    ///
    /// Returning to the app scope goes to the app that is in front *now*, not the one the
    /// trip started from — the walk is through scopes, not through history.
    func show(_ next: CornerChatMode) {
        switch next {
        case .general: showGeneral()
        case .globalContext: showGlobalContext()
        case .frontmostApp:
            guard let latestTarget else { return }
            showFrontmostApp(target: latestTarget)
        }
    }

    /// A swipe walks the same scopes the arrows do, one step per swipe.
    ///
    /// It used to jump straight between the two chats, which was the whole walk when there
    /// were only two. With Global Context between them, a gesture that skipped it would
    /// disagree with the arrow keys about what sits next to what.
    @discardableResult
    func handleHorizontalSwipe(deltaX: CGFloat, draft: String) -> Bool {
        guard abs(deltaX) > 70,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let next = CornerChatMode.step(from: mode, by: deltaX > 0 ? -1 : 1)
        else { return false }
        show(next)
        return true
    }

    /// A question asked from the clip preview: General is already answering it, so the
    /// corner has to be showing General rather than whatever it was showing before.
    /// Everything running, in the same field the app scope uses.
    ///
    /// Global Context is the frontmost app's scope widened to the machine, so it reuses that
    /// surface rather than introducing a third one — the chip says which scope is answering
    /// and the list underneath changes accordingly.
    func showGlobalContext() {
        cancelGeneralStandDown()
        mode = .globalContext
        isVisible = true
        appChat.summonGlobalContext()
    }

    func showGeneralFromPreview() {
        showGeneral()
    }

    private func showGeneral() {
        mode = .general
        isVisible = true
        generalPhase = .expanded
        generalChat.reloadFromStore()
        generalChat.openSession(.general, title: "General Chat")
        armGeneralStandDown(after: AppChatPromptModel.idleDwell)
    }

    func composerInteracted() {
        guard mode == .general else { return }
        generalPhase = .expanded
        armGeneralStandDown(after: AppChatPromptModel.idleDwell)
    }

    func toggleGeneralPin() {
        isGeneralPinned.toggle()
        if isGeneralPinned {
            cancelGeneralStandDown()
        } else {
            armGeneralStandDown(after: AppChatPromptModel.idleDwell)
        }
    }

    func setGeneralComposerFocused(_ focused: Bool) {
        isGeneralComposerFocused = focused
        if focused {
            generalPhase = .expanded
            cancelGeneralStandDown()
        } else if !isGeneralPointerInside && !isGeneralPinned {
            armGeneralStandDown(after: AppChatPromptModel.idleDwell)
        }
    }

    func hoverBegan() {
        if mode == .general {
            isGeneralPointerInside = true
            generalPhase = .expanded
            cancelGeneralStandDown()
        } else {
            appChat.hoverBegan()
        }
    }

    func hoverEnded() {
        if mode == .general {
            isGeneralPointerInside = false
            armGeneralStandDown(after: AppChatPromptModel.idleDwell)
        } else {
            appChat.hoverEnded()
        }
    }

    func standDown() {
        guard mode == .general, isVisible, !isGeneralPointerInside,
              !isGeneralComposerFocused, !isGeneralPinned
        else { return }
        guard !generalChat.isSending else {
            armGeneralStandDown(after: AppChatPromptModel.idleDwell)
            return
        }
        switch generalPhase {
        case .expanded:
            generalPhase = .mini
            armGeneralStandDown(after: AppChatPromptModel.miniDwell)
        case .mini:
            dismiss()
        }
    }

    private func armGeneralStandDown(after delay: TimeInterval) {
        cancelGeneralStandDown()
        generalStandDownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.standDown()
        }
    }

    private func cancelGeneralStandDown() {
        generalStandDownTask?.cancel()
        generalStandDownTask = nil
    }

    func dismiss() {
        cancelGeneralStandDown()
        isVisible = false
        generalPhase = .expanded
        isGeneralPinned = false
        isGeneralComposerFocused = false
        appChat.dismiss()
    }
}
