// AppChatPromptPill.swift
// Context-Dock
//
// The corner input for asking the frontmost app something, in the same shell and shape as
// the clipboard pill.
//
// It opens the way Siri does — showing what this app can actually do — because a blank
// field asks the user to guess. Typing puts the list away, idling shrinks the whole thing
// to the app's own icon, and the controls in the field only appear under the pointer so
// the resting state stays a single quiet line.

import AppKit
import SwiftUI

enum AppChatPromptMetrics {
    static let width: CGFloat = 372
    static let inputHeight: CGFloat = 56
    static let suggestionRowHeight: CGFloat = 34
    static let summaryHeight: CGFloat = 30
    /// Just the app's icon.
    static let miniSize = CGSize(width: 52, height: 44)
    /// Attached files, as chips with a thumbnail — taller than the old bare capsules, and
    /// shared with General so one attachment is the same object in both modes.
    static let attachmentRowHeight: CGFloat = 46
    /// The conversation, with nothing in it yet: header, one exchange's worth of room, and
    /// the composer.
    static let chatHeight: CGFloat = 340

    /// How much a card grows per message, and how far it may grow.
    ///
    /// Both read from General's numbers rather than copying them. App mode was pinned at
    /// 340 while General grew to 620, so the same conversation was given half the room
    /// depending on which scope it was in — and the switch between the two modes looked
    /// like the window had changed rather than the subject.
    static var perMessageHeight: CGFloat { CornerGeneralChatMetrics.perMessageHeight }
    static var maximumChatHeight: CGFloat { CornerGeneralChatMetrics.maximumHeight }

    /// A pure function of model state, deliberately: the corner draws this frame and
    /// hit-tests the same number, so a height measured from content would leave the two
    /// disagreeing. Message count is state; message height is not.
    static func chatHeight(messages: Int) -> CGFloat {
        min(maximumChatHeight, chatHeight + CGFloat(min(messages, 5)) * perMessageHeight)
    }

    // MARK: Dock strip

    static let dockIconSize: CGFloat = 48
    static let dockIconGap: CGFloat = 8
    static let dockInset: CGFloat = 10
    /// gap + hairline + gap between the running section and the pins.
    static let dockDividerSpan: CGFloat = 17
    static let dockHeight: CGFloat = 68
    /// How long the dock takes to become the field, and the field the dock. One number for
    /// the shell, both layers' crossings and the strip's own gather, so nothing in the
    /// corner arrives at a different time from anything else.
    static let dockMorphDuration: TimeInterval = 0.9
    /// The field, folded: a magnifier as the strip's first item, one icon slot wide.
    static var dockSearchStubSpan: CGFloat { dockIconSize + dockIconGap }
    /// The least room the row is ever given: wider than the field, and what a caller that
    /// knows nothing about the screen gets. The corner passes the real budget — the screen
    /// it is on, less the margins the window keeps — so the row grows with what is in it
    /// the way the Dock does, rather than stopping at a card and a half and spilling into
    /// `+N` with half the screen empty beside it.
    static var dockMaximumWidth: CGFloat { width * 1.6 }

    /// What the strip may grow to on a screen of this width. The window already spans the
    /// screen at every anchor, so the only thing that was holding the row in was this
    /// number. Never below the minimum, so a tiny display still draws a usable row and
    /// overflows the rest.
    static func dockMaximumWidth(onScreenOf visibleWidth: CGFloat) -> CGFloat {
        max(dockMaximumWidth, visibleWidth - 2 * cornerScreenMargin)
    }

    /// The margin `CornerDockController.position()` keeps between the shell and the edge
    /// of the screen, named here so the two cannot drift apart.
    static let cornerScreenMargin: CGFloat = 20

    struct DockLayout: Equatable {
        /// Running icons actually drawn; the rest are the `+N` pill.
        let shownRunning: Int
        let overflow: Int
        /// Clipboard / selection affordances drawn after the pins.
        let tools: Int
        let width: CGFloat
    }

