import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Global Context at rest: the running apps and the pins, at Dock size. It offers places
/// to go and never answers anything — typing is what brings the field back.
struct CornerDockStrip: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var pins = DockPinStore.shared
    @ObservedObject private var clipboard = ClipboardPanelController.shared.model
    @State private var hoveredID: String?
    @State private var isDropTarget = false
    @State private var draggingPinID: UUID?
    /// The icon whose Dock-style menu is up — a popover over the icon, arrow down, the
    /// way the Dock does it, rather than a menu at the pointer.
    @State private var menuID: String?

    private typealias M = AppChatPromptMetrics

    private var layout: M.DockLayout {
        M.dockLayout(
            running: model.stripIcons.count, pinned: pins.pins.count,
            tools: model.dockToolCount(clipboardVisible: clipboard.phase.isVisible))
    }

    var body: some View {
        HStack(spacing: M.dockIconGap) {
            // The field, folded: the first item in the strip. Hovering it, or clicking
            // it, widens it back.
            toolIcon("magnifyingglass", title: "Search") { expandField() }
                .onHover { inside in if inside { expandField() } }
            ForEach(Array(model.stripIcons.prefix(layout.shownRunning))) { icon in
                runningIcon(icon)
            }
            if layout.overflow > 0 {
                overflowPill(layout.overflow)
            }
            if !pins.pins.isEmpty {
                // The HStack's own gap on each side of this hairline is the 17-point
                // `dockDividerSpan` the metrics count.
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: M.dockIconSize * 0.7)
                ForEach(pins.pins) { pin in
                    pinnedIcon(pin)
                }
            }
            if layout.tools > 0 {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: M.dockIconSize * 0.7)
                if clipboard.phase.isVisible {
                    toolIcon("doc.on.clipboard", title: "Clipboard") {
                        AppDelegate.shared?.activateClipboardScope()
                    }
                }
                if model.selection != nil {
                    toolIcon("text.cursor", title: "Selection") {
                        model.expandFromDock(seeding: nil)
                        model.toggleSelectionScope()
                    }
                }
            }
        }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock")
    }

    // MARK: Icons

    private func runningIcon(_ icon: MatchDockIcon) -> some View {
        DockStripIcon(
            image: icon.icon, title: icon.title, isRunning: icon.isRunning,
            isAvailable: true, scale: scale(for: icon.id)
        )
        .onHover { inside in
            hoveredID = inside ? icon.id : (hoveredID == icon.id ? nil : hoveredID)
            model.hoveredStripBundleID = inside ? icon.bundleID : nil
        }
        .onTapGesture { activate(bundleID: icon.bundleID) }
        .overlay(RightClickReporter { menuID = icon.id })
        .popover(isPresented: menuBinding(icon.id), arrowEdge: .top) {
            DockIconMenu(items: runningMenuItems(icon))
        }
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(.isButton)
    }

    private func pinnedIcon(_ pin: DockPin) -> some View {
        let document = pin.documentID.flatMap { GlobalSearchService.shared.document(withID: $0) }
        let image = pin.kind.icon ?? document?.icon
        let available: Bool = {
            switch pin.kind {
            case .globalCommand, .cliTool: return document != nil
            default: return pin.kind.isAvailable
            }
        }()
        let running: Bool = {
            if case .app(let bundleID) = pin.kind {
                return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .isEmpty
            }
            return false
        }()
        return DockStripIcon(
            image: image, title: pin.title, isRunning: running,
            isAvailable: available, scale: scale(for: pin.id.uuidString)
        )
        .onHover { inside in
            let id = pin.id.uuidString
            hoveredID = inside ? id : (hoveredID == id ? nil : hoveredID)
            if case .app(let bundleID) = pin.kind {
                model.hoveredStripBundleID = inside ? bundleID : nil
            }
        }
        .onTapGesture { open(pin, document: document) }
        .onDrag {
            draggingPinID = pin.id
            return NSItemProvider(object: "dockpin:\(pin.id.uuidString)" as NSString)
        }
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

    private func runningMenuItems(_ icon: MatchDockIcon) -> [DockIconMenu.Item] {
        guard let bundleID = icon.bundleID else { return [] }
        var items: [DockIconMenu.Item] = [
            .init(title: "Ask about \(icon.title)") {
                model.expandFromDock(seeding: nil)
                model.scopeIntoApp(name: icon.title, bundleID: bundleID)
            },
            .separator,
        ]
        if !pins.isPinned(.app(bundleID: bundleID)) {
            items.append(.init(title: "Pin to Dock") {
                pins.pin(.app(bundleID: bundleID), title: icon.title)
            })
        }
        items.append(.init(title: "Remove from Strip") { model.hideRunningApp(bundleID) })
        items.append(.separator)
        items.append(.init(title: "Quit \(icon.title)") {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .forEach { $0.terminate() }
        })
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
    private func scale(for id: String) -> CGFloat {
        guard let hoveredID else { return 1 }
        if hoveredID == id { return 1.25 }
        let ids = model.stripIcons.prefix(layout.shownRunning).map(\.id)
            + pins.pins.map(\.id.uuidString)
        guard let a = ids.firstIndex(of: hoveredID), let b = ids.firstIndex(of: id)
        else { return 1 }
        return abs(a - b) == 1 ? 1.1 : 1
    }

    // MARK: Actions

    private func expandField() {
        if model.expandFromDock(seeding: nil) {
            CornerDockController.shared.requestComposerFocus()
        }
    }

    private func activate(bundleID: String?) {
        guard let bundleID,
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first
        else { return }
        app.activate()
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

/// One icon in the strip. The running dot sits under it, the way the Dock's does; an icon
/// whose target is gone draws dim rather than vanishing, so the user can unpin it.
struct DockStripIcon: View {
    let image: NSImage?
    let title: String
    let isRunning: Bool
    let isAvailable: Bool
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
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
