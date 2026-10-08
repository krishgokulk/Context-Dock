// CornerDockWindow.swift
// Context-Dock
//
// The single floating shell in the bottom-right corner. The clipboard and the Drop Shelf
// keep separate jobs, separate stores, and separate rules — but they share this one
// window, because the Unified Dock Surface rule is one shell with mode-specific content,
// and two floating containers stacked in the same corner is what it forbids.
//
// The window is fixed at the size of the largest thing it will ever hold and never
// resizes; every pill/card morph is a SwiftUI frame change inside it.

import AppKit
import Combine
import SwiftUI

final class CornerDockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosts the shell. Mouse events are answered only where a pill actually is, so the
/// transparent remainder of the shell never swallows a click meant for the app beneath.
final class CornerDockHostView: NSView {
    weak var controller: CornerDockController?
    var interactiveRects: [NSRect] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DropShelfMetrics.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    /// Sees a drag over the shell, accepts none of it: the shelf's icon (and, open, its card)
    /// is the one drop target, so a release anywhere else on the shell does what it did
    /// before the shelf existed.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropShelfController.shared.dragEntered()
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DropShelfController.shared.dragExitedPill()
    }
}

@MainActor
final class CornerDockController: NSObject {
    static let shared = CornerDockController()

    private var panel: CornerDockPanel?
    private var hostView: CornerDockHostView?
    private var hoverMonitors: [Any] = []
    /// When Command went down alone, for the tap gesture above.
    private var commandTapStarted: Date?
    /// A switch waiting to see whether this tap turns into the system-wide double-Command
    /// gesture instead. Cancelled by the next Command press, so a real double-tap always
    /// wins the ambiguity rather than this firing first and the double-tap undoing it.
    private var pendingCommandSwitch: DispatchWorkItem?
    private var accumulatedChatSwipeX: CGFloat = 0
    private var accumulatedChatSwipeY: CGFloat = 0
    /// One action per swipe: set once a gesture has acted, so its momentum ending does not
    /// act again.
    private var didActInCurrentSwipe = false
    private var sinks: Set<AnyCancellable> = []
    /// Auto-hide has slid the shell below the bottom edge. The panel stays ordered in —
    /// transparent and ignoring the mouse — so the hover monitors keep watching for the
    /// pointer to come back to the edge.
    private(set) var isAutoHidden = false
    private var pendingAutoHide: DispatchWorkItem?
    /// Where `position` last put the shell when shown, and the screen it did it on. Auto-hide
    /// measures from these rather than from the live frame, which is elsewhere while hidden
    /// and in between while sliding.
    private var shownPanelOrigin: NSPoint = .zero
    private var dockScreenFrame: CGRect = .zero
    /// The pointer has been on the dock since it last came up. Leaving it then is the
    /// macOS Dock's quick hide; never having come near it — the dock was raised by a hotkey —
    /// waits out the idle delay instead.
    private var pointerVisitedDock = false
    /// The pointer resting on the apps beside the field, waiting out the dwell before the
    /// field folds into the dock (`foldWhenRestingOnApps`).
    fileprivate var appsFoldIntent: DispatchWorkItem?
    /// The last span the shell drew, so the edge can be matched to it while nothing shows.
    private var lastShownContentRect: CGRect = .zero
    /// Watches the bottom edge while the shell is not on screen at all, so touching it can
    /// bring the dock up. Installed only while auto-hide is on.
    private var edgeMonitors: [Any] = []
    /// The prompt's phase before its latest change, to tell a fold from the field apart.
    private var lastPromptPhase: AppChatPromptPhase = .hidden
    /// Whether the latest phase change may arm the keyboard (`phaseChangeMayTakeKeys`).
    private var phaseChangeMayArm = true
    /// An edge summon passes through the field on its way to the strip; that is not the
    /// user finishing with the keyboard, so the fold it makes keeps the keys.
    private var edgeSummonKeepsKeys = false
    /// Menus of this app being tracked right now. The corner's context menus are ordinary
    /// NSMenus, so their tracking notifications say when one is open.
    private var openMenuCount = 0
    /// The strip's own icon menu — a SwiftUI popover, which posts no NSMenu tracking.
    private var stripMenuOpen = false
    /// When the field last folded into the strip, so the hide can wait for that morph.
    private var foldedAt: Date?

    func stripMenuDidChange(open: Bool) {
        guard stripMenuOpen != open else { return }
        stripMenuOpen = open
        syncAutoHide()
    }

    private var clipboardModel: ClipboardPanelModel { ClipboardPanelController.shared.model }
    /// The result of the last action the corner ran, for a few seconds. One more tool slot
    /// in the strip while it shows, so the shell is measured for it.
    private var actionFeedback: CornerActionFeedback { CornerActionFeedback.shared }
    /// The selection, when the user has raised it. A corner surface like the others, not
    /// the launcher wearing a smaller coat.
    let selection = SelectionScopeModel()
    private var shelf: DropShelfPresentation { DropShelfController.shared.presentation }
    let chatPresentation = CornerChatPresentation.shared
    let keyboardState = CornerDockKeyboardState()
    var prompt: AppChatPromptModel { chatPresentation.appChat }

    var window: NSPanel? { panel }

    /// The corner chat is on screen in some phase — dock, field, badge, conversation — so a
    /// result can be shown here instead of in a floating pill of its own.
    var isCornerChatVisible: Bool {
        chatPresentation.isVisible && panel?.isVisible == true
    }

    func activate() {
        ensurePanel()
        refresh()
    }

