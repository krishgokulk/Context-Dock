import AppKit
import Combine
import SwiftUI

/// Ambient Clipboard surface: a pill that slides into the bottom-right corner on every
/// copy and grows into a card of recent clips under the pointer. It deliberately does not
/// participate in LauncherView's activeSmartQueryKey or dock layer state, so Context Dock
/// can be opened and used while this pill is on screen.
///
/// The window is a *fixed-size transparent* panel: the pill/card morph is a pure SwiftUI
/// frame animation inside it, never an NSWindow resize, because animating a window frame
/// stutters and the whole point of this surface is that the morph reads as smooth.
enum ClipboardPillMetrics {
    static let collapsedSize = CGSize(width: 250, height: 56)
    static let expandedSize = CGSize(width: 372, height: 404)
    /// The panel is larger than the card on every side so the glass shadow is not clipped.
    static let shadowPad: CGFloat = 28
    /// Gap between the card and the screen's bottom-right corner.
    static let screenMargin: CGFloat = 20
    /// Slack around the card's hit rect so a pointer resting on the very edge still counts.
    static let hoverTolerance: CGFloat = 6

    static var panelSize: NSSize {
        NSSize(
            width: expandedSize.width + shadowPad * 2,
            height: expandedSize.height + shadowPad * 2)
    }

    static func cardSize(for phase: PillPhase) -> CGSize {
        phase == .expanded ? expandedSize : collapsedSize
    }
}

/// Borderless panels refuse key status by default; the hotkey path needs it for arrow
/// navigation and Return-to-paste.
final class ClipboardPillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClipboardPanelController: NSObject {
    static let shared = ClipboardPanelController()

    let model = ClipboardPanelModel()
    private var panel: ClipboardPillPanel?
    private var returnApplication: NSRunningApplication?
    private var hoverMonitors: [Any] = []
    private var outsideClickMonitor: Any?
    /// True only for the hotkey path, which is allowed to take focus. A copy-triggered
    /// pill must never pull the user out of what they are typing in.
    private var didTakeFocus = false

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Entry points

    /// A copy landed anywhere on the system. Ambient: orders in without activating us.
    func didCopy(_ entry: LauncherView.ClipboardEntry) {
        ensurePanel()
        model.reload()
        model.ingest(entry)
        model.didCopy()
    }

    /// Clipboard-scope hotkey.
    func toggle() {
        ensurePanel()
        if model.phase == .hidden {
            show()
        } else {
            model.dismiss()
        }
    }

    /// Hotkey path: card opens at the same bottom-right anchor as the pill, focused, and
    /// stays until dismissed.
    func show() {
        captureReturnApplication()
        ensurePanel()
        model.reload()
        model.summon()
        model.armKeyboard()
        didTakeFocus = true
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        model.dismiss()
    }

    /// The card was clicked. Hovering deliberately leaves focus alone, so this is the
    /// first moment the user has asked for the keyboard.
    func armKeyboard() {
        guard model.phase.isVisible, !model.isKeyboardArmed else { return }
        captureReturnApplication()
        model.armKeyboard()
        didTakeFocus = true
        // `.nonactivatingPanel` is what keeps the ambient pill harmless, and it is also
        // exactly what stops this window from ever becoming key. The armed card is a
        // deliberate ask, so it drops the style for as long as it holds the keyboard.
        panel?.styleMask = [.borderless]
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
        startOutsideClickWatch()
    }

    /// Space on the focused row. Text has no file of its own, so it gets a scratch one —
    /// reused rather than accumulating a file per preview.
    func preview() {
        guard let target = model.previewTarget else { return }
        switch target {
        case .file(let url):
            PreviewController.shared.present(url: url, toggleIfSame: true)
        case .text(let text):
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("context-dock-clip-preview.txt")
            guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else {
                return
            }
            PreviewController.shared.present(url: url, toggleIfSame: true)
        }
    }

