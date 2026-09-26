import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Global Context at rest: the running apps and the pins, at Dock size. It offers places
/// to go and never answers anything — typing is what brings the field back.
struct CornerDockStrip: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var pins = DockPinStore.shared
    @ObservedObject private var clipboard = ClipboardPanelController.shared.model
    @ObservedObject private var feedback = CornerActionFeedback.shared
    /// A pin draws only when the search index resolves it; a rebuilt index is a redraw.
    @ObservedObject private var index = GlobalSearchIndexStatus.shared
    @State private var hoveredID: String?
    @State private var isDropTarget = false
    @State private var draggingPinID: UUID?
    /// The magnifier is being hovered and the field is about to come back. The icons draw
    /// themselves condensing while this is true, so the glass morph has something to morph
    /// *from* rather than a strip that blinks out. Cancelled if the pointer leaves first.
    @State private var condensing = false
    /// Set as the pill spreads back into the dock. The icons move out from under a pointer
    /// that has not moved, and whichever one lands under it would magnify and start its
    /// window preview mid-flight — hover waits until the row has arrived.
    @State private var hoverSettlesAt = Date.distantPast
    @State private var hoverIntent: Task<Void, Never>?
    /// The icon whose Dock-style menu is up — a popover over the icon, arrow down, the
    /// way the Dock does it, rather than a menu at the pointer.
    @State private var menuID: String?
    /// A bar-widget plugin drawn as its icon, showing its tile because the pointer is on it.
    @State private var widgetPeekID: UUID?
    @State private var widgetPeekClose: Task<Void, Never>?

    private typealias M = AppChatPromptMetrics

    /// The icons are collapsed toward the pill whenever the field is on its way in or
    /// already up — not only while the magnifier is hovered. Typing a letter and clicking
    /// the magnifier open the field too, and they are the same motion.
    private var gathered: Bool { condensing || model.phase != .dock }

    private var isDock: Bool { model.phase == .dock }

    /// What gathers into the field fades late on the way in — after it has flown to the
    /// pill — and at once on the way back, so it is seen leaving the pill.
    private var movingFade: Animation {
        let full = AppChatPromptMetrics.dockMorphDuration
        return isDock
            ? .easeOut(duration: full * 0.2)
            : .easeIn(duration: full * 0.3).delay(full * 0.5)
    }

    /// The field is up and showing its pill: the strip's apps are that pill, shrunk into
    /// the room the field keeps for it. Typing hides it, as it hid the field's own.
    private var isPill: Bool {
        [.prompt, .suggesting].contains(model.phase) && model.showsFieldPills
            // An app bar's field is compact and draws its own pill after "+": the big
            // icons fade across rather than flying into a pill at the strip's end.
            && !model.fitsField
            && (!model.globalMatchIcons.isEmpty || model.globalOverflowCount > 0)
            // Typing hides it everywhere — tabs and pins included (owner 2026-09-26: while
            // typing the field is compact: attach, send, pin).
            && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the pill sits in the shell: ending where the strip's trailing region begins,
    /// exactly where the field keeps its room.
    private func pillSpan(_ plan: DockStripPlan) -> (start: CGFloat, end: CGFloat) {
        let layout = plan.layout
        let typed = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let end = layout.width - layout.leadingInset - layout.trailingRegion
            - (model.showsTabBar ? M.appFieldTrailingReserve(typed: typed) : 0)
        let width = M.pillWidth(
            icons: model.globalMatchIcons.count, overflow: model.globalOverflowCount > 0)
        return (end - width, end)
    }

    /// One after another. Folding in, the icon nearest the pill goes first, so the row
    /// folds up into it from its end. Spreading out, Finder goes first and the rest follow
    /// in order, so the row unrolls from the magnifier back to the pins. Read when the body
    /// is rebuilt for the new state, so `gathered` is where the row is heading.
    private func gatherAnimation(index: Int, count: Int) -> Animation {
        let full = AppChatPromptMetrics.dockMorphDuration
        let step = gathered ? max(0, count - 1 - index) : index
        return .smooth(duration: full * 0.55).delay(Double(step) * full * 0.05)
    }

    /// Whether the app in this slot is one the field's pill carries.
    private func inPill(_ bundleID: String?) -> Bool {
        guard let bundleID else { return model.globalOverflowCount > 0 }
        return model.globalMatchIcons.contains { $0.bundleID == bundleID }
    }

    /// How far app `index` travels to reach its slot in the field's pill — found by bundle
    /// id, since the pill leads with Finder and the strip with its pinned apps. Anything
    /// the pill does not show lands on the pill's end, where its `+N` is.
    /// An app bar gathers into its own pill in the compact field, right after "+", rather
    /// than into a pill at the strip's end: the icons fly and shrink to where the pill draws
    /// them, then hand over to it — Global's motion, aimed at the app bar's pill.
    private var gathersIntoAppBar: Bool { model.fitsField && model.showsTabBar }

    /// Where an app bar's icon lands, measured from the strip's leading edge. The field and
    /// the strip share their trailing edge, so the pill's end is the strip's width less what
    /// the field draws after the pill: its 14 of padding and the controls after the pill.
    private func appBarGatherOffset(index: Int, plan: DockStripPlan) -> CGFloat {
        let layout = plan.layout
        let from = layout.leadingInset + M.dockSearchStubSpan
            + CGFloat(index + 1) * layout.appSpread
            + CGFloat(index) * (M.dockIconSize + M.dockIconGap) + M.dockIconSize / 2
        let control: CGFloat = 26 + 10  // a 26-point control and the row's spacing before it
        var trailing: CGFloat = 14
        if model.isPointerInside { trailing += control }  // the pin
        if clipboard.phase.announcesCopy { trailing += control }
        if model.selection != nil { trailing += control }
        let pillEnd = layout.width - trailing
        let pillStart = pillEnd - AppChatPromptMetrics.appBarPillWidth(for: model)
        // Pins lead, so an icon is past the hairline when it is a tab with a pin before it.
        let icons = model.allRunningIcons
        let pastDivider = icons.indices.contains(index)
            && !model.isAppPinIcon(icons[index].id)
            && icons.prefix(index).contains { model.isAppPinIcon($0.id) }
        let size = AppChatPromptMetrics.appBarIconSize
        let to = pillStart + 8 + CGFloat(index) * (size + AppChatPromptMetrics.appBarIconGap)
            + (pastDivider ? 1 + AppChatPromptMetrics.appBarIconGap : 0) + size / 2
        return to - from
    }

    private func gatherOffset(index: Int, bundleID: String?, plan: DockStripPlan) -> CGFloat {
        let layout = plan.layout
        let pills = model.globalMatchIcons
        let (pillStart, pillEnd) = pillSpan(plan)
        let from = layout.leadingInset + M.dockSearchStubSpan
            + CGFloat(index + 1) * layout.appSpread
            + CGFloat(index) * (M.dockIconSize + M.dockIconGap) + M.dockIconSize / 2
        let to: CGFloat
        if let bundleID, let slot = pills.firstIndex(where: { $0.bundleID == bundleID }) {
            // 8 of capsule padding, then half an 18-point icon; 25 per icon after that.
            to = pillStart + 17 + CGFloat(slot) * M.matchPillIconSpan
        } else {
            to = pillEnd - 20  // the `+N`
        }
        return to - from
    }

    /// The row and its geometry, made together: an app appears once, whether it is pinned,
    /// running or both.
    private var plan: DockStripPlan {
        DockStripPlan.make(
            running: model.stripIcons, pins: model.stripPins,
            tools: model.dockToolCount(
                clipboardVisible: clipboard.phase.announcesCopy,
                feedbackVisible: feedback.glyph != nil),
            fieldIcons: model.promptIconCount)
    }

    var body: some View {
        HStack(spacing: M.dockIconGap) {
            // The field, folded: the first item in the strip. Hovering it, or clicking
            // it, widens it back.
            // The field, folded: the magnifier in Global, the app's own icon in its Context
            // Dock — what the field says it is about when it opens.
            foldedField { expandField() }
                .scaleEffect(condensing ? 1.12 : 1)
                .onHover { inside in inside ? beginHoverExpand() : cancelHoverExpand() }
                // The hairline between the field, folded, and the apps — the same one the
                // pins get. Drawn over room that is already there, so it costs no width, and
                // centred between what the eye sees — the 20-point glyph, not its 48-point
                // slot — and Finder. It belongs to the magnifier and leaves with it.
                .overlay(alignment: .center) {
                    let glyphEdge: CGFloat = 10
                    let appEdge = M.dockIconSize / 2 + M.dockIconGap + self.plan.layout.appSpread
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: M.dockIconSize * 0.7)
                        .offset(x: (glyphEdge + appEdge) / 2)
                        .allowsHitTesting(false)
                }
                // The field's own magnifier opens on this exact spot; this one hands over.
                .opacity(isDock ? 1 : 0)
                .animation(movingFade, value: isDock)
                .allowsHitTesting(isDock)
            // One region for apps: the pinned ones first, in the order the user placed
            // them, then whatever else is running. Composed once for the whole pass —
            // `scale(for:)` runs per icon per hover frame and must not compose again.
            let plan = self.plan
            let ids = plan.composition.apps.map(\.id)
                + plan.composition.otherPins.map(\.id.uuidString)
            // Each app flies to its own slot in the field's small pill and shrinks to its
            // size — drawn there, not laid out there, so the row's geometry never moves
            // (memory `corner-pill-size-must-be-pure`) — then hands over to the pill.
            let count = plan.composition.apps.count + (plan.layout.overflow > 0 ? 1 : 0)
            ForEach(Array(plan.composition.apps.enumerated()), id: \.element.id) { index, slot in
                if gathersIntoAppBar {
                    // Flies and shrinks to its place in the field's pill, then hands over to
                    // it: gone once it has arrived, back at once when the bar spreads out.
                    let inPill = index < AppChatPromptModel.appBarVisibleIcons
                    appIcon(slot, ids: ids)
                        .scaleEffect(gathered
                            ? AppChatPromptMetrics.appBarIconSize / M.dockIconSize : 1)
                        .offset(x: gathered && inPill
                            ? appBarGatherOffset(index: index, plan: plan) : 0)
                        .animation(gatherAnimation(index: index, count: count), value: gathered)
                        .opacity(isDock ? 1 : 0)
                        .animation(inPill ? movingFade : .easeIn(duration: 0.12), value: isDock)
                        .allowsHitTesting(isDock)
                        .padding(.leading, plan.layout.appSpread)
                } else {
                    let stays = isDock || (isPill && inPill(slot.bundleID))
                    appIcon(slot, ids: ids)
                        .scaleEffect(gathered ? M.pillIconScale : 1)
                        .offset(x: gathered ? gatherOffset(index: index, bundleID: slot.bundleID, plan: plan) : 0)
                        .animation(gatherAnimation(index: index, count: count), value: gathered)
                        // An app the pill does not carry goes as it leaves; the rest are the pill.
                        .opacity(stays ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: stays)
                        .allowsHitTesting(stays)
                        .padding(.leading, plan.layout.appSpread)
                }
            }
            if plan.layout.overflow > 0 {
                let stays = isDock || (isPill && model.globalOverflowCount > 0)
                overflowPill(plan.layout.overflow)
                    .scaleEffect(gathered ? M.pillIconScale : 1)
                    .offset(
                        x: gathered
                            ? gatherOffset(
                                index: plan.composition.apps.count, bundleID: nil, plan: plan)
                            : 0)
                    .animation(gatherAnimation(index: count - 1, count: count), value: gathered)
                    .opacity(stays ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: stays)
                    .allowsHitTesting(isDock)
                    .padding(.leading, plan.layout.appSpread)
            }
            if !plan.composition.otherPins.isEmpty {
                // The HStack's own gap on each side of this hairline is the 17-point
                // `dockDividerSpan` the metrics count.
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: M.dockIconSize * 0.7)
                ForEach(plan.composition.otherPins) { pin in
                    if plan.composition.widgetSlots[pin.id] != nil,
                        let pluginID = pin.kind.pluginID,
                        let manifest = PluginRegistry.shared.plugin(id: pluginID)?.manifest
                    {
                        // A pinned plugin with a bar widget IS its widget here — a live
                        // tile in the row, Phase 4's strip host.
                        PluginStripTile(pin: pin, manifest: manifest, model: model)
                            .modifier(DockPinDrag(pinID: pin.id, dragging: $draggingPinID))
                            .overlay(RightClickReporter { menuID = pin.id.uuidString })
                            .popover(isPresented: menuBinding(pin.id.uuidString), arrowEdge: .top) {
                                DockIconMenu(items: pinnedMenuItems(pin))
                            }
                    } else {
                        pinnedIcon(pin, ids: ids)
                    }
                }
            }
            if plan.layout.tools > 0 {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: M.dockIconSize * 0.7)
                // The corner's own cards, not the field's scope chips: a dock icon opens a
                // surface beside the dock, it does not bring the field back with a chip in it.
                if clipboard.phase.announcesCopy {
                    toolIcon("doc.on.clipboard", title: "Clipboard") {
                        ClipboardPanelController.shared.show()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    // Hovering opens the card without taking the keyboard; a click arms it.
                    .onHover { inside in
                        guard inside else { return }
                        let controller = ClipboardPanelController.shared
                        controller.model.reload()
                        controller.model.summon()
                    }
                }
                // An app bar carries only the clipboard (`dockToolCount`): drawing more than
                // it counts would run past the width it was given.
                if model.selection != nil, !model.showsTabBar {
                    toolIcon("text.cursor", title: "Selection") {
                        CornerDockController.shared.showSelectionScopeFromDock()
                    }
                }
                // What the last action came to, for a few seconds — the dock's inline
                // result, in the corner's own idiom: the clipboard's slot and lifetime.
                if let result = feedback.glyph, !model.showsTabBar {
                    ActionFeedbackGlyph(feedback: result, size: M.dockIconSize)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        // The same curve and length as the shell's morph: the icons are still travelling
        // into the pill while the field opens, which is the whole point of the flow.
        .animation(
            .smooth(duration: AppChatPromptMetrics.dockMorphDuration * 0.8), value: gathered)
        .animation(.smooth(duration: 0.25), value: feedback.current?.id)
        .animation(.smooth(duration: 0.25), value: clipboard.phase.announcesCopy)
        .padding(.horizontal, plan.layout.leadingInset)
        .frame(height: M.dockHeight)
        // The pill's capsule, drawn behind the icons that became it — it arrives once they
        // have, so what the eye follows is the icons, not a second shape appearing.
        .background(alignment: .leading) {
            let span = pillSpan(plan)
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7))
                .frame(width: max(0, span.end - span.start), height: 30)
                .offset(x: span.start)
                .opacity(isPill ? 1 : 0)
                .animation(
                    isPill
                        ? .easeOut(duration: M.dockMorphDuration * 0.3)
                            .delay(M.dockMorphDuration * 0.35)
                        : .easeIn(duration: M.dockMorphDuration * 0.15),
                    value: isPill)
                .allowsHitTesting(false)
        }
        // The gaps between icons catch the pointer only while this is the dock. Over the
        // field the strip is drawn on top, and an empty stretch of it must not swallow a
        // click on the text. A background, not the strip's own content shape: that shape
        // bounds the whole subtree, and an empty one took the pill and the pins with it.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .allowsHitTesting(isDock)
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $isDropTarget) { providers in
            acceptDrop(providers)
        }
        .onChange(of: isDropTarget) { _, inside in
            // The pointer carried a pin off the strip and let go elsewhere: unpin. A drop
            // back on the strip clears `draggingPinID` in acceptDrop before this fires.
            if !inside, let id = draggingPinID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if draggingPinID == id, NSEvent.pressedMouseButtons == 0 {
                        DockPinStore.shared.unpin(id)
                        model.updateTabStrip()
                        draggingPinID = nil
                    }
                }
            }
        }
        .overlay {
            if isDropTarget {
                Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
            }
        }
        // The strip is unmounted while the field is up, so this normally has nothing to
        // do — it clears the flag on the path where SwiftUI keeps the view's identity
        // instead, which would otherwise leave the dock permanently condensed.
        .onChange(of: model.phase) { _, phase in
            if phase == .dock {
                condensing = false
                hoverSettlesAt = Date().addingTimeInterval(AppChatPromptMetrics.dockMorphDuration * 0.75)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock")
    }

    // MARK: Icons

    /// An app, once. A pinned app that is running is this same icon with a dot under it —
    /// never a second copy beside the pins.
    @ViewBuilder
    private func appIcon(_ slot: DockAppSlot, ids: [String]) -> some View {
        let id = slot.id
        DockStripIcon(
            image: slot.running?.icon ?? slot.pin?.kind.icon, title: slot.title,
            isRunning: slot.isRunning,
            isAvailable: slot.pin.map { $0.kind.isAvailable } ?? true,
            scale: scale(for: id, among: ids)
        )
        .onHover { inside in
            // As the field's pill, resting on an app asks for the dock back, as the field's
            // own pill did.
            guard isDock else {
                if inside { _ = model.foldToDock() }
                return
            }
            // Still spreading out of the pill: an icon arriving under the pointer is not
            // the pointer choosing it. Leaving is always honoured, so nothing sticks.
            if inside, Date() < hoverSettlesAt { return }
            hoveredID = inside ? id : (hoveredID == id ? nil : hoveredID)
            // A tab or an app's pin has no app window to preview.
            guard !model.isTabIcon(slot.bundleID), !model.isAppPinIcon(slot.bundleID) else { return }
            model.hoveredStripTarget = inside ? .app(bundleID: slot.bundleID) : nil
        }
        .onTapGesture {
            // One of the app's pins, big or in the pill: it runs, as its row would.
            if let pin = model.appPin(forIconID: slot.bundleID) {
                model.openAppPin(pin)
            // A tab, big or in the pill: Safari shows it.
            } else if model.isTabIcon(slot.bundleID), let icon = slot.running {
                model.openTabIcon(icon)
            // As the pill, a click scopes the field into the app, as the pill always has.
            } else if !isDock, let icon = model.globalMatchIcons.first(where: { $0.bundleID == slot.bundleID }) {
                model.openGlobalMatchIcon(icon)
            } else {
                openApp(slot)
            }
        }
        // Only a pinned app can be dragged: dragging is how the user reorders and unpins,
        // and a running app nobody pinned has no place to be moved to.
        // An app's pin drags the same way: off the strip unpins it.
        .modifier(DockPinDrag(
            pinID: slot.pin?.id ?? model.appPin(forIconID: slot.bundleID)?.id,
            dragging: $draggingPinID))
        // A tab's menu pins it, a pin's unpins it; an app's menu (Quit, Hide, Show in
        // Finder) is for apps.
        .overlay(RightClickReporter { menuID = id })
        .popover(isPresented: menuBinding(id), arrowEdge: .top) {
            DockIconMenu(items: appMenuItems(slot))
        }
        .accessibilityLabel(slot.title)
        .accessibilityAddTraits(.isButton)
    }

    /// A pin that is not an app — a command, a CLI tool, a file, a folder. Apps never come
    /// through here; they are slots in the app region, pinned or not.
    private func pinnedIcon(_ pin: DockPin, ids: [String]) -> some View {
        let document = pin.documentID.flatMap { GlobalSearchService.shared.document(withID: $0) }
        let image = pin.kind.icon ?? document?.icon
        let available: Bool = {
            switch pin.kind {
            case .globalCommand, .cliTool: return document != nil
            default: return pin.kind.isAvailable
            }
        }()
        // A plugin that declares an icon view is drawn live — its artwork, its waveform —
        // in the slot its symbol would take. Everything around the icon is the same.
        let liveIcon = pin.kind.pluginID
            .flatMap { PluginRegistry.shared.plugin(id: $0)?.manifest }
            .flatMap { PluginStripIcon.drawsLive($0) ? $0 : nil }
        return Group {
            if let liveIcon {
                PluginStripIcon(manifest: liveIcon, scale: scale(for: pin.id.uuidString, among: ids))
                    .id(liveIcon.id)
            } else {
                DockStripIcon(
                    image: image, title: pin.title, isRunning: false,
                    isAvailable: available, scale: scale(for: pin.id.uuidString, among: ids),
                    fallbackSymbol: pin.kind.fallbackSymbol
                )
            }
        }
        .onHover { inside in
            let id = pin.id.uuidString
            hoveredID = inside ? id : (hoveredID == id ? nil : hoveredID)
            // A widget the user folded to its icon answers the pointer with the widget
            // itself, not the command preview card.
            if barWidgetManifest(pin) != nil {
                peekWidget(pin.id, inside)
                return
            }
            // The same dwell the apps use, so a pinned file answers the pointer the way a
            // running app does.
            model.hoveredStripTarget = inside ? .pin(id: pin.id) : nil
        }
        .onTapGesture { open(pin, document: document) }
        .modifier(DockPinDrag(pinID: pin.id, dragging: $draggingPinID))
        .overlay(RightClickReporter { menuID = pin.id.uuidString })
        .popover(isPresented: menuBinding(pin.id.uuidString), arrowEdge: .top) {
            DockIconMenu(items: pinnedMenuItems(pin))
        }
        // On a background so it does not share the view with the menu's popover.
        .background {
            Color.clear.popover(isPresented: widgetPeekBinding(pin.id), arrowEdge: .top) {
                if let manifest = barWidgetManifest(pin) {
                    PluginStripTile(pin: pin, manifest: manifest, model: model)
                        .padding(10)
                        .onHover { inside in peekWidget(pin.id, inside) }
                }
            }
        }
        .accessibilityLabel(pin.title)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func foldedField(action: @escaping () -> Void) -> some View {
        if model.showsTabBar,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: model.appBundleID)
        {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .frame(width: M.dockIconSize, height: M.dockIconSize)
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .help("Ask \(model.appName)")
                .accessibilityLabel("Ask \(model.appName)")
                .accessibilityAddTraits(.isButton)
        } else {
            toolIcon("magnifyingglass", title: "Search", action: action)
        }
    }

    private func toolIcon(_ symbol: String, title: String, action: @escaping () -> Void)
        -> some View
    {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: M.dockIconSize, height: M.dockIconSize)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Menus

    /// The plugin's manifest when it has a bar widget — the one kind of pin that can be
    /// drawn either as its tile or as its icon.
    private func barWidgetManifest(_ pin: DockPin) -> PluginManifest? {
        guard let pluginID = pin.kind.pluginID,
            let manifest = PluginRegistry.shared.plugin(id: pluginID)?.manifest,
            manifest.views.widget?.family == .bar
        else { return nil }
        return manifest
    }

    /// Opens at once; closes a beat after the pointer leaves both the icon and the tile,
    /// so crossing the gap between them does not put it away.
    private func peekWidget(_ id: UUID, _ inside: Bool) {
        widgetPeekClose?.cancel()
        if inside {
            widgetPeekID = id
            return
        }
        widgetPeekClose = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, widgetPeekID == id else { return }
            widgetPeekID = nil
        }
    }

    private func widgetPeekBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { widgetPeekID == id && menuID == nil },
            set: { if !$0, widgetPeekID == id { widgetPeekID = nil } })
    }

    private func menuBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { menuID == id }, set: { if !$0, menuID == id { menuID = nil } })
    }

    /// One menu for one icon. What it offers follows from the two facts the slot carries:
    /// a running app can be asked about and quit, a pinned one can be unpinned, and an app
    /// that is neither is not on the strip at all.
    private func appMenuItems(_ slot: DockAppSlot) -> [DockIconMenu.Item] {
        let bundleID = slot.bundleID
        if let pin = model.appPin(forIconID: bundleID) {
            return [.init(title: "Unpin") {
                pins.unpin(pin.id)
                model.updateTabStrip()
            }]
        }
        if model.isTabIcon(bundleID) {
            let pinned = model.isTabPinned(iconID: bundleID)
            return [.init(title: pinned ? "Unpin Tab" : "Pin Tab") {
                model.toggleTabPin(iconID: bundleID)
            }]
        }
        var items: [DockIconMenu.Item] = []
        if slot.isRunning {
            items.append(.init(title: "Ask about \(slot.title)") {
                model.expandFromDock(seeding: nil)
                model.scopeIntoApp(name: slot.title, bundleID: bundleID)
            })
        } else {
            items.append(.init(title: "Open \(slot.title)") { openApp(slot) })
        }
        items.append(.separator)
        if let pin = slot.pin {
            items.append(.init(title: "Unpin") { pins.unpin(pin.id) })
        } else {
            items.append(.init(title: "Pin to Dock") {
                pins.pin(.app(bundleID: bundleID), title: slot.title)
            })
            // Only meaningful for an app the user never placed: a pin is removed by
            // unpinning it, not by hiding the app that is running under it.
            items.append(.init(title: "Remove from Strip") { model.hideRunningApp(bundleID) })
        }
        if slot.isRunning {
            items.append(.separator)
            items.append(.init(title: "Quit \(slot.title)") {
                let apps = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleID)
                let quit = apps.reduce(false) { $0 || $1.terminate() }
                // The corner ran it, so the corner says what came of it — the strip's own
                // quit was the one app action that reported nothing, which is why the tint
                // and the glyph showed for some quits and not for others.
                DockActionFeedback.appQuit(slot.title, bundleID: bundleID, succeeded: quit)
            })
        }
        return items
    }

    private func pinnedMenuItems(_ pin: DockPin) -> [DockIconMenu.Item] {
        var items: [DockIconMenu.Item] = []
        if barWidgetManifest(pin) != nil {
            let asIcon = pin.showsAsIcon == true
            items.append(.init(title: asIcon ? "Show as Widget" : "Show as Icon") {
                pins.setShowsAsIcon(pin.id, !asIcon)
                // The strip's width is planned from a cached read of which pins are
                // widgets; this pin just changed which it is.
                DockStripPlan.forgetEnvironment()
                widgetPeekID = nil
            })
            items.append(.separator)
        }
        items.append(.init(title: "Unpin") { pins.unpin(pin.id) })
        switch pin.kind {
        case .file(let path), .folder(let path):
            items.append(.init(title: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            })
        default:
            break
        }
        return items
    }

    private func overflowPill(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: M.dockIconSize, height: M.dockIconSize)
            .background(Color.primary.opacity(0.08), in: Circle())
            .onTapGesture { model.expandFromDock(seeding: nil) }
            .accessibilityLabel("\(count) more running apps")
    }

    /// Dock magnify: the hovered icon up, its neighbours a little, everything else at rest.
    /// `ids` is the row as drawn, passed in rather than rebuilt per icon.
    private func scale(for id: String, among ids: [String]) -> CGFloat {
        guard let hoveredID else { return 1 }
        if hoveredID == id { return 1.25 }
        guard let a = ids.firstIndex(of: hoveredID), let b = ids.firstIndex(of: id)
        else { return 1 }
        return abs(a - b) == 1 ? 1.1 : 1
    }

    // MARK: Actions

    private func expandField() {
        hoverIntent?.cancel()
        hoverIntent = nil
        // `condensing` is deliberately left standing: the strip is on its way out and
        // must not spring back to full size underneath the field arriving over it. It is
        // cleared when the phase comes back to `.dock`, below.
        if model.expandFromDock(seeding: nil) {
            CornerDockController.shared.requestComposerFocus()
        }
    }

    /// Hovering the magnifier opens the field — but not on the first pixel. A pointer on its
    /// way to an app icon crosses the magnifier, and expanding there means the strip pulls
    /// itself out from under the hand. It waits `Self.hoverDwell`, condensing while it waits,
    /// so the gesture is visible before it is committed and leaving cancels it cleanly.
    private static let hoverDwell: TimeInterval = 0.16

    private func beginHoverExpand() {
        guard model.phase == .dock, hoverIntent == nil else { return }
        condensing = true
        hoverIntent = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.hoverDwell * 1_000_000_000))
            guard !Task.isCancelled else { return }
            hoverIntent = nil
            expandField()
        }
    }

    private func cancelHoverExpand() {
        hoverIntent?.cancel()
        hoverIntent = nil
        condensing = false
    }

    /// Clicking an app: bring it forward if it is up, launch it if it is not. A pinned app
    /// that has been quit is still a place to go, which is what pinning it was for.
    private func openApp(_ slot: DockAppSlot) {
        AppActivation.bringForward(bundleID: slot.bundleID, name: slot.title)
    }

    private func open(_ pin: DockPin, document: GlobalSearchService.SearchDocument?) {
        switch pin.kind {
        case .app(let bundleID):
            AppActivation.bringForward(bundleID: bundleID, name: pin.title)
        case .file(let path), .folder(let path):
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            }
        case .menuCommand, .appAction, .tab:
            model.openAppPin(pin)  // an app's pin; Global's strip never holds one
        case .globalCommand, .cliTool:
            guard let document else { return }
            // A pinned plugin answers where it is: a one-shot runs from the dock, a plugin
            // with a panel opens it as the card above the pin — the field is not brought
            // back for either, since neither has anything to type into it. Opening the
            // field and folding it again read as the click having misfired.
            if let pluginID = pin.kind.pluginID,
                let manifest = PluginRegistry.shared.plugin(id: pluginID)?.manifest
            {
                if manifest.views.panel != nil {
                    // The click toggles the card whichever way it came up — hover already
                    // shows an icon's panel, so a click on that icon puts it away.
                    if model.pluginCardPinID == pin.id || model.previewPinID == pin.id {
                        model.dismissPluginCard()
                    } else {
                        model.pluginCardPinID = pin.id
                    }
                } else {
                    GlobalContextRow.run(document)
                }
                return
            }
            // Commands and tools run through the list's own path so a CLI scopes the field
            // and a system command opens its scope, exactly as choosing the row would.
            model.expandFromDock(seeding: nil)
            model.run(.global(document))
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        draggingPinID = nil
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, text.hasPrefix("dockpin:"),
                    let id = UUID(uuidString: String(text.dropFirst("dockpin:".count)))
                else { return }
                Task { @MainActor in
                    // Dropped back on the strip: move to the end of its own pins, Global's or
                    // the app's. Per-slot targets are a refinement the user has not asked for.
                    DockPinStore.shared.moveToEnd(id)
                    model.updateTabStrip()
                }
            }
            accepted = true
        }
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil),
                    let kind = DockPinKind(fileURL: url)
                else { return }
                Task { @MainActor in
                    DockPinStore.shared.pin(kind, title: url.lastPathComponent)
                }
            }
            accepted = true
        }
        return accepted
    }
}

