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
    private var latestTarget: CornerChatTarget?

    let appChat: AppChatPromptModel
    let generalChat: GeneralChatWindowModel

    init(
        appChat: AppChatPromptModel? = nil,
        generalChat: GeneralChatWindowModel? = nil
    ) {
        self.appChat = appChat ?? AppChatPromptModel()
        self.generalChat = generalChat ?? .shared
    }

    func cycle(target: CornerChatTarget) {
        latestTarget = target
        if !isVisible {
            showFrontmostApp(target: target)
        } else if mode == .frontmostApp {
            showGeneral()
        } else {
            showFrontmostApp(target: target)
        }
    }

    func showFrontmostApp(target: CornerChatTarget) {
        latestTarget = target
        mode = .frontmostApp
        isVisible = true
        appChat.summon(
            app: target.name,
            bundleID: target.bundleID,
            suggestions: target.suggestions,
            summary: target.summary)
    }

    @discardableResult
    func handleLeftArrow(draft: String) -> Bool {
        guard mode == .frontmostApp,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        showGeneral()
        return true
    }

    @discardableResult
    func handleHorizontalSwipe(deltaX: CGFloat, draft: String) -> Bool {
        guard abs(deltaX) > 70,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        if mode == .general {
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
        generalChat.reloadFromStore()
        generalChat.openSession(.general, title: "General Chat")
    }

    func dismiss() {
        isVisible = false
        appChat.dismiss()
    }
}
