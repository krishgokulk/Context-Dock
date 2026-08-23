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

    func dragEntered() {
        wantsClipboardSuppressed = true
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

    func hoverBegan() {
        // Hovering an empty corner must not open an empty card over the user's work.
        guard itemCount > 0, phase != .inviting else { return }
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

    private func set(_ next: DropShelfPhase) {
        guard phase != next else { return }
        phase = next
        onPhaseChange?(next)
    }
}
