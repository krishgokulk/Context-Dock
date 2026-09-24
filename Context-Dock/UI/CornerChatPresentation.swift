// CornerChatPresentation.swift
// Context-Dock
//
// Presentation state for the one corner chat shell. The two chat modes keep their own
// models and pipelines; this object only decides which one the shell is showing.

import AppKit
import Combine
import Foundation

enum CornerChatMode: Equatable {
    case frontmostApp
    /// Everything running, not one app: the machine's menus and actions, ranked together.
    /// The layer above the frontmost app — its scope widened, not a different conversation.
    case globalContext
    case general
}

/// Where the corner's keys and swipes go — the Dock's navigation, in one place, so the keys
/// and the swipes can never disagree about what sits next to what (00-DOCK-AND-CORNER §4b).
///
///                  Global Context
///                        ↑↓
///     General Chat  ←/→  Context Dock (the frontmost app)
///                        ↑↓
///                    Media Dock
///
/// General Chat is a place you step into from either scope and back out of to the one you
/// came from. Global Context and the frontmost app are layers, one above the other. The
/// Media Dock is not in the corner yet (00-DOCK-AND-CORNER §4), so the step below the
/// frontmost app goes nowhere for now.
enum CornerNavigation {
    enum Move: Equatable {
        /// ← on an empty field.
        case leftKey
        /// → on an empty field.
        case rightKey
        /// A sideways swipe. `right` is the fingers moving right.
        case swipeSideways(right: Bool)
        /// ↑, or a swipe down — the layer above.
        case layerUp
        /// ↓, or a swipe up — the layer below.
        case layerDown
    }

    /// Pure: the scope a move lands on, or nil where the Dock does nothing.
    /// `origin` is the scope General Chat was entered from.
    static func destination(
        for move: Move, from mode: CornerChatMode, origin: CornerChatMode
    ) -> CornerChatMode? {
        if mode == .general {
            switch move {
            // Back to where the trip started — by the key pointing that way, by any sideways
            // swipe (the Dock toggles), and by either vertical move.
            case .rightKey, .swipeSideways, .layerUp, .layerDown: return origin
            case .leftKey: return nil
            }
        }
        switch move {
        case .leftKey, .swipeSideways(right: true): return .general
        case .rightKey, .swipeSideways(right: false): return nil
        case .layerUp: return mode == .frontmostApp ? .globalContext : nil
        case .layerDown: return mode == .globalContext ? .frontmostApp : nil
        }
    }
}

/// A trackpad gesture over the corner's field, read the way the Dock reads it: sideways
/// past 70 points and 1.8 times the vertical travel, vertical past 55 points and 1.15 times
/// the sideways travel. Totals include the momentum, so a fast flick counts.
enum CornerSwipe {
    static func classify(dx: CGFloat, dy: CGFloat) -> CornerNavigation.Move? {
        let horizontal = abs(dx)
        let vertical = abs(dy)
        if horizontal > 70, horizontal > vertical * 1.8 {
            return .swipeSideways(right: dx > 0)
        }
        if vertical > 55, vertical > horizontal * 1.15 {
            // The Dock's sign: negative is the swipe up, which goes to the layer below.
            return dy < 0 ? .layerDown : .layerUp
        }
        return nil
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
                guard let self, self.mode != .general, phase == .hidden else { return }
                self.isVisible = false
            }
            .store(in: &sinks)

        // A Global Context row that launched, activated, or sent a menu command to an app
        // is the user asking to go there — not an incidental background switch, which is
        // why this is a deliberate signal from the model rather than a raw frontmost-app
        // listener that would just as readily fire while the user is mid-search for
        // something unrelated.
        self.appChat.onAppLaunchedFromGlobalContext = { [weak self] name, bundleID in
            self?.showFrontmostApp(target: CornerChatTarget(name: name, bundleID: bundleID))
        }
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
        #if DEBUG
        // Temporary trace: who brings the app chat up while the selection card is showing.
        let trace = "\(Date()) showFrontmostApp(\(target.name))\n"
            + Thread.callStackSymbols.prefix(14).joined(separator: "\n") + "\n\n"
        if let data = trace.data(using: .utf8),
            let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/dorax-trace.log"))
        {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? trace.write(toFile: "/tmp/dorax-trace.log", atomically: true, encoding: .utf8)
        }
        #endif
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