    // MARK: - Window

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = CornerDockPanel(
            contentRect: NSRect(
                origin: .zero, size: CornerDockLayout.panelSize(for: anchor)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // SwiftUI draws the glass shadow; a native one would square off the cards.
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.identifier = GlassFloatingPanel.identifier

        let host = CornerDockHostView(
            frame: NSRect(origin: .zero, size: CornerDockLayout.panelSize(for: anchor)))
        host.controller = self
        host.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: CornerDockSurface())
        hosting.frame = host.bounds
        hosting.autoresizingMask = [.width, .height]
        host.addSubview(hosting)
        p.contentView = host

        panel = p
        hostView = host
        position()

        // One shell, two independent surfaces: it follows both and shows itself whenever
        // either has something to say.
        // Clipboard and shelf are tied to the Space where they appeared. Frontmost App
        // Chat is different: its identity is the live app on the active Space, so it
        // follows the same environment update as the main Context Dock chat.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ClipboardPanelController.shared.model.userLeftTheSpace()
                DropShelfController.shared.presentation.collapse()
                CornerDockController.shared.prompt.userLeftTheSpace()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard
                        let app = AppDelegate.shared?.menuBarOwningUserFacingApplication(),
                        let bundleID = app.bundleIdentifier,
                        bundleID != Bundle.main.bundleIdentifier
                    else { return }
                    ContextDockEnvironment.shared.frontmostAppDidChange(
                        name: app.localizedName ?? "", bundleID: bundleID)
                }
            }
        }

        ContextDockEnvironment.shared.frontmostAppUpdates
            .sink { [weak self] appInfo in
                Task { @MainActor in
                    guard let self, self.prompt.phase.isVisible else { return }
                    let app = NSWorkspace.shared.runningApplications.first {
                        $0.bundleIdentifier == appInfo.bundleID && !$0.isTerminated
                    }
                    // Let LauncherView consume the same environment event first, then
                    // switch the shared session and redraw this second presentation.
                    await Task.yield()
                    self.prompt.frontmostAppDidChange(
                        app: appInfo.name,
                        bundleID: appInfo.bundleID,
                        suggestions: AppChatSuggestionProvider.suggestions(for: app),
                        summary: AppChatSuggestionProvider.summary(for: app))
                    self.prompt.loadMenuItems()
                }
            }
            .store(in: &sinks)

        clipboardModel.$phase.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.publishKeyboardOwner()
            }
        }.store(in: &sinks)
        clipboardModel.$isKeyboardArmed.sink { [weak self] _ in
            Task { @MainActor in self?.publishKeyboardOwner() }
        }.store(in: &sinks)
        // The board opening or closing changes what stands over the field, and so the
        // shell's height; a copy's icon changes the strip's width.
        clipboardModel.$isBoardOpen.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        clipboardModel.$recentlyCopied.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        // The board belongs to the App and Global field. The shell going away, or switching
        // to General Chat — which has a field of its own — closes it rather than leaving it
        // open and unseen, holding the field's idle clock.
        // Read again once the change has landed: `@Published` reports before it does, and
        // showing Global sets the mode a moment before it sets visible — the board being
        // opened would read that moment as "the shell went away".
        chatPresentation.$isVisible.combineLatest(chatPresentation.$mode)
            .sink { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.clipboardModel.isBoardOpen,
                        !self.chatPresentation.isVisible || self.chatPresentation.mode == .general
                    else { return }
                    ClipboardPanelController.shared.closeBoard(refocus: false)
                }
            }
            .store(in: &sinks)
        // A result arriving or leaving changes the strip's width by one slot.
        actionFeedback.$current.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        // A plugin field taking the caret needs the panel to be key, and the key monitor to
        // stand aside; letting go hands the keys back to whoever held them.
        PluginKeyboardClaim.shared.$isEditing.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.syncPanelKeyboard()
                self.publishKeyboardOwner()
            }
        }.store(in: &sinks)
        // The preview card appears and disappears with the walk through the list, so the
        // stack has to be measured again when the focus moves — otherwise the card is drawn
        // in a slot nothing reserved and the rect below it is wrong for every row.
        clipboardModel.$focusedEntryIndex.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        shelf.$phase.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        selection.$phase.sink { [weak self] phase in
            Task { @MainActor in
                guard let self else { return }
                self.selectionPhaseDidChange(phase.isVisible)
                self.refresh()
                // The selection card carries a field, and it is summoned by a hotkey — as
                // explicit a request for the keyboard as the chat's own. Without arming,
                // the panel keeps `.nonactivatingPanel`, never becomes key, and the field
                // shows a caret that no keystroke can reach: `publishKeyboardOwner` names
                // the selection the owner, the card focuses its field, and nothing types.
                self.syncPanelKeyboard()
                self.publishKeyboardOwner()
            }
        }.store(in: &sinks)
        prompt.$phase.sink { [weak self] next in
            Task { @MainActor in
                guard let self else { return }
                // The field folding into the resting strip ends the typing: like the macOS
                // Dock, a dock at rest does not keep the keyboard from the app in front
                // (owner 2026-09-26).
                var folded = next == .dock && self.lastPromptPhase.showsInput
                self.phaseChangeMayArm = CornerKeyboardOwner.phaseChangeMayTakeKeys(
                    from: self.lastPromptPhase, to: next,
                    cornerHasKeys: NSApp.isActive && self.panel?.isKeyWindow == true)
                self.lastPromptPhase = next
                if folded { self.foldedAt = Date() }
                if folded, self.edgeSummonKeepsKeys {
                    self.edgeSummonKeepsKeys = false
                    folded = false
                }
                // A fold the pointer made — resting on the running apps' pill — is the user
                // working the dock with the mouse, not done with it: the keys stay. An idle
                // fold hands them back once its morph has landed, since taking the key status
                // away re-orders the window and would cut the morph and the hover short.
                if folded, !self.pointerIsOverDock {
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + AppChatPromptMetrics.dockMorphDuration + 0.05
                    ) { [weak self] in
                        guard let self, self.prompt.phase == .dock,
                            !self.anySurfaceWantsKeyboard, !self.pointerIsOverDock
                        else { return }
                        self.giveKeyboardBack()
                    }
                }
            }
            Task { @MainActor in
                self?.refresh()
                // The prompt is a text field the user asked for by name, so unlike the
                // ambient pills it takes focus the moment it appears. Disarming is not its
                // decision alone: a selection card or an armed clipboard may still need the
                // keys after the chat closes.
                // Not when the user is working in another app and the phase moved on its own
                // (`phaseChangeMayTakeKeys`): that pulled DoraX in front of their app.
                if self?.phaseChangeMayArm ?? true { self?.syncPanelKeyboard() }
                self?.publishKeyboardOwner()
            }
        }.store(in: &sinks)
        chatPresentation.$mode.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.requestComposerFocus()
            }
        }.store(in: &sinks)
        chatPresentation.$isVisible.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        // Moving the shell is a placement change, not just a redraw: the window itself has
        // to travel to the other edge. Any settings change re-places it, which is cheap —
        // `position` writes the same origin when nothing moved.
        AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.position()
                self?.refresh()
                self?.syncEdgeWatch()
            }
        }.store(in: &sinks)
        syncEdgeWatch()
        NotificationCenter.default.addObserver(
            forName: AXMenuReader.scriptedMenusDidLoad, object: nil, queue: .main
        ) { [weak self] note in
            let pid = note.userInfo?["pid"] as? pid_t
            MainActor.assumeIsolated {
                self?.prompt.scriptedMenusDidLoad(pid: pid)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openMenuCount += 1
                self.syncAutoHide()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openMenuCount = max(0, self.openMenuCount - 1)
                self.syncAutoHide()
            }
        }
        chatPresentation.generalChat.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &sinks)
        // App mode's card grows with its transcript, and those messages live on the dock's
        // conversation rather than on the prompt — so watching `$phase` alone left the card
        // taller than the rect the mouse was tested against. Deferred a turn because
        // `objectWillChange` fires before the change lands; `refresh` returns immediately
        // when the geometry is unchanged, which is most of the time.
        prompt.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &sinks)
        // The strip is as wide as its pins, and a pin is drawn only when the search index
        // can resolve it. Both change from outside the corner — a pin added in Settings, a
        // plugin saved from the Creator — so both re-measure the shell here, or the strip
        // keeps the width it had until the pointer happens to cross it.
        DockPinStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &sinks)
        GlobalSearchIndexStatus.shared.$documentCount.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                DockStripPlan.forgetEnvironment()
                self?.refresh()
            }
        }.store(in: &sinks)
    }

    /// Which edge the shell is anchored to. Read fresh each time rather than cached: the
    /// user can move it while the surface is up, and the window and the cards inside it
    /// have to agree on the answer in the same frame.
    var anchor: CornerDockAnchor {
        CornerDockAnchor(rawValue: AppSettings.shared.cornerDockAnchorRaw) ?? .right
    }

    private func position() {
        guard let panel else { return }
        // Moving between an edge and the centre changes the shape of the window, not only
        // where it sits: a row needs three cards' width, a column needs one.
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let pad = CornerDockLayout.pad
        let margin: CGFloat = 20
        // The panel spans the screen at every anchor. Centred, that is what lets the field
        // sit in the middle while the clipboard keeps the right-hand corner; at an edge it
        // is what lets the dock strip be as wide as its icons instead of being cut off at
        // one card. The origin works out the same for all three.
        let wanted = CornerDockLayout.panelSize(
            for: anchor, panelWidth: visible.width - 2 * margin + 2 * pad)
        if panel.frame.size != wanted {
            panel.setContentSize(wanted)
            hostView?.frame = CGRect(origin: .zero, size: wanted)
        }
        let size = panel.frame.size
        let x: CGFloat
        switch anchor {
        case .right: x = visible.maxX - margin + pad - size.width
        case .left: x = visible.minX + margin - pad
        case .center: x = visible.minX + margin - pad
        }
        shownPanelOrigin = NSPoint(x: x, y: visible.minY + margin - pad)
        dockScreenFrame = screen?.frame ?? visible
        panel.setFrameOrigin(isAutoHidden ? hiddenPanelOrigin : shownPanelOrigin)
    }

    // MARK: - Auto-hide

    /// What the shell draws, in screen coordinates at its shown position.
    private var shownContentRect: CGRect {
        guard let rects = hostView?.interactiveRects, let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
            .offsetBy(dx: shownPanelOrigin.x, dy: shownPanelOrigin.y)
    }

    private var hiddenPanelOrigin: NSPoint {
        let content = shownContentRect
        let top = content.isEmpty ? shownPanelOrigin.y + (panel?.frame.height ?? 0) : content.maxY
        let distance = CornerDockAutoHide.hideDistance(
            contentTop: top, screenMinY: dockScreenFrame.minY, shadow: CornerDockLayout.pad)
        return NSPoint(x: shownPanelOrigin.x, y: shownPanelOrigin.y - distance)
    }

    /// Only the resting strip hides. Anything the user opened — or is typing into, or is
    /// dragging onto — keeps the shell where it is.
    private var restsForAutoHide: Bool {
        CornerDockAutoHide.canHide(
            enabled: AppSettings.shared.cornerDockAutoHide,
            stripShowing: chatPresentation.isVisible && chatPresentation.mode != .general
                && prompt.phase == .dock,
            hoverCardShowing: showsHoverCard,
            selectionShowing: selection.phase.isVisible,
            clipboardExpanded: clipboardModel.phase == .expanded,
            shelfNeedsAttention: shelf.phase != .collapsed,
            pluginEditing: PluginKeyboardClaim.shared.isEditing,
            menuOpen: openMenuCount > 0 || stripMenuOpen)
    }

    private var pointerIsOverDock: Bool {
        CornerDockAutoHide.pointerIsOver(
            mouse: NSEvent.mouseLocation, screenFrame: dockScreenFrame,
            content: shownContentRect, slack: ClipboardPillMetrics.hoverTolerance)
    }

    /// Bring what is on screen in line with the rule: reveal the moment the shell stops
    /// resting, hide a beat after the pointer has left a resting one.
    private func syncAutoHide() {
        guard let panel, panel.isVisible else {
            cancelPendingAutoHide()
            if isAutoHidden {
                // Ordered out while hidden: the next time it shows, it shows.
                isAutoHidden = false
                self.panel?.alphaValue = 1
                self.panel?.ignoresMouseEvents = false
            }
            pointerVisitedDock = false
            return
        }
        guard restsForAutoHide else {
            cancelPendingAutoHide()
            if isAutoHidden { setAutoHidden(false) }
            return
        }
        if isAutoHidden || pointerIsOverDock {
            if !isAutoHidden { pointerVisitedDock = true }
            cancelPendingAutoHide()
        } else if pendingAutoHide == nil {
            let delay = CornerDockAutoHide.delay(
                base: pointerVisitedDock
                    ? CornerDockAutoHide.hideDelay : CornerDockAutoHide.idleDelay,
                sinceFold: foldedAt.map { Date().timeIntervalSince($0) },
                foldDuration: AppChatPromptMetrics.dockMorphDuration)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingAutoHide = nil
                guard self.restsForAutoHide, !self.pointerIsOverDock else { return }
                self.setAutoHidden(true)
            }
            pendingAutoHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelPendingAutoHide() {
        pendingAutoHide?.cancel()
        pendingAutoHide = nil
    }

    /// Any key in the shell is the user working in it: the idle clock starts again.
    private func restartAutoHideClock() {
        guard AppSettings.shared.cornerDockAutoHide, pendingAutoHide != nil else { return }
        cancelPendingAutoHide()
        syncAutoHide()
    }

    private func syncEdgeWatch() {
        let wanted = AppSettings.shared.cornerDockAutoHide
        if wanted, edgeMonitors.isEmpty {
            // Dragged too: carrying a file to the edge is the Dock's other way up, and a held
            // button sends drags, never moves.
            if let global = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged],
                handler: { [weak self] _ in self?.edgeTouched() })
            {
                edgeMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged],
                handler: { [weak self] event in
                    self?.edgeTouched()
                    return event
                })
            {
                edgeMonitors.append(local)
            }
        } else if !wanted, !edgeMonitors.isEmpty {
            edgeMonitors.forEach { NSEvent.removeMonitor($0) }
            edgeMonitors.removeAll()
        }
    }

    /// The pointer at the bottom edge with nothing of the shell on screen: bring the dock up,
    /// at rest. A hidden-but-shown shell is the hover watch's to reveal, not this.
    private func edgeTouched() {
        guard AppSettings.shared.cornerDockAutoHide, panel != nil else { return }
        // Slid away: the hover watch reveals it on a move, but it never sees a drag.
        if isAutoHidden {
            if CornerDockAutoHide.pointerReveals(
                mouse: NSEvent.mouseLocation, screenFrame: dockScreenFrame,
                content: shownContentRect)
            {
                summonFromEdge()
            }
            return
        }
        guard !chatPresentation.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: {
                NSMouseInRect(mouse, $0.frame, false)
            })
        else { return }
        // Before the dock has ever been measured on this screen, the whole edge answers.
        let span =
            dockScreenFrame == screen.frame && !lastShownContentRect.isEmpty
            ? lastShownContentRect : screen.frame
        guard
            CornerDockAutoHide.pointerReveals(
                mouse: mouse, screenFrame: screen.frame, content: span)
        else { return }
        summonFromEdge()
    }

    /// The edge brings up the resting dock — the strip, not the field — holding the keys, so
    /// the first letter typed opens the field with it (owner 2026-09-26). The keys go back
    /// to the app in front when the strip hides again.
    private func summonFromEdge() {
        cancelPendingAutoHide()
        pointerVisitedDock = true
        if !(chatPresentation.isVisible && prompt.phase == .dock) {
            edgeSummonKeepsKeys = true
            chatPresentation.showGlobalContext()
            if !prompt.restAsDockNow() { edgeSummonKeepsKeys = false }
        }
        armKeyboard()
        setAutoHidden(false)
    }

    /// Whether the shell is on screen only because a drag asked for it, so it goes again when
    /// the drag does.
    private var shelfRevealedTheShell = false
    /// A file drag raised or is crossing the shell: no keyboard arming until it ends. Read
    /// through `dragHoldsKeyboard`, which lets go once no button is held, so a drag whose end
    /// was never reported cannot keep the keys away.
    private var dragRaisedShell = false
    private var dragHoldsKeyboard: Bool {
        get {
            if dragRaisedShell, NSEvent.pressedMouseButtons == 0 { dragRaisedShell = false }
            return dragRaisedShell
        }
        set { dragRaisedShell = newValue }
    }

    /// A drag was sighted and the shelf's icon — in the shell's row — is where it drops. If
    /// nothing has the shell on screen, bring the resting dock up for the drag, without the
    /// keys: a drag is not a request to type.
    func revealForShelfDrag() {
        guard panel != nil else { return }
        // A drag is not a request to type, and taking the keys mid-drag activates DoraX
        // while another app's drag session is live — the freeze the owner hit dragging a
        // file onto the dock (2026-10-08). The keys stay where they are until it ends.
        dragHoldsKeyboard = true
        cancelPendingAutoHide()
        if !chatPresentation.isVisible {
            chatPresentation.showGlobalContext()
            _ = prompt.restAsDockNow()
            shelfRevealedTheShell = true
        }
        setAutoHidden(false)
        // Above the edge strip that spotted the drag, which declines it: the icon has to be
        // the window under the pointer.
        panel?.orderFrontRegardless()
    }

    /// The drag ended — dropped or not. A shell the drag raised puts itself away, unless the
    /// shelf is open: that one is the user's now.
    func shelfDragEnded() {
        dragHoldsKeyboard = false
        guard shelfRevealedTheShell else { return }
        shelfRevealedTheShell = false
        guard !shelf.phase.isCardShown else { return }
        chatPresentation.dismiss()
    }

    private func setAutoHidden(_ hidden: Bool) {
        guard let panel, hidden != isAutoHidden else { return }
        isAutoHidden = hidden
        panel.ignoresMouseEvents = hidden
        if !hidden { syncMouseTransparency() }
        if hidden { pointerVisitedDock = false }
        let target = hidden ? hiddenPanelOrigin : shownPanelOrigin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CornerDockAutoHide.slideDuration
            context.timingFunction = CAMediaTimingFunction(
                name: hidden ? .easeIn : .easeOut)
            panel.animator().setFrame(
                NSRect(origin: target, size: panel.frame.size), display: true)
            panel.animator().alphaValue = hidden ? 0 : 1
        } completionHandler: { [weak self] in
            // A hotkey-raised dock can still hold the keys; give them back to the app the
            // user is in, since a dock under the screen edge cannot be typed at. After the
            // slide, where re-ordering the window is invisible.
            MainActor.assumeIsolated {
                guard let self, self.isAutoHidden else { return }
                self.giveKeyboardBack()
            }
        }
    }

    // MARK: - Visibility

    func refresh() {
        guard let panel, let hostView else { return }
        defer { syncAutoHide() }
        let slots = currentSlots()
        let rects = [
            slots.shelf, slots.preview, slots.clipboard, slots.selection, slots.list,
            slots.prompt,
        ]
            .compactMap { $0 }

        // Nothing moved, nothing to do. The models this follows republish on every
        // keystroke — the draft is `@Published` — and without this the corner recomputed
        // its geometry on each one for a card whose size had not changed.
        if rects == hostView.interactiveRects, panel.isVisible == !rects.isEmpty {
            return
        }
        hostView.interactiveRects = rects
        if !rects.isEmpty { lastShownContentRect = shownContentRect }
        syncMouseTransparency()

        let shouldShow = !rects.isEmpty
        if shouldShow {
            if !panel.isVisible {
                position()
                panel.orderFrontRegardless()
            }
            startHoverWatch()
        } else {
            panel.orderOut(nil)
            stopHoverWatch()
        }
    }

    /// Sizes come from each surface's own phase; the placement comes from the shared
    /// layout, so what is drawn and what is hit-tested cannot drift apart.
    private func currentSlots()
        -> (
            shelf: CGRect?, preview: CGRect?, clipboard: CGRect?, selection: CGRect?,
            list: CGRect?, prompt: CGRect?
        )
    {
        CornerDockLayout.slots(
            shelf: DropShelfMetrics.cardSize(for: shelf.phase),
            preview: showsClipPreview ? ClipboardPreviewMetrics.size : nil,
            clipboard: clipboardModel.phase.isVisible
                ? ClipboardPillMetrics.cardSize(for: clipboardModel.phase) : nil,
            selection: selection.phase.isVisible
                ? SelectionScopeMetrics.size(
                    rows: selection.rows.count, answering: selection.isShowingAnswer,
                    consent: selection.isAsking,
                    outcome: selection.showsOutcome,
                    folderPreview: selection.showsFolderPreview,
                    sendConfirm: selection.pendingSend != nil) : nil,
            list: showsClipboardBoard
                ? ClipboardBoardMetrics.size
                : showsScopeBoard
                ? AppScopeBoardMetrics.size(shell: AppChatPromptMetrics.boardWidth(for: prompt))
                : showsExtensionPanel
                ? (prompt.scopedPlugin.map { CornerPluginCardMetrics.size(for: $0) }
                    ?? ExtensionScopeMetrics.size)
                : (showsAppSnapshot
                    ? AppSnapshotMetrics.size
                    : (showsAppChatList
                        ? prompt.boardSize
                        : (showsWindowRow
                            ? windowRowSize
                            : (showsPinPreview
                                ? pinPreviewSize
                                : (showsPluginCard
                                    ? pluginCardPin.map { CornerPluginCardMetrics.size(for: $0.manifest) }
                                    : nil))))),
            prompt: chatPresentation.isVisible ? promptSize : nil,
            listAnchorOffset: hoverCardAnchorOffset,
            anchor: anchor, panelWidth: panel?.frame.width)
    }

    /// Set while the dock stood aside for the selection card; the card's dismissal brings
    /// the dock back.
    private var dockStoodAsideForSelection = false
    /// The scope the Selection card was opened from, so closing it comes back there — an
    /// app's Context Dock, not always Global (owner 2026-09-26).
    private var modeBeforeSelection: CornerChatMode?

    /// The dock's selection icon: the dock becomes the selection card. One shell, one place
    /// — the card takes the dock's slot rather than stacking over it, and Backspace on its
    /// empty field (or Esc) brings the dock back.
    func showSelectionScopeFromDock() {
        let opener: CornerChatMode? = chatPresentation.isVisible ? chatPresentation.mode : nil
        AppDelegate.shared?.activateSelectionScope(sourceBundleID: nil)
        guard selection.phase.isVisible else { return }
        dockStoodAsideForSelection = true
        modeBeforeSelection = opener
        chatPresentation.dismiss()
    }

    private func selectionPhaseDidChange(_ visible: Bool) {
        guard !visible, dockStoodAsideForSelection else { return }
        dockStoodAsideForSelection = false
        let back = modeBeforeSelection
        modeBeforeSelection = nil
        if back == .frontmostApp {
            chatPresentation.show(.frontmostApp)
        } else {
            chatPresentation.showGlobalContext()
        }
        prompt.foldToDock()
    }

    /// The window row takes the list's slot: both sit directly above the field, and a
    /// docked pill has no list. Reusing the slot keeps the layout arithmetic in one place.
    var showsWindowRow: Bool {
        chatPresentation.isVisible && chatPresentation.mode != .general
            && prompt.phase == .dock && prompt.windowRowBundleID != nil
            && !showsPluginCard
    }

    /// Any of the three cards the strip raises above an icon.
    var showsHoverCard: Bool { showsWindowRow || showsPinPreview || showsPluginCard }

    /// The size the layout gave that card — the one number the container and the slot share.
    var hoverCardSize: CGSize? {
        if showsWindowRow { return windowRowSize }
        if showsPinPreview { return pinPreviewSize }
        if showsPluginCard, let card = pluginCardPin {
            return CornerPluginCardMetrics.size(for: card.manifest)
        }
        return nil
    }

    /// A pinned plugin's panel: opened by a tap in its tile, or by the pointer resting on a
    /// plugin that draws as an icon — its panel is what that icon previews, the way an app
    /// previews its windows. It holds the slot the hover cards use; a tapped-open card wins
    /// over the hover, so it is not put away by the pointer crossing the next icon.
    var showsPluginCard: Bool {
        chatPresentation.isVisible && chatPresentation.mode != .general
            && prompt.phase == .dock && pluginCardPin != nil
    }

    var pluginCardPin: (pin: DockPin, manifest: PluginManifest)? {
        CornerPluginCardRouting.cardPin(
            open: prompt.pluginCardPinID, hovered: prompt.previewPinID,
            pins: DockPinStore.shared.pins + DockPinStore.shared.appPins,
            manifest: { PluginRegistry.shared.plugin(id: $0)?.manifest })
    }

    private var windowRowSize: CGSize {
        CornerWindowRowMetrics.size(
            count: max(
                1,
                AppWindowSnapshotService.shared
                    .windowSnapshots(for: prompt.windowRowBundleID ?? "").count))
    }

    /// How far the hover card has to move from where the stack would draw it — centred over
    /// the field — to sit over the icon it is about.
    ///
    /// Taken as the difference between two rects `CornerDockLayout.slots` already worked
    /// out, rather than repeating the arithmetic here. The cards are drawn by a centred
    /// stack, not placed at the slot rect, so moving the rect alone moved only where the
    /// shell listens for the mouse — drawn and hit-tested have to be the same number, and
    /// this is how they stay that way. Zero for every other board, since nothing else asks
    /// for an anchor offset.
    var hoverCardDrawOffset: CGFloat {
        guard showsWindowRow || showsPinPreview || showsPluginCard || showsScopeBoard
        else { return 0 }
        let slots = currentSlots()
        guard let list = slots.list, let prompt = slots.prompt else { return 0 }
        // Where the stack puts it without being asked: centred on the field when the shell
        // is a centred row, flush with the anchored edge when it is a column.
        let drawnMinX: CGFloat
        switch anchor {
        case .right: drawnMinX = prompt.maxX - list.width
        case .left: drawnMinX = prompt.minX
        case .center: drawnMinX = prompt.midX - list.width / 2
        }
        return list.minX - drawnMinX
    }

    /// Where the hover card wants to sit: over the icon it is about. Only the strip's own
    /// two cards ask for this — the list, the snapshot and the extension panel belong to
    /// the field and stay centred on it.
    private var hoverCardAnchorOffset: CGFloat? {
        // The app's card stands over the field's left half, its leading edge on the field's,
        // above the chip that opened it.
        if showsScopeBoard {
            return AppScopeBoardMetrics.size(shell: AppChatPromptMetrics.boardWidth(for: prompt))
                .width / 2
        }
        let target: DockHoverTarget?
        if showsPluginCard, let card = pluginCardPin {
            target = .pin(id: card.pin.id)
        } else if showsWindowRow || showsPinPreview {
            target = prompt.dockPreviewTarget
        } else {
            target = nil
        }
        guard let target else { return nil }
        return DockStripPlan.make(
            running: prompt.stripIcons, pins: prompt.stripPins,
            tools: prompt.dockToolCount(clipboardVisible: clipboardModel.showsDockIcon, feedbackVisible: actionFeedback.glyph != nil),
            fieldIcons: prompt.promptIconCount
        ).iconCenterOffset(for: target)
    }

    /// The other half of the strip's hover: a pinned file, folder or command, in the slot
    /// the window row uses for apps. Both are "what is this icon?", so they share a slot
    /// and can never be up at once.
    var showsPinPreview: Bool {
        chatPresentation.isVisible && chatPresentation.mode != .general
            && prompt.phase == .dock && hoveredPin != nil && !showsPluginCard
    }

    var hoveredPin: DockPin? {
        guard let id = prompt.previewPinID else { return nil }
        return DockPinStore.shared.pin(withID: id)
    }

    private var pinPreviewSize: CGSize {
        guard let pin = hoveredPin else { return .zero }
        let preview =
            DockPinPreviewService.shared.preview(for: pin)
            ?? .missing(name: pin.title, reason: "")
        return DockPinPreviewMetrics.size(for: preview, expanded: prompt.pinPreviewExpanded)
    }

    /// The app's commands, or what it can do — a card of its own above the field, and only
    /// while the App Chat field is the thing on screen.
    var showsAppChatList: Bool {
        chatPresentation.isVisible
            && chatPresentation.mode != .general
            && prompt.phase == .suggesting
            && prompt.listRowCount > 0
    }

    /// An extension's own interface, in the board slot.
    var showsExtensionPanel: Bool {
        chatPresentation.isVisible
            && chatPresentation.mode != .general
            && prompt.showsExtensionPanel
    }

    /// The scoped app's window, in the same slot the list uses — the two are never both up,
    /// because one is what the app is doing and the other is what it can do.
    var showsAppSnapshot: Bool {
        chatPresentation.isVisible
            && chatPresentation.mode != .general
            && prompt.showsWindowSnapshot
            && prompt.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The clipboard, in the result board above the field (owner 2026-10-07). It wins the
    /// slot over every other board: it is what the user just asked for by name.
    var showsClipboardBoard: Bool {
        chatPresentation.isVisible
            && chatPresentation.mode != .general
            && clipboardModel.isBoardOpen
            && prompt.phase.showsInput
    }

    /// The app's card — what DoraX can do here, what it sees, what it may do — in the result
    /// board, opened from the field's app chip (owner 2026-10-07: "inside the result sheet",
    /// not a popover). Second only to the clipboard, which is asked for by name.
    var showsScopeBoard: Bool {
        chatPresentation.isVisible
            && chatPresentation.mode != .general
            && prompt.isShowingScopeCard
            && !prompt.isGlobalScope
            && (prompt.phase == .prompt || prompt.phase == .suggesting)
    }

    /// The field and the apps as two pieces of glass (Part B, owner 2026-10-07), in Global
    /// and in an app's Context Dock alike. See `CornerSplitShell`.
    var showsSplitShell: Bool {
        CornerSplitShell.splits(
            isVisible: chatPresentation.isVisible,
            isGeneral: chatPresentation.mode == .general,
            phase: prompt.phase,
            stripHasContent: splitWidths.strip > 0)
    }

    /// The split bottom line's two widths: the apps fitted to what they hold, the field the
    /// rest of the shell — the whole of it when the apps' piece has nothing to show.
    var splitWidths: (field: CGFloat, strip: CGFloat) {
        CornerSplitShell.widths(
            shell: AppChatPromptMetrics.boardWidth(for: prompt),
            apps: CornerSplitStrip.apps(for: prompt).count,
            pins: CornerSplitStrip.pins(for: prompt).count,
            tools: CornerSplitStrip.toolCount(for: prompt),
            widgetExtra: CornerSplitStrip.composition(for: prompt).widgetExtraWidth)
    }

    /// The width the field's text stack is laid out at.
    var splitFieldLayoutWidth: CGFloat { splitWidths.field }

    /// The clipboard hotkey or icon: the field comes up — Global Context's when nothing was
    /// on screen or General Chat was, the current scope's otherwise — with the clipboard in
    /// its board. The scope and any conversation underneath are left exactly as they were,
    /// so Back returns to them.
    func showClipboardBoard() {
        activate()
        if !chatPresentation.isVisible || chatPresentation.mode == .general {
            chatPresentation.showGlobalContext()
        }
        switch prompt.phase {
        case .dock:
            prompt.expandFromDock(seeding: nil)
        case .mini, .hidden:
            prompt.set(prompt.messages.isEmpty ? .prompt : .chat)
        case .prompt, .suggesting, .chat:
            break
        }
        cancelPendingAutoHide()
        if isAutoHidden { setAutoHidden(false) }
        refresh()
        requestComposerFocus()
    }

    /// Back from the clipboard: the field is the one it was, keys and all — unless the clip
    /// is on its way into another app, which needs the keys more.
    func clipboardBoardClosed(refocus: Bool = true) {
        refresh()
        prompt.touch()
        guard refocus, chatPresentation.isVisible else { return }
        requestComposerFocus()
    }

    /// The preview belongs to an open, expanded card with a clip actually chosen — not to a
    /// pill that happens to be on screen.
    var showsClipPreview: Bool {
        clipboardModel.phase == .expanded && clipboardModel.focusedEntry != nil
    }

    private var promptSize: CGSize {
        if chatPresentation.mode == .general {
            return chatPresentation.generalPhase == .mini
                ? AppChatPromptMetrics.miniSize
                : CornerGeneralChatMetrics.size(for: chatPresentation.generalChat)
        }
        // The one reading the field draws itself at (`shellSize`), so what is drawn and
        // what is hit-tested are the same number.
        return AppChatPromptMetrics.shellSize(
            for: prompt, phase: prompt.phase,
            clipboardVisible: clipboardModel.showsDockIcon,
            feedbackVisible: actionFeedback.glyph != nil)
    }

    // MARK: - Keyboard

    /// The clipboard card was clicked. `.nonactivatingPanel` keeps the ambient pills
    /// harmless and is also exactly what stops this window becoming key, so the style is
    /// dropped for as long as the card holds the keyboard.
    func armKeyboard() {
        guard let panel, !dragHoldsKeyboard else { return }
        panel.styleMask = [.borderless]
        // The plain, no-argument activate() is cooperative — macOS can decline or defer it,
        // and silently did exactly that when this ran from a global hotkey/event-monitor
        // callback (the double-Command launch, a Carbon-registered hotkey) rather than from
        // a click on our own window: the panel reordered to the front and looked open, but
        // the app never actually became the active application, so every keystroke kept
        // going to whatever was frontmost before. Every other hotkey path in this app already
        // uses the forceful, unconditional form for exactly this reason.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { finishArmingWhenActive() }
    }

    private var armWhenActiveObserver: NSObjectProtocol?

    /// The activation was deferred. With Terminal in front (its Secure Keyboard Entry most
    /// of all) macOS can hold an activation asked for from a hover rather than a click, and
    /// the panel came up looking open with no caret and no keys (owner 2026-10-07: "while
    /// Terminal is frontmost our input field isn't working"). Ask again a moment later, and
    /// make the panel key the moment DoraX does become active.
    private func finishArmingWhenActive() {
        if armWhenActiveObserver == nil {
            armWhenActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let observer = self.armWhenActiveObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self.armWhenActiveObserver = nil
                    }
                    guard self.keyboardState.isArmed || self.prompt.phase.showsInput else { return }
                    self.panel?.makeKeyAndOrderFront(nil)
                    self.publishKeyboardOwner()
                    // The field already owned the keys on paper; asking again puts the caret
                    // in it now that the window really is key.
                    if self.keyboardState.owner == .chat { self.keyboardState.composerInteracted() }
                }
            }
        }
        for delay in [0.12, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !NSApp.isActive, let panel = self.panel,
                    panel.isVisible, !panel.styleMask.contains(.nonactivatingPanel)
                else { return }
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Recompute who should hold the keyboard and tell every board. Called whenever one of
    /// them opens, arms or closes — the boards themselves only listen.
    func publishKeyboardOwner() {
        keyboardState.ownerChanged(
            clipboardArmed: ClipboardPanelController.shared.model.isKeyboardArmed,
            selectionWantsKeyboard: selection.phase.isVisible,
            chatShowsInput: prompt.phase.showsInput,
            pluginEditing: PluginKeyboardClaim.shared.isEditing)
    }

    /// The chat asks for the caret — unless a louder surface is holding it. Arming the
    /// clipboard and then switching chat modes used to hand the keys straight back to the
    /// chat, which is why the clips could not be walked.
    func requestComposerFocus() {
        ensurePanel()
        armKeyboard()
        guard
            CornerKeyboardOwner.owner(
                clipboardArmed: ClipboardPanelController.shared.model.isKeyboardArmed,
                selectionWantsKeyboard: selection.phase.isVisible,
                chatShowsInput: prompt.phase.showsInput) == .chat
        else { return }
        chatPresentation.composerInteracted()
        keyboardState.composerInteracted()
    }

    /// Take or release the keyboard to match what is on screen.
    ///
    /// One place, because two surfaces answering it independently is how the selection card
    /// ended up focused inside a window that could not become key.
    func syncPanelKeyboard() {
        // A file drag in flight: the keys stay with the app the drag came from
        // (`armKeyboard` refuses them too).
        if dragHoldsKeyboard { return }
        if CornerKeyboardOwner.panelHoldsKeyboard(
            clipboardArmed: ClipboardPanelController.shared.model.isKeyboardArmed,
            selectionWantsKeyboard: selection.phase.isVisible,
            chatShowsInput: prompt.phase.showsInput,
            pluginEditing: PluginKeyboardClaim.shared.isEditing)
        {
            armKeyboard()
        } else {
            disarmKeyboard()
        }
    }

    func disarmKeyboard() {
        panel?.styleMask = [.borderless, .nonactivatingPanel]
        keyboardState.stoodDown()
        // `NSApp` has no "give back active status" of its own — the only way is
        // explicitly activating whoever had it before `armKeyboard`'s forceful
        // `ignoringOtherApps` took it. Skipping that left Context-Dock the active
        // application long after the corner had stopped needing keys at all, which is
        // what silently broke the double-Command launch some of the time: its global
        // monitor only fires while some *other* app is active, by NSEvent's own design,
        // and nothing here ever gave that back on its own. Switching Spaces "fixed" it
        // by accident, since macOS reactivates whichever real app owns the space you
        // land on — the same rescue this now does on purpose, immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            if self.panel?.isKeyWindow == true {
                // Still key with the chat gone and nothing else asking for keys: typing was
                // landing in an empty corner instead of the app in front.
                if !self.chatPresentation.isVisible, !self.anySurfaceWantsKeyboard {
                    self.giveKeyboardBack()
                }
                return
            }
            // Nothing to give back when this app is not the active one — reactivating a
            // remembered app then would pull the user out of whatever they switched to.
            guard NSApp.isActive else { return }
            AppDelegate.shared?.previousFrontmostApp?.activate(options: [
                .activateIgnoringOtherApps
            ])
        }
    }

    private var anySurfaceWantsKeyboard: Bool {
        CornerKeyboardOwner.panelHoldsKeyboard(
            clipboardArmed: ClipboardPanelController.shared.model.isKeyboardArmed,
            selectionWantsKeyboard: selection.phase.isVisible,
            chatShowsInput: prompt.phase.showsInput,
            pluginEditing: PluginKeyboardClaim.shared.isEditing)
    }

    /// Hand the keys to the app in front, now. A `.nonactivatingPanel` can stay the key
    /// window while another app is active — that is what the style is for — so activating
    /// that app is not enough on its own: the panel has to stop being key, which ordering it
    /// out does. It goes straight back in front, unkeyed, when it still has something drawn.
    private func giveKeyboardBack() {
        guard let panel, panel.isKeyWindow else { return }
        panel.styleMask = [.borderless, .nonactivatingPanel]
        keyboardState.stoodDown()
        guard NSApp.isActive else {
            resignKeyByReordering(panel)
            return
        }
        // Handing the app in front its activation takes the key status away by itself. The
        // off-and-on reorder below ran here as well and was seen: after a ⌘⌘ launch the strip
        // blinked out and back a second after folding, then slid away (owner 2026-09-27).
        AppDelegate.shared?.previousFrontmostApp?.activate(options: [
            .activateIgnoringOtherApps
        ])
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return }
            self.resignKeyByReordering(panel)
        }
    }

    /// A non-activating panel can stay key while DoraX is not the active app, and only
    /// taking it off screen and back ends that. It is visible, so it is kept for that case.
    private func resignKeyByReordering(_ panel: NSPanel) {
        let wasShown = panel.isVisible
        panel.orderOut(nil)
        if wasShown { panel.orderFrontRegardless() }
    }

    // MARK: - Hover

    private func startHoverWatch() {
        guard hoverMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved],
            handler: { [weak self] _ in self?.evaluateHover() })
        {
            hoverMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved],
            handler: { [weak self] event in
                self?.evaluateHover()
                return event
            })
        {
            hoverMonitors.append(local)
        }
        // A file dragged in from another app moves the pointer with the button down, which is
        // not a `mouseMoved`; the shelf still has to become reachable when it gets there.
        if let drag = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged],
            handler: { [weak self] _ in self?.syncMouseTransparency() })
        {
            hoverMonitors.append(drag)
        }
        if let swipe = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel],
            handler: { [weak self] event in self?.handleChatSwipe(event) ?? event })
        {
            hoverMonitors.append(swipe)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown],
            handler: { [weak self] event in self?.handleChatNavigationKey(event) ?? event })
        {
            hoverMonitors.append(keys)
        }
        // A tap of Command switches the app scope to Global and back — the gesture the dock
        // uses. It is a tap, not a hold: Command pressed and released on its own, with no
        // other key in between, so every ⌘-shortcut still means what it always did.
        if let flags = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged],
            handler: { [weak self] event in self?.handleCommandTap(event) ?? event })
        {
            hoverMonitors.append(flags)
        }
    }

    /// Left arrow, but only when the chat is the surface the key was meant for.
    ///
    /// This is a monitor over the whole corner panel, and it used to ask nothing except
    /// which key was pressed — so arrowing through the clipboard's own list opened General
    /// chat, because the clipboard and the chat share this window.
    /// Command, pressed and released alone, toggles the app scope and Global.
    ///
    /// Anything else — another key while it is down, a second modifier, too long a hold —
    /// disqualifies the tap, because ⌘ is half the shortcuts on the machine and stealing it
    /// would be worse than not having the gesture.
    private func handleCommandTap(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCommandDown = flags.contains(.command)
        let hasOtherModifier = !flags.subtracting([.command]).isEmpty

        if isCommandDown {
            // A fresh press means the previous release might not have been an isolated tap
            // after all — it could be completing the system-wide double-Command gesture,
            // which reads this exact key from a monitor of its own. Let that decide first.
            pendingCommandSwitch?.cancel()
            pendingCommandSwitch = nil
            commandTapStarted = hasOtherModifier ? nil : Date()
            return event
        }
        guard let started = commandTapStarted else { return event }
        commandTapStarted = nil
        guard Date().timeIntervalSince(started) < 0.4,
              chatPresentation.isVisible,
              prompt.phase.showsInput
        else { return event }

        // Held slightly past the system-wide double-tap's own window before acting, rather
        // than switching immediately: a genuine double-tap landing while the corner is
        // already open used to switch modes on the first release and then have the
        // double-tap dismiss the corner out from under that switch, on its second. Waiting
        // this long costs nothing on an isolated tap, which is not a fast gesture to begin
        // with, and the event itself is left alone either way — this only defers *acting*
        // on it, never whether some other monitor gets to see it.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingCommandSwitch != nil, self.chatPresentation.isVisible
            else { return }
            self.pendingCommandSwitch = nil
            switch self.chatPresentation.mode {
            case .frontmostApp: self.chatPresentation.show(.globalContext)
            case .globalContext: self.chatPresentation.show(.frontmostApp)
            case .general: break
            }
        }
        pendingCommandSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        return event
    }

    /// The key event this panel's monitor last consumed.
    ///
    /// Returning nil from a local monitor does not stop SwiftUI's own key dispatch: the
    /// field's `onKeyPress` still received the same press, so every key both handle ran twice
    /// — → stepped two apps (Finder, then Code), ← went to Global and on to General Chat,
    /// Esc on a highlighted row cleared the query it had just kept (traced 2026-09-26). The
    /// field asks this first and stands down: one press, one handler.
    private var consumedKeyEvent: (timestamp: TimeInterval, keyCode: UInt16)?

    /// Whether the key event being dispatched right now was already taken by the monitor.
    var monitorConsumedCurrentKey: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
            let consumed = consumedKeyEvent
        else { return false }
        return event.timestamp == consumed.timestamp && event.keyCode == consumed.keyCode
    }

    private func handleChatNavigationKey(_ event: NSEvent) -> NSEvent? {
        restartAutoHideClock()
        let result = handleChatNavigationKeyBody(event)
        if result == nil, event.type == .keyDown {
            consumedKeyEvent = (event.timestamp, event.keyCode)
        }
        return result
    }

    private func handleChatNavigationKeyBody(_ event: NSEvent) -> NSEvent? {
        // A key pressed while Command is down means this was a shortcut, not a tap.
        commandTapStarted = nil
        pendingCommandSwitch?.cancel()
        pendingCommandSwitch = nil

        // Backspace on the selection card's empty field leaves it — the way out of a
        // scope everywhere else in the corner, and the way back to the dock it replaced.
        if event.keyCode == 51,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let panel, event.window === panel,
            selection.phase.isVisible, selection.query.isEmpty,
            keyboardState.owner == .selection,
            // The card is the Selection Scope: leaving it closes it (B4).
            DockKeyRules.emptyBackspace(
                browsingFolder: false, selectionScope: true, chatOpen: false,
                scopedFromGlobal: false) == .leaveSelectionAndClose
        {
            selection.dismiss()
            return nil
        }

        // Esc on the selection card steps back one layer — answer → actions → closed. Taken
        // here, like Backspace above, because with an answer up the key did not reach the
        // field's own handler and Esc did nothing.
        if event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let panel, event.window === panel,
            selection.phase.isVisible,
            keyboardState.owner == .selection
        {
            selection.escapePressed()
            return nil
        }

        // Esc puts an open shelf away — the same key that closes every other card here.
        if event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let panel, event.window === panel,
            shelf.phase.isCardShown
        {
            shelf.collapse()
            return nil
        }

        // A plugin's field has the caret: every key is its. The dock's own reading of a
        // typed letter — bring the field back — is exactly what put the "5" in the wrong
        // place.
        if PluginKeyboardClaim.shared.isEditing { return event }

        // The clipboard board takes its keys before the field does: the arrows walk the
        // clips rather than the caret, Return pastes rather than asks, and Esc, ← or
        // Backspace on an empty filter go back to the field as it was.
        if let panel, event.window === panel, showsClipboardBoard,
            let key = ClipboardBoardKey.action(
                keyCode: event.keyCode,
                command: event.modifierFlags.contains(.command),
                shift: event.modifierFlags.contains(.shift),
                option: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control),
                filterEmpty: clipboardModel.query.isEmpty)
        {
            applyClipboardBoardKey(key)
            return nil
        }

        // Esc puts the app's card away and leaves the field as it was.
        if let panel, event.window === panel, showsScopeBoard, event.keyCode == 53 {
            prompt.isShowingScopeCard = false
            return nil
        }

        // ⌘R reads the scoped app's live menus again (C12).
        if DockKeyRules.isMenuRereadKey(
            keyCode: event.keyCode, command: event.modifierFlags.contains(.command),
            control: event.modifierFlags.contains(.control),
            option: event.modifierFlags.contains(.option),
            shift: event.modifierFlags.contains(.shift)),
            let panel, event.window === panel,
            chatPresentation.isVisible, chatPresentation.mode != .general,
            prompt.phase.showsInput,
            prompt.refreshLiveMenus()
        {
            return nil
        }

        // The dock has no field, so nothing below can answer for it. Printable characters
        // bring the field back with the character in it; every other key keeps doing what
        // it does on an empty Global field — → steps into the first running app, ← walks
        // back, Esc leaves. Nothing else has a field to act on and passes through.
        if let panel, event.window === panel,
            chatPresentation.isVisible, chatPresentation.mode != .general,
            prompt.phase == .dock,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        {
            switch event.keyCode {
            case 53:  // Esc
                prompt.dismiss()
                return nil
            case 124:  // →
                if prompt.arrowRightFromDock() { return nil }
                return chatPresentation.handleRightArrow(draft: "") ? nil : event
            case 123:  // ←
                return chatPresentation.handleLeftArrow(draft: "") ? nil : event
            case 126:  // ↑ — the layer above, as the Dock's key does at rest
                return chatPresentation.handleLayerKey(up: true) ? nil : event
            case 125:  // ↓ — the layer below
                return chatPresentation.handleLayerKey(up: false) ? nil : event
            case 48, 36, 76, 51, 117:  // Tab Return Enter Backspace Delete
                return event
            default:
                guard let text = event.characters, !text.isEmpty,
                    text.unicodeScalars.allSatisfy({
                        !CharacterSet.controlCharacters.contains($0)
                            && !CharacterSet.newlines.contains($0)
                    })
                else { return event }
                // Through the field, once it has focus: a seeded model did not reach it.
                prompt.expandFromDock(seeding: nil)
                requestComposerFocus()
                FieldCaret.typeWhenFocused(text, in: panel)
                return nil
            }
        }

        // The field is back but has not taken focus yet — SwiftUI hands it over a turn
        // later. A letter typed in that moment went nowhere, so typing fast from the dock
        // lost whole words. Carry it into the field's text instead.
        if let panel, event.window === panel,
            chatPresentation.isVisible, chatPresentation.mode != .general,
            prompt.phase.showsInput, prompt.phase != .chat,
            // Behind a queue that is still waiting, every key joins it — even once the field
            // has focus — or it overtakes the letters ahead of it ("safari" → "afaris").
            FieldCaret.isWaitingForFocus
                || (keyboardState.owner == .chat && !(panel.firstResponder is NSTextView)),
            FieldCaret.carriesTextIntoUnfocusedField(
                characters: event.characters,
                hasCommandControlOrOption: !event.modifierFlags
                    .intersection([.command, .control, .option]).isEmpty)
        {
            requestComposerFocus()
            FieldCaret.typeWhenFocused(event.characters ?? "", in: panel)
            return nil
        }

        // Any other key with the clipboard board open is the filter's — the caret moving,
        // a letter deleted. None of the field's scope rules below apply: they read the
        // question's text, which is empty while the filter is typed, so a Backspace in the
        // filter would have left the app's scope.
        if let panel, event.window === panel, showsClipboardBoard { return event }

        // The Dock's keyboard rules (`DockKeyRules`), before any of the field's own meanings
        // below: a highlighted pill or row is what the key is about. Backspace here lets go
        // of the highlight and nothing else — it never deletes, leaves a scope or quits the
        // app a row names (C6).
        if let panel, event.window === panel,
            chatPresentation.isVisible, chatPresentation.mode != .general,
            prompt.phase.showsInput, prompt.phase != .chat,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            keyboardState.owner != .selection, keyboardState.owner != .clipboard,
            !ClipboardPanelController.shared.model.isKeyboardArmed,
            let key = DockKey(keyCode: event.keyCode)
        {
            if prompt.focusedPillIndex != nil, prompt.applyPillRowKey(key) { return nil }
            if prompt.applyResultFocusKey(key) { return nil }
        }

        // Backspace on an empty field leaves the scope. Like Tab, the field's own handler
        // never saw it — `onKeyPress` competes with the text system for the delete keys,
        // and the text system wins even when there is nothing to delete.
        if event.keyCode == 51,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let panel, event.window === panel,
            chatPresentation.isVisible, prompt.phase.showsInput,
            prompt.query.isEmpty
        {
            if prompt.applyEmptyBackspace() { return nil }
            // The frontmost app's Context Dock, with nothing to step out of inside it: one
            // more Backspace is Global Context's search (owner 2026-10-08: "Backspace goes
            // back to the Global Context search input").
            if chatPresentation.mode == .frontmostApp, prompt.phase != .chat {
                chatPresentation.showGlobalContext()
                return nil
            }
        }

        // Tab: the focus system claims it inside a text field, so `onKeyPress(.tab)` never
        // sees it and the row under the highlight could not be entered with the key the
        // dock uses for exactly that.
        if event.keyCode == 48,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let panel, event.window === panel,
            chatPresentation.isVisible, prompt.phase.showsInput
        {
            if prompt.enterFocusedRow() { return nil }
            if prompt.acceptGlobalTopMatch() { return nil }
            // Nothing to take: Tab walks into the pills beside the field (C7).
            if prompt.applyPillRowKey(.tab) { return nil }
            return event
        }
        // → on an empty field with nothing highlighted walks into the next app, or along the
        // scopes — the field's own `onKeyPress(.rightArrow)` ladder, taken here as well so it
        // does not depend on the field holding the caret. A scope swap had left it without
        // one, and → stopped at Finder (2026-09-26).
        if let panel, event.window === panel,
            event.keyCode == 124,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            chatPresentation.isVisible, chatPresentation.mode != .general,
            prompt.phase.showsInput, prompt.phase != .chat,
            prompt.rightArrowWalksFromEmptyField,
            !ClipboardPanelController.shared.model.isKeyboardArmed
        {
            if prompt.scopeIntoFirstRunningApp() { return nil }
            return chatPresentation.handleRightArrow(draft: "") ? nil : event
        }

        guard let panel, event.window === panel,
              event.keyCode == 123,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              chatPresentation.isVisible,
              prompt.phase.showsInput,
              !ClipboardPanelController.shared.model.isKeyboardArmed
        else { return event }
        // ← on an empty Global field folds it into the dock, before the presentation's
        // own walk between scopes is considered.
        // Global only: in an app's Context Dock, which can fold too now, ← is the way back.
        if chatPresentation.mode != .general, prompt.isGlobalScope, prompt.foldToDock() {
            return nil
        }
        // ← inside a scope entered from Global walks back one app, and from the first home
        // to Global — the mirror of →, as the Dock walks. Without it an empty Finder field
        // went straight to General Chat (owner, 2026-09-26).
        if chatPresentation.mode != .general, prompt.query.isEmpty,
            prompt.stepBackThroughRunningApps()
        {
            return nil
        }
        return chatPresentation.handleLeftArrow(draft: prompt.query) ? nil : event
    }

    private func applyClipboardBoardKey(_ key: ClipboardBoardKey) {
        let controller = ClipboardPanelController.shared
        switch key {
        case .back:
            controller.closeBoard()
        case .clearFilter:
            clipboardModel.setBoardQuery("")
        case .move(let step, let selecting):
            clipboardModel.moveEntry(step, selecting: selecting)
        case .paste:
            controller.pasteMany(clipboardModel.actionableEntries())
        case .copy:
            let entries = clipboardModel.actionableEntries()
            guard !entries.isEmpty else { return }
            controller.copy(entries)
            controller.finishBoard()
        case .delete:
            clipboardModel.removeActionableEntries()
        case .quickLook:
            controller.preview()
        case .cycleKind(let step):
            clipboardModel.cycleKind(step)
        case .togglePin:
            prompt.togglePin()
        case .settings:
            AppDelegate.shared?.showSettings()
        }
    }

    private func handleChatSwipe(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel,
              let promptRect = currentSlots().prompt,
              promptRect.contains(event.locationInWindow)
        else { return event }
        // Over the text only (owner 2026-09-26): the pill beside it scrolls sideways, and a
        // swipe over the chip or the buttons was switching to General Chat by accident. The
        // field's frame is in the hosting view's top-left space; the event is bottom-left.
        if let host = panel.contentView, !prompt.inputFrame.isEmpty {
            let point = CGPoint(
                x: event.locationInWindow.x,
                y: host.bounds.height - event.locationInWindow.y)
            guard prompt.inputFrame.insetBy(dx: -8, dy: -10).contains(point) else {
                return event
            }
        }
        // Split, the text field's own frame runs on under the apps beside it (its layout
        // keeps one width); the apps scroll sideways and never switch the scope (owner
        // 2026-10-07). Only the field's visible glass counts.
        if showsSplitShell,
            event.locationInWindow.x > promptRect.minX + splitWidths.field
        {
            return event
        }

        if event.phase == .began {
            accumulatedChatSwipeX = 0
            accumulatedChatSwipeY = 0
            didActInCurrentSwipe = false
        }
        // Through the fingers AND the momentum: a fast flick lands most of its travel after
        // the lift (§4b W2).
        if event.phase == .began || event.phase == .changed
            || event.momentumPhase == .began || event.momentumPhase == .changed
        {
            accumulatedChatSwipeX += event.scrollingDeltaX
            accumulatedChatSwipeY += event.scrollingDeltaY
        }
        // Decided when the fingers lift, and again when the momentum ends — a flick that
        // was short at the lift still counts once its momentum lands. Never twice.
        guard event.phase == .ended || event.momentumPhase == .ended else { return event }
        if didActInCurrentSwipe {
            if event.momentumPhase == .ended {
                accumulatedChatSwipeX = 0
                accumulatedChatSwipeY = 0
            }
            return event
        }
        guard let move = CornerSwipe.classify(dx: accumulatedChatSwipeX, dy: accumulatedChatSwipeY)
        else { return event }
        accumulatedChatSwipeX = 0
        accumulatedChatSwipeY = 0
        let sideways: Bool
        if case .swipeSideways = move { sideways = true } else { sideways = false }

        // Scoped into something from Global Context: that scope owns the surface until it
        // is left. A sideways swipe is swallowed; a vertical one is left to scroll (§4b W8).
        if chatPresentation.mode != .general, prompt.returnsToGlobalScope {
            didActInCurrentSwipe = true
            return sideways ? nil : event
        }
        // Over a conversation, vertical travel is the transcript scrolling, not a request
        // to change layer.
        if !sideways, chatPresentation.isShowingConversation { return event }
        guard chatPresentation.handleSwipe(move) else { return event }
        didActInCurrentSwipe = true
        return nil
    }

    private func stopHoverWatch() {
        hoverMonitors.forEach { NSEvent.removeMonitor($0) }
        hoverMonitors.removeAll()
    }

    /// Let clicks and drags through the empty part of the shell to the app beneath it.
    /// See `CornerDockMouseRule`; driven from the pointer monitors because a window that
    /// ignores the mouse gets no events of its own to notice the pointer coming back.
    private func syncMouseTransparency() {
        guard let panel, let hostView else { return }
        let cards = hostView.interactiveRects
        let origin = panel.frame.origin
        let shouldIgnore = CornerDockMouseRule.shouldIgnoreMouse(
            pointer: NSEvent.mouseLocation,
            cards: cards.map { $0.offsetBy(dx: origin.x, dy: origin.y) },
            slack: ClipboardPillMetrics.hoverTolerance, autoHidden: isAutoHidden)
        if panel.ignoresMouseEvents != shouldIgnore { panel.ignoresMouseEvents = shouldIgnore }
    }

    /// Routes the pointer to whichever pill is under it. Only one card is ever open: the
    /// corner is one surface, not two competing ones.
    private func evaluateHover() {
        guard let panel else { return }
        syncMouseTransparency()
        // Hidden, the only thing the pointer can do is come back to the edge under it.
        if isAutoHidden {
            if CornerDockAutoHide.pointerReveals(
                mouse: NSEvent.mouseLocation, screenFrame: dockScreenFrame,
                content: shownContentRect)
            {
                summonFromEdge()
            }
            return
        }
        defer { if AppSettings.shared.cornerDockAutoHide { syncAutoHide() } }
        if !panel.isVisible { position() }
        let origin = panel.frame.origin
        let mouse = NSEvent.mouseLocation
        let slack = ClipboardPillMetrics.hoverTolerance

        func contains(_ rect: CGRect?) -> Bool {
            guard let rect else { return false }
            return rect
                .offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -slack, dy: -slack)
                .contains(mouse)
        }

        let slots = currentSlots()
        let overShelf = contains(slots.shelf)
        let overClipboard = contains(slots.clipboard)
        let overPrompt = contains(slots.prompt)
        foldWhenRestingOnApps(prompt: slots.prompt, origin: origin, mouse: mouse)

        // The shelf opens by click, not by hover: a pointer passing over its card is not a
        // request to keep it open, and not one to close it either.
        if overPrompt {
            clipboardModel.hoverEnded()
            chatPresentation.hoverBegan()
        } else if overShelf {
            clipboardModel.hoverEnded()
        } else if overClipboard {
            clipboardModel.hoverBegan()
        } else {
            clipboardModel.hoverEnded()
            chatPresentation.hoverEnded()
        }
    }
}

