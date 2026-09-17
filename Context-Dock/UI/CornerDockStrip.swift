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
    @State private var hoverIntent: Task<Void, Never>?
    /// The icon whose Dock-style menu is up — a popover over the icon, arrow down, the
    /// way the Dock does it, rather than a menu at the pointer.
    @State private var menuID: String?

    private typealias M = AppChatPromptMetrics

    /// The icons are collapsed toward the pill whenever the field is on its way in or
    /// already up — not only while the magnifier is hovered. Typing a letter and clicking
    /// the magnifier open the field too, and they are the same motion.
    private var gathered: Bool { condensing || model.phase != .dock }

    /// The row and its geometry, made together: an app appears once, whether it is pinned,
    /// running or both.
    private var plan: DockStripPlan {
        DockStripPlan.make(
            running: model.stripIcons, pins: pins.pins,
            tools: model.dockToolCount(
                clipboardVisible: clipboard.phase.isVisible,
                feedbackVisible: feedback.current != nil))
    }

    var body: some View {
        HStack(spacing: M.dockIconGap) {
            // The field, folded: the first item in the strip. Hovering it, or clicking
            // it, widens it back.
            toolIcon("magnifyingglass", title: "Search") { expandField() }
                .scaleEffect(condensing ? 1.12 : 1)
                .onHover { inside in inside ? beginHoverExpand() : cancelHoverExpand() }
            // Everything but the magnifier condenses toward it while the field comes back:
            // each icon shrinks in place and fades, so the capsule reads as gathering itself
            // into the field rather than being replaced by it. Sizes are untouched — the
            // strip's own layout stays exactly as wide as the metrics say (memory
            // `corner-pill-size-must-be-pure`); only what is drawn inside it moves.
            Group {
            // One region for apps: the pinned ones first, in the order the user placed
            // them, then whatever else is running. Composed once for the whole pass —
            // `scale(for:)` runs per icon per hover frame and must not compose again.
            let plan = self.plan
            let ids = plan.composition.apps.map(\.id)
                + plan.composition.otherPins.map(\.id.uuidString)
            ForEach(plan.composition.apps) { slot in
                appIcon(slot, ids: ids)
            }
            if plan.layout.overflow > 0 {
                overflowPill(plan.layout.overflow)
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
                if clipboard.phase.isVisible {
                    toolIcon("doc.on.clipboard", title: "Clipboard") {
                        ClipboardPanelController.shared.show()
                    }
                    // Hovering opens the card without taking the keyboard; a click arms it.
                    .onHover { inside in
                        guard inside else { return }
                        let controller = ClipboardPanelController.shared
                        controller.model.reload()
                        controller.model.summon()
                    }
                }
                if model.selection != nil {
                    toolIcon("text.cursor", title: "Selection") {
                        CornerDockController.shared.showSelectionScopeFromDock()
                    }
                }
                // What the last action came to, for a few seconds — the dock's inline
                // result, in the corner's own idiom: the clipboard's slot and lifetime.
                if let result = feedback.current {
                    ActionFeedbackGlyph(feedback: result, size: M.dockIconSize)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            }
            // Gathering toward the trailing edge, which is where the field's own small
            // pill of running apps lands: the big icons are seen to collapse into that
            // pill rather than dissolving while something else appears somewhere else.
            // A scaleEffect draws smaller without laying out smaller, which is what keeps
            // this off the focus machinery's books.
            .scaleEffect(gathered ? 0.38 : 1, anchor: .trailing)
            .blur(radius: gathered ? 1.2 : 0)
        }
        // The same curve and length as the shell's morph: the icons are still collapsing
        // while the field opens, which is the whole point of the flow. Fading is the
        // shell's job — this layer only shrinks, so the two are never fighting over how
        // visible the row is.
        .animation(
            .smooth(duration: AppChatPromptMetrics.dockMorphDuration * 0.8), value: gathered)
        .animation(.smooth(duration: 0.25), value: feedback.current?.id)
        .padding(.horizontal, M.dockInset)
        .frame(height: M.dockHeight)
        .contentShape(Rectangle())
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
            if phase == .dock { condensing = false }
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
            hoveredID = inside ? id : (hoveredID == id ? nil : hoveredID)
            model.hoveredStripTarget = inside ? .app(bundleID: slot.bundleID) : nil
        }
        .onTapGesture { openApp(slot) }
        // Only a pinned app can be dragged: dragging is how the user reorders and unpins,
        // and a running app nobody pinned has no place to be moved to.
        .modifier(DockPinDrag(pinID: slot.pin?.id, dragging: $draggingPinID))
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
        .accessibilityLabel(pin.title)
        .accessibilityAddTraits(.isButton)
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

    private func menuBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { menuID == id }, set: { if !$0, menuID == id { menuID = nil } })
    }

    /// One menu for one icon. What it offers follows from the two facts the slot carries:
    /// a running app can be asked about and quit, a pinned one can be unpinned, and an app
    /// that is neither is not on the strip at all.
    private func appMenuItems(_ slot: DockAppSlot) -> [DockIconMenu.Item] {
        let bundleID = slot.bundleID
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
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .forEach { $0.terminate() }
            })
        }
        return items
    }

    private func pinnedMenuItems(_ pin: DockPin) -> [DockIconMenu.Item] {
        var items: [DockIconMenu.Item] = [.init(title: "Unpin") { pins.unpin(pin.id) }]
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
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: slot.bundleID)
            .first
        {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: slot.bundleID)
        {
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func open(_ pin: DockPin, document: GlobalSearchService.SearchDocument?) {
        switch pin.kind {
        case .app(let bundleID):
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first {
                running.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID)
            {
                NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .file(let path), .folder(let path):
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            }
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
                    let store = DockPinStore.shared
                    guard let from = store.pins.firstIndex(where: { $0.id == id }) else { return }
                    // Dropped back on the strip: move to the end of the pins. Per-slot
                    // targets are a refinement the user has not asked for.
                    store.move(from: from, to: store.pins.count)
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
