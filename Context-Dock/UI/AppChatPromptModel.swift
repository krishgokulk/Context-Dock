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

import AppKit
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

/// What is actually behind the selection — `AppChatSelectionScope` is only ever a count
/// and an icon, and showing the selection in place needs something to show.
enum AppChatSelectionContent: Equatable {
    case text(String)
    case files([URL])
}

enum AppChatPromptPhase: Equatable {
    case hidden
    /// Shrunk to the frontmost app's own icon, holding whatever was typed.
    case mini
    /// Global Context at rest: the field folded away, the running apps and the pins
    /// standing as a dock. Nothing typed, nothing waiting.
    case dock
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
    /// How long the untouched "what this app can do" list stays up before the field
    /// closes back to just itself — the dock's own results sheet doesn't show at all
    /// until the arrow keys ask for it, and this offer is the same kind of thing.
    static let suggestionsDwell: TimeInterval = 2
    /// How long an untouched, empty Global field waits before folding into the dock.
    static let dockDwell: TimeInterval = 2

    /// Read through a closure so a test can flip it without touching UserDefaults. The
    /// key is the General settings toggle; absent means on.
    var autoShrinkEnabled: () -> Bool = {
        UserDefaults.standard.object(forKey: "autoShrinkInputField") as? Bool ?? true
    }

    /// Running apps the user took off the strip this session. Not persisted: like an icon
    /// dragged out of the Dock while its app runs, it comes back next launch.
    @Published var hiddenRunningBundleIDs: Set<String> = []

    /// What the pointer is over in the strip, for the card above it. An app answers with
    /// its windows; a pinned file, folder or command answers with what it is.
    @Published var hoveredStripTarget: DockHoverTarget? {
        didSet { scheduleWindowRowUpdate() }
    }
    /// What that card is showing, once the pointer has rested long enough. The strip sets
    /// `hoveredStripTarget` on every icon; this follows it after 250 ms and lets go 150 ms
    /// after the pointer has left both the icon and the card.
    @Published private(set) var dockPreviewTarget: DockHoverTarget? {
        didSet {
            // Expanded belongs to the card that was expanded; the next one opens at its
            // own size.
            if dockPreviewTarget != oldValue { pinPreviewExpanded = false }
        }
    }
    /// A pin card the user pinned open. The pointer moving over other icons, or away, no
    /// longer puts it away; unpinning hands the slot back to the hover.
    @Published private(set) var pinnedPreviewPinID: UUID?
    /// The pin card grown by its expand control (`DockPinPreviewMetrics.folderExpanded`).
    @Published private(set) var pinPreviewExpanded = false
    private var windowRowTask: Task<Void, Never>?
    private var pointerInWindowRow = false

    /// The app whose windows the row is showing, if that is what is up.
    var windowRowBundleID: String? {
        if case .app(let bundleID) = dockPreviewTarget { return bundleID }
        return nil
    }

    /// The pin whose card is up, if that is what is up.
    var previewPinID: UUID? {
        if case .pin(let id) = dockPreviewTarget { return id }
        return nil
    }

