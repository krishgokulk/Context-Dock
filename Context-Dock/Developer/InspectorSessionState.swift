#if DEBUG
import Foundation

/// Every Inspect Mode transition, with no AppKit in sight.
///
/// The interesting failures in an inspector are transitions, not drawing: a lock that outlives
/// the window it pointed at, a hover that redraws on every pointer move because "unchanged"
/// was never checked, an Escape that leaves the mode when it should only have released the
/// selection. Deciding all of it here means it is testable offline in milliseconds, and the
/// controller above is only wiring.
///
/// Mutators return whether they changed anything so callers can skip redundant redraws — the
/// pointer generates far more events than there are distinct answers.
@MainActor
final class InspectorSessionState {
    enum EscapeOutcome: Equatable {
        case ignored
        case clearedLock
        case disabled
    }

    private(set) var isEnabled = false
    private(set) var hoveredKey: InspectRegistryKey?
    private(set) var lockedKey: InspectRegistryKey?

    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return false }
        isEnabled = true
        return true
    }

    @discardableResult
    func disable() -> Bool {
        guard isEnabled else { return false }
        isEnabled = false
        hoveredKey = nil
        lockedKey = nil
        return true
    }

    /// Hover is preview only, and a locked selection freezes it: the panel someone is reading
    /// must not change under them because the pointer drifted off the region.
    @discardableResult
    func hover(_ key: InspectRegistryKey?) -> Bool {
        guard isEnabled, lockedKey == nil, hoveredKey != key else { return false }
        hoveredKey = key
        return true
    }

    @discardableResult
    func lock(_ key: InspectRegistryKey?) -> Bool {
        guard isEnabled, lockedKey != key else { return false }
        lockedKey = key
        if key != nil { hoveredKey = key }
        return true
    }

    func escape() -> EscapeOutcome {
        guard isEnabled else { return .ignored }
        if lockedKey != nil {
            lockedKey = nil
            hoveredKey = nil
            return .clearedLock
        }
        disable()
        return .disabled
    }

    /// Drop selections whose registration no longer exists. A closed window, a scrolled-away
    /// message and a rebuilt surface all arrive here the same way: as a key that is simply
    /// absent from the live set.
    @discardableResult
    func reconcile(liveKeys: Set<InspectRegistryKey>) -> Bool {
        guard isEnabled else { return false }
        var changed = false

        if let hoveredKey, !liveKeys.contains(hoveredKey) {
            self.hoveredKey = nil
            changed = true
        }
        if let lockedKey, !liveKeys.contains(lockedKey) {
            self.lockedKey = nil
            changed = true
        }
        return changed
    }
}
#endif
