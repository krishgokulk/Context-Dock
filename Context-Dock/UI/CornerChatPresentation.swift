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
        if !isVisible {
            showFrontmostApp(target: target)
        } else if mode == .frontmostApp {
            mode = .general
            generalChat.reloadFromStore()
        } else {
            showFrontmostApp(target: target)
        }
    }

    func showFrontmostApp(target: CornerChatTarget) {
        mode = .frontmostApp
        isVisible = true
        appChat.summon(
            app: target.name,
            bundleID: target.bundleID,
            suggestions: target.suggestions,
            summary: target.summary)
    }

    func dismiss() {
        isVisible = false
        appChat.dismiss()
    }
}