    /// A pinned plugin whose panel is open above its tile — a tap in the widget asked for it.
    /// Takes the same slot as the hover cards and wins over them while it is up: a card the
    /// user opened is not put away by the pointer passing over the next icon.
    @Published var pluginCardPinID: UUID?

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
    /// The content behind `selection` — `AppChatSelectionScope` itself is only ever a
    /// label and an icon, never enough to actually preview what would be carried.
    @Published private(set) var selectionContent: AppChatSelectionContent?
    /// The selection icon was clicked: this session's own surface is standing in for the
    /// separate Selection Scope card, showing what is selected in place of the app's own
    /// suggestions rather than opening a second card stacked on top of this one.
    @Published private(set) var isShowingSelectionScope = false
    /// Global Context only: the dock's own top match for what is typed, and the matching
    /// app icons it shows beside the field. Resolved by the dock's coordinator so the two
    /// surfaces agree on what "the best match" means.
    @Published private(set) var globalTopMatch: GlobalContextTopMatch?
    @Published private(set) var globalMatchIcons: [MatchDockIcon] = []
    @Published private(set) var globalOverflowCount = 0
    /// What the field widens for: its running-app pills. The pins are not in the field —
    /// they are the strip's trailing region, which stays on screen while the field is up.
    /// The icons the field holds beside it: Safari's tab pills in a Safari scope, else the
    /// running apps. What the field's width is sized for.
    /// The icons the field keeps room for. In a Safari scope the field leads with the app's
    /// chip rather than the magnifier, and that chip is counted as pill slots too.
    var promptIconCount: Int {
        globalMatchIcons.count + (showsTabBar ? AppChatPromptMetrics.appFieldChromeSlots : 0)
    }
    /// The tabs behind the Safari scope's icons, by icon id.
    var tabsByIconID: [String: SafariTab] = [:]
    /// The app's pins behind its bar's leading icons, by icon id.
    var appPinsByIconID: [String: DockPin] = [:]
    /// The text field's frame in the corner's hosting view (top-left origin). Not published:
    /// only the swipe monitor reads it, and a redraw per layout pass would be for nothing.
    var inputFrame: CGRect = .zero

    /// The app's own bar: a Safari scope's open tabs take the running apps' place in the
    /// Global shell — the strip of big icons at rest, the small pill in the field (owner
    /// 2026-09-25: "exactly like Global"). Any other app's Context Dock gets the same bar
    /// once it has pins (task 4b): the bar is the app's own things, and those are its pins.
    var showsTabBar: Bool {
        guard !isGlobalScope else { return false }
        if BrowserTabList.listsTabs(bundleID: appBundleID) { return true }
        return isAppContextDock && !dockPins.pins(forApp: appBundleID).isEmpty
    }
    /// The pins the strip shows: Global's, never an app bar's — that bar is the app's own
    /// things, and its own pins are the leading icons of the bar itself (`tabStripIcons`).
    var stripPins: [DockPin] { showsTabBar ? [] : dockPins.pins }
    /// The Global shell — resting as the big dock and opening back into the field. Global
    /// Context's, and an app bar's (owner 2026-09-26): idle, an app folds into a big bar of
    /// its pins and tabs the way Global folds into its running apps.
    var usesDockShell: Bool { isGlobalScope || showsTabBar }
    /// The field is fitted to its own content rather than to the strip's width. Every app
    /// scope, the app bar's included: open, it is the compact field (owner 2026-09-26:
    /// "stay compact" — the field used to take the big bar's width and looked large one
    /// moment and small the next). Only Global's field shares its strip's width.
    var fitsField: Bool { !isGlobalScope }
    /// How many of the app bar's icons the field makes room for; the rest scroll sideways
    /// inside the pill rather than widening the field or becoming +N.
    static let appBarVisibleIcons = 5
    /// The frontmost app's own chat — its Context Dock, Finder's included — rather than
    /// Global, a CLI tool or an extension's panel.
    var isAppContextDock: Bool {
        !isGlobalScope && !appBundleID.isEmpty && !isCLIScope
            && scopedExtension == nil && scopedCommand == nil
    }
    /// Global's height: Global Context and every app's Context Dock are one bar (owner
    /// 2026-09-25: "why is the Context Dock smaller than Global Context?").
    var usesDockHeight: Bool { isGlobalScope || isAppContextDock }
    /// The field carries the small pill of the strip's icons.
    var showsFieldPills: Bool { isSearchField || showsTabBar }
    /// Every running app, uncut — what the strip draws from. `globalMatchIcons` is this
    /// list trimmed to what fits beside the field.
    @Published private(set) var allRunningIcons: [MatchDockIcon] = []
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
    @Published private(set) var isPinned = AppChatPromptModel.pinStore.bool(
        forKey: AppChatPromptModel.pinnedDefaultsKey)