extension CornerDockController {
    /// Over the apps beside Global's empty field, the field folds back into the resting dock
    /// — the same apps with their previews, menus and window management (owner 2026-10-08:
    /// "over apps: back to the dock with running apps, pins"). Watched here, from the pointer
    /// the window already tracks, after a short dwell so crossing the apps does not fold it.
    /// Asked for by the pointer, so neither "fold on its own" nor the pin holds it back;
    /// `restAsDockNow` still refuses a typed field or a turn in progress.
    fileprivate func foldWhenRestingOnApps(prompt slot: CGRect?, origin: CGPoint, mouse: CGPoint) {
        let strip = slot.flatMap {
            CornerSplitShell.stripRect(
                slot: $0, fieldWidth: splitWidths.field, stripWidth: splitWidths.strip,
                height: AppChatPromptMetrics.fieldHeight(global: true))
        }
        // Global's field, and every app's Context Dock, which rests the same way (owner
        // 2026-10-08: "collapse the input field like Global Context").
        let resting = showsSplitShell && prompt.usesDockShell
            && strip.map { $0.offsetBy(dx: origin.x, dy: origin.y).contains(mouse) } == true
        guard resting else {
            appsFoldIntent?.cancel()
            appsFoldIntent = nil
            return
        }
        guard appsFoldIntent == nil else { return }
        DoraXTurnLog.record(
            "corner.apps pointer on the apps: mouse \(mouse) strip \(String(describing: strip)) origin \(origin)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appsFoldIntent = nil
            guard self.showsSplitShell, self.prompt.usesDockShell else {
                DoraXTurnLog.record("corner.apps dwell ended with the split gone")
                return
            }
            let folded = self.prompt.restAsDockNow()
            DoraXTurnLog.record(
                "corner.apps fold \(folded ? "done" : "refused") phase \(self.prompt.phase)")
        }
        appsFoldIntent = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CornerSplitShell.foldDwell, execute: work)
    }
}

