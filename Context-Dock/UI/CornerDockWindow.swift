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
    private var accumulatedChatSwipeX: CGFloat = 0
    private var accumulatedChatSwipeY: CGFloat = 0
    private var sinks: Set<AnyCancellable> = []

    private var clipboardModel: ClipboardPanelModel { ClipboardPanelController.shared.model }
    /// The selection, when the user has raised it. A corner surface like the others, not
    /// the launcher wearing a smaller coat.
    let selection = SelectionScopeModel()
    private var shelf: DropShelfPresentation { DropShelfController.shared.presentation }
    let chatPresentation = CornerChatPresentation.shared
    let keyboardState = CornerDockKeyboardState()
    var prompt: AppChatPromptModel { chatPresentation.appChat }

    var window: NSPanel? { panel }

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
        // The preview card appears and disappears with the walk through the list, so the
        // stack has to be measured again when the focus moves — otherwise the card is drawn
        // in a slot nothing reserved and the rect below it is wrong for every row.
        clipboardModel.$focusedEntryIndex.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        shelf.$phase.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &sinks)
        selection.$phase.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.publishKeyboardOwner()
            }
        }.store(in: &sinks)
        prompt.$phase.sink { [weak self] phase in
            Task { @MainActor in
                self?.refresh()
                // The prompt is a text field the user asked for by name, so unlike the
                // ambient pills it takes focus the moment it appears.
                if phase.showsInput {
                    self?.armKeyboard()
                } else {
                    self?.disarmKeyboard()
                }
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
        let wanted = CornerDockLayout.panelSize(for: anchor)
        if panel.frame.size != wanted {
            panel.setContentSize(wanted)
            hostView?.frame = CGRect(origin: .zero, size: wanted)
        }
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let pad = CornerDockLayout.pad
        let margin: CGFloat = 20
        let size = panel.frame.size
        let x: CGFloat
        switch anchor {
        case .right: x = visible.maxX - margin + pad - size.width
        case .left: x = visible.minX + margin - pad
        case .center: x = visible.midX - size.width / 2
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
            selection: selection.phase.isVisible ? SelectionScopeMetrics.size : nil,
            list: showsAppSnapshot
                ? AppSnapshotMetrics.size
                : (showsAppChatList
                    ? AppChatListMetrics.size(
                        rows: prompt.listRowCount, output: prompt.showsCommandOutput)
                    : nil),
            prompt: chatPresentation.isVisible ? promptSize : nil,
            anchor: anchor)
    }

    /// The app's commands, or what it can do — a card of its own above the field, and only
    /// while the App Chat field is the thing on screen.
    var showsAppChatList: Bool {
        chatPresentation.isVisible
            && chatPresentation.mode != .general
            && prompt.phase == .suggesting
            && (prompt.listRowCount > 0 || prompt.showsCommandOutput)
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
        return AppChatPromptMetrics.size(
            for: prompt.phase,
            suggestions: prompt.listRowCount,
            messages: prompt.messages.count,
            hasApproval: ApprovalCenter.shared.pending(for: .corner) != nil,
            attachments: prompt.attachments.count)
    }

    /// Where a stood-down shelf pill would reappear, so the corner can be reached again.
    private func dormantShelfRect() -> CGRect? {
        guard !DropShelfController.shared.store.items.isEmpty else { return nil }
        return CornerDockLayout.slots(
            shelf: DropShelfMetrics.collapsedSize,
            clipboard: clipboardModel.phase.isVisible
                ? ClipboardPillMetrics.cardSize(for: clipboardModel.phase) : nil,
            selection: selection.phase.isVisible ? SelectionScopeMetrics.size : nil,
            list: showsAppChatList ? AppChatListMetrics.size(rows: prompt.listRowCount) : nil,
            prompt: prompt.phase.isVisible ? promptSize : nil,
            anchor: anchor
        ).shelf
    }

    // MARK: - Keyboard

    /// The clipboard card was clicked. `.nonactivatingPanel` keeps the ambient pills
    /// harmless and is also exactly what stops this window becoming key, so the style is
    /// dropped for as long as the card holds the keyboard.
    func armKeyboard() {
        guard let panel else { return }
        panel.styleMask = [.borderless]
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Recompute who should hold the keyboard and tell every board. Called whenever one of
    /// them opens, arms or closes — the boards themselves only listen.
    func publishKeyboardOwner() {
        keyboardState.ownerChanged(
            clipboardArmed: ClipboardPanelController.shared.model.isKeyboardArmed,
            selectionVisible: selection.phase.isVisible,
            chatShowsInput: prompt.phase.showsInput)
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
                selectionVisible: selection.phase.isVisible,
                chatShowsInput: prompt.phase.showsInput) == .chat
        else { return }
        chatPresentation.composerInteracted()
        keyboardState.composerInteracted()
    }

    func disarmKeyboard() {
        panel?.styleMask = [.borderless, .nonactivatingPanel]
        keyboardState.stoodDown()
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
            commandTapStarted = hasOtherModifier ? nil : Date()
            return event
        }
        guard let started = commandTapStarted else { return event }
        commandTapStarted = nil
        guard Date().timeIntervalSince(started) < 0.4,
              chatPresentation.isVisible,
              prompt.phase.showsInput
        else { return event }

        switch chatPresentation.mode {
        case .frontmostApp: chatPresentation.show(.globalContext)
        case .globalContext: chatPresentation.show(.frontmostApp)
        case .general: return event
        }
        return nil
    }

    private func handleChatNavigationKey(_ event: NSEvent) -> NSEvent? {
        // A key pressed while Command is down means this was a shortcut, not a tap.
        commandTapStarted = nil

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
            return event
        }
        guard let panel, event.window === panel,
              event.keyCode == 123,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              chatPresentation.isVisible,
              prompt.phase.showsInput,
              !ClipboardPanelController.shared.model.isKeyboardArmed,
              chatPresentation.handleLeftArrow(draft: prompt.query)
        else { return event }
        return nil
    }

    private func handleChatSwipe(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel,
              let promptRect = currentSlots().prompt,
              promptRect.contains(event.locationInWindow)
        else { return event }

        if event.phase == .began {
            accumulatedChatSwipeX = 0
            accumulatedChatSwipeY = 0
        }
        if event.phase == .began || event.phase == .changed
            || event.momentumPhase == .began || event.momentumPhase == .changed
        {
            accumulatedChatSwipeX += event.scrollingDeltaX
            accumulatedChatSwipeY += event.scrollingDeltaY
        }
        guard event.phase == .ended || event.momentumPhase == .ended else { return event }
        defer {
            accumulatedChatSwipeX = 0
            accumulatedChatSwipeY = 0
        }
        guard abs(accumulatedChatSwipeX) > abs(accumulatedChatSwipeY) * 1.8 else {
            return event
        }
        let draft = chatPresentation.mode == .general
            ? chatPresentation.generalChat.input : prompt.query
        return chatPresentation.handleHorizontalSwipe(
            deltaX: accumulatedChatSwipeX, draft: draft) ? nil : event
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
            if CornerDockController.shared.showsAppSnapshot {
                AppSnapshotCard(model: prompt)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if CornerDockController.shared.showsAppChatList {
                AppChatListCard(model: prompt)
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
        HStack(alignment: .bottom, spacing: CornerDockLayout.gap) {
            if shelf.phase.isVisible {
                DropShelfPill(presentation: shelf, store: shelfStore)
            }

            VStack(alignment: .center, spacing: CornerDockLayout.gap) {
                chatBoards
                chatSurface
            }

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
                if clipboardModel.phase.isVisible {
                    ClipboardDockPill(model: clipboardModel)
                }
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
            if clipboardModel.phase.isVisible {
                ClipboardDockPill(model: clipboardModel)
            }
            chatBoards
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
