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

/// Hosts both pills. Mouse events are answered only where a pill actually is, so the
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropShelfController.shared.dragEntered()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DropShelfController.shared.dragExitedPill()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropShelfController.shared.acceptDrop(sender.draggingPasteboard)
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
                DropShelfController.shared.presentation.autoHide()
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
        prompt.$phase.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                // The prompt is a text field the user asked for by name, so unlike the
                // ambient pills it takes focus the moment it appears. Disarming is not its
                // decision alone: a selection card or an armed clipboard may still need the
                // keys after the chat closes.
                self?.syncPanelKeyboard()
                self?.publishKeyboardOwner()
            }
        }.store(in: &sinks)
        chatPresentation.$mode.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.requestComposerFocus()
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
            }
        }.store(in: &sinks)
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
        panel.setFrameOrigin(NSPoint(x: x, y: visible.minY + margin - pad))
    }

    // MARK: - Visibility

    func refresh() {
        guard let panel, let hostView else { return }
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

        let shouldShow = !rects.isEmpty
        if shouldShow {
            if !panel.isVisible {
                position()
                panel.orderFrontRegardless()
            }
            startHoverWatch()
        } else {
            panel.orderOut(nil)
            // The corner keeps answering the pointer while the shelf still holds
            // something, or a stood-down shelf would strand its items.
            if DropShelfController.shared.store.items.isEmpty {
                stopHoverWatch()
            } else {
                startHoverWatch()
            }
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
            shelf: shelf.phase.isVisible
                ? DropShelfMetrics.cardSize(for: shelf.phase) : nil,
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
            list: showsExtensionPanel
                ? ExtensionScopeMetrics.size
                : (showsAppSnapshot
                    ? AppSnapshotMetrics.size
                    : (showsAppChatList
                        ? AppChatListMetrics.size(rows: prompt.listRowCount, width: AppChatPromptMetrics.boardWidth(for: prompt))
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
        guard showsWindowRow || showsPinPreview || showsPluginCard else { return 0 }
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
            tools: prompt.dockToolCount(clipboardVisible: clipboardModel.phase.announcesCopy, feedbackVisible: actionFeedback.glyph != nil),
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
        // The same composition the strip draws from: a pinned app that is running is one
        // icon there, so it must be one icon wide here.
        let composition = DockStripPlan.make(
            running: prompt.stripIcons, pins: prompt.stripPins,
            tools: prompt.dockToolCount(clipboardVisible: clipboardModel.phase.announcesCopy, feedbackVisible: actionFeedback.glyph != nil)
        ).composition
        return AppChatPromptMetrics.size(
            for: prompt.phase,
            suggestions: prompt.listRowCount,
            messages: prompt.messages.count,
            hasApproval: ApprovalCenter.shared.pending(for: .corner) != nil,
            attachments: prompt.attachments.count,
            running: composition.unpinnedRunningCount,
            pinnedApps: composition.pinnedAppCount,
            pinned: composition.otherPins.count,
            pinnedExtraWidth: composition.widgetExtraWidth,
            tools: prompt.dockToolCount(clipboardVisible: clipboardModel.phase.announcesCopy, feedbackVisible: actionFeedback.glyph != nil),
            promptIcons: prompt.promptIconCount,
            fieldHeight: AppChatPromptMetrics.fieldHeight(global: prompt.usesDockHeight),
            fitsContent: prompt.fitsField,
            maximumWidth: DockStripPlan.screenBudget,
            appBarPillWidth: AppChatPromptMetrics.appBarPillWidth(for: prompt))
    }

    /// Where a stood-down shelf pill would reappear, so the corner can be reached again.
    private func dormantShelfRect() -> CGRect? {
        guard !DropShelfController.shared.store.items.isEmpty else { return nil }
        return CornerDockLayout.slots(
            shelf: DropShelfMetrics.collapsedSize,
            clipboard: clipboardModel.phase.isVisible
                ? ClipboardPillMetrics.cardSize(for: clipboardModel.phase) : nil,
            selection: selection.phase.isVisible
                ? SelectionScopeMetrics.size(
                    rows: selection.rows.count, answering: selection.isShowingAnswer,
                    consent: selection.isAsking,
                    outcome: selection.showsOutcome,
                    folderPreview: selection.showsFolderPreview,
                    sendConfirm: selection.pendingSend != nil) : nil,
            list: showsAppChatList ? AppChatListMetrics.size(rows: prompt.listRowCount, width: AppChatPromptMetrics.boardWidth(for: prompt)) : nil,
            prompt: prompt.phase.isVisible ? promptSize : nil,
            anchor: anchor, panelWidth: panel?.frame.width
        ).shelf
    }

    // MARK: - Keyboard

    /// The clipboard card was clicked. `.nonactivatingPanel` keeps the ambient pills
    /// harmless and is also exactly what stops this window becoming key, so the style is
    /// dropped for as long as the card holds the keyboard.
    func armKeyboard() {
        guard let panel else { return }
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
            guard self?.panel?.isKeyWindow != true else { return }
            AppDelegate.shared?.previousFrontmostApp?.activate(options: [
                .activateIgnoringOtherApps
            ])
        }
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

    private func handleChatNavigationKey(_ event: NSEvent) -> NSEvent? {
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
            keyboardState.owner == .selection
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

        // A plugin's field has the caret: every key is its. The dock's own reading of a
        // typed letter — bring the field back — is exactly what put the "5" in the wrong
        // place.
        if PluginKeyboardClaim.shared.isEditing { return event }

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
            prompt.query.isEmpty,
            prompt.leaveScopeForGlobal()
        {
            return nil
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
        guard let panel, event.window === panel,
              event.keyCode == 123,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              chatPresentation.isVisible,
              prompt.phase.showsInput,
              !ClipboardPanelController.shared.model.isKeyboardArmed
        else { return event }
        // ← on an empty Global field folds it into the dock, before the presentation's
        // own walk between scopes is considered.
        if chatPresentation.mode != .general, prompt.foldToDock() { return nil }
        return chatPresentation.handleLeftArrow(draft: prompt.query) ? nil : event
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

    /// Routes the pointer to whichever pill is under it. Only one card is ever open: the
    /// corner is one surface, not two competing ones.
    private func evaluateHover() {
        guard let panel else { return }
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
        let overShelf = contains(slots.shelf) || contains(dormantShelfRect())
        let overClipboard = contains(slots.clipboard)
        let overPrompt = contains(slots.prompt)

        if overPrompt {
            shelf.hoverEnded()
            clipboardModel.hoverEnded()
            chatPresentation.hoverBegan()
        } else if overShelf {
            clipboardModel.hoverEnded()
            shelf.hoverBegan()
        } else if overClipboard {
            shelf.hoverEnded()
            clipboardModel.hoverBegan()
        } else {
            shelf.hoverEnded()
            clipboardModel.hoverEnded()
            chatPresentation.hoverEnded()
        }
    }
}

/// Both pills in the one shell: the shelf above, the clipboard in the corner, each
/// dropping out of the stack when it has nothing to show.
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
        // Centred, the shell is a row: shelf, field, clipboard side by side, with what
        // answers the field stacked over the field itself. Anchored to an edge it stays a
        // column, because a row against the screen's corner would run off it.
        if anchor == .center {
            centredRow
        } else {
            column
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
            if CornerDockController.shared.showsExtensionPanel {
                ExtensionScopeCard(
                    model: prompt, ext: prompt.scopedExtension,
                    command: prompt.scopedCommand)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsAppSnapshot {
                AppSnapshotCard(model: prompt)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsAppChatList {
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
                AppChatPromptPill(model: prompt).transition(.opacity)
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
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: shelf.phase.isVisible)
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
            if shelf.phase.isVisible {
                DropShelfPill(presentation: shelf, store: shelfStore)
            }

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
                chatBoards
                    .offset(x: CornerDockController.shared.hoverCardDrawOffset)
                    .animation(
                        .smooth(duration: 0.22),
                        value: CornerDockController.shared.hoverCardDrawOffset)
                chatSurface
            }
            .frame(width: AppChatPromptMetrics.width, alignment: .bottom)
        }
    }

    private var column: some View {
        VStack(alignment: anchor.horizontalAlignment, spacing: CornerDockLayout.gap) {
            if shelf.phase.isVisible {
                DropShelfPill(presentation: shelf, store: shelfStore)
            }
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
            .spring(response: 0.34, dampingFraction: 0.84), value: shelf.phase.isVisible
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