/// The one shell: the field and its boards, the clipboard in the corner, the open shelf
/// above — each dropping out of the stack when it has nothing to show.
struct CornerDockSurface: View {
    @ObservedObject private var clipboardModel = ClipboardPanelController.shared.model
    @ObservedObject private var shelf = DropShelfController.shared.presentation
    @ObservedObject private var shelfStore = DropShelfController.shared.store
    @ObservedObject private var prompt = CornerDockController.shared.prompt
    @ObservedObject private var chatPresentation = CornerDockController.shared.chatPresentation
    @ObservedObject private var settings = AppSettings.shared

    /// The same answer `CornerDockLayout.slots` is given, so what is drawn sits exactly
    /// where the shell hit-tests it.
    private var anchor: CornerDockAnchor {
        CornerDockAnchor(rawValue: settings.cornerDockAnchorRaw) ?? .right
    }

    /// The composer and Global Context both carry their own "you just copied something"
    /// icon now — next to "+" in one, next to the running-app capsule in the other — the
    /// same transient `phase` this ambient pill reads. Drawing both said the same thing
    /// twice, closer together the more the shell's own anchor pushed them toward each
    /// other. General has no clipboard icon of its own yet, so it keeps this one.
    private var clipboardAlreadyShownInComposer: Bool {
        // The expanded card is never "already shown": the dock's own clipboard icon is
        // what opens it, and hiding it for being open would hide what was just asked for.
        chatPresentation.isVisible && chatPresentation.mode != .general
            && clipboardModel.phase != .expanded
    }