/// Drag to reorder, drag off to unpin — for pinned icons only. A running app nobody pinned
/// has no order of its own, so `.onDrag` is not attached at all rather than attached and
/// refused: an armed drag that goes nowhere still lifts the icon off the strip.
private struct DockPinDrag: ViewModifier {
    let pinID: UUID?
    @Binding var dragging: UUID?

    func body(content: Content) -> some View {
        if let pinID {
            content.onDrag {
                dragging = pinID
                return NSItemProvider(object: "dockpin:\(pinID.uuidString)" as NSString)
            }
        } else {
            content
        }
    }
}

/// One icon in the strip. The running dot sits under it, the way the Dock's does; an icon
/// whose target is gone draws dim rather than vanishing, so the user can unpin it.
struct DockStripIcon: View {
    let image: NSImage?
    let title: String
    let isRunning: Bool
    let isAvailable: Bool
    let scale: CGFloat
    /// What to draw when the real icon is missing — a file that has been moved, an app that
    /// has been uninstalled. It names what the icon stands for rather than leaving an empty
    /// dashed square, which told the user nothing about what they had pinned.
    var fallbackSymbol: String = "app.dashed"

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: fallbackSymbol)
                        .resizable().aspectRatio(contentMode: .fit)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(contentMode: .fit)
            .frame(
                width: AppChatPromptMetrics.dockIconSize - 8,
                height: AppChatPromptMetrics.dockIconSize - 8)
            .opacity(isAvailable ? 1 : 0.4)
            .scaleEffect(scale, anchor: .bottom)
            .animation(.snappy(duration: 0.18), value: scale)
            Circle()
                .fill(Color.primary.opacity(isRunning ? 0.6 : 0))
                .frame(width: 4, height: 4)
        }
        .frame(
            width: AppChatPromptMetrics.dockIconSize, height: AppChatPromptMetrics.dockIconSize)
        .contentShape(Rectangle())
        .help(title)
    }
}

/// The Dock's own menu shape: a rounded card over the icon with the arrow pointing down at
/// it. A `contextMenu` opens at the pointer, which is not where the Dock puts it.
struct DockIconMenu: View {
    struct Item: Identifiable {
        let id = UUID()
        let title: String?
        let action: () -> Void
        init(title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
        private init() {
            title = nil
            action = {}
        }
        static var separator: Item { Item() }
    }

    let items: [Item]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                if let title = item.title {
                    Button {
                        dismiss()
                        item.action()
                    } label: {
                        Text(title)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DockMenuButtonStyle())
                } else {
                    Divider().padding(.horizontal, 8).padding(.vertical, 2)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 170)
    }
}

private struct DockMenuButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering || configuration.isPressed ? 0.25 : 0))
            )
            .onHover { hovering = $0 }
    }
}

/// Reports a right-click (or Control-click) on the view it overlays; every other event
/// passes through to the view underneath.
struct RightClickReporter: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class ReporterView: NSView {
        var onRightClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only right-clicks are ours; a left-click must reach the SwiftUI gesture below.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) { onRightClick?() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onRightClick?() } else { super.mouseDown(with: event) }
        }
    }
}
