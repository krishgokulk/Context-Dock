// DropShelfPresentation.swift
// Context-Dock
//
// What the Drop Shelf is currently showing. Kept apart from the window and the store so
// the rules — when the shelf appears, when it opens, when it stands the clipboard down —
// can be reasoned about and tested without a drag or a screen.

import Combine
import Foundation

/// What the shelf's icon is doing. The icon itself is always there — the last item of every
/// dock row — so there is no "hidden": the phases are only what it shows.
enum DropShelfPhase: Equatable {
    /// A plain icon at the end of the row.
    case collapsed
    /// A drag is in flight somewhere: the icon is the drop target and says so.
    case inviting
    /// The shelf is open, in the same shell, showing what it holds.
    case expanded

    /// Whether the card of items is showing.
    var isCardShown: Bool { self == .expanded }
}

/// Which of a dock row's trailing tools are showing, in the order they are drawn. The shelf is
/// the last one, in every scope and with or without pins, whenever it shows.
enum DockToolKind: Equatable {
    case clipboard, selection, feedback, shelf
}

/// When the Drop Shelf's icon is in a row (owner 2026-10-06: "only appear when the user
/// added files"). It holds something, or a drag is in flight — the row is where a drop
/// lands, and a drag brings the shell up for it — or its card is open. An empty shelf with
/// nothing being dragged is an icon for nothing, so it takes no room.
enum DropShelfVisibility {
    static func shows(itemCount: Int, phase: DropShelfPhase) -> Bool {
        itemCount > 0 || phase != .collapsed
    }
}

enum DockTools {
    /// The row's tools, shelf last. An app's bar carries no action results, only the clipboard
    /// for a copy's few seconds and the selection while there is one.
    static func row(
        showsTabBar: Bool, clipboard: Bool, selection: Bool, feedback: Bool, shelf: Bool = true
    ) -> [DockToolKind] {
        var tools: [DockToolKind] = []
        if clipboard { tools.append(.clipboard) }
        if selection { tools.append(.selection) }
        if feedback, !showsTabBar { tools.append(.feedback) }
        if shelf { tools.append(.shelf) }
        return tools
    }
}

@MainActor
final class DropShelfPresentation: ObservableObject {
    @Published private(set) var phase: DropShelfPhase = .collapsed

    /// A drag is over the shelf's icon itself, as opposed to somewhere else on the shell.
    @Published private(set) var isDragOverIcon = false

    /// Set by the controller from the store; the icon's badge reads it.
    var itemCount: Int = 0

    /// True while a drag is in flight. The clipboard pill stands down for the duration:
    /// a drag is not a copy, so nothing is lost by it, and it removes the only case where
    /// two pills fight for the same corner and the same pointer.
    @Published private(set) var wantsClipboardSuppressed = false

    /// The card was opened by a drag resting on the icon rather than by a click, so it goes
    /// away again with the drag instead of staying open over the user's work.
    private var openedByDrag = false

    var onPhaseChange: ((DropShelfPhase) -> Void)?

    /// What a click on the icon does: open the shelf, or put it away.
    func toggle() {
        openedByDrag = false
        set(phase == .expanded ? restingPhase : .expanded)
    }

    /// Esc, a change of Space, or anything else that puts the shelf away.
    func collapse() {
        openedByDrag = false
        set(restingPhase)
    }

    // MARK: - Selection

    /// Which items are picked, and the order they were picked in. The shelf exists to be
    /// dragged out of, and dragging one file at a time is the slow way to move four.
    @Published private(set) var selectedIDs: Set<UUID> = []
    private var pickOrder: [UUID] = []
    private var selectionAnchor: UUID?

    func isSelected(_ item: DropShelfItem) -> Bool { selectedIDs.contains(item.id) }

