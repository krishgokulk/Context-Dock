// AppChatPromptModel.swift
// Context-Dock
//
// Ask the frontmost app something without leaving it: a hotkey puts an input field in the
// corner shell, alongside the clipboard and the shelf.
//
// This is the frontmost app chat. It answers here.
//
// The engine is not its own: turns go through `AppScopedChatService.send`, the same call
// the other chat surfaces use, so grounding, tool routing and command approval behave
// identically — a different window is not a reason to build a second brain or lower a
// gate. What belongs to this surface is only how the conversation is shown.

import Combine
import Foundation

/// One turn in the conversation.
struct AppChatMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
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
    /// The conversation.
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
    /// What the turn is doing right now, in words.
    @Published private(set) var status = ""
    @Published private(set) var isAnswering = false
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

    /// Opens the same conversation in the dock, for when the corner is too small for it.
    func openInDock() {
        Self.handOff(app: appName, bundleID: appBundleID, query: "", attachments: attachments)
        dismiss()
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
        if phase != .chat { set(restingInputPhase) }
        touch()
    }

    /// Any interaction puts the clock back, unless the surface is pinned.
    private func touch() {
        guard !isPinned, phase.isVisible else { return }
        arm(after: Self.idleDwell)
    }

    func hoverBegan() {
        guard phase.isVisible else { return }
        // Coming back reopens the conversation if there is one.
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
        attachments = []
        messages = []
        status = ""
        isPinned = false
        set(.hidden)
    }

    // MARK: - Sending

    /// Asks, and answers here. The turn runs through the shared service, so this surface
    /// owns the presentation and nothing else.
    @discardableResult
    func submit() -> Bool {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return false }
        let files = attachments

        messages.append(AppChatMessage(text: question, isFromUser: true))
        messages.append(AppChatMessage(text: "", isFromUser: false))
        query = ""
        attachments = []
        isAnswering = true
        status = ""
        set(.chat)
        touch()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let answer = try await AppScopedChatService.send(
                    scope: .app(bundleId: self.appBundleID),
                    appName: self.appName,
                    query: question,
                    history: self.historyForService(),
                    attachments: files,
                    onStream: nil,
                    onStatus: { [weak self] line in
                        self?.status = line
                    })
                self.finish(with: answer.text)
            } catch {
                self.finish(with: "That didn't go through: \(error.localizedDescription)")
            }
        }
        return true
    }

    private func finish(with text: String) {
        isAnswering = false
        status = ""
        if let index = messages.lastIndex(where: { !$0.isFromUser }) {
            messages[index].text = text
        }
        touch()
    }

    /// Everything already said, in the shape the service expects.
    private func historyForService() -> [ChatMessage] {
        messages
            .filter { !$0.text.isEmpty }
            .map { ChatMessage(role: $0.isFromUser ? .user : .assistant, content: $0.text) }
    }

    private static func handOff(
        app: String, bundleID: String, query: String, attachments: [URL]
    ) {
        NotificationCenter.default.post(
            name: .appChatPromptSubmitted,
            object: nil,
            userInfo: [
                "appName": app,
                "bundleId": bundleID,
                "query": query,
                "attachments": attachments.map(\.path),
            ])
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

extension Notification.Name {
    /// Corner prompt → Context Dock's app-scoped chat. Carried by notification because the
    /// chat's state lives inside LauncherView and is not reachable from a window.
    static let appChatPromptSubmitted = Notification.Name("appChatPromptSubmitted")
}