    func paste(_ entry: LauncherView.ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !entry.filePaths.isEmpty {
            pasteboard.writeObjects(entry.filePaths.map { URL(fileURLWithPath: $0) as NSURL })
        } else if let data = entry.imageData
            ?? entry.imageFileName.flatMap({ ClipboardImageStore.read(fileName: $0) }),
            let image = NSImage(data: data)
        {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setString(entry.text, forType: .string)
        }

        // The ambient pill never activated us, so the paste target is simply whatever is
        // frontmost; only the hotkey path has an app to hand focus back to.
        let target = didTakeFocus ? returnApplication : NSWorkspace.shared.frontmostApplication
        model.dismiss()
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Window

    private func captureReturnApplication() {
        if let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            returnApplication = app
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = ClipboardPillPanel(
            contentRect: NSRect(origin: .zero, size: ClipboardPillMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        // SwiftUI draws the glass shadow; a native one would square off the card.
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
        p.contentView = NSHostingView(rootView: ClipboardDockPill(model: model))
        panel = p

        model.onPhaseChange = { [weak self] phase in
            self?.applyPhase(phase)
        }

    }

    /// An armed card is dismissed by a click anywhere else. App-active state cannot be
    /// used for this: activating an accessory app whose only window is a floating panel
    /// bounces active straight back, so `didResignActive` fires immediately after arming.
    private func startOutsideClickWatch() {
        guard outsideClickMonitor == nil, let panel else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.model.isKeyboardArmed else { return }
            guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.model.dismiss()
        }
    }

    private func stopOutsideClickWatch() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    private func applyPhase(_ phase: PillPhase) {
        guard let panel else { return }
        if phase.isVisible {
            if !panel.isVisible {
                positionPanel()
                panel.orderFrontRegardless()
            }
            startHoverWatch()
        } else {
            stopHoverWatch()
            stopOutsideClickWatch()
            panel.orderOut(nil)
            // Back to a window that cannot take focus from anyone.
            panel.styleMask = [.borderless, .nonactivatingPanel]
            if didTakeFocus {
                didTakeFocus = false
                returnApplication?.activate()
            }
        }
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let pad = ClipboardPillMetrics.shadowPad
        let margin = ClipboardPillMetrics.screenMargin
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.maxX - margin + pad - size.width,
                y: visible.minY + margin - pad))
    }

    /// The card lives in a background app's non-key window, where SwiftUI's own hover
    /// tracking is unreliable. Pointer position is watched directly instead, and the hit
    /// rect is derived from the same metrics the layout uses.
    private func startHoverWatch() {
        guard hoverMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.evaluateHover() }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged], handler: handler)
        {
            hoverMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged],
            handler: { [weak self] event in
                self?.evaluateHover()
                return event
            })
        {
            hoverMonitors.append(local)
        }
        evaluateHover()
    }

    private func stopHoverWatch() {
        hoverMonitors.forEach { NSEvent.removeMonitor($0) }
        hoverMonitors.removeAll()
    }

    private func evaluateHover() {
        guard let panel, panel.isVisible else { return }
        if cardRect(in: panel).contains(NSEvent.mouseLocation) {
            model.hoverBegan()
        } else {
            model.hoverEnded()
        }
    }

    private func cardRect(in panel: NSPanel) -> NSRect {
        let pad = ClipboardPillMetrics.shadowPad
        let size = ClipboardPillMetrics.cardSize(for: model.phase)
        let slack = ClipboardPillMetrics.hoverTolerance
        return NSRect(
            x: panel.frame.maxX - pad - size.width - slack,
            y: panel.frame.minY + pad - slack,
            width: size.width + slack * 2,
            height: size.height + slack * 2)
    }
}

@MainActor
final class ClipboardPanelModel: ObservableObject {
    struct SourceChoice: Identifiable, Equatable {
        let bundleID: String
        let name: String
        let count: Int
        var id: String { bundleID }
        var isAll: Bool { bundleID.isEmpty }
    }

    @Published var entries: [LauncherView.ClipboardEntry] = []
    @Published var query = ""
    @Published var sourceIndex = 0
    @Published var focusedEntryIndex: Int?

