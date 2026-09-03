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

    static let miniSize = CGSize(width: 96, height: 44)

    static func cardSize(for phase: PillPhase) -> CGSize {
        switch phase {
        case .expanded: return expandedSize
        case .mini: return miniSize
        case .collapsed, .hidden: return collapsedSize
        }
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
    private var returnApplication: NSRunningApplication?
    private var outsideClickMonitor: Any?
    private var isSuppressed = false
    /// True only for the hotkey path, which is allowed to take focus. A copy-triggered
    /// pill must never pull the user out of what they are typing in.
    private var didTakeFocus = false

    var isVisible: Bool { model.phase.isVisible }

    // MARK: - Entry points

    /// A copy landed anywhere on the system. Ambient: orders in without activating us.
    func didCopy(_ entry: LauncherView.ClipboardEntry) {
        guard !isSuppressed else { return }
        ensurePanel()
        model.reload()
        model.ingest(entry)
        model.didCopy()
    }

    /// Stood down while a drag is in flight. A drag is not a copy, so the ambient pill
    /// has nothing to announce, and standing it down removes the only case where it and
    /// the Drop Shelf fight for the same corner and the same pointer. The hotkey is
    /// unaffected — that is a deliberate ask, not an ambient reaction.
    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        guard suppressed, !model.isKeyboardArmed else { return }
        model.dismiss()
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
        CornerDockController.shared.armKeyboard()
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
        CornerDockController.shared.armKeyboard()
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

    /// The app a paste would land in, named so a menu can say where it is going.
    var returnAppName: String {
        let target = didTakeFocus ? returnApplication : NSWorkspace.shared.frontmostApplication
        return target?.localizedName ?? "the frontmost app"
    }

    /// Put the selection on the pasteboard and leave it there. No paste, no dismissal —
    /// the user asked for a copy, which is a thing they will use somewhere else, later.
    func copy(_ entries: [LauncherView.ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        ClipboardScopeService.writeToPasteboard(entries)
    }

    /// A drag is leaving with these clips, so the copy monitor must not treat the temporary
    /// file the drag wrote as something the user copied.
    func beginDrag(_ entries: [LauncherView.ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        setSuppressed(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.setSuppressed(false)
        }
    }

    func pasteMany(_ entries: [LauncherView.ClipboardEntry]) {
        guard let first = entries.first else { return }
        guard entries.count > 1 else { return paste(first) }
        ClipboardScopeService.writeToPasteboard(entries)
        let target = didTakeFocus ? returnApplication : NSWorkspace.shared.frontmostApplication
        model.dismiss()
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let pid = target?.processIdentifier else { return }
            ClipboardScopeService.postPasteShortcut(to: pid)
        }
    }

    func paste(_ entry: LauncherView.ClipboardEntry) {
        ClipboardScopeService.writeToPasteboard([entry])

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
        CornerDockController.shared.activate()
        model.onPhaseChange = { [weak self] phase in
            self?.applyPhase(phase)
        }
    }

    private func applyPhase(_ phase: PillPhase) {
        // The shared shell owns the window; this surface owns only its own state.
        CornerDockController.shared.refresh()
        if phase.isVisible {
            startOutsideClickWatch()
        } else {
            stopOutsideClickWatch()
            CornerDockController.shared.disarmKeyboard()
            if didTakeFocus {
                didTakeFocus = false
                returnApplication?.activate()
            }
        }
    }

    /// An armed card is dismissed by a click anywhere else. App-active state cannot be
    /// used for this: activating an accessory app whose only window is a floating panel
    /// bounces active straight back, so `didResignActive` fires immediately after arming.
    private func startOutsideClickWatch() {
        guard outsideClickMonitor == nil,
            let panel = CornerDockController.shared.window
        else { return }
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
    /// Which clips are picked, and the order they were picked in — pasting three clips into
    /// a document should produce them in the order the user chose, not the order history
    /// happens to hold them.
    @Published private(set) var selectedIDs: Set<UUID> = []
    private var pickOrder: [UUID] = []
    /// Where a ⇧-click measures from.
    private var selectionAnchor: UUID?

    /// The clips an action applies to: the selection when there is one, otherwise whatever
    /// row is focused, otherwise the row acted on directly.
    func actionableEntries(fallback entry: LauncherView.ClipboardEntry? = nil)
        -> [LauncherView.ClipboardEntry]
    {
        let visible = visibleEntries
        let selected = ClipboardScopeService.orderedSelection(
            from: visible, selectedIDs: selectedIDs, pickOrder: pickOrder)
        if !selected.isEmpty { return selected }
        if let entry { return [entry] }
        if let index = focusedEntryIndex, visible.indices.contains(index) {
            return [visible[index]]
        }
        return []
    }

    func isSelected(_ entry: LauncherView.ClipboardEntry) -> Bool {
        selectedIDs.contains(entry.id)
    }

    /// Plain click replaces, ⌘ adds or removes, ⇧ extends from the last plain click.
    func selectEntry(_ entry: LauncherView.ClipboardEntry, extend: Bool, toggle: Bool) {
        if toggle {
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
                pickOrder.removeAll { $0 == entry.id }
            } else {
                selectedIDs.insert(entry.id)
                pickOrder.append(entry.id)
            }
            selectionAnchor = entry.id
        } else if extend {
            let range = ClipboardScopeService.rangeSelection(
                in: visibleEntries, from: selectionAnchor, to: entry.id)
            selectedIDs = range
            // A range has no pick order of its own; list order is the honest answer.
            pickOrder = visibleEntries.map(\.id).filter { range.contains($0) }
        } else {
            selectedIDs = [entry.id]
            pickOrder = [entry.id]
            selectionAnchor = entry.id
        }
        noteInteraction()
    }

    func selectAllVisible() {
        let ids = visibleEntries.map(\.id)
        selectedIDs = Set(ids)
        pickOrder = ids
        noteInteraction()
    }

    func clearSelection() {
        selectedIDs = []
        pickOrder = []
        selectionAnchor = nil
    }

    /// Delete the clips an action would apply to.
    ///
    /// The history file has one writer — the dock, which also owns the image blobs beside
    /// it — so this asks rather than rewriting it from here. The rows go immediately so the
    /// list answers the key press; the dock's own prune is what makes it durable.
    func removeActionableEntries(fallback entry: LauncherView.ClipboardEntry? = nil) {
        let doomed = actionableEntries(fallback: entry)
        guard !doomed.isEmpty else { return }
        let ids = Set(doomed.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        clearSelection()
        if let focusedEntryIndex, !visibleEntries.indices.contains(focusedEntryIndex) {
            self.focusedEntryIndex = visibleEntries.isEmpty ? nil : visibleEntries.count - 1
        }
        NotificationCenter.default.post(
            name: .clipboardEntriesRemovalRequested,
            object: nil,
            userInfo: ["ids": ids.map(\.uuidString)])
        noteInteraction()
    }

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
        clearSelection()
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
        noteInteraction()
        let count = sources.count
        guard count > 0 else { return }
        sourceIndex = (sourceIndex + (direction >= 0 ? 1 : -1) + count) % count
        focusedEntryIndex = nil
    }

    func selectSource(bundleID: String) {
        noteInteraction()
        guard let index = sources.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        sourceIndex = index
        focusedEntryIndex = nil
    }

    /// Any deliberate interaction is attention: it puts the stand-down back to full.
    private func noteInteraction() {
        guard phase.isVisible else { return }
        armStandDown(after: Self.armedDwell)
    }

    /// Move the focus, and optionally take the row it lands on with it.
    ///
    /// `select` is ⌘ or ⇧ held: walking the list while picking is the only way to build a
    /// selection without the mouse, and the arrows on their own must keep meaning "move",
    /// because that is what Return then pastes.
    func moveEntry(_ direction: Int, selecting select: Bool = false) {
        noteInteraction()
        let count = visibleEntries.count
        guard count > 0 else {
            focusedEntryIndex = nil
            return
        }
        let current = focusedEntryIndex ?? (direction >= 0 ? -1 : count)
        let next = min(max(current + direction, 0), count - 1)
        focusedEntryIndex = next

        guard select, visibleEntries.indices.contains(next) else { return }

        // An anchor and a cursor, not a growing pile. Adding on every press meant reversing
        // could only ever select more: ⌘↓ ⌘↓ ⌘↑ left three rows picked when the user was
        // plainly taking one back. The selection is the span between where the walk started
        // and where it is now, so moving toward the anchor shrinks it.
        if selectionAnchor == nil || selectedIDs.isEmpty {
            let originIndex = visibleEntries.indices.contains(current) ? current : next
            selectionAnchor = visibleEntries[originIndex].id
        }
        let range = ClipboardScopeService.rangeSelection(
            in: visibleEntries, from: selectionAnchor, to: visibleEntries[next].id)
        selectedIDs = range
        // A span has no pick order of its own; list order is the honest answer.
        pickOrder = visibleEntries.map(\.id).filter { range.contains($0) }
    }

    var focusedEntry: LauncherView.ClipboardEntry? {
        guard let focusedEntryIndex,
            visibleEntries.indices.contains(focusedEntryIndex)
        else { return nil }
        return visibleEntries[focusedEntryIndex]
    }

    // MARK: - Pill phase

    /// How long the full pill lingers after a copy nobody reached for.
    static let copyDwell: TimeInterval = 4
    /// How long the shrunken badge lingers after that.
    static let miniDwell: TimeInterval = 3
    /// How long a card the user drove with the keyboard waits before standing down. It
    /// outlives an ambient pill, but it does not outlive the user's attention.
    static let armedDwell: TimeInterval = 5
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

    /// Copies that landed while the pill was already up. Shown as "+N" so a burst reads
    /// as "three more were caught" rather than one clip silently replacing another.
    @Published private(set) var burstCount = 0

    /// The pointer is on the card. Nothing shrinks underneath it.
    private var isPointerOver = false

    func armKeyboard() {
        guard phase.isVisible else { return }
        isKeyboardArmed = true
        phase = .expanded
        armStandDown(after: Self.armedDwell)
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
        // Already on screen: this is a burst, and the count is what the user needs.
        if phase.isVisible {
            burstCount += 1
        } else {
            burstCount = 0
        }
        phase = .collapsed
        armStandDown(after: Self.copyDwell)
    }

    func hoverBegan() {
        isPointerOver = true
        guard phase != .hidden else { return }
        cancelHide()
        // The clips have been looked at, so there is no longer a backlog to report.
        burstCount = 0
        phase = .expanded
    }

    func hoverEnded() {
        isPointerOver = false
        guard phase == .expanded else { return }
        // A card holding the keyboard stays open, but it starts ticking: the pointer
        // leaving is the last thing that kept it exempt.
        if isKeyboardArmed {
            armStandDown(after: Self.armedDwell)
        } else {
            phase = .collapsed
            armStandDown(after: Self.hoverExitDwell)
        }
    }

    /// One step smaller, never straight to nothing: card, pill, badge, gone. A card under
    /// the pointer is exempt — it belongs to whoever is reading it.
    func standDown() {
        guard !isPointerOver else {
            armStandDown(after: Self.armedDwell)
            return
        }
        switch phase {
        case .expanded:
            isKeyboardArmed = false
            phase = .collapsed
            armStandDown(after: Self.hoverExitDwell)
        case .collapsed:
            phase = .mini
            armStandDown(after: Self.miniDwell)
        case .mini:
            dismiss()
        case .hidden:
            break
        }
    }

    /// Switching Space is leaving. The card is about a corner of a screen the user has
    /// walked away from, and following them there would be an interruption, not a service.
    func userLeftTheSpace() {
        dismiss()
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
        burstCount = 0
    }

    private func armStandDown(after delay: TimeInterval) {
        hideTask?.cancel()
        isHideArmed = true
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.standDown()
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
    /// Icon and count only: the pill has aged out of its full form but is still there to
    /// be caught.
    case mini
    case collapsed
    case expanded

    var isVisible: Bool { self != .hidden }
}

struct ClipboardDockPill: View {
    @ObservedObject var model: ClipboardPanelModel
    /// `onKeyPress` only delivers to a focused view, so a key window is not enough on its
    /// own — the card has to actually hold SwiftUI focus once it is armed.
    @FocusState private var cardFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var searchHovered = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var expanded: Bool { model.phase == .expanded }
    private var cardSize: CGSize { ClipboardPillMetrics.cardSize(for: model.phase) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            miniContent
                .opacity(model.phase == .mini ? 1 : 0)
            collapsedContent
                .opacity(model.phase == .collapsed ? 1 : 0)
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
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.burstCount)
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
            // Undo the narrowing before closing the panel: a selection and a query are both
            // work the user did, and one key should not throw them away with the window.
            if !model.selectedIDs.isEmpty {
                model.clearSelection()
                return .handled
            }
            if !model.query.isEmpty {
                model.query = ""
                return .handled
            }
            ClipboardPanelController.shared.close()
            return .handled
        }
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selectAllVisible()
            return .handled
        }
        .onKeyPress(keys: ["c"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let entries = model.actionableEntries()
            guard !entries.isEmpty else { return .ignored }
            ClipboardPanelController.shared.copy(entries)
            return .handled
        }
        // There was no way to drop a clip from here at all: the list could be searched,
        // selected and pasted, and never pruned.
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !model.actionableEntries().isEmpty else { return .ignored }
            model.removeActionableEntries()
            return .handled
        }
        // Modifier-aware, because the plain-key form of `onKeyPress` never sees which keys
        // were held — so ⌘↓ was arriving here as a bare ↓ and only ever moved the focus.
        .onKeyPress(keys: [.downArrow, .upArrow]) { press in
            let direction = press.key == .downArrow ? 1 : -1
            let selecting = !press.modifiers.isDisjoint(with: [.command, .shift])
            model.moveEntry(direction, selecting: selecting)
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
            let entries = model.actionableEntries()
            guard !entries.isEmpty else { return .ignored }
            ClipboardPanelController.shared.pasteMany(entries)
            return .handled
        }
        // Typing is searching. The arrows, Space and Return above keep their jobs; anything
        // that would put a character on screen opens the field and goes into it, so finding
        // a clip never starts with hunting for a control.
        .onKeyPress(phases: .down) { press in
            guard !searchFocused,
                press.modifiers.isDisjoint(with: [.command, .control, .option]),
                let character = press.characters.first,
                character.isLetter || character.isNumber
            else { return .ignored }
            model.query.append(character)
            searchFocused = true
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
            if model.burstCount > 0 {
                Text("+\(model.burstCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
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

    /// What the pill ages into: enough to say the clipboard is there and how much is in
    /// it, small enough to stop being furniture.
    private var miniContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(model.entries.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if model.burstCount > 0 {
                Text("+\(model.burstCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .frame(
            width: ClipboardPillMetrics.miniSize.width,
            height: ClipboardPillMetrics.miniSize.height)
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
        let selected = model.isSelected(entry)
        return Button {
            model.focusedEntryIndex = index
            // A modifier means "pick this", a plain click still means "paste this" — the
            // fast path stays one click.
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) || flags.contains(.shift) {
                model.selectEntry(
                    entry, extend: flags.contains(.shift), toggle: flags.contains(.command))
            } else {
                ClipboardPanelController.shared.paste(entry)
            }
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
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
                if !entry.sourceBundleId.isEmpty,
                    let icon = appIcon(bundleID: entry.sourceBundleId)
                {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(rowTint(index: index, selected: selected),
                in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        // Dragging a selected row drags the whole selection; dragging an unselected one
        // drags just it, without disturbing what was picked.
        .onDrag {
            let dragged = selected ? model.actionableEntries() : [entry]
            ClipboardPanelController.shared.beginDrag(dragged)
            return ClipboardScopeService.dragProvider(for: dragged.first ?? entry)
                ?? NSItemProvider()
        } preview: {
            dragPreview(for: selected ? model.actionableEntries() : [entry])
        }
        .contextMenu {
            Button("Copy") { ClipboardPanelController.shared.copy(model.actionableEntries(fallback: entry)) }
            Button("Paste into \(ClipboardPanelController.shared.returnAppName)") {
                ClipboardPanelController.shared.pasteMany(
                    model.actionableEntries(fallback: entry))
            }
            Divider()
            Button(model.isSelected(entry) ? "Deselect" : "Select") {
                model.selectEntry(entry, extend: false, toggle: true)
            }
            Button("Select All") { model.selectAllVisible() }
            Divider()
            Button("Remove", role: .destructive) {
                model.removeActionableEntries(fallback: entry)
            }
        }
    }

    private func rowTint(index: Int, selected: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.24) }
        if model.focusedEntryIndex == index { return Color.accentColor.opacity(0.18) }
        return Color.primary.opacity(0.05)
    }

    /// A stack with a count, rather than the single-row screenshot macOS would use — a
    /// three-clip drag that looks like one clip is a drag the user cannot trust.
    private func dragPreview(for entries: [LauncherView.ClipboardEntry]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(entries.prefix(3).enumerated()), id: \.element.id) { offset, entry in
                thumbnail(entry, size: CGSize(width: 44, height: 34))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .offset(x: CGFloat(offset) * 6, y: CGFloat(offset) * 6)
            }
        }
        .padding(6)
        .overlay(alignment: .bottomTrailing) {
            if entries.count > 1 {
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
        }
    }

    /// Search leads the row, then the app chips.
    ///
    /// The model has always filtered on a query — text, OCR text, file names, source app —
    /// and nothing ever set it. The glyph is the smallest thing that can: it widens into a
    /// field under the pointer, on a click, or the moment a printable key is typed, and
    /// gives the width back when it is empty and unfocused, so at rest the row is chips.
    private var filterRow: some View {
        HStack(spacing: 6) {
            searchField

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sources) { source in
                        filterPill(source)
                    }
                }
                .padding(.trailing, 12)
            }
            // Reaching for the chips is asking for the chips. An open field is holding
            // width they need, so scrolling hands it back — but never while a query is in
            // it, because collapsing then would hide the thing doing the filtering.
            .onScrollPhaseChange { _, phase in
                guard phase != .idle, model.query.isEmpty else { return }
                searchHovered = false
                searchFocused = false
            }
            // A chip sliding under the field fades out rather than being sliced in half.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing)
            )
        }
        .padding(.leading, 12)
        .frame(height: 46)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: searchExpanded)
    }

    private var searchExpanded: Bool {
        searchHovered || searchFocused || !model.query.isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(searchExpanded ? .primary : .secondary)

            if searchExpanded {
                TextField("Search clips", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($searchFocused)
                    .frame(width: 116)
                    .onKeyPress(.escape) {
                        // Clear first, close second: one Escape should not throw away the
                        // panel and the query together.
                        if model.query.isEmpty {
                            searchFocused = false
                            return .handled
                        }
                        model.query = ""
                        return .handled
                    }

                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            searchExpanded ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                searchFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1))
        )
        .contentShape(Capsule())
        .onHover { searchHovered = $0 }
        .onTapGesture { searchFocused = true }
        .help("Search clips")
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

extension Notification.Name {
    /// Corner panel → the dock, asking it to drop these clips from the history both of
    /// them read. The corner does not rewrite that file: the dock owns it and the image
    /// blobs stored beside it, and two writers would race over both.
    static let clipboardEntriesRemovalRequested = Notification.Name(
        "clipboardEntriesRemovalRequested")
}
