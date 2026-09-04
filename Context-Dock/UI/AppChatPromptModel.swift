// AppChatPromptModel.swift
// Context-Dock
//
// Ask the frontmost app something without leaving it: a hotkey puts an input field in the
// corner shell, alongside the clipboard and the shelf.
//
// This is the frontmost app chat. It answers here, and it is the dock's chat — not a
// second one that resembles it.
//
// The turn runs through Context Dock's own pipeline and the answer lands in
// `AppChatConversation`, which the dock writes and this reads. Nothing about routing,
// grounding, or approval is reimplemented here, so the two cannot drift: they are the
// same conversation shown in two places.

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

/// What the corner prompt is about. The frontmost app chat and General chat share the
/// one pill — same phases, same animations, same dwell — and differ only in where the
/// question goes and what the transcript reads. Two surfaces for two scopes is what the
/// Unified Dock Surface rule forbids.
enum AppChatPromptScope: Equatable {
    case app
    case general
}

/// The app a question would be about, remembered rather than re-read.
///
/// General mode has no app, and while it is showing the frontmost app keeps changing
/// underneath it. Switching back must not depend on the right app still being in front —
/// it goes back to the one the user was actually asking about.
struct AppChatTarget: Equatable {
    var name: String
    var bundleID: String
    var suggestions: [AppChatSuggestion]
    var summary: String
}

/// What the user had typed and attached in a scope they switched away from. The two modes
/// are two conversations, so a half-written question survives a look at the other one.
private struct AppChatDraft {
    var query = ""
    var attachments: [URL] = []
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
    /// Set at summon time. The pill itself never changes scope mid-life; an app switch
    /// only re-scopes an app-scoped prompt, never a general one.
    @Published private(set) var scope: AppChatPromptScope = .app
    @Published var query = ""
    /// The app the question is about, captured when the prompt opened — not read live,
    /// because opening the prompt is itself an app switch.
    @Published private(set) var appName = ""
    @Published private(set) var appBundleID = ""
    /// What this app can do, shown before anything is typed.
    @Published private(set) var suggestions: [AppChatSuggestion] = []
    /// The line above them: "5 actions · 2 skills · 1 built-in tools · 3 cli tools".
    @Published private(set) var capabilitySummary = ""

    /// The dock's conversation, not a copy of it.
    /// Scope-aware reads. General chat answers live in GeneralChatWindowModel — the same
    /// conversation the full window shows — so opening the window later continues the
    /// corner thread instead of forking a second one.
    var messages: [AIChatMessage] {
        scope == .general ? GeneralChatWindowModel.shared.messages : conversation.messages
    }
    var isAnswering: Bool {
        scope == .general
            ? GeneralChatWindowModel.shared.isSending : conversation.isLoading
    }
    var liveSteps: [String] {
        scope == .general
            ? GeneralChatWindowModel.shared.activeProgress : conversation.liveSteps
    }
    /// How many steps the turn that just finished took, kept after the live stream is
    /// gone. The stream is the answer to "what is it doing"; this is the answer to "what
    /// did it do", and collapsing to it is what stops a finished run from holding the
    /// space the result needs.
    @Published private(set) var lastStepCount = 0
    private var runningStepCount = 0

    /// Called as the live stream changes. The steps are a passthrough onto whichever
    /// conversation owns the turn, so there is nothing here to observe directly — the
    /// high-water mark has to be taken while the turn is still running.
    func noteActivity() {
        if isAnswering {
            runningStepCount = max(runningStepCount, liveSteps.count)
        } else if runningStepCount > 0 {
            lastStepCount = runningStepCount
            runningStepCount = 0
        }
    }

    /// Files the question should carry.
    @Published private(set) var attachments: [URL] = []
    /// The user said "stay". Nothing times the surface out while this holds.
    @Published private(set) var isPinned = false

    /// The app mode's target, held across a visit to General mode.
    private var storedAppTarget: AppChatTarget?
    private var appDraft = AppChatDraft()
    private var generalDraft = AppChatDraft()

