// DropShelfPresentation.swift
// Context-Dock
//
// What the Drop Shelf is currently showing. Kept apart from the window and the store so
// the rules — when the shelf appears, when it opens, when it stands the clipboard down —
// can be reasoned about and tested without a drag or a screen.

import Combine
import Foundation

enum DropShelfPhase: Equatable {
    /// Nothing held and nothing being dragged.
    case hidden
    /// A drag is over the drop area.
    case inviting
    /// Items are on the shelf; the collapsed pill shows the count.
    case holding
    /// Pointer is on the pill; the card of items is open.
    case expanded

    var isVisible: Bool { self != .hidden }
}

@MainActor
final class DropShelfPresentation: ObservableObject {
    @Published private(set) var phase: DropShelfPhase = .hidden

    /// Set by the controller from the store. The shelf has nothing to show without it.
    var itemCount: Int = 0

    /// True while a drag is in flight. The clipboard pill stands down for the duration:
    /// a drag is not a copy, so nothing is lost by it, and it removes the only case where
    /// two pills fight for the same corner and the same pointer.
    @Published private(set) var wantsClipboardSuppressed = false

    var onPhaseChange: ((DropShelfPhase) -> Void)?

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

    /// How long the pill lingers before standing down. The shelf keeps what it holds
    /// either way — hiding is only the pill leaving the corner, never the items leaving
    /// the shelf.
    static let holdingDwell: TimeInterval = 5

    /// True while a stand-down is pending. Kept separate from the task so the rule is
    /// assertable without waiting on wall-clock time.
    private(set) var isHideArmed = false
    private var hideTask: Task<Void, Never>?

    func dragEntered() {
        wantsClipboardSuppressed = true
        cancelHide()
        set(.inviting)
    }

    func dragExited() {
        wantsClipboardSuppressed = false
        set(restingPhase)
    }

    func dropCompleted() {
        wantsClipboardSuppressed = false
        set(restingPhase)
    }

    /// Reaches the shelf even once it has stood down: the corner keeps answering the
    /// pointer while items are held, or hiding would strand them.
    func hoverBegan() {
        // Hovering an empty corner must not open an empty card over the user's work.
        guard itemCount > 0, phase != .inviting else { return }
        cancelHide()
        set(.expanded)
    }

    func hoverEnded() {
        guard phase == .expanded else { return }
        set(restingPhase)
    }

    /// The store changed underneath: the last item may have been removed, or the first
    /// added.
    func itemCountChanged() {
        guard phase != .inviting else { return }
        if itemCount == 0 {
            set(.hidden)
        } else if phase == .hidden {
            set(.holding)
        }
    }

    private var restingPhase: DropShelfPhase {
        itemCount > 0 ? .holding : .hidden
    }

    /// The stand-down itself. Public so the rule can be exercised without waiting five
    /// seconds in a test.
    func autoHide() {
        cancelHide()
        set(.hidden)
    }

    private func armHide() {
        hideTask?.cancel()
        isHideArmed = true
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.holdingDwell * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.autoHide()
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
        isHideArmed = false
    }

    private func set(_ next: DropShelfPhase) {
        guard phase != next else { return }
        phase = next
        // Only the resting, collapsed state stands down. An open card belongs to the
        // pointer, and an invitation belongs to the drag.
        if next == .holding { armHide() } else { cancelHide() }
        onPhaseChange?(next)
    }
}