    /// The scope General Chat was entered from, and goes back to.
    private(set) var generalOrigin: CornerChatMode = .frontmostApp

    /// ← on an empty field: into General Chat. With something typed the arrow is the caret's.
    @discardableResult
    func handleLeftArrow(draft: String) -> Bool {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return navigate(.leftKey)
    }

    /// → on an empty field: out of General Chat, back to where the trip started.
    @discardableResult
    func handleRightArrow(draft: String) -> Bool {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return navigate(.rightKey)
    }

    /// ↑ / ↓ with nothing to move through: the layer above or below.
    @discardableResult
    func handleLayerKey(up: Bool) -> Bool {
        navigate(up ? .layerUp : .layerDown)
    }

    /// Carry out one move of `CornerNavigation`. False where the Dock does nothing.
    @discardableResult
    func navigate(_ move: CornerNavigation.Move) -> Bool {
        guard let next = CornerNavigation.destination(
            for: move, from: mode, origin: generalOrigin)
        else { return false }
        if next == .general { generalOrigin = mode }
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
            guard let target = currentFrontmostTarget() ?? latestTarget else { return }
            showFrontmostApp(target: target)
        }
    }

    /// The app to show, resolved fresh rather than trusting whatever was frontmost when
    /// the corner first opened.
    ///
    /// `latestTarget` is a snapshot from whenever this session was last told to summon —
    /// the hotkey, or a Global Context row that launched something. Nothing updates it in
    /// between, so a step away from the corner to a different real app, taken without
    /// touching the corner at all, left this walking back to whichever app was frontmost
    /// when the corner opened rather than the one actually in front now. Reading
    /// `NSWorkspace.shared.frontmostApplication` here would not fix it either — this fires
    /// while the corner's own panel holds key focus, which reports us, the same trap the
    /// hotkey path already routes around via the menu-bar owner instead.
    private func currentFrontmostTarget() -> CornerChatTarget? {
        guard let target = frontmostTargetProvider() else { return nil }
        latestTarget = target
        return target
    }

    /// Who is in front, as a closure.
    ///
    /// The default is the real read, and it stays the behaviour: returning to the app scope
    /// goes to the app in front NOW. A test cannot have an opinion about that — the answer is
    /// whatever app happens to own the menu bar while the suite runs — so two tests here
    /// passed or failed depending on what was open on the developer's screen (#30). They set
    /// this to `{ nil }` and walk back to the target they gave, which is the thing they are
    /// actually about.
    var frontmostTargetProvider: () -> CornerChatTarget? = {
        guard let app = AppDelegate.shared?.menuBarOwningUserFacingApplication(),
              !app.isTerminated,
              let bundleID = app.bundleIdentifier, !bundleID.isEmpty
        else { return nil }
        return CornerChatTarget(
            name: app.localizedName ?? bundleID,
            bundleID: bundleID,
            suggestions: AppChatSuggestionProvider.suggestions(for: app),
            summary: AppChatSuggestionProvider.summary(for: app))
    }

    /// A finished swipe over the field. Whatever is typed stays where it is — the owner's
    /// call (§4b W10): the Dock swipes with text in the field, and so does the corner; each
    /// scope keeps its own draft.
    @discardableResult
    func handleSwipe(_ move: CornerNavigation.Move) -> Bool {
        navigate(move)
    }

    /// The sideways half, by distance — kept for the callers and tests that speak in points.
    @discardableResult
    func handleHorizontalSwipe(deltaX: CGFloat, draft: String = "") -> Bool {
        guard let move = CornerSwipe.classify(dx: deltaX, dy: 0) else { return false }
        return handleSwipe(move)
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
        CornerDockController.shared.publishKeyboardOwner()
        CornerDockController.shared.requestComposerFocus()
        Task { @MainActor in
            CornerDockController.shared.publishKeyboardOwner()
            CornerDockController.shared.requestComposerFocus()
        }
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
