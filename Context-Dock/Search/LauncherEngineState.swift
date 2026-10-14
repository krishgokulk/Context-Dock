// LauncherEngineState.swift
// Context-Dock
//
// What the old launcher remembers between keystrokes, held outside SwiftUI (#257, stage E1).
//
// These were `@State` on `LauncherView`, which only stays alive while that view sits in a
// window. The engine the Corner runs on reads them, and it is on its way out of the view
// (E2: a headless `DockEngine`). Moved unchanged: same names, types, defaults and comments.

import AppKit
import Combine
import SwiftUI

@MainActor
final class LauncherEngineState: ObservableObject {
    static let shared = LauncherEngineState()

    @Published var searchState: SearchState = SearchState()
    @Published var queryChangeTask: Task<Void, Never>? = nil
    @Published var queryChangeGeneration: Int = 0
    // Selected note in the Quick Note (provider:notepad) split editor scope.
    @Published var notepadSelectedNoteID: UUID? = nil
    // True while a Quick Note AI prompt is generating into the open note.
    @Published var notepadAIGenerating: Bool = false
    // Frontmost-window context attached to the next Quick Note AI prompt.
    @Published var notepadFrontmostContext: String? = nil
    @Published var notepadFrontmostLabel: String? = nil
    @Published var notepadCapturedText: String? = nil
    // Image/file attachments for the next Quick Note AI prompt.
    @Published var notepadAttachments: [URL] = []
    // Clipboard scope: selected source-app filter (empty = All).
    @Published var clipboardSourceFilterBundleId: String = ""
    @Published var clipboardSourceFilterName: String = ""
    @Published var clipboardSourcePillFocusIndex: Int? = nil
    // Running apps explicitly shared with General AI chat from the app picker.
    @Published var chatFocusApps: [GeneralChatFocusApp] = []
    /// The newest thing this general-chat session built, if it built one.
    ///
    /// The dock throws no window at the user here: the sheet is where they asked, so the
    /// artifact arrives as a button beside Clear and opens only when pressed. Session
    /// state, not a store read — an artifact from a thread that has since been cleared is
    /// not something this composer should still be offering.
    @Published var generalChatArtifact: URL? = nil
    /// True while a submitted dock turn is carrying files or captured text. Early routes
    /// check it so an attachment is never dropped without the user being told.
    @Published var pendingAttachmentTurn: Bool = false
    @Published var isShowingChatFocusAppPicker: Bool = false
    @Published var hoveredChatFocusBundleId: String? = nil
    // These are isolated from searchState so their mutations don't trigger a struct-wide re-render
    // (SwiftUI re-renders all readers of a @State struct when ANY property changes)
    // General launcher/search state lives in LauncherViewModel.
    // rem-powered Reminders panel chat
    // AI chat session state lives in AIChatViewModel.
    // Tool-removal cleanup banner
    // Per-panel terminal history — keyed by searchState.activeSmartQueryKey or searchState.contextApp bundleID
    @Published var panelConsoleLinesMap: [String: [(line: String, isCommand: Bool)]] = [:]
    @Published var panelShowConsoleMap: [String: Bool] = [:]
    @Published var panelConsoleHeight: CGFloat = 160
    // Per-panel embedded PTY terminals (real SwiftTerm instances)
    @Published var panelTerminalControllers: [String: TerminalHostController] = [:]
    @Published var livePanelMode: LauncherView.LivePanelMode = .results([])
    @Published var livePanelVisible: Bool = false  // drives the slide-in animation
    /// One cancellable idle timer for a batch of Global Context quit actions. Keeping
    /// this in the view avoids polling and makes a second quit simply reset the timer.
    @Published var globalQuitIdleDismissTask: Task<Void, Never>? = nil
    @Published var globalQuitIdleDismissGeneration: Int = 0
    @Published var qlRightClickPos: CGPoint? = nil  // position for QL pill context menu
    @Published var panelTerminalHost: TerminalHostController? = nil
    @Published var l2: L2State = L2State()
    @Published var pendingTerminalCommand: LauncherView.PendingTerminalCommand? = nil
    @Published var pendingFinderOperation: PendingFinderOperation? = nil
    @Published var finderDesktopRecentPills: [DockPill] = []
    @Published var finderDesktopIndexedPills: [DockPill] = []  // all user-folder files, pre-loaded for instant filter
    /// Non-nil while browsing INTO a folder in Finder desktop mode: the result list
    /// shows that folder's contents instead of the search results. Right-arrow on a
    /// focused folder drills in; Backspace on an empty field pops back out.
    @Published var finderBrowsePath: String? = nil
    /// Multi-file clipboard clips the user expanded into a stack of individual files.
    @Published var expandedClipboardEntryIDs: Set<UUID> = []
    /// Captured text (OCR / on-screen grab) attached to the frontmost-app chat — the
    /// "Capture Text" action feeds on-screen content (e.g. a Messages thread) to the
    /// scoped chat so the model can act on what's visible.
    @Published var contextDockChatCapturedText: String? = nil
    /// Files / screenshots attached to the frontmost-app chat via its + menu.
    @Published var contextDockChatFiles: [URL] = []
    @Published var finderDesktopFullIndexPrimed: Bool = false  // complete (all-file-type) index built once per session
    @Published var finderDesktopSearchPills: [DockPill] = []
    @Published var finderDesktopSearchQuery: String = ""
    /// Grace window right after a hotkey open during which a launch-time Selection Scope
    /// (frozen payload) survives the `.activateContextDock` posts the open sequence fires.
    @Published var launchSelectionScopeGraceUntil: Date = .distantPast
    /// The frozen selection that makes Selection Scope active. Deliberately INDEPENDENT of
    /// globalContextActivation: selections come from the frontmost app, so the scope belongs to
    /// whichever surface the user is on (Context Dock or Global Context). Storing it inside the
    /// activation meant entering the scope forced Global Context — launching with a frontmost
    /// selection jumped surfaces, and clicking the selection icon in Context Dock threw the user
    /// out of it.
    @Published var selectionScopePayload: GlobalContextActivation? = nil
    /// Hotkey-opened Selection Scope starts as a bare compact bar (input + selection pill only),
    /// matching the idle launcher shell. Typing — or ↓ — unfolds the actions sheet. Entering the
    /// scope from the selection button keeps the sheet open immediately, as before.
    @Published var selectionScopeSheetCollapsed: Bool = false
    /// True only when the frozen selection came from a writable text control, so "Replace text"
    /// is offered for a Mail draft or code editor but not for Finder files or a read-only page.
    @Published var selectionScopeSourceAcceptsReplacement: Bool = false
    /// Set by the Selection Scope router when it ran a real row, so the answer path knows the
    /// work actually happened (and may attach app buttons). Nil means nothing executed.
    @Published var selectionRouterExecutedRouteTitle: String? = nil
    /// Set when the router checked the whole catalog and found no route — turns the fallback
    /// answer into "here's the gap, here's the extension" instead of a guess.
    @Published var selectionRouterNoRouteNote: String? = nil
    /// Recipient remembered by the `deliver.email` route while the answer is still being written.
    /// The finished text becomes the draft body, so "summarise this and mail it to X" is one
    /// request instead of two disconnected ones.
    @Published var selectionRouterPendingEmail: PendingSelectionEmail? = nil
    /// Activation generation already entered, so the window-open handler and the posted
    /// activation don't both rebuild the surface for one hotkey press.
    @Published var lastAppliedSelectionActivation: Int = -1
    /// Cloud-consent request rendered inline in the chat (instead of the floating window)
    /// whenever a chat surface is already on screen.
    @Published var pendingPrivacyApproval: AIPrivacyApprovalCenter.PendingApproval? = nil
    @Published var pendingCapabilityApproval: AICapabilityApprovalCenter.PendingApproval? = nil
    /// Adapter / menu-command approval rendered inline in the chat (instead of the
    /// floating panel) whenever a chat surface is already on screen.
    @Published var pendingAdapterApproval: AdapterActionRequest? = nil
    /// Candidates behind the pick-one buttons on the last answer, kept so a click runs the
    /// exact route that was offered.
    @Published var pendingActionCandidates: [DoraXActionCandidate] = []
    @Published var pendingActionQuery: String = ""
    /// "This scope has no tool for that" offer — link an installed CLI, or install one.
    @Published var pendingCapabilityGap: CapabilityGapService.Gap? = nil
    @Published var capabilityGapWorking: Bool = false
    @Published var lastAppliedDockHeightPreset: DockHeightPreset? = nil
    @Published var lastAppliedDockSurfaceMode: DockSurfaceMode? = nil
    /// Global Context's collapsed⇄expanded phase at the last applied frame. The height preset
    /// and surface mode both stay put across that transition, so without this the resize
    /// cannot tell it apart from a row appearing.
    @Published var lastAppliedGlobalTypingPhase: GlobalContextTypingPhase? = nil
    // Visible shell height is staged separately from the NSWindow's target capacity so the
    // input stays pinned while only the area beneath it animates open/closed.
    @Published var renderedDockHeight: CGFloat? = nil
    @Published var isHoveringSearchIcon: Bool = false
    @Published var isHoveringInputField: Bool = false
    @Published var suppressMouseDrivenInteractionUntil: Date = .distantPast
    @Published var suppressMouseDrivenInteractionOrigin: NSPoint? = nil
    // Swipe gesture monitor
    // Swipe and launcher hover state lives in LauncherViewModel.
    @Published var isHoveringNowPlayingIcon: Bool = false  // Hover over Now Playing icon
    @Published var showMediaHoverDock: Bool = false  // Popover-style media dock on hover

    // The view models the launcher used to own as `@StateObject`s (#257 E2): one copy, shared
    // by the window's view and the windowless engine (`DockEngine`).
    let selectionModel = SelectionObserverModel()
    let launcherViewModel = LauncherViewModel()
    let globalContextViewModel = GlobalContextViewModel()
    let finderContext = FinderContextViewModel()
    let contextDockViewModel = ContextDockViewModel()
    let aiChatViewModel = AIChatViewModel()

    private init() {}
}