    var body: some View {
        // Centred, the shell is a row: field, clipboard side by side, with what answers the
        // field — and the open shelf — stacked over the field itself. Anchored to an edge it stays a
        // column, because a row against the screen's corner would run off it.
        Group {
            if anchor == .center {
                centredRow
            } else {
                column
            }
        }
    }

    /// The open shelf — a card in the shell, from the shelf icon at the end of the row.
    @ViewBuilder
    private var shelfCard: some View {
        if shelf.phase.isCardShown {
            DropShelfCard(presentation: shelf, store: shelfStore)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// What answers the field: the selection, the app's commands, or its window.
    @ViewBuilder
    private var chatBoards: some View {
        if CornerDockController.shared.selection.phase.isVisible {
            SelectionScopeCard(model: CornerDockController.shared.selection)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        if chatPresentation.isVisible, chatPresentation.mode != .general {
            if CornerDockController.shared.showsClipboardBoard {
                // The clipboard, as Raycast lays it out: clips beside the chosen one.
                ClipboardBoardCard(model: clipboardModel, prompt: prompt)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsScopeBoard {
                // The app's card, in the board rather than hanging off the chip.
                AppScopeBoard(model: prompt)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsExtensionPanel, let plugin = prompt.scopedPlugin {
                // A plugin opened from Global search: its panel, in the board (D6). × leaves
                // the scope, as Backspace does.
                CornerPluginCard(
                    pin: nil, manifest: plugin, model: prompt,
                    onClose: { _ = prompt.leaveScopeForGlobal() })
                    .id(plugin.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsExtensionPanel {
                ExtensionScopeCard(
                    model: prompt, ext: prompt.scopedExtension,
                    command: prompt.scopedCommand)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsAppSnapshot {
                AppSnapshotCard(model: prompt)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsAppChatList {
                // The list, with the highlighted row's preview in its right half (#191).
                AppChatListCard(model: prompt)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsHoverCard {
                // One card, whatever it is showing. Three views in this chain meant crossing
                // from an app to a pin tore one down and raised the other from the bottom,
                // while app to app — the same view, updated — slid. Same identity for all
                // three now; what is inside crossfades and the shell slides and resizes.
                CornerHoverCardHost(prompt: prompt)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// The field itself, in whichever mode is showing.
    ///
    /// Both chat modes are the same shape — a board above a field — so switching scope is a
    /// cross-fade of what the board holds, not one container torn down and a differently
    /// built one put up. That teardown is what used to flicker.
    @ViewBuilder
    private var chatSurface: some View {
        if chatPresentation.isVisible {
            if chatPresentation.mode == .general {
                if chatPresentation.generalPhase == .mini {
                    CornerGeneralChatMini().transition(.opacity)
                } else {
                    CornerGeneralChatView(model: chatPresentation.generalChat)
                        .transition(.opacity)
                }
            } else {
                // One structure in both layouts, so the field keeps its identity — and its
                // caret — when the shell splits: only the apps beside it come and go. Field
                // under the results, apps under the preview, one bottom line (Part B).
                let split = CornerDockController.shared.showsSplitShell
                let shell = AppChatPromptMetrics.boardWidth(for: prompt)
                // One liquid-glass container: the apps bud off the field's end and move out
                // past the merge distance, so the glass pinches in two like a water droplet
                // rather than a second capsule fading in beside the first.
                GlassEffectContainer(spacing: CornerSplitShell.dropletSpacing) {
                    HStack(alignment: .bottom, spacing: split ? CornerSplitShell.gap : 0) {
                        AppChatPromptPill(model: prompt)
                        if split {
                            CornerSplitStrip(
                                model: prompt, width: CornerDockController.shared.splitWidths.strip)
                                // Fades in as it buds off the field; gone at once on the fold.
                                // Left to fade out under the pointer, it stayed on screen beside
                                // a half-folded field until the pointer left (owner 2026-10-08:
                                // "dock only on mouse-out"); the dock's own icons arrive in its
                                // place as the field folds.
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                        }
                    }
                    .frame(width: split ? shell : nil, alignment: .leading)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: split)
                .animation(
                    .spring(response: 0.38, dampingFraction: 0.85),
                    value: CornerDockController.shared.splitWidths.strip)
                .transition(.opacity)
            }
        }
    }

    /// Shelf | field-and-its-boards | clipboard-and-its-preview — the same arithmetic
    /// `CornerDockLayout.slots` measures, so what is drawn is what is hit-tested.
    private var centredRow: some View {
        // Drawn the way `CornerDockLayout.slots` hit-tests it: the shelf and the field as a
        // centred row, the clipboard on its own at the right-hand corner — the same spot the
        // right anchor gives it, so a copy lands where the hand already knows to look.
        ZStack(alignment: .bottom) {
            centredRowContent
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 0)
                clipboardStack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(CornerDockLayout.pad)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: shelf.phase.isCardShown)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84), value: clipboardModel.phase.isVisible)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: prompt.phase)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: chatPresentation.mode)
    }

    private var clipboardStack: some View {
        VStack(alignment: .center, spacing: CornerDockLayout.gap) {
            if CornerDockController.shared.showsClipPreview,
                let focused = clipboardModel.focusedEntry
            {
                ClipboardPreviewCard(
                    model: clipboardModel,
                    entry: focused,
                    isPinned: clipboardModel.isPreviewPinned,
                    onTogglePin: { clipboardModel.togglePreviewPin() }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if clipboardModel.phase.isVisible, !clipboardAlreadyShownInComposer {
                ClipboardDockPill(model: clipboardModel)
            }
        }
    }

    private var centredRowContent: some View {
        HStack(alignment: .bottom, spacing: CornerDockLayout.gap) {
            // Pinned to the composer's own width, not whatever it happens to be showing:
            // the mini badge collapses to 52pt and Global Context's list is 372pt, and
            // this row centers itself on the sum of its children's widths. Without this,
            // opening Global Context (or idling back down to the badge) changed that sum
            // and the whole row — shelf, field, clipboard together — visibly slid sideways
            // to stay centered, when nothing about the shelf or clipboard had changed. The
            // dock never has this problem because its bar is one fixed-width container
            // that content changes happen inside of, not a row that resizes around them.
            VStack(alignment: .center, spacing: CornerDockLayout.gap) {
                // The strip's hover cards step sideways to stand over their icon, the way
                // an icon's menu does; every other board keeps the field's centre, because
                // it belongs to the field and not to one icon.
                // The open shelf stands over the field with the other boards — never beside
                // it, where it read as a second container next to the shell.
                shelfCard
                chatBoards
                    .offset(x: CornerDockController.shared.hoverCardDrawOffset)
                    .animation(
                        .smooth(duration: 0.22),
                        value: CornerDockController.shared.hoverCardDrawOffset)
                chatSurface
            }
            // The shell's one width (#189): every surface in it is drawn at this.
            .frame(width: DockShellWidth.current, alignment: .bottom)
        }
    }

    private var column: some View {
        VStack(alignment: anchor.horizontalAlignment, spacing: CornerDockLayout.gap) {
            shelfCard
            if CornerDockController.shared.showsClipPreview,
                let focused = clipboardModel.focusedEntry
            {
                ClipboardPreviewCard(
                    model: clipboardModel,
                    entry: focused,
                    isPinned: clipboardModel.isPreviewPinned,
                    onTogglePin: { clipboardModel.togglePreviewPin() }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if clipboardModel.phase.isVisible, !clipboardAlreadyShownInComposer {
                ClipboardDockPill(model: clipboardModel)
            }
            chatBoards
                .offset(x: CornerDockController.shared.hoverCardDrawOffset)
                .animation(
                    .smooth(duration: 0.22),
                    value: CornerDockController.shared.hoverCardDrawOffset)
            chatSurface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor.frameAlignment)
        .padding(CornerDockLayout.pad)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84), value: shelf.phase.isCardShown
        )
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84),
            value: clipboardModel.phase.isVisible)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84), value: prompt.phase)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84), value: chatPresentation.mode)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.84),
            value: chatPresentation.generalPhase)
    }
}

/// The strip's card above an icon: an app's windows, a pin's preview, or a plugin's panel.
/// One view with one identity so moving the pointer along the strip slides the card and
/// crossfades what is in it, whichever kind the next icon wants.
struct CornerHoverCardHost: View {
    @ObservedObject var prompt: AppChatPromptModel

    private var controller: CornerDockController { .shared }

    var body: some View {
        let size = controller.hoverCardSize ?? .zero
        ZStack {
            if controller.showsWindowRow, let bundleID = prompt.windowRowBundleID {
                CornerWindowRow(bundleID: bundleID, model: prompt)
                    .transition(.opacity)
            } else if controller.showsPinPreview, let pin = controller.hoveredPin {
                CornerPinPreviewCard(pin: pin, model: prompt)
                    .id(pin.id)
                    .transition(.opacity)
            } else if controller.showsPluginCard, let card = controller.pluginCardPin {
                CornerPluginCard(pin: card.pin, manifest: card.manifest, model: prompt)
                    .id(card.pin.id)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.smooth(duration: 0.22), value: size)
        .animation(.easeInOut(duration: 0.16), value: prompt.dockPreviewTarget)
        .animation(.easeInOut(duration: 0.16), value: prompt.pluginCardPinID)
    }
}
