// CornerChatPresentation.swift
// Context-Dock
//
// Presentation state for the one corner chat shell. The two chat modes keep their own
// models and pipelines; this object only decides which one the shell is showing.

import Combine
import Foundation

enum CornerChatMode: Equatable {
    case frontmostApp
    case general
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

    private var isShowingSomethingToDismiss: Bool {
        switch mode {
        case .general: return generalPhase == .expanded
        case .frontmostApp: return appChat.phase.showsInput
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

    @discardableResult
    func handleLeftArrow(draft: String) -> Bool {
        guard mode == .frontmostApp,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        showGeneral()
        return true
    }

    /// General → the frontmost app's chat, the way `handleLeftArrow` goes the other way.
    /// It returns to the app that is in front now, not the one the trip started from.
    @discardableResult
    func handleRightArrow(draft: String) -> Bool {
        guard mode == .general,
            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let latestTarget
        else { return false }
        showFrontmostApp(target: latestTarget)
        return true
    }

    @discardableResult
    func handleHorizontalSwipe(deltaX: CGFloat, draft: String) -> Bool {
        guard abs(deltaX) > 70,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        if mode == .general {
            guard deltaX < 0 else { return false }
            guard let latestTarget else { return false }
            showFrontmostApp(target: latestTarget)
            return true
        }
        guard deltaX > 0 else { return false }
        showGeneral()
        return true
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
