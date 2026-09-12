import Foundation
import Testing

@testable import Context_Dock

// Whether an adapter action may run as a read — without a model, without asking.
//
// The root of the blank-note bug, one layer below the guard in AppAdapterManager. ChatRouteResolver
// classified an adapter action as read-only when nobody had declared it dangerous:
// `!isDestructive && !requiresApproval`. New Note is neither, so it was read-only, so
// `unattendedRoute` ran it deterministically before any model, and `executionApproval` would
// have granted it without asking. "How many notes do i have?" created a note.
//
// The guard in AppAdapterManager.refusalReason still stands as defence in depth. This is the
// classification the guard was compensating for.

@MainActor
struct AdapterRouteClassificationTests {

    private func action(
        type: AdapterActionType, requiresApproval: Bool = false, isDestructive: Bool = false
    ) -> AdapterAction {
        AdapterAction(
            id: "test.\(type.rawValue)", name: "Test", icon: "circle",
            description: "", type: type,
            menuPath: type == .menubar ? ["File", "New Note"] : nil,
            script: type == .applescript ? "return \"\"" : nil,
            requiresApproval: requiresApproval, isDestructive: isDestructive)
    }

    /// The reported case. A menu click is a command however harmless its name.
    @Test func aMenuClickIsNeverReadOnly() {
        #expect(!ChatRouteResolver.isReadOnly(action(type: .menubar)))
    }

    /// The counterweight, and why this is not "adapter actions are never read-only": an
    /// AppleScript that returns what is playing is a read, and "what's playing?" depends on it
    /// being one.
    @Test func aScriptThatReadsIsStillReadOnly() {
        #expect(ChatRouteResolver.isReadOnly(action(type: .applescript)))
    }

    /// Declared-dangerous stays out, whatever the type.
    @Test func anythingDeclaredDangerousIsNotReadOnly() {
        #expect(!ChatRouteResolver.isReadOnly(action(type: .applescript, isDestructive: true)))
        #expect(!ChatRouteResolver.isReadOnly(action(type: .applescript, requiresApproval: true)))
    }

    /// The consequence that mattered: a menu click must never be picked as the route that runs
    /// on its own, before any model and before any sheet.
    @Test func aMenuClickIsNeverTheUnattendedRoute() {
        let route = ChatRoute(
            id: "action:test", kind: .adapterAction, title: "New Note", payload: "test",
            appName: "Notes", bundleId: "com.apple.Notes",
            isReadOnly: ChatRouteResolver.isReadOnly(action(type: .menubar)))
        #expect(
            ChatRouteResolver.unattendedRoute([route]) == nil,
            "a menu click ran deterministically as a 'read' and created a note")
    }
}
