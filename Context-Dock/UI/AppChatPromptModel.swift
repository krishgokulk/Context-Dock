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
    /// The app's own menu commands matching what is typed, ranked by the dock's rule.
    /// See `AppChatMenuBrowsing`.
    @Published var menuMatches: [AXMenuItem] = []
    /// Which row the arrow keys are on, or nil when the user has not chosen one.
    ///
    /// Starts nil deliberately. With a row preselected, Enter ran a command when the user
    /// had typed a question — the list is an offer, and taking it should be something you
    /// do, not something that happens because you did not avoid it.
    @Published var focusedMenuIndex: Int?
    /// Every command the app offers, read once per app rather than per keystroke.
    var allMenuItems: [AXMenuItem] = []
    /// What this app's adapter declares it can do — curated, unlike the menus.
    var adapterActions: [AdapterAction] = []
    /// The one list the card draws: actions and commands ranked together.
    @Published var rows: [AppChatRow] = []
    /// What the app has selected right now — carried by the question, so it is shown.
    @Published private(set) var selection: AppChatSelectionScope?
    /// Global Context only: the dock's own top match for what is typed, and the matching
    /// app icons it shows beside the field. Resolved by the dock's coordinator so the two
    /// surfaces agree on what "the best match" means.
    @Published private(set) var globalTopMatch: GlobalContextTopMatch?
    @Published private(set) var globalMatchIcons: [MatchDockIcon] = []
    @Published private(set) var globalOverflowCount = 0
    /// This scope was entered from Global, so leaving it goes back there rather than to the
    /// frontmost app.
    @Published var returnsToGlobalScope = false
    /// Guards async Finder results against the keystroke that overtook them.
    var finderSearchGeneration = 0
    /// The Global Extension this scope is showing, drawn in the board above the field.
    @Published var scopedExtension: UserGlobalExtension?
    /// The Global Command this scope is showing — Quick Note, Currency Converter, the rest
    /// of Settings → Integrations → Global → Commands.
    @Published var scopedCommand: SystemCommand?
    /// What the panel's assistant has been asked and has answered, while this scope is up.
    @Published var panelConversation: [ChatMessage] = []
    @Published var isAskingPanel = false
    /// The line above them: "5 actions · 2 skills · 1 built-in tools · 3 cli tools".
    @Published private(set) var capabilitySummary = ""

    /// The dock's conversation, not a copy of it.
    var messages: [AIChatMessage] { conversation.messages }
    var isAnswering: Bool { conversation.isLoading }
    var liveSteps: [String] { conversation.liveSteps }
    /// Files the question should carry.
    @Published private(set) var attachments: [URL] = []
    /// The user said "stay". Nothing times the surface out while this holds.
    /// Whether the corner chat starts pinned. A toggle that reset itself every relaunch was
    /// not a preference — it was a button that occasionally worked, so pressing it wrote the
    /// choice down rather than only holding it in memory for as long as this object exists.
    @Published private(set) var isPinned = UserDefaults.standard.bool(
        forKey: AppChatPromptModel.pinnedDefaultsKey)

    /// A question is out and its answer has not arrived. The transcript legitimately goes
    /// empty in between, so the card holds rather than reading that as "nothing here".
    private var awaitingAnswer = false
    private var answerWatchdog: Task<Void, Never>?
    /// How long a handed-over question may stay unanswered before the card gives up. Long
    /// enough for a model to start speaking, short enough that a lost question is visibly
    /// lost rather than a card that sits there.
    private static let answerGrace: TimeInterval = 12

    private(set) var isStandDownArmed = false
    private(set) var isPointerInside = false
    private var hasPresentedConversation = false
    /// The user has already done something here — asked, or run a command. What the app can
    /// do is an opening offer, not a thing to re-present after every action.
    var hasActed = false
    private let conversation: AppChatConversation
    let globalResultSource: GlobalContextResultSource
    private var standDownTask: Task<Void, Never>?
    private var conversationObservation: AnyCancellable?
    private var messagesObservation: AnyCancellable?
    private var selectionObservation: AnyCancellable?
    private var globalResultsObservation: AnyCancellable?
    /// Half-written questions, kept per scope so a walk between them loses nothing.
    private var drafts: [String: String] = [:]

    var onPhaseChange: ((AppChatPromptPhase) -> Void)?
    /// A Global Context row acted on an app, and that app appears to have taken the front a
    /// moment later — args are (name, bundleID). The corner reads this as "follow me there",
    /// not as an incidental background switch to ignore.
    var onAppLaunchedFromGlobalContext: ((String, String) -> Void)?

    init(conversation: AppChatConversation? = nil, globalResultSource: GlobalContextResultSource? = nil) {
        let source = conversation ?? AppChatConversation.shared
        self.conversation = source
        self.globalResultSource = globalResultSource ?? .shared
        globalResultsObservation = self.globalResultSource.updates.sink { [weak self] in
            guard let self, self.isSearchField, self.phase.showsInput else { return }
            let focusedID = self.focusedRow?.id
            self.updateMenuMatches()
            self.focusedMenuIndex = focusedID.flatMap { id in self.rows.firstIndex { $0.id == id } }
        }
        conversationObservation = source.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // The dock switches the conversation one hop after the corner asks it to, so a
        // scope change reads the *outgoing* app's messages, goes to .chat, and is then
        // left holding a full-height card with nothing in it. Watch the messages
        // themselves and step back to the field when they go.
        messagesObservation = source.$messages.sink { [weak self] incoming in
            self?.followConversation(messages: incoming)
        }
        // The selection changes under the corner while it is open — the user highlights
        // something and then asks about it, which is the whole point of the surface.
        selectionObservation = AXContextReader.shared.contextPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] context in
                guard let self else { return }
                self.selection = AppChatSelectionScope.from(
                    context: context, scopedTo: self.appBundleID)
            }
    }

    /// Set by `AppChatMenuBrowsing` as the user types in Global Context.
    func setGlobalTyping(top: GlobalContextTopMatch?, icons: [MatchDockIcon], overflow: Int) {
        globalTopMatch = top
        globalMatchIcons = icons
        globalOverflowCount = overflow
    }

    /// Point the surface at a scope. The scope's identity stays `private(set)` — only the
    /// model may change what it is about — and this is the one door.
    ///
    /// Each scope keeps its own half-written question. App Chat and Global Context share
    /// this one model, so without that a walk from one to the other threw away whatever the
    /// user had typed — and walking back did not bring it home.
    func adoptScope(
        name: String, bundleID: String, suggestions: [AppChatSuggestion] = [],
        summary: String = ""
    ) {
        let outgoing = scopeKey
        let incoming = Self.scopeKey(name: name, bundleID: bundleID)
        if outgoing != incoming {
            drafts[outgoing] = query
            query = drafts[incoming] ?? ""
            // The answer being waited for belonged to the scope being left.
            stopAwaitingAnswer()
        }
        appName = name
        appBundleID = bundleID
        self.suggestions = suggestions
        capabilitySummary = summary
    }

    /// What a scope is called when it holds a draft. The bundle id where there is one, the
    /// name otherwise — Global Context has no bundle id and is still a scope.
    private var scopeKey: String { Self.scopeKey(name: appName, bundleID: appBundleID) }

    private static func scopeKey(name: String, bundleID: String) -> String {
        bundleID.isEmpty ? name : bundleID
    }

    // MARK: - Opening

    func summon(
        app name: String,
        bundleID: String = "",
        suggestions: [AppChatSuggestion] = [],
        summary: String = ""
    ) {
        adoptScope(
            name: name, bundleID: bundleID, suggestions: suggestions, summary: summary)
        selection = AppChatSelectionScope.from(
            context: AXContextReader.shared.current, scopedTo: bundleID)
        loadMenuItems()
        set(restingInputPhase)
        arm(after: Self.idleDwell)
    }

    /// Opens on suggestions when there are any, because a blank field asks the user to
    /// guess what the app can do.
    private var restingInputPhase: AppChatPromptPhase {
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Typed: the app's matching commands sit under the field. Untyped: what it can do,
        // but only until the user has done something — running a command and being handed
        // the opening menu again reads as the surface forgetting what just happened.
        if typed { return isBrowsingMenus ? .suggesting : .prompt }
        // A window snapshot occupies the board even with no rows to list, and so does an
        // extension's own interface.
        if showsWindowSnapshot || showsExtensionPanel { return .suggesting }
        // A scope stepped into from Global shows only what it found. With nothing found the
        // field rests alone rather than opening an empty board.
        if returnsToGlobalScope { return rows.isEmpty ? .prompt : .suggesting }
        if hasActed { return .prompt }
        // Attaching a file is composing a question about it. Offering the app's opening
        // menu on top of that answers something the user has already stopped asking.
        if !attachments.isEmpty { return .prompt }
        return (rows.isEmpty && suggestions.isEmpty) ? .prompt : .suggesting
    }

    // MARK: - Controls

    /// Pinning is the user saying "stay", so the clock stops entirely rather than being
    /// reset — a pinned surface is not waiting for attention, it has been given some.
    /// The pick-one buttons the newest answer is offering — a route it could take, or a
    /// specialist it could ask.
    ///
    /// Shown as a card above the composer rather than as buttons inside the transcript, the
    /// way the clipboard panel stacks its preview: a decision the turn is waiting on belongs
    /// where the eye already is, not somewhere the user has to scroll back to.
    var pendingChoices: [ActionChoice] {
        guard !isAnswering, let last = messages.last, last.role == .assistant else { return [] }
        return last.actionChoices
    }

    /// The turn belongs to the dock's pipeline, so the choice does too.
    func pick(_ choice: ActionChoice) {
        NotificationCenter.default.post(
            name: .appChatPromptPickAction, object: nil,
            userInfo: ["choiceID": choice.id, "title": choice.title])
    }

    func togglePin() {
        isPinned.toggle()
        // Only here, not wherever this session happens to reset the in-memory flag (idling
        // out, dismissing): a toggle is the user stating a preference, an idle timeout is
        // not them changing their mind about it.
        UserDefaults.standard.set(isPinned, forKey: Self.pinnedDefaultsKey)
        if isPinned {
            cancel()
        } else {
            arm(after: Self.idleDwell)
        }
    }

    /// Not private: tests reset this key explicitly so one test's pin does not leak into
    /// the next — `UserDefaults.standard` is one real domain shared by the whole process.
    static let pinnedDefaultsKey = "cornerChatPinned"

    /// Opens the same conversation in the dock, for when the corner is too small for it.
    func openInDock() {
        Self.handOff(app: appName, bundleID: appBundleID, query: "", attachments: attachments)
        dismiss()
    }

    /// Stop the turn that is running.
    ///
    /// The turn belongs to the dock's pipeline, so this asks for the same reason clearing
    /// does — and a request that arrives after the turn already finished is simply ignored
    /// on the other side.
    func cancelTurn() {
        guard isAnswering else { return }
        NotificationCenter.default.post(name: .appChatPromptCancel, object: nil)
        touch()
    }

    /// Start the app-scoped conversation over.
    ///
    /// `AppChatConversation` has one writer and this is not it: the dock's pipeline produces
    /// those messages, so clearing them is a request to the dock rather than something the
    /// corner does behind its back.
    func newConversation() {
        NotificationCenter.default.post(name: .appChatPromptNewChat, object: nil)
        query = ""
        attachments = []
        hasPresentedConversation = false
        hasActed = false
        stopAwaitingAnswer()
        set(restingInputPhase)
        touch()
    }

    func attach(_ url: URL) {
        guard !attachments.contains(url) else { return }
        attachments.append(url)
        syncListPhase()
        touch()
    }

    func detach(_ url: URL) {
        attachments.removeAll { $0 == url }
        syncListPhase()
        touch()
    }

    /// Typing is attention: it puts the clock back rather than making the prompt immortal.
    /// It also puts the suggestion list away — a typed question is not a browse — and
    /// brings it back if the field is cleared again.
    func queryChanged() {
        guard phase.isVisible else { return }
        updateMenuMatches()
        syncListPhase()
        touch()
    }

    /// The pill's height comes from its phase, so the phase has to follow the list — which
    /// can also arrive *after* typing, when the live menu read lands.
    func syncListPhase() {
        guard phase.isVisible, phase != .chat else { return }
        set(restingInputPhase)
    }

    /// The card follows the conversation in both directions.
    ///
    /// Only the drop existed, and it took the card away from the question that had just
    /// been asked: entering a scope with no history of its own — a CLI tool, an app never
    /// chatted with — makes the dock start a fresh session, and a fresh session publishes
    /// an empty transcript one hop after the question is handed over. The card went back to
    /// being a list of subcommands, and when the answer landed nothing put it back, so the
    /// tool looked like it had ignored the question entirely.
    private func followConversation(messages incoming: [AIChatMessage]) {
        if incoming.isEmpty {
            // Our own question emptied it. Hold the card until the turn either shows up or
            // gives up, rather than treating the clear as "there is nothing here".
            guard !awaitingAnswer else { return }
            dropChatPhaseWithoutAConversation(messages: incoming)
            return
        }
        guard awaitingAnswer else { return }
        awaitingAnswer = false
        answerWatchdog?.cancel()
        answerWatchdog = nil
        hasPresentedConversation = true
        guard phase.isVisible else { return }
        set(.chat)
    }

    /// A conversation surface with no conversation and no turn running is a field.
    ///
    /// Guards the gap between asking for a scope change and the dock performing it, which
    /// is where the empty card came from.
    private func dropChatPhaseWithoutAConversation(messages incoming: [AIChatMessage]) {
        guard phase == .chat, incoming.isEmpty, !isAnswering else { return }
        hasPresentedConversation = false
        set(restingInputPhase)
    }

    /// Stop waiting for an answer, and let the ordinary rules take the card back.
    private func stopAwaitingAnswer() {
        awaitingAnswer = false
        answerWatchdog?.cancel()
        answerWatchdog = nil
    }

    /// A question that never reaches a turn must not leave an empty card standing forever.
    private func armAnswerWatchdog() {
        answerWatchdog?.cancel()
        answerWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.answerGrace * 1_000_000_000))
            guard !Task.isCancelled, let self, self.awaitingAnswer else { return }
            self.awaitingAnswer = false
            self.dropChatPhaseWithoutAConversation(messages: self.messages)
        }
    }

    /// Any interaction puts the clock back, unless the surface is pinned.
    func touch() {
        guard !isPinned, !isAnswering, phase.isVisible else { return }
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
        guard phase.isVisible, !bundleID.isEmpty, bundleID != appBundleID else { return }
        // A scope the user chose is not the frontmost app's to take. Global Context, a tool,
        // an app stepped into from Global — clicking away from any of them used to swap the
        // field to whatever came forward, losing the place the user had picked.
        guard !isGlobalScope, !returnsToGlobalScope else { return }
        query = ""
        attachments = []
        appName = name
        appBundleID = bundleID
        self.suggestions = suggestions
        capabilitySummary = summary
        Self.changeScope(app: name, bundleID: bundleID)
        selection = AppChatSelectionScope.from(
            context: AXContextReader.shared.current, scopedTo: bundleID)
        stopAwaitingAnswer()
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
        hasActed = false
        stopAwaitingAnswer()
        set(.hidden)
    }

    // MARK: - Sending

    /// Asks. The turn runs on Context Dock's pipeline — the same code the dock's own
    /// chat uses — and the answer arrives in the shared conversation this renders.
    @discardableResult
    func submit() -> Bool {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return false }
        Self.handOff(
            app: appName, bundleID: appBundleID, query: question, attachments: attachments)
        query = ""
        attachments = []
        hasPresentedConversation = true
        hasActed = true
        awaitingAnswer = true
        armAnswerWatchdog()
        set(.chat)
        touch()
        return true
    }

    /// A question was asked elsewhere and its answer belongs here.
    ///
    /// The same state `submit()` enters, for the case where another corner surface —
    /// Selection Scope — owns the question. Without it the transcript would open empty,
    /// see the dock clear the session for the new scope, and step straight back to a field.
    func expectAnswer() {
        hasPresentedConversation = true
        hasActed = true
        awaitingAnswer = true
        armAnswerWatchdog()
        set(.chat)
        touch()
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

    func set(_ next: AppChatPromptPhase) {
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
    /// Corner prompt → the dock, asking it to empty the app-scoped transcript both of them
    /// are showing. The corner does not clear it itself: that conversation has one writer.
    static let appChatPromptNewChat = Notification.Name("appChatPromptNewChat")
    /// Corner prompt → the dock, asking it to stop the turn it is running. The pipeline is
    /// the dock's, so stopping it is the dock's to do.
    static let appChatPromptCancel = Notification.Name("appChatPromptCancel")
    /// The corner picked one of the answer's offered routes; the dock runs it.
    static let appChatPromptPickAction = Notification.Name("appChatPromptPickAction")
}