    let storeURL: URL

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL
    }

    static var defaultStoreURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support")
        return base.appendingPathComponent("Context-Dock/clipboard-history.json")
    }

    /// Clips handed straight over by the copy monitor. The history's disk write is
    /// debounced 600ms, so the very clip that raises the pill is not on disk yet; these
    /// are merged into every reload until the stored history catches up.
    private var pendingIngest: [LauncherView.ClipboardEntry] = []

    func ingest(_ entry: LauncherView.ClipboardEntry) {
        pendingIngest.removeAll { sameClip($0, entry) }
        pendingIngest.insert(entry, at: 0)
        applyPendingIngest()
    }

    private func sameClip(
        _ lhs: LauncherView.ClipboardEntry, _ rhs: LauncherView.ClipboardEntry
    ) -> Bool {
        // An empty hash is not an identity — falling back to it would collapse every
        // un-hashed clip into one row.
        lhs.contentHash.isEmpty || rhs.contentHash.isEmpty
            ? lhs.id == rhs.id
            : lhs.contentHash == rhs.contentHash
    }

    private func applyPendingIngest() {
        for entry in pendingIngest.reversed() {
            entries.removeAll { sameClip($0, entry) }
            entries.insert(entry, at: 0)
        }
    }

    var sources: [SourceChoice] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for entry in entries where !entry.sourceBundleId.isEmpty {
            if counts[entry.sourceBundleId] == nil {
                order.append(entry.sourceBundleId)
                names[entry.sourceBundleId] = entry.sourceAppName.isEmpty
                    ? entry.sourceBundleId : entry.sourceAppName
            }
            counts[entry.sourceBundleId, default: 0] += 1
        }
        return [SourceChoice(bundleID: "", name: "All", count: entries.count)]
            + order.map {
                SourceChoice(
                    bundleID: $0,
                    name: names[$0] ?? $0,
                    count: counts[$0] ?? 0
                )
            }
    }

    var selectedSource: SourceChoice {
        let choices = sources
        return choices.indices.contains(sourceIndex) ? choices[sourceIndex] : choices[0]
    }

    var visibleEntries: [LauncherView.ClipboardEntry] {
        let source = selectedSource.bundleID
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            let sourceMatches = source.isEmpty || entry.sourceBundleId == source
            guard sourceMatches else { return false }
            guard !needle.isEmpty else { return true }
            let fileNames = entry.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: " ")
            return [entry.text, entry.ocrText, fileNames, entry.sourceAppName]
                .joined(separator: " ").lowercased().contains(needle)
        }
    }

    func resetScope() {
        query = ""
        sourceIndex = 0
        focusedEntryIndex = nil
    }

    func reload(resetScope shouldReset: Bool = false) {
        if shouldReset { resetScope() }
        let decoded: [LauncherView.ClipboardEntry] = {
            guard let data = try? Data(contentsOf: storeURL),
                let stored = try? JSONDecoder().decode(
                    [LauncherView.ClipboardEntry].self, from: data)
            else { return [] }
            return stored.sorted { $0.timestamp > $1.timestamp }
        }()
        pendingIngest.removeAll { pending in decoded.contains { sameClip($0, pending) } }
        entries = decoded
        applyPendingIngest()
        sourceIndex = min(sourceIndex, max(0, sources.count - 1))
        if let focusedEntryIndex, !visibleEntries.indices.contains(focusedEntryIndex) {
            self.focusedEntryIndex = nil
        }
    }

    func cycleSource(_ direction: Int) {
        let count = sources.count
        guard count > 0 else { return }
        sourceIndex = (sourceIndex + (direction >= 0 ? 1 : -1) + count) % count
        focusedEntryIndex = nil
    }

    func selectSource(bundleID: String) {
        guard let index = sources.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        sourceIndex = index
        focusedEntryIndex = nil
    }

    func moveEntry(_ direction: Int) {
        let count = visibleEntries.count
        guard count > 0 else {
            focusedEntryIndex = nil
            return
        }
        let current = focusedEntryIndex ?? (direction >= 0 ? -1 : count)
        focusedEntryIndex = min(max(current + direction, 0), count - 1)
    }

    var focusedEntry: LauncherView.ClipboardEntry? {
        guard let focusedEntryIndex,
            visibleEntries.indices.contains(focusedEntryIndex)
        else { return nil }
        return visibleEntries[focusedEntryIndex]
    }

    // MARK: - Pill phase

    /// How long the pill lingers after a copy nobody reached for.
    static let copyDwell: TimeInterval = 4
    /// Shorter: the pointer has already been here and left.
    static let hoverExitDwell: TimeInterval = 1.5

    @Published private(set) var phase: PillPhase = .hidden {
        didSet {
            guard oldValue != phase else { return }
            onPhaseChange?(phase)
        }
    }

    /// The controller orders the window in and out off this, rather than observing
    /// `$phase`: the phase machine stays the single place a transition is decided.
    var onPhaseChange: ((PillPhase) -> Void)?

    /// True while an auto-hide is pending. Kept separate from `hideTask` so the machine
    /// is assertable without waiting on wall-clock time.
    private(set) var isHideArmed = false
    private var hideTask: Task<Void, Never>?

    /// True once the user has clicked the card. Hovering is mouse-only so the pill never
    /// steals focus; the click is the deliberate act that hands over the keyboard, and an
    /// armed card stops behaving like an ambient pill — it stays until dismissed.
    @Published private(set) var isKeyboardArmed = false

    func armKeyboard() {
        guard phase.isVisible else { return }
        isKeyboardArmed = true
        cancelHide()
        phase = .expanded
    }

    /// What Space should open for the row the user is on, or for the newest clip when
    /// they have not arrowed anywhere yet.
    var previewTarget: ClipboardPreviewTarget? {
        guard let entry = focusedEntry ?? visibleEntries.first else { return nil }
        if let path = entry.filePaths.first {
            return .file(URL(fileURLWithPath: path))
        }
        if let fileName = entry.imageFileName {
            return .file(ClipboardImageStore.url(for: fileName))
        }
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : .text(entry.text)
    }

    /// A copy landed. Reading the history outranks announcing a new clip, so an open
    /// card is left alone rather than yanked back to a pill under the pointer.
    func didCopy() {
        guard phase != .expanded else { return }
        phase = .collapsed
        armHide(after: Self.copyDwell)
    }

    func hoverBegan() {
        guard phase != .hidden else { return }
        cancelHide()
        phase = .expanded
    }

    func hoverEnded() {
        guard phase == .expanded, !isKeyboardArmed else { return }
        phase = .collapsed
        armHide(after: Self.hoverExitDwell)
    }

    /// The hotkey is a deliberate ask: open the card and leave it open.
    func summon() {
        resetScope()
        cancelHide()
        phase = .expanded
    }

    func toggleSummon() {
        if phase == .hidden { summon() } else { dismiss() }
    }

    func dismiss() {
        cancelHide()
        phase = .hidden
        focusedEntryIndex = nil
        isKeyboardArmed = false
    }

    private func armHide(after delay: TimeInterval) {
        hideTask?.cancel()
        isHideArmed = true
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
        isHideArmed = false
    }
}