    /// Plain click replaces, ⌘ adds or removes, ⇧ extends — the same rule the clipboard
    /// follows, read from the same helper.
    func select(_ item: DropShelfItem, in items: [DropShelfItem], extend: Bool, toggle: Bool) {
        if toggle {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
                pickOrder.removeAll { $0 == item.id }
            } else {
                selectedIDs.insert(item.id)
                pickOrder.append(item.id)
            }
            selectionAnchor = item.id
        } else if extend {
            let range = ClipboardScopeService.rangeSelection(
                in: items, from: selectionAnchor, to: item.id)
            selectedIDs = range
            pickOrder = items.map(\.id).filter { range.contains($0) }
        } else {
            selectedIDs = [item.id]
            pickOrder = [item.id]
            selectionAnchor = item.id
        }
    }

    func selectAll(_ items: [DropShelfItem]) {
        selectedIDs = Set(items.map(\.id))
        pickOrder = items.map(\.id)
    }

    func clearSelection() {
        selectedIDs = []
        pickOrder = []
        selectionAnchor = nil
    }

    /// The items an action applies to, in pick order: the selection when there is one,
    /// otherwise just the row acted on.
    func actionableItems(in items: [DropShelfItem], fallback item: DropShelfItem?)
        -> [DropShelfItem]
    {
        let selected = ClipboardScopeService.orderedSelection(
            from: items, selectedIDs: selectedIDs, pickOrder: pickOrder)
        if !selected.isEmpty { return selected }
        return item.map { [$0] } ?? []
    }

    // MARK: - Drags

    /// A drag was sighted — over the shell, or at the screen edge that watches for one. The
    /// icon becomes the drop target. An open shelf stays open: it is already one.
    func dragEntered() {
        wantsClipboardSuppressed = true
        if phase != .expanded { set(.inviting) }
    }

    /// The drag left without dropping.
    func dragExited() {
        wantsClipboardSuppressed = false
        isDragOverIcon = false
        if openedByDrag { collapse() } else if phase == .inviting { set(.collapsed) }
    }

    /// The pointer, carrying something, is on the icon. Like any drag target it opens, so
    /// the user sees where the drop will land.
    func iconDragEntered() {
        wantsClipboardSuppressed = true
        isDragOverIcon = true
        if DropShelfDragRule.expandsOnHover(dragOverIcon: true, expanded: phase == .expanded) {
            openedByDrag = true
            set(.expanded)
        }
    }

    func iconDragExited() {
        isDragOverIcon = false
    }

    /// Something landed. A shelf the drag opened stays open, so the item is seen arriving;
    /// otherwise the icon goes back to resting and its badge counts the new item.
    func dropCompleted() {
        wantsClipboardSuppressed = false
        isDragOverIcon = false
        openedByDrag = false
        if phase == .inviting { set(.collapsed) }
    }

    private var restingPhase: DropShelfPhase { .collapsed }

    private func set(_ next: DropShelfPhase) {
        guard phase != next else { return }
        phase = next
        onPhaseChange?(next)
    }
}

/// Who is the drop target, as pure rules the icon and the shell both read.
enum DropShelfDragRule {
    /// The icon opens when a drag rests on it, unless it is open already.
    static func expandsOnHover(dragOverIcon: Bool, expanded: Bool) -> Bool {
        dragOverIcon && !expanded
    }

    /// Where a drop is taken. Only the icon and, while it is open, the card of items accept
    /// one; the rest of the shell declines, so a release anywhere else does what it did
    /// before the shelf existed.
    static func acceptsDrop(overIcon: Bool, overCard: Bool, expanded: Bool) -> Bool {
        overIcon || (expanded && overCard)
    }

    /// How the icon is drawn for a drag: resting, invited (a drag is in flight), or the
    /// target itself (the pointer is on it).
    enum Highlight: Equatable { case none, invited, target }

    static func highlight(phase: DropShelfPhase, dragOverIcon: Bool) -> Highlight {
        if dragOverIcon { return .target }
        return phase == .inviting ? .invited : .none
    }
}