    /// Where the pin preference lives. The app's own defaults — except under the test
    /// suite, which runs inside a copy of this app and so shares its domain: a developer
    /// who had pinned their own corner made every model the suite built start pinned, and
    /// a pinned model ignores `standDown`. Half a dozen tests across three files read
    /// "expected .mini, got .prompt" for weeks and were filed as an idle-timer flake. The
    /// test script names a separate suite in `CONTEXT_DOCK_DEFAULTS_SUITE`; nothing else
    /// sets it, so the app never sees it.
    static let pinStore: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["CONTEXT_DOCK_DEFAULTS_SUITE"],
            let store = UserDefaults(suiteName: suite)
        {
            return store
        }
        return .standard
    }()

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
    private let conversation: AppChatConversation
    let globalResultSource: GlobalContextResultSource
    /// Safari's open tabs, as the shared tab manager last read them. Tests replace it.
    var tabSource: () -> [SafariTab] = {
        // A quit Safari has no tabs, whatever the cache last held.
        NSRunningApplication.runningApplications(withBundleIdentifier: BrowserTabList.safariBundleID)
            .isEmpty ? [] : SafariTabManager.shared.cachedTabs(maxAge: 45)
    }
    /// The page Safari is showing, which leads the pills. Tests replace it.
    var currentTabURL: () -> String? = { SafariTabManager.shared.lastSelectedTab()?.url }
    /// Shows a tab in Safari. Tests replace it so they never script the user's Safari.
    var switchTab: (SafariTab) -> Void = { SafariTabManager.shared.switchTo($0) }
    /// Where pins live. Tests hand in their own so they never touch the user's pins.
    var dockPins: DockPinStore = .shared
    /// Loads a page in the app a pinned tab belongs to, when that tab is no longer open.
    /// Tests replace it.
    var openPage: (URL, String) -> Void = { url, bundleID in
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.open(
            [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    /// The consent gate a pinned menu command passes before it runs — the same one every
    /// menu click the AI makes goes through. Tests replace it.
    var askMenuConsent: ([String], String, String) async -> Bool = { path, bundleID, name in
        await AppAdapterManager.shared.ensureMenuConsent(
            path: path, targetBundleId: bundleID, appName: name)
    }
    /// Runs a menu path in this scope's app once consent is settled. Tests replace it.
    var performMenuPath: (([String]) -> Void)? = nil
    /// Reads Safari's tabs again, then calls back. Tests replace it so they never script
    /// the user's Safari.
    var refreshTabCache: (@escaping @MainActor () -> Void) -> Void = { done in
        SafariTabManager.shared.refreshCachedTabsIfNeeded { _ in done() }
    }
    private var standDownTask: Task<Void, Never>?
    private var conversationObservation: AnyCancellable?
    private var messagesObservation: AnyCancellable?
    private var selectionObservation: AnyCancellable?
    private var globalResultsObservation: AnyCancellable?
    private var runningAppsObservation: AnyCancellable?
    private var clipboardPillObservation: AnyCancellable?
    private var pinPillObservation: AnyCancellable?
    /// Guards against the reconfirming read below feeding straight back into the sink
    /// that triggered it — `refreshSelectionForCurrentScope` publishes through the same
    /// reader this observation reads, so calling it from inside the sink without this
    /// would re-enter itself on every publish it makes.
    private var isReconfirmingSelection = false
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
                guard let self, !self.isReconfirmingSelection else { return }
                // Global Context is scoped to no app in particular — `adoptScope` gives it
                // an empty bundle id on purpose — so matching against `appBundleID` the way
                // every other scope does could never pass, and the selection button had no
                // way to be anything but permanently nil there. What it means instead is
                // "whatever is selected in whichever real app is out there right now" — so
                // it trusts the reader's own bundle id, the same one `.appActivated`
                // already keeps pointed at a real app and never at us.
                let scopedTo =
                    self.isGlobalScope
                    ? (context.bundleId == Bundle.main.bundleIdentifier ? "" : context.bundleId)
                    : self.appBundleID
                let next = AppChatSelectionScope.from(context: context, scopedTo: scopedTo)
                if next == nil, self.selection != nil {
                    // A live event just claimed the selection is gone. That is either a
                    // real deselection, or the same race `refreshSelectionOnly` and
                    // `updateFocusedElement` already guard against — a read that came
                    // back empty because our own window just took key focus, not because
                    // the user deselected anything. This is the one path that skipped
                    // that check, which is what made the icon appear correctly on open
                    // and then erase itself moments later. One more explicit, targeted
                    // read before believing a passive event over what this session
                    // already knew — off the stack this sink is running on, since that
                    // read publishes right back through the reader this sink observes.
                    self.isReconfirmingSelection = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.refreshSelectionForCurrentScope()
                        self.isReconfirmingSelection = false
                    }
                    return
                }
                self.applySelection(from: context, scopedTo: scopedTo)
            }
        // The dock's own running-app row refreshes the instant an app launches or quits —
        // it watches `NSWorkspace` directly rather than waiting for the next keystroke.
        // This pill row reads the same running apps but only ever recomputed them when
        // typing changed, so a switch made anywhere but this field never showed up in it.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        runningAppsObservation = Publishers.Merge(
            workspaceCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            workspaceCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.updateGlobalTyping(for: self.query)
        }
        // Same staleness, one copy away: the clipboard pill leads this row precisely
        // because copying is the thing that just happened, but nothing here noticed a
        // copy until the next keystroke recomputed the row anyway.
        pinPillObservation = DockPinStore.shared.$pins
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateGlobalTyping(for: self.query)
            }
        clipboardPillObservation = ClipboardPanelController.shared.model.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateGlobalTyping(for: self.query)
            }
    }

    /// Set by `AppChatMenuBrowsing` as the user types in Global Context.
    ///
    /// Takes the running apps whole and cuts them here, because the two surfaces that draw
    /// them do not want the same number. Beside a 372-point field four icons fit and the
    /// rest are `+N`; the strip is a dock as wide as the screen, and cutting to four before
    /// it ever saw the list is why it stopped growing at four apps however much room stood
    /// empty beside it. `DockStripPlan` does the strip's own cutting, against the width it
    /// actually has.
    func setGlobalTyping(
        top: GlobalContextTopMatch?, running: [MatchDockIcon],
        fieldCapacity: Int = AppChatPromptMetrics.matchIconBaseCount
    ) {
        globalTopMatch = top
        allRunningIcons = running
        globalMatchIcons = Array(running.prefix(max(1, fieldCapacity)))
        globalOverflowCount = max(running.count - globalMatchIcons.count, 0)
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
        isShowingSelectionScope = false
        refreshSelectionForCurrentScope()
        loadMenuItems()
        // The running-app pills used to be a Global Context-only concept. They are really
        // "what else is running, and where can this field take me next" — true of this
        // scope too, and the dock's own equivalent shows them here as well.
        updateGlobalTyping(for: "")
        set(restingInputPhase)
        armForIdle()
    }

    /// The reader's snapshot, refreshed against whichever app this session's selection
    /// should reflect right now — opening a scope is itself an app switch, so without this
    /// the snapshot could still be of whatever the reader last saw, and the selection
    /// button either showed a stale selection or none at all until the next unrelated AX
    /// event happened to refresh it. `runAdapterAction` already does this for the same
    /// reason; nothing that opens a scope did before this.
    ///
    /// Global Context has no one app to refresh against — `adoptScope` gives it an empty
    /// bundle id on purpose — so it reads whichever real app the menu bar says owns the
    /// screen right now instead, the same resolver the hotkey path already trusts to never
    /// resolve to us.
    func refreshSelectionForCurrentScope() {
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        if isGlobalScope {
            if let app = AppDelegate.shared?.menuBarOwningUserFacingApplication(),
                app.bundleIdentifier != ownBundleID
            {
                AXContextReader.shared.refreshLightweight(from: app)
                AXContextReader.shared.refreshSelectionOnly(from: app)
            }
        } else if !appBundleID.isEmpty,
            let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == appBundleID && !$0.isTerminated
            })
        {
            AXContextReader.shared.refreshLightweight(from: app)
            AXContextReader.shared.refreshSelectionOnly(from: app)
        }
        let context = AXContextReader.shared.current
        let scopedTo =
            isGlobalScope
            ? (context.bundleId == ownBundleID ? "" : context.bundleId)
            : appBundleID
        applySelection(from: context, scopedTo: scopedTo)
    }

    /// Sets `selection` and `selectionContent` together — the two must never disagree, or
    /// the icon could promise a selection the in-place view then has nothing to show.
    private func applySelection(from context: AXContext, scopedTo bundleID: String) {
        selection = AppChatSelectionScope.from(context: context, scopedTo: bundleID)
        guard selection != nil else {
            selectionContent = nil
            return
        }
        if !context.selectedFilePaths.isEmpty {
            selectionContent = .files(context.selectedFilePaths.map { URL(fileURLWithPath: $0) })
        } else if let text = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            selectionContent = .text(text)
        } else {
            selectionContent = nil
        }
    }

    /// The selection icon, clicked: show what is selected in place of this session's own
    /// suggestions, rather than opening the separate Selection Scope card on top of it.
    func toggleSelectionScope() {
        guard selection != nil || isShowingSelectionScope else { return }
        isShowingSelectionScope.toggle()
        // The chip sits right above the field either way; the suggestions board sitting
        // above that too was three things stacked for what should read as one small
        // addition to the composer, not a second board's worth of attention.
        if isShowingSelectionScope, phase == .suggesting { set(.prompt) }
        touch()
    }

    /// Esc back out of the in-place selection view — to whatever this session was showing
    /// before, not a dismiss. Returns false when there was nothing to back out of, so the
    /// key keeps its other meanings.
    @discardableResult
    func leaveSelectionScope() -> Bool {
        guard isShowingSelectionScope else { return false }
        isShowingSelectionScope = false
        touch()
        return true
    }

    /// The field, alone. It used to open on the app's suggestions whenever there were any,
    /// on the theory that a blank field asks the user to guess what the app can do — and
    /// what that produced was a sheet of 224 rows over a field nobody had typed into, gone
    /// again two seconds later. The owner asked not to see it (2026-09-16). The list is
    /// still there: ↓ opens it (`moveMenuFocus`), the same door the dock's own results
    /// sheet has, and the capability summary under the field still says what is in scope.
    private var restingInputPhase: AppChatPromptPhase {
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Typed: the field alone, same as the dock. Typing never pops the sheet open by
        // itself, and it closes right back down if a down-arrow peek was open when the next
        // character landed — the arrow key is the only door in.
        if typed { return .prompt }
        // A window snapshot occupies the board even with no rows to list, and so does an
        // extension's own interface.
        if showsWindowSnapshot || showsExtensionPanel { return .suggesting }
        // A scope stepped into from Global shows only what it found. With nothing found the
        // field rests alone rather than opening an empty board. An *app* stepped into from
        // Global never reaches this line — it answers with its window snapshot above — so
        // what this governs is Finder and a CLI tool, where the rows are the thing the step
        // went to fetch: the search results, the tool's subcommands.
        if returnsToGlobalScope { return rows.isEmpty ? .prompt : .suggesting }
        // Attaching a file is composing a question about it. A list open over that is
        // answering something the user has already stopped asking.
        if !attachments.isEmpty { return .prompt }
        // A list the user arrowed open stays open while they are still standing in it —
        // this is also asked when a live menu read lands, and that must not close what was
        // just opened. The focused row is what "still in it" means, and it is why the rule
        // reads it rather than the phase alone: a list opened to pick "Library" out of what
        // was typed stayed open after the row ran, and `rows` had meanwhile been rebuilt
        // for the now-empty field — so what stood over that field was every action the app
        // has, 174 of them, which is the sheet the owner asked not to see wearing a
        // different coat. Taking a row or asking a question lets go of the focus, and the
        // list goes with it.
        if phase == .suggesting, focusedMenuIndex != nil, !rows.isEmpty { return .suggesting }
        // Nothing else opens the list by itself: not a scope-in, not a cleared field, not
        // a detached file, not the pointer coming back to the badge. Only the arrows.
        return .prompt
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
        Self.pinStore.set(isPinned, forKey: Self.pinnedDefaultsKey)
        if isPinned {
            cancel()
        } else {
            armForIdle()
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
        // A dock has no clock to put back.
        guard !isPinned, !isAnswering, phase.isVisible, phase != .dock else { return }
        armForIdle()
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
        applySelection(from: AXContextReader.shared.current, scopedTo: bundleID)
        isShowingSelectionScope = false
        stopAwaitingAnswer()
        hasPresentedConversation = !messages.isEmpty
        set(hasPresentedConversation ? .chat : restingInputPhase)
        if isPinned || isPointerInside {
            cancel()
        } else {
            armForIdle()
        }
    }

    // MARK: - Standing down

    /// One step smaller. An idle prompt shrinks to the frontmost app's own icon rather
    /// than a generic dot, so the corner still says which app it is about, and it keeps
    /// any half-written question for whoever comes back for it.
    func standDown() {
        guard !isPinned, !isPointerInside, !isAnswering else { return }
        switch phase {
        case .suggesting:
            // The dock's own results sheet does not show at all until the arrow keys ask
            // for it; this offer is the same kind of thing, so idling closes it back to
            // just the field rather than shrinking the whole thing down to a badge over
            // an offer nobody asked to see again.
            set(.prompt)
            armForIdle()
        case .prompt where canRestAsDock:
            // The dock has no timer of its own: it stays until Esc, a click outside, or a
            // Space switch, the way the Dock does.
            set(.dock)
        case .prompt, .chat:
            set(.mini)
            arm(after: Self.miniDwell)
        case .mini:
            dismiss()
        case .dock, .hidden:
            break
        }
    }

    /// An empty Global field with the setting on is the only thing that rests as a dock.
    var canRestAsDock: Bool {
        usesDockShell
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && autoShrinkEnabled()
    }

    /// The strip's running section: the dock's own running pills, minus the removed ones.
    var stripIcons: [MatchDockIcon] {
        allRunningIcons.filter { icon in
            guard let bundleID = icon.bundleID else { return true }
            return !hiddenRunningBundleIDs.contains(bundleID)
        }
    }

    func hideRunningApp(_ bundleID: String) {
        hiddenRunningBundleIDs.insert(bundleID)
    }

    /// The corner's own affordances that join the strip: the clipboard when a copy just
    /// happened, the selection when there is one, the result of an action for a few seconds
    /// after it ran. Same rules as the field's own row.
    func dockToolCount(clipboardVisible: Bool, feedbackVisible: Bool = false) -> Int {
        // A Safari scope's bar is its tabs alone (owner 2026-09-25): the Context Dock's
        // own things, not Global's.
        guard !showsTabBar else { return 0 }
        return (clipboardVisible ? 1 : 0) + (selection != nil ? 1 : 0) + (feedbackVisible ? 1 : 0)
    }

    /// The first printable character brings the field back and lands in it. Anything the
    /// field would have done with the key itself — arrows, Return, Esc — is not this.
    @discardableResult
    func expandFromDock(seeding text: String?) -> Bool {
        guard phase == .dock else { return false }
        set(.prompt)
        if let text, !text.isEmpty {
            query = text
            queryChanged()
        }
        armForIdle()
        return true
    }

    /// Puts the plugin card away however it came up. A tapped-open card is closed by
    /// forgetting the tap; a hover-opened one by letting go of the hover, so it stays away
    /// until the pointer leaves the icon and comes back — the pointer is still on the icon
    /// that opened it, and a card that came straight back would read as the × misfiring.
    func dismissPluginCard() {
        pluginCardPinID = nil
        windowRowTask?.cancel()
        dockPreviewTarget = nil
    }

    func togglePinPreviewPinned(_ id: UUID) {
        pinnedPreviewPinID = pinnedPreviewPinID == id ? nil : id
        if pinnedPreviewPinID == nil { scheduleWindowRowUpdate() }
    }

    func togglePinPreviewExpanded() {
        pinPreviewExpanded.toggle()
    }

    /// What the card slot shows: a pinned card wins over whatever the pointer is on.
    nonisolated static func previewTarget(
        hovered: DockHoverTarget?, pinnedPin: UUID?
    ) -> DockHoverTarget? {
        if let pinnedPin { return .pin(id: pinnedPin) }
        return hovered
    }

    /// Puts away the card above the strip — windows, pin preview — and leaves the strip up.
    /// An app quit from its window row takes the row with it; the dock stays where it was.
    func dismissDockPreview() {
        windowRowTask?.cancel()
        hoveredStripTarget = nil
        dockPreviewTarget = nil
        pointerInWindowRow = false
    }

    func windowRowHovered(_ inside: Bool) {
        pointerInWindowRow = inside
        if inside { windowRowTask?.cancel() } else { scheduleWindowRowUpdate() }
    }

    private func scheduleWindowRowUpdate() {
        windowRowTask?.cancel()
        let target = hoveredStripTarget
        let delay: TimeInterval = target == nil ? 0.15 : 0.25
        windowRowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if target == nil, self.pointerInWindowRow { return }
            self.dockPreviewTarget = Self.previewTarget(
                hovered: target, pinnedPin: self.pinnedPreviewPinID)
        }
    }

    /// ← on an empty Global field folds it now rather than waiting out the dwell.
    @discardableResult
    func foldToDock() -> Bool {
        guard phase == .prompt, canRestAsDock, !isPinned, !isAnswering else { return false }
        cancel()
        set(.dock)
        return true
    }

    /// The pointer rested on an app bar's pill: show the big bar of its pins and tabs at
    /// once (owner 2026-09-26), as resting on Global's small pill does. Asked for by hand,
    /// so "keep open" does not refuse it — that setting is about not folding on its own.
    @discardableResult
    func expandAppBar() -> Bool {
        guard showsTabBar, usesDockShell, phase == .prompt, !isAnswering,
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        cancel()
        set(.dock)
        return true
    }

    /// → on the dock does what → on an empty Global field does: step into the first
    /// running app. The caller falls through to the presentation's own right-arrow when
    /// there is nothing to step into.
    @discardableResult
    func arrowRightFromDock() -> Bool {
        guard phase == .dock else { return false }
        guard scopeIntoFirstRunningApp() else { return false }
        if phase == .dock {
            set(.prompt)
            syncListPhase()
        }
        return true
    }

    /// Switching Space is leaving, and the question was about an app on the screen the
    /// user walked away from.
    func userLeftTheSpace() {
        isPointerInside = false
        if !isPinned { armForIdle() }
    }

    func dismiss() {
        cancel()
        windowRowTask?.cancel()
        dockPreviewTarget = nil
        hoveredStripTarget = nil
        pluginCardPinID = nil
        query = ""
        suggestions = []
        capabilitySummary = ""
        attachments = []
        isPinned = false
        hasPresentedConversation = false
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
        // The question was asked from the list, not into it.
        focusedMenuIndex = nil
        query = ""
        attachments = []
        hasPresentedConversation = true
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

    /// Arms the idle timer for whichever phase is showing right now: the "what this app
    /// can do" offer gets the short dwell, everything else gets the long one. Callers used
    /// to all reach for the same delay regardless of what they were arming down from,
    /// which is what let the suggestions list sit open as long as a real conversation did.
    private func armForIdle() {
        if phase == .suggesting { arm(after: Self.suggestionsDwell); return }
        arm(after: phase == .prompt && canRestAsDock ? Self.dockDwell : Self.idleDwell)
    }

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
        // A plugin's card belongs to the strip; leaving the dock takes it down with it.
        if next != .dock { pluginCardPinID = nil }
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