    private(set) var isStandDownArmed = false
    private(set) var isPointerInside = false
    private var hasPresentedConversation = false
    private let conversation: AppChatConversation
    private var standDownTask: Task<Void, Never>?
    private var conversationObservation: AnyCancellable?
    private var generalConversationObservation: AnyCancellable?

    var onPhaseChange: ((AppChatPromptPhase) -> Void)?

    init(conversation: AppChatConversation? = nil) {
        let source = conversation ?? AppChatConversation.shared
        self.conversation = source
        conversationObservation = source.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        generalConversationObservation = GeneralChatWindowModel.shared.objectWillChange.sink {
            [weak self] _ in
            guard self?.scope == .general else { return }
            self?.objectWillChange.send()
        }
    }

    // MARK: - Opening

    func summon(
        app name: String,
        bundleID: String = "",
        suggestions: [AppChatSuggestion] = [],
        summary: String = ""
    ) {
        scope = .app
        appName = name
        appBundleID = bundleID
        self.suggestions = suggestions
        capabilitySummary = summary
        storedAppTarget = AppChatTarget(
            name: name, bundleID: bundleID, suggestions: suggestions, summary: summary)
        set(restingInputPhase)
        arm(after: Self.idleDwell)
    }

    // MARK: - Switching modes

    /// The other chat, in the same pill.
    ///
    /// One surface, two scopes: the Unified Dock Surface rule is what makes this a switch
    /// rather than a second window appearing beside the first. Each side keeps its own
    /// draft, attachments, target and transcript — the only thing they share is the shell.
    func toggleScope() {
        switch scope {
        case .app: showGeneral()
        case .general: showApp()
        }
    }

    private func showGeneral() {
        appDraft = AppChatDraft(query: query, attachments: attachments)
        storedAppTarget = AppChatTarget(
            name: appName, bundleID: appBundleID,
            suggestions: suggestions, summary: capabilitySummary)
        scope = .general
        appName = ""
        appBundleID = ""
        suggestions = []
        capabilitySummary = ""
        query = generalDraft.query
        attachments = generalDraft.attachments
        hasPresentedConversation = !messages.isEmpty
        set(hasPresentedConversation ? .chat : .prompt)
        touch()
    }

    private func showApp() {
        generalDraft = AppChatDraft(query: query, attachments: attachments)
        scope = .app
        if let target = storedAppTarget {
            appName = target.name
            appBundleID = target.bundleID
            suggestions = target.suggestions
            capabilitySummary = target.summary
        }
        query = appDraft.query
        attachments = appDraft.attachments
        hasPresentedConversation = !messages.isEmpty
        set(hasPresentedConversation ? .chat : restingInputPhase)
        touch()
    }

