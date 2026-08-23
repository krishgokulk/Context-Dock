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