/// Space previews a clip through the shared PreviewController. A file clip points at the
/// file, an image clip at its stored blob; text has no URL until someone writes one, which
/// is the controller's job, not the model's.
enum ClipboardPreviewTarget: Equatable {
    case file(URL)
    case text(String)
}

enum PillPhase: Equatable {
    case hidden
    case collapsed
    case expanded

    var isVisible: Bool { self != .hidden }
}

struct ClipboardDockPill: View {
    @ObservedObject var model: ClipboardPanelModel
    /// `onKeyPress` only delivers to a focused view, so a key window is not enough on its
    /// own — the card has to actually hold SwiftUI focus once it is armed.
    @FocusState private var cardFocused: Bool
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var expanded: Bool { model.phase == .expanded }
    private var cardSize: CGSize { ClipboardPillMetrics.cardSize(for: model.phase) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            collapsedContent
                .opacity(expanded ? 0 : 1)
            expandedContent
                .opacity(expanded ? 1 : 0)
        }
        .frame(width: cardSize.width, height: cardSize.height, alignment: .bottomLeading)
        // The panel is only a shadow's worth taller than the card, so anything that
        // overflows is clipped by the window itself — newest rows first. Clip to the
        // card instead, and let the scroll view own the leftover height.
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            ClipboardPanelController.shared.armKeyboard()
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            model.isKeyboardArmed
                                ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.16),
                            lineWidth: model.isKeyboardArmed ? 1.5 : 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: .bottomTrailing
        )
        .padding(ClipboardPillMetrics.shadowPad)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.phase)
        .focusable(model.isKeyboardArmed)
        .focusEffectDisabled()
        .focused($cardFocused)
        .onChange(of: model.isKeyboardArmed) { _, armed in
            cardFocused = armed
        }
        .onReceive(refresh) { _ in
            guard model.phase.isVisible else { return }
            model.reload()
        }
        .onKeyPress(.escape) {
            ClipboardPanelController.shared.close()
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveEntry(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveEntry(-1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.cycleSource(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.cycleSource(1)
            return .handled
        }
        .onKeyPress(.space) {
            ClipboardPanelController.shared.preview()
            return .handled
        }
        .onKeyPress(.return) {
            guard let entry = model.focusedEntry else { return .ignored }
            ClipboardPanelController.shared.paste(entry)
            return .handled
        }
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack(spacing: 10) {
            thumbnail(model.visibleEntries.first, size: CGSize(width: 30, height: 24))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.visibleEntries.first.map(entryTitle) ?? "Clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(collapsedSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(model.entries.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.09), in: Capsule())
        }
        .padding(.horizontal, 14)
        .frame(
            width: ClipboardPillMetrics.collapsedSize.width,
            height: ClipboardPillMetrics.collapsedSize.height)
    }

    private var collapsedSubtitle: String {
        guard let entry = model.visibleEntries.first else { return "Nothing copied yet" }
        let app = entry.sourceAppName.isEmpty ? "Unknown App" : entry.sourceAppName
        return "Copied from \(app)"
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
            Divider().opacity(0.2)
            filterRow
        }
        .frame(
            width: ClipboardPillMetrics.expandedSize.width,
            height: ClipboardPillMetrics.expandedSize.height)
    }

    private var rows: some View {
        Group {
            if model.visibleEntries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("No clips from this app")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) {
                                index, entry in
                                row(entry, index: index).id(entry.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: model.focusedEntryIndex) { _, index in
                        guard let index, model.visibleEntries.indices.contains(index) else {
                            return
                        }
                        proxy.scrollTo(model.visibleEntries[index].id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: LauncherView.ClipboardEntry, index: Int) -> some View {
        Button {
            model.focusedEntryIndex = index
            ClipboardPanelController.shared.paste(entry)
        } label: {
            HStack(spacing: 10) {
                thumbnail(entry, size: CGSize(width: 34, height: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entryTitle(entry))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(entry.timestamp.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !entry.sourceBundleId.isEmpty,
                    let icon = appIcon(bundleID: entry.sourceBundleId)
                {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                model.focusedEntryIndex == index
                    ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.sources) { source in
                    filterPill(source)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 46)
    }

    private func filterPill(_ source: ClipboardPanelModel.SourceChoice) -> some View {
        let selected = model.selectedSource.bundleID == source.bundleID
        return Button {
            model.selectSource(bundleID: source.bundleID)
        } label: {
            HStack(spacing: 5) {
                if source.isAll {
                    Image(systemName: "square.grid.2x2").font(.system(size: 10, weight: .semibold))
                } else if let icon = appIcon(bundleID: source.bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(source.name).lineLimit(1)
                Text("\(source.count)").foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .help(source.name)
    }

    // MARK: - Shared bits

    @ViewBuilder
    private func thumbnail(_ entry: LauncherView.ClipboardEntry?, size: CGSize) -> some View {
        if let entry,
            let data = entry.imageData
                ?? entry.imageFileName.flatMap({ ClipboardImageStore.read(fileName: $0) }),
            let image = NSImage(data: data)
        {
            Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(
                systemName: (entry?.filePaths.isEmpty ?? true)
                    ? "doc.on.clipboard" : "doc.fill"
            )
            .font(.system(size: 15))
            .frame(width: size.width, height: size.height)
            .foregroundStyle(.secondary)
        }
    }

    private func entryTitle(_ entry: LauncherView.ClipboardEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if !entry.filePaths.isEmpty {
            return entry.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: ", ")
        }
        return entry.imageFileName == nil && entry.imageData == nil ? "Clipboard Item" : "Image"
    }

    private func appIcon(bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