    private static func runWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * dockIconSize + CGFloat(count - 1) * dockIconGap
    }

    /// Pure: counts in, geometry out. Pins are never dropped — the user chose them — so
    /// the running section is what gives way, keeping one slot for the `+N` pill.
    /// `tools` are the corner's own affordances — clipboard, selection — that sit in the
    /// field's row when it is up and join the strip when it is not.
    ///
    /// `pinnedApps` are pinned *and* share the app region with the running ones, with no
    /// divider between them, because an app is one icon whether it is pinned, running or
    /// both. Like every other pin they are never dropped; `running` here counts only the
    /// apps nobody pinned, and those are what give way. `pinned` is the rest of the pins —
    /// commands, tools, files — which keep their own region after the divider.
    ///
    /// `pinnedExtraWidth` is what the pins region needs beyond one icon per pin: a pinned
    /// plugin drawing as a bar widget is `slots` icons wide, and the shell has to be measured
    /// for the tile that is drawn, not the icon that is not.
    static func dockLayout(
        running: Int, pinnedApps: Int = 0, pinned: Int, pinnedExtraWidth: CGFloat = 0,
        tools: Int = 0, maximumWidth: CGFloat = dockMaximumWidth
    ) -> DockLayout {
        let pinsWidth = pinned > 0 ? dockDividerSpan + runWidth(pinned) + pinnedExtraWidth : 0
        let toolsWidth = tools > 0 ? dockDividerSpan + runWidth(tools) : 0
        // Pinned apps take their slots out of the same region, gap included, before the
        // running ones are counted.
        let pinnedAppsWidth = pinnedApps > 0
            ? CGFloat(pinnedApps) * (dockIconSize + dockIconGap) : 0
        let available = maximumWidth - dockSearchStubSpan - 2 * dockInset - pinsWidth
            - toolsWidth - pinnedAppsWidth
        // How many running icons fit in what is left. At least one slot unless pinned apps
        // are already holding the region, in which case a strip of only pins is honest.
        let capacity = max(
            pinnedApps > 0 ? 0 : 1, Int((available + dockIconGap) / (dockIconSize + dockIconGap)))
        let shownRunning: Int
        let overflow: Int
        if running <= capacity {
            shownRunning = running
            overflow = 0
        } else {
            shownRunning = max(0, capacity - 1)  // one slot for +N
            overflow = running - shownRunning
        }
        let runningSlots = shownRunning + (overflow > 0 ? 1 : 0)
        let width = dockSearchStubSpan + 2 * dockInset
            + runWidth(max(1, pinnedApps + runningSlots)) + pinsWidth + toolsWidth
        return DockLayout(
            shownRunning: shownRunning, overflow: overflow, tools: tools, width: width)
    }

    /// What sits over the field — an approval waiting on a yes, attached files — is part
    /// of the card's height in every phase. Attachments were not counted at all before, so
    /// pasting a file into App mode drew a row the card had no room for.
    static func sheetHeight(hasApproval: Bool, attachments: Int, hasSelectionRow: Bool = false)
        -> CGFloat
    {
        var result: CGFloat = 0
        if hasApproval { result += ApprovalCard.height + 1 }
        if attachments > 0 { result += attachmentRowHeight }
        if hasSelectionRow { result += attachmentRowHeight }
        return result
    }

    static func size(
        for phase: AppChatPromptPhase,
        suggestions: Int,
        messages: Int = 0,
        hasApproval: Bool = false,
        attachments: Int = 0,
        hasSelectionRow: Bool = false,
        running: Int = 0,
        pinnedApps: Int = 0,
        pinned: Int = 0,
        pinnedExtraWidth: CGFloat = 0,
        tools: Int = 0
    ) -> CGSize {
        let sheet = sheetHeight(
            hasApproval: hasApproval, attachments: attachments, hasSelectionRow: hasSelectionRow)
        switch phase {
        case .hidden, .mini:
            return miniSize
        case .dock:
            return CGSize(
                width: dockLayout(
                    running: running, pinnedApps: pinnedApps, pinned: pinned,
                    pinnedExtraWidth: pinnedExtraWidth, tools: tools).width,
                height: dockHeight)
        case .prompt, .suggesting:
            // The list is its own card above this one, so the field stays a field.
            return CGSize(width: width, height: inputHeight + sheet)
        case .chat:
            return CGSize(width: width, height: chatHeight(messages: messages) + sheet)
        }
    }
}

