import Foundation
import Testing

@testable import Context_Dock

// Inspect Mode's interesting failures are transitions, not drawing: a lock that outlives its
// window, a hover that redraws on every pointer move, an Escape that leaves the mode when it
// should only have released the selection. All of that is decided in InspectorSessionState, so
// all of it is testable here without a window, a pointer or a screen.

@MainActor
struct InspectorSessionStateTests {
    private let windowID = InspectWindowID(rawValue: 31)

    private func key(_ id: InspectID, _ token: UUID = UUID()) -> InspectRegistryKey {
        InspectRegistryKey(windowID: windowID, id: id, instanceToken: token)
    }

    @Test func enableAndDisableAreIdempotent() {
        let state = InspectorSessionState()

        #expect(state.enable() == true)
        #expect(state.enable() == false)
        #expect(state.isEnabled)

        #expect(state.disable() == true)
        #expect(state.disable() == false)
        #expect(state.isEnabled == false)
    }

    @Test func disablingClearsHoverAndLock() {
        let state = InspectorSessionState()
        state.enable()
        state.hover(key(.generalChat.thread))
        state.lock(key(.generalChat.input))

        state.disable()

        #expect(state.hoveredKey == nil)
        #expect(state.lockedKey == nil)
    }

    @Test func hoverIsIgnoredWhileDisabled() {
        let state = InspectorSessionState()

        #expect(state.hover(key(.generalChat.thread)) == false)
        #expect(state.hoveredKey == nil)
    }

    @Test func repeatedHoverOnTheSameKeyReportsNoChange() {
        let state = InspectorSessionState()
        state.enable()
        let target = key(.generalChat.thread)

        #expect(state.hover(target) == true)
        #expect(state.hover(target) == false)
        #expect(state.hover(target) == false)
    }

    @Test func hoverDoesNotMoveWhileATargetIsLocked() {
        let state = InspectorSessionState()
        state.enable()
        let locked = key(.generalChat.thread)
        state.lock(locked)

        #expect(state.hover(key(.generalChat.input)) == false)
        #expect(state.lockedKey == locked)
        #expect(state.hoveredKey == locked)
    }

    @Test func lockingOutsideAnyRegionClearsTheLock() {
        let state = InspectorSessionState()
        state.enable()
        state.lock(key(.generalChat.thread))

        #expect(state.lock(nil) == true)
        #expect(state.lockedKey == nil)
    }

    @Test func firstEscapeClearsTheLockAndSecondDisables() {
        let state = InspectorSessionState()
        state.enable()
        state.lock(key(.generalChat.thread))

        #expect(state.escape() == .clearedLock)
        #expect(state.isEnabled)
        #expect(state.lockedKey == nil)

        #expect(state.escape() == .disabled)
        #expect(state.isEnabled == false)
    }

    @Test func escapeIsIgnoredWhileDisabled() {
        let state = InspectorSessionState()

        #expect(state.escape() == .ignored)
    }

    @Test func reconcileClearsAHoverWhoseRegistrationIsGone() {
        let state = InspectorSessionState()
        state.enable()
        state.hover(key(.generalChat.thread))

        #expect(state.reconcile(liveKeys: []) == true)
        #expect(state.hoveredKey == nil)
    }

    @Test func reconcileClearsALockWhoseRegistrationIsGone() {
        let state = InspectorSessionState()
        state.enable()
        state.lock(key(.generalChat.thread))

        #expect(state.reconcile(liveKeys: []) == true)
        #expect(state.lockedKey == nil)
    }

    @Test func reconcileKeepsSelectionsThatAreStillLive() {
        let state = InspectorSessionState()
        state.enable()
        let live = key(.generalChat.thread)
        state.lock(live)

        #expect(state.reconcile(liveKeys: [live]) == false)
        #expect(state.lockedKey == live)
    }

    @Test func aRecreatedWindowDoesNotInheritTheEarlierLock() {
        let state = InspectorSessionState()
        state.enable()
        let token = UUID()
        let oldWindowKey = InspectRegistryKey(
            windowID: InspectWindowID(rawValue: 41), id: .generalChat.thread, instanceToken: token
        )
        let newWindowKey = InspectRegistryKey(
            windowID: InspectWindowID(rawValue: 42), id: .generalChat.thread, instanceToken: token
        )
        state.lock(oldWindowKey)

        #expect(state.reconcile(liveKeys: [newWindowKey]) == true)
        #expect(state.lockedKey == nil)
    }
}
