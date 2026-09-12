import Foundation
import Testing
@testable import Context_Dock

@MainActor
struct CornerGlobalContextParityTests {
    private func pill(_ index: Int, enabled: Bool = true, execute: @escaping () -> Void = {}) -> DockPill {
        var row = DockPill(id: "history-\(index)", name: "Page \(index)", icon: "globe", badge: "example.com", execute: execute)
        row.isEnabled = enabled
        row.resolvedURL = URL(string: "https://example.com/\(index)")
        row.menuContext = "Yesterday"
        return row
    }

    @Test func scopedQueryUsesAllDockRowsAndKeepsCompactHeight() {
        let source = GlobalContextResultSource()
        let expected = (0..<20).map { pill($0) }
        var receivedQuery = ""
        source.scopedResults = { query, _, _ in
            receivedQuery = query
            return query.isEmpty ? [] : expected
        }
        let model = AppChatPromptModel(conversation: AppChatConversation(), globalResultSource: source)
        model.summonGlobalContext()
        model.query = "safari history"
        model.updateMenuMatches()
        #expect(receivedQuery == "safari history")
        #expect(model.rows.map(\.title) == expected.map(\.name))
        #expect(model.listRowCount == 5)
        for _ in 0..<20 { #expect(model.moveMenuFocus(by: 1)) }
        #expect(model.focusedRow?.title == "Page 19")
        if case .dock(let row) = model.rows[0] {
            #expect(row.resolvedURL == expected[0].resolvedURL)
            #expect(row.menuContext == "Yesterday")
        } else { Issue.record("Expected the dock's original result") }
    }

    @Test func bareGlobalQueryUsesDockPureGlobalRowsBeforeGenericDocuments() {
        let source = GlobalContextResultSource()
        let expected = [pill(1), pill(2)]
        source.pureGlobalResults = { query in
            query == "quit" ? expected : []
        }
        source.scopedResults = { _, _, _ in [pill(99)] }
        let model = AppChatPromptModel(conversation: AppChatConversation(), globalResultSource: source)

        model.summonGlobalContext()
        model.query = "quit"
        model.updateMenuMatches()

        #expect(model.rows.map(\.title) == ["Page 1", "Page 2"])
    }

    @Test func tabRunsTheDockActionAndDisabledRowsDoNotRun() {
        let source = GlobalContextResultSource()
        var executions = 0
        let enabled = pill(1) { executions += 1 }
        source.scopedResults = { query, _, _ in query.isEmpty ? [] : [enabled] }
        let model = AppChatPromptModel(conversation: AppChatConversation(), globalResultSource: source)
        model.summonGlobalContext()
        model.query = "safari history"
        model.updateMenuMatches()
        #expect(model.acceptGlobalTopMatch())
        #expect(executions == 1)
        model.run(.dock(pill(2, enabled: false) { executions += 1 }))
        #expect(executions == 1)
    }

    @Test func refreshPreservesFocusedIdentityAndUsesLatestQuery() {
        let source = GlobalContextResultSource()
        let first = pill(1), second = pill(2)
        var results = [first, second]
        source.scopedResults = { query, _, _ in query.isEmpty ? [] : results }
        let model = AppChatPromptModel(conversation: AppChatConversation(), globalResultSource: source)
        model.summonGlobalContext()
        model.query = "safari history"
        model.updateMenuMatches()
        model.moveMenuFocus(by: 1)
        results = [second, first]
        source.refresh()
        #expect(model.focusedRow?.id == "dock:history-1")
        #expect(model.focusedMenuIndex == 1)
        model.query = ""
        source.refresh()
        #expect(model.rows.isEmpty)
    }

    @Test func globalLaunchClearsAnEarlierExtensionScope() {
        let model = AppChatPromptModel(conversation: AppChatConversation(), globalResultSource: GlobalContextResultSource())
        model.returnsToGlobalScope = true
        model.summonGlobalContext()
        #expect(model.isGlobalScope)
        #expect(!model.returnsToGlobalScope)
        #expect(!model.showsExtensionPanel)
    }
}