    /// General chat in the same corner pill: it opens on the input line alone — the
    /// start screen is the full window's job — and the same phases carry it from there.
    func summonGeneral() {
        if scope == .app, !appBundleID.isEmpty {
            appDraft = AppChatDraft(query: query, attachments: attachments)
            storedAppTarget = AppChatTarget(
                name: appName, bundleID: appBundleID,
                suggestions: suggestions, summary: capabilitySummary)
        }
        scope = .general
        appName = ""
        appBundleID = ""
        suggestions = []
        capabilitySummary = ""
        query = generalDraft.query
        attachments = generalDraft.attachments
        hasPresentedConversation = !messages.isEmpty
        set(.prompt)
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
    /// General chat's "bigger place" is the full window, which reads the very model the
    /// pill was writing to — nothing to hand off.
    func openInDock() {
        if scope == .general {
            GeneralChatWindowController.shared.show()
        } else {
            Self.handOff(app: appName, bundleID: appBundleID, query: "", attachments: attachments)
        }
        dismiss()
    }

    /// Start over in the same scope. General chat's transcript belongs to the window
    /// model, which clears it directly; the app-scoped one belongs to the dock, and the
    /// dock stays its only writer — so this asks rather than reaching in.
    func newConversation() {
        if scope == .general {
            GeneralChatWindowModel.shared.newChat()
        } else {
            NotificationCenter.default.post(name: .appChatPromptNewChat, object: nil)
        }
        query = ""
        attachments = []
        hasPresentedConversation = false
        set(restingInputPhase)
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
        isPointerInside = true
        // Coming back reopens the conversation if there is one.
        if phase == .mini {
            set(hasPresentedConversation ? .chat : restingInputPhase)
        }
        cancel()
    }

    func hoverEnded() {
        guard phase.isVisible else { return }
        isPointerInside = false
        touch()
    }

    /// Follow the live frontmost-app scope while this corner entry point is visible. The
    /// shared dock handler switches the actual conversation before this chooses which
    /// presentation to show, so the corner never owns a parallel per-app history.
    func frontmostAppDidChange(
        app name: String,
        bundleID: String,
        suggestions: [AppChatSuggestion],
        summary: String
    ) {
        // DoraX is never the app the question is about. Taking the keyboard for the prompt
        // makes this app frontmost, so without this an open prompt re-targets itself.
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }

        // General mode is not about an app and must not be disturbed by one — but the
        // switch back is, so the target is kept current the whole time it is hidden. The
        // app draft goes with it: a half-written question about Safari is not a question
        // about the app that replaced it.
        if scope == .general {
            if storedAppTarget?.bundleID != bundleID { appDraft = AppChatDraft() }
            storedAppTarget = AppChatTarget(
                name: name, bundleID: bundleID, suggestions: suggestions, summary: summary)
            return
        }
        guard phase.isVisible, bundleID != appBundleID else { return }
        storedAppTarget = AppChatTarget(
            name: name, bundleID: bundleID, suggestions: suggestions, summary: summary)
        query = ""
        attachments = []
        appName = name
        appBundleID = bundleID
        self.suggestions = suggestions
        capabilitySummary = summary
        Self.changeScope(app: name, bundleID: bundleID)
        hasPresentedConversation = !messages.isEmpty
        set(hasPresentedConversation ? .chat : restingInputPhase)
        if isPinned || isPointerInside {
            cancel()
        } else {
            arm(after: Self.idleDwell)
        }
    }

    // MARK: - Standing down

    /// One step smaller. An idle prompt shrinks to the frontmost app's own icon rather
    /// than a generic dot, so the corner still says which app it is about, and it keeps
    /// any half-written question for whoever comes back for it.
    func standDown() {
        guard !isPinned, !isPointerInside, !isAnswering else { return }
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
        isPointerInside = false
        if !isPinned { arm(after: Self.idleDwell) }
    }

    func dismiss() {
        cancel()
        query = ""
        suggestions = []
        capabilitySummary = ""
        attachments = []
        isPinned = false
        hasPresentedConversation = false
        set(.hidden)
    }

    // MARK: - Sending

    /// Asks. The turn runs on Context Dock's pipeline — the same code the dock's own
    /// chat uses — and the answer arrives in the shared conversation this renders.
    @discardableResult
    func submit() -> Bool {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return false }
        if scope == .general {
            let general = GeneralChatWindowModel.shared
            general.attachments = attachments
            general.input = question
            general.send()
        } else {
            Self.handOff(
                app: appName, bundleID: appBundleID, query: question, attachments: attachments)
        }
        query = ""
        attachments = []
        hasPresentedConversation = true
        set(.chat)
        touch()
        return true
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

    private static func changeScope(app: String, bundleID: String) {
        NotificationCenter.default.post(
            name: .appChatPromptScopeChanged,
            object: nil,
            userInfo: ["appName": app, "bundleId": bundleID])
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
    static let appChatPromptScopeChanged = Notification.Name("appChatPromptScopeChanged")
    /// Corner prompt → the dock, asking it to empty the app-scoped transcript both of
    /// them are showing. The corner does not clear it itself: `AppChatConversation` has
    /// one writer and this is not it.
    static let appChatPromptNewChat = Notification.Name("appChatPromptNewChat")
}
