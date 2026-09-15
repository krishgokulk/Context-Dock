import Foundation
import Testing

@testable import Context_Dock

@Suite("Integration selection")
struct IntegrationSelectionTests {
    @Test func removedSelectionFallsForwardThenBack() {
        var state = IntegrationSelectionState(scope: .apps, selectedAppID: "b")
        state.reconcile(availableAppIDs: ["a", "b", "c"])
        state.reconcile(availableAppIDs: ["a", "c"])
        #expect(state.selectedAppID == "c")
        state.reconcile(availableAppIDs: ["a"])
        #expect(state.selectedAppID == "a")
    }

    @Test func emptyAppsClearsSelectionWithoutChangingScope() {
        var state = IntegrationSelectionState(scope: .apps, selectedAppID: "a")
        state.reconcile(availableAppIDs: [])
        #expect(state.scope == .apps)
        #expect(state.selectedAppID == nil)
    }

    @Test func firstAppIsSelectedWhenNothingWasSelected() {
        var state = IntegrationSelectionState(scope: .apps)
        state.reconcile(availableAppIDs: ["a", "b"])
        #expect(state.selectedAppID == "a")
    }

    @Test func survivingSelectionIsNeverReassigned() {
        var state = IntegrationSelectionState(scope: .apps, selectedAppID: "c")
        state.reconcile(availableAppIDs: ["a", "b", "c"])
        state.reconcile(availableAppIDs: ["c", "a"])
        #expect(state.selectedAppID == "c")
    }

    @Test func destinationAppliesScopeBundleTabAndFocus() {
        var state = IntegrationSelectionState(scope: .apps)
        state.apply(
            IntegrationDestination(
                scope: .global,
                tab: .resources,
                focus: .cliTools))
        #expect(state.scope == .global)
        #expect(state.tab == .resources)
        #expect(state.focus == .cliTools)
    }
}
