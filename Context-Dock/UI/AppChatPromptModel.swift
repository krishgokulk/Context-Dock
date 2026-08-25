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

/// One turn in the conversation. Nothing answers yet, so an assistant message is only
/// ever the app saying what it cannot do.
struct AppChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isFromUser: Bool
}

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
    /// The conversation, opened by sending or by the expand control.
    case chat

    var isVisible: Bool { self != .hidden }
    /// Every one of these draws the same input row; only what sits under it differs.
    var showsInput: Bool { self == .prompt || self == .suggesting || self == .chat }
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

    /// The conversation so far.
    @Published private(set) var messages: [AppChatMessage] = []
    /// Files the question should carry.
    @Published private(set) var attachments: [URL] = []
    /// The user said "stay". Nothing times the surface out while this holds.
    @Published private(set) var isPinned = false

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

    // MARK: - Controls

    /// Pinning is the user saying "stay", so the clock stops entirely rather than being
    /// reset — a pinned surface is not waiting for attention, it has been given some.
    func togglePin() {
        isPinned.toggle()
        if isPinned {
            cancel()
        } else {
            arm(after: Self.idleDwell)
        }
    }

    func toggleExpanded() {
        set(phase == .chat ? restingInputPhase : .chat)
        touch()
    }

    func attach(_ url: URL) {
        guard !attachments.contains(url) else { return }
        attachments.append(url)
        touch()
    }

    func detach(_ url: URL) {
        attachments.removeAll { $0 == url }
        touch()
    }

    /// Typing is attention: it puts the clock back rather than making the prompt immortal.
    /// It also puts the suggestion list away — a typed question is not a browse — and
    /// brings it back if the field is cleared again.
    func queryChanged() {
        guard phase.isVisible else { return }
        // A conversation stays a conversation; only the pre-send states swap.
        if phase != .chat {
            set(restingInputPhase)
        }
        touch()
    }

    /// Any interaction puts the clock back, unless the surface is pinned.
    private func touch() {
        guard !isPinned, phase.isVisible else { return }
        arm(after: Self.idleDwell)
    }

    func hoverBegan() {
        guard phase.isVisible else { return }
        // Coming back to a conversation reopens the conversation, not a blank prompt.
        if phase == .mini {
            set(messages.isEmpty ? restingInputPhase : .chat)
        }
        touch()
    }

    // MARK: - Standing down

    /// One step smaller. An idle prompt shrinks to the frontmost app's own icon rather
    /// than a generic dot, so the corner still says which app it is about, and it keeps
    /// any half-written question for whoever comes back for it.
    func standDown() {
        guard !isPinned else { return }
        switch phase {
        case .prompt, .suggesting, .chat:
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
        messages = []
        attachments = []
        isPinned = false
        set(.hidden)
    }

    // MARK: - Sending

    /// Not connected yet — but doing nothing at all reads as broken rather than
    /// unfinished, so the question is kept, shown in the conversation, and answered with
    /// the plain fact that there is nowhere to send it. Still returns false: nothing was
    /// sent, and no caller should believe otherwise.
    @discardableResult
    func submit() -> Bool {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        messages.append(AppChatMessage(text: question, isFromUser: true))
        messages.append(
            AppChatMessage(
                text: "Not connected yet — \(appName.isEmpty ? "this app" : appName) chat has"
                    + " no route to send this to. Your question is kept here.",
                isFromUser: false))
        query = ""
        set(.chat)
        touch()
        return false
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