struct AppChatPromptPill: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var keyboardState = CornerDockController.shared.keyboardState
    @ObservedObject private var approvals = ApprovalCenter.shared
    /// Watched, not asked once: the clipboard can arm while this field is already up, and
    /// the caret has to leave when it does.
    @ObservedObject private var clipboard = ClipboardPanelController.shared.model
    @ObservedObject private var selection = CornerDockController.shared.selection
    @ObservedObject private var actionFeedback = CornerActionFeedback.shared
    @FocusState private var fieldFocused: Bool
    @State private var pointerInside = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    private var size: CGSize {
        // The strip's own composition, not the raw counts: an app that is pinned and
        // running is one icon there, and a pin this build cannot resolve is none.
        let tools = model.dockToolCount(
            clipboardVisible: clipboard.phase.isVisible,
            feedbackVisible: actionFeedback.glyph != nil)
        let composition = DockStripPlan.make(
            running: model.stripIcons, pins: DockPinStore.shared.pins, tools: tools
        ).composition
        return AppChatPromptMetrics.size(
            for: model.phase,
            suggestions: model.listRowCount,  // list rows live in AppChatListCard now
            messages: model.messages.count,
            hasApproval: approvals.pending(for: .corner) != nil,
            attachments: model.attachments.count,
            hasSelectionRow: model.isShowingSelectionScope,
            running: composition.unpinnedRunningCount,
            pinnedApps: composition.pinnedAppCount,
            pinned: composition.otherPins.count,
            pinnedExtraWidth: composition.widgetExtraWidth,
            tools: tools)
    }

    var body: some View {
        Group {
            if model.isGlobalScope {
                globalBody
            } else {
                legacyBody
            }
        }
        .onHover { pointerInside = $0 }
        // One rule decides who holds the caret, and this field asks it rather than
        // asserting. Before, every phase change and focus token pulled focus back here —
        // so arming the clipboard armed a card that never got the keys.
        // Claimed when named, and on appear too: a board that mounts after the owner was
        // decided has no change to react to, which is exactly how the clipboard ended up
        // armed and keyless.
        .onAppear { syncFocus() }
        // The phase is now part of the answer to "may this field hold the caret", so it has
        // to be asked again when the phase moves — expanding from the dock changes nothing
        // about the keyboard owner.
        .onChange(of: model.phase) { _, _ in syncFocus() }
        .onChange(of: keyboardState.owner) { _, _ in syncFocus() }
        .onChange(of: keyboardState.focusRequestToken) { _, _ in syncFocus() }
        // A panel minimised or restored changes the pills without anything being typed, so
        // the row has to be asked again rather than waiting for the next keystroke.
        .onReceive(NotificationCenter.default.publisher(for: .minimizedPanelsChanged)) { _ in
            model.updateGlobalTyping(for: model.query)
        }
    }

    /// Global Context: one glass shell whose frame and corner radius carry the whole
    /// morph, with the field and the strip mounted inside it the whole time and crossing
    /// over by opacity.
    ///
    /// This replaced two glass shapes swapped by `glassEffectID`, and the reason is not
    /// taste. A layer that mounts and unmounts has to be given a transition to move at all,
    /// and any transition that changes geometry on the layer holding the TextField and its
    /// FocusState re-lays that subtree out every frame — SwiftUI's FocusBridge then rebuilds
    /// the window's key view loop every frame and the app hangs on hover (every sample in
    /// `updateDefaultKeyViewLoop`). Nothing here mounts during the morph and no inner width
    /// changes: `inputStack` is laid out at its full width from the first frame and the
    /// shell simply reveals more of it. Layout stays still; only the shell and opacity move.
    /// This is the shape `legacyBody` has always used, for the same reason.
    private var globalBody: some View {
        let showsInput = model.phase.showsInput
        let isDock = model.phase == .dock
        return ZStack(alignment: .bottomTrailing) {
            inputStack
                .frame(width: AppChatPromptMetrics.width, alignment: .bottomLeading)
                .opacity(showsInput ? 1 : 0)
                .allowsHitTesting(showsInput)
                .animation(fieldFade, value: model.phase)

            CornerDockStrip(model: model)
                .opacity(isDock ? 1 : 0)
                .allowsHitTesting(isDock)
                .animation(stripFade, value: model.phase)

            miniContent
                .opacity(model.phase == .mini ? 1 : 0)
                .allowsHitTesting(model.phase == .mini)
                .animation(.easeInOut(duration: 0.2), value: model.phase)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
        // The shell's own shape carries the morph: a capsule at dock height, the field's
        // 22-point card once it is open. Clipped to it so the wide layer never shows
        // outside the glass while the frame is still narrow.
        .clipShape(
            RoundedRectangle(cornerRadius: shellRadius, style: .continuous))
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: shellRadius, style: .continuous))
        // The dock glows in the result's colour; here the glass takes a stroke of it. Red
        // for anything destructive, the acted-on app's own colour otherwise, the phase's
        // when there is no app. Gone with the result.
        .overlay {
            RoundedRectangle(cornerRadius: shellRadius, style: .continuous)
                .strokeBorder(feedbackTint ?? .clear, lineWidth: 1.5)
                .opacity(feedbackTint == nil ? 0 : 0.85)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.3), value: actionFeedback.current?.id)
        .animation(.easeInOut(duration: 0.25), value: actionFeedback.progressTitle)
        .animation(shellMorph, value: model.phase)
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
    }

    private var feedbackTint: Color? {
        guard let result = actionFeedback.current else { return nil }
        return ActionFeedbackTint.color(
            for: result, appColor: actionFeedback.appIcon(for: result)?.dominantSwiftUIColor)
    }

    /// A capsule while it rests as a dock, a card once the field is open. Animated as one
    /// number, so the corner never looks like two shapes changing at once.
    private var shellRadius: CGFloat {
        model.phase == .dock ? AppChatPromptMetrics.dockHeight / 2 : 22
    }

    /// The whole morph, one curve. `dockMorphDuration` is the single number to turn when
    /// this feels fast or slow.
    private var shellMorph: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .smooth(duration: AppChatPromptMetrics.dockMorphDuration)
    }

    /// The field arrives after the shell has started widening, so it is read as the shell
    /// opening rather than a card fading in over a dock; it leaves at once, before the
    /// shell narrows enough to slice it.
    private var fieldFade: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.15) }
        let full = AppChatPromptMetrics.dockMorphDuration
        return model.phase.showsInput
            ? .easeOut(duration: full * 0.5).delay(full * 0.34)
            : .easeIn(duration: full * 0.22)
    }

    /// The mirror of `fieldFade`: the strip goes early on the way out and comes back late
    /// on the way in, so the small pill of apps inside the field is the thing on screen in
    /// the middle of the morph, and it is what appears to grow back into the dock.
    private var stripFade: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.15) }
        let full = AppChatPromptMetrics.dockMorphDuration
        return model.phase == .dock
            ? .easeOut(duration: full * 0.42).delay(full * 0.42)
            : .easeIn(duration: full * 0.3)
    }

    /// Everything that is not Global keeps the shell it had.
    ///
    /// Both layers stay mounted and cross-fade. Swapping them with a transition looked
    /// right in isolation and wrong in the shell: the 372-point input stack is still
    /// laid out at full width while the frame shrinks to the 52-point badge, and the
    /// clip outside this frame cuts it off mid-word — the badge showed an app icon and
    /// the first letter of its name, over the outgoing card's glass.
    ///
    /// The wide layer is also faded out faster than the frame collapses, so it is
    /// already invisible by the time the pill is narrow enough to slice it.
    private var legacyBody: some View {
        ZStack(alignment: .bottomLeading) {
            inputStack
                .frame(width: AppChatPromptMetrics.width, alignment: .bottomLeading)
                .opacity(model.phase.showsInput ? 1 : 0)
                .allowsHitTesting(model.phase.showsInput)
                .animation(.easeOut(duration: 0.11), value: model.phase)

            miniContent
                .opacity(model.phase == .mini ? 1 : 0)
                .allowsHitTesting(model.phase == .mini)
                .animation(.easeIn(duration: 0.16).delay(0.06), value: model.phase)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
    }

    private func syncFocus() {
        // The field is mounted in every phase now, including while the corner rests as a
        // dock — the morph needs it laid out and still. A mounted field must not be
        // focusable when it is not the thing on screen, or the dock's own keys go into an
        // invisible text field instead of bringing it back.
        fieldFocused = keyboardState.owner == .chat && model.phase.showsInput
    }

    // MARK: - Input

    /// Every state reads upward from one stable composer at the bottom. Suggestions are
    /// simply the empty transcript: they occupy the same space answers will use later.
    private var inputStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.phase == .chat {
                header
                Divider().opacity(0.18)
                transcript
                Divider().opacity(0.18)
            }
            // A turn asked from here can need a yes, and that question belongs directly
            // over the field — the same place the `/` picker and the command list appear —
            // rather than inside a transcript the user can scroll away from.
            if let request = approvals.pending(for: .corner) {
                ApprovalCard(request: request)
                    .frame(height: ApprovalCard.height)
                Divider().opacity(0.18)
            }
            if !model.pendingChoices.isEmpty {
                choiceCard
                Divider().opacity(0.18)
            }
            // The selection icon, clicked: what is selected shown the same way an actual
            // attachment is — a chip above the field, in this same composer — rather than
            // a second card opened on top of it.
            if model.isShowingSelectionScope {
                selectionRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !model.attachments.isEmpty { attachmentRow }
            inputRow
        }
        .frame(width: AppChatPromptMetrics.width, alignment: .topLeading)
        .animation(.easeOut(duration: 0.16), value: model.isShowingSelectionScope)
        .animation(.easeOut(duration: 0.16), value: model.selectionContent)
    }

    /// What the answer is waiting on, above the composer.
    ///
    /// The buttons exist inside the message too, and inside a scrolling transcript in a
    /// 372-point card that is somewhere the user has to go back to. A turn that has stopped to
    /// ask belongs at the point of reply, which is where the clipboard panel already puts its
    /// preview.
    private var choiceCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.pendingChoices) { choice in
                Button { model.pick(choice) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(choice.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(choice.routeLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Who the chat is with, and what to do with the chat itself — the same shape General
    /// mode uses, so switching scope changes the subject rather than the furniture.
    private var header: some View {
        HStack(spacing: 8) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text(model.appName.isEmpty ? "This app" : model.appName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text("App Chat")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 6)

            // Stop lives in the composer, which is drawn in every phase this header is —
            // one job, one button, rather than two of them 300 points apart.
            Button { model.openInDock() } label: {
                headerGlyph("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open this conversation in the dock")

            Button { model.newConversation() } label: {
                headerGlyph("trash")
            }
            .buttonStyle(.plain)
            .help("Clear this conversation")

            Button { model.togglePin() } label: {
                headerGlyph(model.isPinned ? "pin.fill" : "pin", tinted: model.isPinned)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
    }

    private func headerGlyph(_ symbol: String, tinted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tinted ? Color.accentColor : .secondary)
            .frame(width: 26, height: 26)
            .background(tinted ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
            .contentShape(Rectangle())
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            if model.appBundleID.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            } else if model.isGlobalScope {
                globalLeadingChip
            } else if model.returnsToGlobalScope {
                scopeChipWithExit
            } else {
                appChip
            }

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    placeholder
                }
                // What Tab would complete to, greyed behind the caret. Drawn in the field's
                // own metrics with the typed part transparent, so the ghost lines up with
                // the text instead of floating near it.
                if !model.globalGhostCompletion.isEmpty {
                    HStack(spacing: 0) {
                        Text(model.query).foregroundStyle(.clear)
                        Text(model.globalGhostCompletion)
                            .foregroundStyle(.secondary.opacity(0.45))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($fieldFocused)
                    .onChange(of: model.query) { _, _ in model.queryChanged() }
                    .onSubmit {
                        // A chosen row runs — a command or an adapter action. On a window
                        // snapshot with nothing typed, Return switches to that app, because
                        // that is what the switcher is for. Anything else is a question.
                        if model.runFocusedRow() { return }
                        if model.activateSnapshotApp() { return }
                        // A panel on screen is what the field is talking to.
                        if model.showsExtensionPanel {
                            model.askPanelAssistant()
                            return
                        }
                        // Inside a CLI scope, Return runs the line against that tool rather
                        // than asking the model about it.
                        if model.isCLIScope {
                            model.runCLICommand()
                            return
                        }
                        if model.isSearchField {
                            if let first = model.rows.first { model.run(first) }
                            return
                        }
                        model.submit()
                    }
                    .onKeyPress(.space) {
                        // Only once the user has arrowed into the list; with the caret in
                        // the field, a space is a space.
                        model.previewFocusedRow() ? .handled : .ignored
                    }
                    .onKeyPress(.tab) {
                        // The row the arrows landed on first; the top match only when the
                        // user has not chosen one.
                        if model.enterFocusedRow() { return .handled }
                        return model.acceptGlobalTopMatch() ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow) {
                        model.moveMenuFocus(by: 1) ? .handled : .ignored
                    }
                    .onKeyPress(.upArrow) {
                        model.moveMenuFocus(by: -1) ? .handled : .ignored
                    }
                    .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                        // Backspace on an empty field leaves the scope — the dock's way out,
                        // and the one most people reach for before they find the "−". Both
                        // delete keys, because `.delete` alone did not match the backspace
                        // this field actually receives.
                        if model.query.isEmpty, model.leaveScopeForGlobal() { return .handled }
                        return .ignored
                    }
                    .onKeyPress(.escape) {
                        // Unwind, then leave. Dismissing mid-answer threw away a turn the
                        // user was waiting on and a question they had half-written, for
                        // one press of the key that usually means "step back".
                        if !model.query.isEmpty {
                            model.query = ""
                            model.queryChanged()
                            return .handled
                        }
                        if model.leaveSelectionScope() { return .handled }
                        if model.isAnswering {
                            model.cancelTurn()
                            return .handled
                        }
                        model.dismiss()
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        // Left out of a scope entered from Global goes back to Global,
                        // before the walk between scopes is considered at all.
                        if model.query.isEmpty, model.leaveScopeForGlobal() { return .handled }
                        return CornerDockController.shared.chatPresentation
                            .handleLeftArrow(draft: model.query) ? .handled : .ignored
                    }
                    .onKeyPress(.rightArrow) {
                        // A chosen row is what the user is pointing at, so → steps into it
                        // before anything else. Otherwise it takes the ghost completion, and
                        // on an empty field it steps into an app; failing all of that it
                        // walks back through the scopes.
                        if model.enterFocusedRow() { return .handled }
                        if model.acceptGhostCompletion() { return .handled }
                        if model.scopeIntoFirstRunningApp() { return .handled }
                        return CornerDockController.shared.chatPresentation
                            .handleRightArrow(draft: model.query) ? .handled : .ignored
                    }
                    .onKeyPress(keys: ["p"]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        model.togglePin()
                        return .handled
                    }
                    .onKeyPress(keys: ["k"]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        model.newConversation()
                        return .handled
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        CornerDockController.shared.requestComposerFocus()
                    })
            }

            // The dock's own match pills, mounted rather than imitated: the apps that
            // answer what is typed, with "+N" for the rest. Same view, same icons, same
            // running dot as the dock's global bar.
            // Global Context and the scopes reached from it only: a scoped app chat is a
            // conversation about that one app, and a row of every other running app next
            // to it read as clutter rather than "somewhere else to go" — this was tried
            // widened to the plain frontmost-app chat too and asked back out.
            // Hidden once the user has typed and the board is answering: the rows say what
            // matched, and two answers to one question is the clutter the dock avoids. An
            // untyped field is not that case — there the pills are the only thing offering
            // anywhere to go, so they stay through a scope change.
            if model.isSearchField,
                model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !model.globalMatchIcons.isEmpty || model.globalOverflowCount > 0
            {
                ContextMatchDock(
                    phase: .idle,
                    icons: model.globalMatchIcons,
                    overflowCount: model.globalOverflowCount,
                    isSearching: false,
                    onSelect: { icon in model.openGlobalMatchIcon(icon) })
                    // Opacity only, for the same reason as the field above: this pill is a
                    // sibling of the TextField inside the focused subtree, and a geometry
                    // transition here moves the field's own layout while focus is claimed.
                    .transition(.opacity)
                    // Resting the pointer on the small pills asks for the big ones: the
                    // field folds into the dock at once rather than waiting out the dwell.
                    .onHover { inside in if inside { model.foldToDock() } }
                // Beside the running-app capsule, not inside it: the clipboard used to
                // lead that list as one of its icons, which put a permanent member in a
                // row meant to be "what's running" and made a stale old copy look as
                // current as a fresh one. Same transient signal as the composer's own.
                if clipboard.phase.isVisible {
                    clipboardTrailingButton
                }
            }

            // The dock shows this in Global Context too, independent of whether the
            // running-apps row has anything in it — a selection is worth carrying into a
            // question whether or not the field is also offering somewhere else to go.
            // This lived only in the composer's own branch below, so Global Context and
            // the scopes reached from it never had a way to see or reach the selection at
            // all, whatever the frontmost app's AX tree actually reported.
            if model.isSearchField, model.selection != nil {
                selectionScopeButton
            }

            // What the last action came to, beside the field for a few seconds — the
            // dock's inline result, carried here so a result reaches the surface the user
            // is on. Same transient lifetime as the clipboard's own icon.
            if let result = actionFeedback.glyph {
                ActionFeedbackGlyph(feedback: result)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            // What Return does, shown rather than left to the row below to explain: the
            // dock puts this same icon in its own search field once there is a match for
            // what is typed, so the field itself — not just a row you have to look down
            // at — says what is about to open. Whichever row the arrows landed on, or the
            // top one otherwise, same as the row hint and the ghost text agree with.
            if model.isSearchField, !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let icon = model.leadingResultIcon
            {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .animation(.easeOut(duration: 0.1), value: model.focusedMenuIndex)
            }

            // Attaching and sending live in the field, always drawn, the way the dock's own
            // composer keeps its "+" on screen. Hiding them until the pointer arrived meant
            // the two things you do most here were invisible until found by accident, and
            // gone entirely once a conversation started.
            //
            // Global Context and the scopes entered from it are search fields rather than
            // composers, and the dock carries none of this there — so neither does this.
            if !model.isSearchField {
                attachMenu
                // Gated on `entries.isEmpty` this stayed forever after the first copy of
                // the session — not what the dock does. The dock's own trailing button
                // reads a transient flag a fresh copy sets and a timer clears a few
                // seconds later; `phase` is the corner's version of that same transient
                // signal, already driving the ambient clipboard pill's own collapse-then-
                // vanish, so reading it here says "a copy just happened" rather than
                // "a clipboard exists somewhere," and needs no timer of its own.
                if clipboard.phase.isVisible {
                    clipboardTrailingButton
                }
                // Only when there is something to open: an icon that does nothing on a
                // blank selection is a button shaped like a promise it cannot keep.
                if model.selection != nil {
                    selectionScopeButton
                }
            }

            if model.isAnswering {
                Button { model.cancelTurn() } label: {
                    controlGlyph("stop.fill", tinted: true)
                }
                .buttonStyle(.plain)
                .help("Stop")
                .transition(.opacity)
            } else if model.isCLIScope,
                !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Asking the tool, through the pipeline — which decides what to run and
                // asks before running it.
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Ask \(model.cliCommand)")
                .transition(.opacity)
            } else if !model.isSearchField,
                !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Send")
                .transition(.opacity)
            }

            // Expand and pin stay with the pointer while this row is the whole surface;
            // once a conversation exists the header carries them, and drawing them twice
            // six points apart is two buttons for one job.
            if pointerInside, model.phase != .chat, !model.isGlobalScope {
                surfaceControls
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: AppChatPromptMetrics.inputHeight)
        .animation(.easeOut(duration: 0.14), value: pointerInside)
        .animation(.easeOut(duration: 0.12), value: model.isAnswering)
        .animation(.easeOut(duration: 0.12), value: model.query.isEmpty)
        .animation(.easeOut(duration: 0.16), value: model.selection)
        .animation(.easeOut(duration: 0.16), value: model.isShowingSelectionScope)
    }

    /// Opens the frontmost app's selection as its own corner card — the same surface the
    /// Selection Scope hotkey opens, reached here without leaving the keyboard to find it in
    /// Settings. Sits beside "+" because both add something to work with; this one reads it
    /// off the screen instead of picking a file.
    private var selectionScopeButton: some View {
        Button {
            // In place, not a second card: this session already knows what is selected
            // and already carries it on whatever question gets asked here, so opening the
            // separate Selection Scope card on top of an already-open chat stacked one
            // surface on another for something this one could just show itself.
            model.toggleSelectionScope()
        } label: {
            controlGlyph("text.cursor", tinted: model.isShowingSelectionScope)
        }
        .buttonStyle(.plain)
        .help(model.isShowingSelectionScope ? "Back to \(model.appName)" : "Show the current selection")
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    /// The dock's own clipboard affordance, mounted here rather than imitated: same
    /// controller, same toggle, so opening it here and opening it from the dock's search
    /// bar land in the exact same panel rather than two that happen to look alike.
    private var clipboardTrailingButton: some View {
        Button {
            AppDelegate.shared?.activateClipboardScope()
        } label: {
            controlGlyph("doc.on.clipboard")
        }
        .buttonStyle(.plain)
        .help("Open the clipboard")
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    private var attachMenu: some View {
        Menu {
            Button("Upload File") { pickFiles(imagesOnly: false) }
            Button("Upload Photo") { pickFiles(imagesOnly: true) }
            Divider()
            Button("Take Screenshot") { capture(interactive: false) }
            Button("Capture Area") { capture(interactive: true) }
            Button("Capture Text") { captureText() }
        } label: {
            controlGlyph("plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .help("Add context")
    }

    /// The app the question is about, named rather than implied.
    /// In Global Context the leading chip is the top match, not the scope — the same thing
    /// the dock's global bar shows, so three letters and a glance tell the user what Tab
    /// would take.
    private var globalLeadingChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .frame(width: 26, height: 26)
            // The thing the field is pointing at, so the icon answers "what happens if I
            // press Return" without the user reading a row.
            if let icon = model.leadingResultIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .help(model.globalTopMatch.map { "Tab to open \($0.title)" } ?? "Search everything")
    }

    /// The scope chip with a way out of it — the "−" the dock's scope chip carries. Only
    /// for a scope entered from Global: the frontmost app's own scope is not something the
    /// user stepped into, so there is nothing to step back from.
    private var scopeChipWithExit: some View {
        HStack(spacing: 6) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(model.appName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Button { model.leaveScopeForGlobal() } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Back to Global Context")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.09), in: Capsule())
        // The scope's name is the subject of everything else in this row, so it keeps its
        // width and the placeholder gives way — truncating it to "F" said nothing at all.
        .layoutPriority(1)
    }

    private var appChip: some View {
        HStack(spacing: 6) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(model.appName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private var placeholder: some View {
        if let running = actionFeedback.progressTitle {
            // What is happening, where the prompt would be — the dock says it in its own
            // field the same way. It leaves when the app is there and the placeholder comes
            // back, which is the whole of the announcement.
            Text(running)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
                .transition(.opacity)
        } else if model.phase == .suggesting {
            HStack(spacing: 6) {
                Text(AppChatListCard.placeholder(for: model))
                    .foregroundStyle(.secondary.opacity(0.85))
                Text("— press Enter to send…")
                    .foregroundStyle(.secondary.opacity(0.45))
            }
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
        } else {
            Text("\(AppChatListCard.placeholder(for: model))…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    /// What acts on the surface rather than on the question: where it opens, and whether it
    /// stays. Attach and send are in the field itself, because they are part of asking.
    private var surfaceControls: some View {
        HStack(spacing: 8) {
            Button {
                model.openInDock()
            } label: {
                controlGlyph("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open this conversation in the dock")

            Button {
                model.togglePin()
            } label: {
                controlGlyph(model.isPinned ? "pin.fill" : "pin", tinted: model.isPinned)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")
        }
    }

    private func controlGlyph(_ symbol: String, tinted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tinted ? Color.accentColor : .secondary)
            .frame(width: 26, height: 26)
            .background(
                tinted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                in: Circle())
    }

    // MARK: - Attachments

    private func pickFiles(imagesOnly: Bool) {
        for url in ChatAttachmentCapture.pickFiles(imagesOnly: imagesOnly) {
            model.attach(url)
        }
    }

    private func capture(interactive: Bool) {
        ChatAttachmentCapture.captureScreenshot(interactive: interactive) { url in
            model.attach(url)
        }
    }

    private func captureText() {
        ChatAttachmentCapture.captureScreenText { text in
            model.query += model.query.isEmpty ? text : "\n" + text
            model.queryChanged()
        }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments, id: \.self) { url in
                    ChatAttachmentChip(url: url) { model.detach(url) }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: AppChatPromptMetrics.attachmentRowHeight)
    }

    /// What is selected, as a chip — a real file reuses the exact same attachment chip an
    /// actually-attached one draws; text gets the same shape without a thumbnail, since it
    /// has no file to generate one from.
    @ViewBuilder
    private var selectionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                switch model.selectionContent {
                case .files(let urls):
                    ForEach(urls, id: \.self) { url in
                        ChatAttachmentChip(url: url) { model.leaveSelectionScope() }
                    }
                case .text(let text):
                    selectionTextChip(text)
                case nil:
                    EmptyView()
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: AppChatPromptMetrics.attachmentRowHeight)
    }

    private func selectionTextChip(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Button { model.leaveSelectionScope() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .opacity(0.45)
            }
            .buttonStyle(.plain)
            .help("Close the selection")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            Color.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .frame(maxWidth: 260, alignment: .leading)
        .help(text)
    }

    // MARK: - Suggestions

    // MARK: - Conversation

    /// The dock's own message view, so steps, tool chips, receipts and route choices
    /// render here exactly as they do in the dock. Reimplementing it would have been the
    /// same drift this surface was built to avoid.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) {
                        index, message in
                        AIChatMessageView(
                            message: message,
                            isStreaming: model.isAnswering && index == model.messages.count - 1,
                            // The dock passed this and the corner did not, so a proposed app
                            // action reached this transcript with its Install card drawn
                            // nowhere. Same message, same flag, same installer — the corner
                            // only supplies its own scope.
                            onInstallProposal: { json in
                                guard let data = json.data(using: .utf8),
                                    let proposal = try? JSONDecoder()
                                        .decode(ExtensionProposalData.self, from: data)
                                else { return }
                                Task { @MainActor in
                                    // The corner is a frontmost-app surface, so its proposals
                                    // are app actions. A selection-scope or rule proposal
                                    // has its own installer, still on the dock (#12); filing
                                    // one as an adapter action would be worse than saying so.
                                    guard proposal.layer.lowercased() == "contextdock" else {
                                        AppChatConversation.shared.messages.append(
                                            AIChatMessage(
                                                role: .assistant,
                                                content: "That kind of extension is saved from "
                                                    + "the dock's chat for now — open the same "
                                                    + "conversation there and press Install."))
                                        return
                                    }
                                    await AdapterActionProposalInstaller.install(
                                        proposal,
                                        bundleId: model.appBundleID,
                                        appName: model.appName)
                                }
                            },
                            assistantAvatarImage: appIcon,
                            liveSteps: model.isAnswering && index == model.messages.count - 1
                                ? model.liveSteps : []
                        )
                        .id(message.id)
                    }
                    // The dock draws its activity timeline over exactly this data; the
                    // corner drew a bare spinner over it. A spinner is the app declining
                    // to say what it is doing while it holds the user's question.
                    if model.isAnswering && model.messages.last?.role == .user {
                        LiveAgentProgressView(steps: waitingSteps)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: model.messages.count) { _, _ in
                guard let last = model.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What to show between sending and the first token.
    ///
    /// The steps are the truth when there are any. Before the first one arrives there is
    /// still something honest to say — which app the question went to — and saying it beats
    /// a spinner, which tells the user only that the app is busy with something.
    private var waitingSteps: [String] {
        let steps = model.liveSteps.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard steps.isEmpty else { return steps }
        return ["Reading \(model.appName.isEmpty ? "this app" : model.appName)…"]
    }

    // MARK: - Shrunken

    /// The app's own icon: the corner still says which app this was about.
    private var miniContent: some View {
        Group {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            width: AppChatPromptMetrics.miniSize.width,
            height: AppChatPromptMetrics.miniSize.height)
    }

    private var appIcon: NSImage? {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: model.appBundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
