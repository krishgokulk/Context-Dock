// AppChatPromptModel.swift
// Context-Dock
//
// Ask the frontmost app something without leaving it: a hotkey puts an input field in the
// corner shell, alongside the clipboard and the shelf.
//
// The surface is built; what it does with the question is not. `submit()` deliberately
// reports that it sent nothing rather than pretending, so nothing downstream can mistake
// this for a working route.

import Combine
import Foundation

/// One thing the frontmost app can do, offered before the user has typed anything.
struct AppChatSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case action
        case skill
        case tool
    }

    let icon: String
    let title: String
    let kind: Kind
    var id: String { "\(title)-\(icon)" }
}

enum AppChatPromptPhase: Equatable {
    case hidden
    /// Shrunk to the frontmost app's own icon, holding whatever was typed.
    case mini
    /// The input field alone: the user is writing a question.
    case prompt
    /// The input plus what this app can do, which is how it opens.
    case suggesting

    var isVisible: Bool { self != .hidden }
    /// Both states draw the same input row; only the list below it differs.
    var showsInput: Bool { self == .prompt || self == .suggesting }
}

@MainActor
final class AppChatPromptModel: ObservableObject {
    /// How long an untouched prompt waits. Matches the clipboard card: nothing in this
    /// corner outlives the user's attention.
    static let idleDwell: TimeInterval = 5
    /// How long the badge holding an unfinished question waits after that.
    static let miniDwell: TimeInterval = 8

    @Published private(set) var phase: AppChatPromptPhase = .hidden
    @Published var query = ""
    /// The app the question is about, captured when the prompt opened — not read live,
    /// because opening the prompt is itself an app switch.
    @Published private(set) var appName = ""
    @Published private(set) var appBundleID = ""
    /// What this app can do, shown before anything is typed.
    @Published private(set) var suggestions: [AppChatSuggestion] = []
    /// The line above them: "5 actions · 2 skills · 1 built-in tools · 3 cli tools".
    @Published private(set) var capabilitySummary = ""

    private(set) var isStandDownArmed = false
    private var standDownTask: Task<Void, Never>?

    var onPhaseChange: ((AppChatPromptPhase) -> Void)?

    // MARK: - Opening

    func summon(
        app name: String,
        bundleID: String = "",
        suggestions: [AppChatSuggestion] = [],
        summary: String = ""
    ) {
        appName = name
        appBundleID = bundleID
        self.suggestions = suggestions
        capabilitySummary = summary
        set(restingInputPhase)
        arm(after: Self.idleDwell)
    }

    /// Opens on suggestions when there are any, because a blank field asks the user to
    /// guess what the app can do.
    private var restingInputPhase: AppChatPromptPhase {
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (!suggestions.isEmpty && !typed) ? .suggesting : .prompt
    }

    /// Typing is attention: it puts the clock back rather than making the prompt immortal.
    /// It also puts the suggestion list away — a typed question is not a browse — and
    /// brings it back if the field is cleared again.
    func queryChanged() {
        guard phase.isVisible else { return }
        if phase.showsInput {
            set(restingInputPhase)
        }
        arm(after: Self.idleDwell)
    }

    func hoverBegan() {
        guard phase.isVisible else { return }
        set(restingInputPhase)
        arm(after: Self.idleDwell)
    }

    // MARK: - Standing down

    /// One step smaller. An idle prompt shrinks to the frontmost app's own icon rather
    /// than a generic dot, so the corner still says which app it is about, and it keeps
    /// any half-written question for whoever comes back for it.
    func standDown() {
        switch phase {
        case .prompt, .suggesting:
            set(.mini)
            arm(after: Self.miniDwell)
        case .mini:
            dismiss()
        case .hidden:
            break
        }
    }

    /// Switching Space is leaving, and the question was about an app on the screen the
    /// user walked away from.
    func userLeftTheSpace() {
        dismiss()
    }

    func dismiss() {
        cancel()
        query = ""
        suggestions = []
        capabilitySummary = ""
        set(.hidden)
    }

    // MARK: - Sending

    /// Not connected yet. Returns false so no caller can mistake this for a sent message.
    @discardableResult
    func submit() -> Bool {
        false
    }

    // MARK: - Timer

    private func arm(after delay: TimeInterval) {
        standDownTask?.cancel()
        isStandDownArmed = true
        standDownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.standDown()
        }
    }

    private func cancel() {
        standDownTask?.cancel()
        standDownTask = nil
        isStandDownArmed = false
    }

    private func set(_ next: AppChatPromptPhase) {
        guard phase != next else { return }
        phase = next
        onPhaseChange?(next)
    }
}
