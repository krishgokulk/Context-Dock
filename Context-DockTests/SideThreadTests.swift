// SideThreadTests.swift
// Context-DockTests
//
// Unit tests for Task UI/UX 3/5 (#333): Side Thread (branch a sub-conversation).

import Foundation
import Testing

@testable import Context_Dock

@Suite("Side Thread Sub-Conversation (#333)", .serialized)
@MainActor
struct SideThreadTests {

    @Test("SideThreadState lifecycle and snippet extraction")
    func stateAndSnippetExtraction() {
        let emptyState = SideThreadState(
            parentTurnSnippet: "Parent context",
            parentScopeKey: "app:com.apple.Safari"
        )
        #expect(emptyState.isEmpty)
        #expect(emptyState.turnCount == 0)
        #expect(emptyState.parentTurnSnippet == "Parent context")
        #expect(emptyState.parentScopeKey == "app:com.apple.Safari")

        // Single-line snippet
        let msg1 = AIChatMessage(role: .assistant, content: "Safari found 3 open tabs about Swift Testing.")
        #expect(SideThreadSummarizer.extractTurnSnippet(from: msg1, maxLength: 50) == "Safari found 3 open tabs about Swift Testing.")

        // Multi-line snippet uses the first non-empty line
        let msg2 = AIChatMessage(
            role: .assistant,
            content: "\n\nFirst line summary\nSecond line details that should not be in the snippet."
        )
        #expect(SideThreadSummarizer.extractTurnSnippet(from: msg2, maxLength: 50) == "First line summary")

        // Long snippet is truncated cleanly with ellipsis
        let longText = String(repeating: "A", count: 100)
        let msg3 = AIChatMessage(role: .assistant, content: longText)
        let snippet = SideThreadSummarizer.extractTurnSnippet(from: msg3, maxLength: 30)
        #expect(snippet.count == 30)
        #expect(snippet.hasSuffix("…"))
    }

    @Test("SideThreadSummarizer generates structured fold-back markdown summary")
    func summarizerFoldBackFormat() {
        let parentSnippet = "Here are the top 3 restaurants in San Francisco"
        let userQ = AIChatMessage(role: .user, content: "Are any of them vegetarian?")
        let assistantA = AIChatMessage(role: .assistant, content: "Yes, Greens Restaurant in Fort Mason is 100% vegetarian.")

        let summary = SideThreadSummarizer.generateFoldBackSummary(
            parentSnippet: parentSnippet,
            messages: [userQ, assistantA]
        )

        #expect(summary.contains("📌 **Side Thread Summary**"))
        #expect(summary.contains("branched from: “Here are the top 3 restaurants in San Francisco”"))
        #expect(summary.contains("Q:** Are any of them vegetarian?"))
        #expect(summary.contains("A:** Yes, Greens Restaurant in Fort Mason is 100% vegetarian."))

        // Empty side thread fallback
        let emptySummary = SideThreadSummarizer.generateFoldBackSummary(
            parentSnippet: "Main topic",
            messages: []
        )
        #expect(emptySummary.contains("Side conversation concluded with no additional findings."))
    }

    @Test("AppChatConversation branching, message isolation, discard, and fold-back")
    func appChatConversationBranching() {
        let conv = AppChatConversation.shared
        conv.scopeBundleId = "com.apple.Safari"
        conv.scopeAppName = "Safari"
        conv.messages = [
            AIChatMessage(role: .user, content: "What is on this webpage?"),
            AIChatMessage(role: .assistant, content: "This is the documentation for Apple Silicon GPU architecture.")
        ]
        conv.activeSideThread = nil

        // 1. Branch side thread from last turn
        conv.branchSideThread(from: conv.messages.last)
        #expect(conv.activeSideThread != nil)
        #expect(conv.activeSideThread?.parentTurnSnippet.contains("Apple Silicon GPU") == true)
        #expect(conv.activeSideThread?.parentScopeKey == "app:com.apple.Safari")
        #expect(conv.activeSideThread?.isEmpty == true)

        // 2. Add side thread turn — main messages MUST NOT change
        let sideUserMsg = AIChatMessage(role: .user, content: "Does it support ray tracing?")
        let sideAssistantMsg = AIChatMessage(role: .assistant, content: "Yes, starting with the M3 family.")
        conv.activeSideThread?.messages.append(sideUserMsg)
        conv.activeSideThread?.messages.append(sideAssistantMsg)

        #expect(conv.messages.count == 2, "Main transcript must not be polluted by side thread messages")
        #expect(conv.activeSideThread?.turnCount == 2)

        // 3. Test Discard
        conv.discardSideThread()
        #expect(conv.activeSideThread == nil)
        #expect(conv.messages.count == 2, "Discarding leaves main transcript completely untouched")

        // 4. Branch again and Fold Back
        conv.branchSideThread(from: conv.messages.last)
        conv.activeSideThread?.messages.append(sideUserMsg)
        conv.activeSideThread?.messages.append(sideAssistantMsg)
        conv.foldBackSideThread()

        #expect(conv.activeSideThread == nil)
        #expect(conv.messages.count == 3, "Fold back appends exactly one summary turn to the main transcript")
        let lastMsg = conv.messages.last
        #expect(lastMsg?.role == .assistant)
        #expect(lastMsg?.content.contains("📌 **Side Thread Summary**") == true)
        #expect(lastMsg?.content.contains("M3 family") == true)
    }

    @Test("GeneralChatWindowModel branching, discard, fold-back, and scope isolation")
    func generalChatWindowModelBranching() {
        let model = GeneralChatWindowModel.shared
        model.openGeneralSession()
        model.messages = [
            AIChatMessage(role: .user, content: "Plan a trip to Japan"),
            AIChatMessage(role: .assistant, content: "Here is a 7-day itinerary for Tokyo and Kyoto.")
        ]
        model.activeSideThread = nil

        // Branch
        model.branchSideThread(from: model.messages.last)
        #expect(model.activeSideThread != nil)
        #expect(model.activeSideThread?.parentTurnSnippet.contains("Tokyo and Kyoto") == true)

        // Side turns
        let q = AIChatMessage(role: .user, content: "Do I need a rail pass?")
        let a = AIChatMessage(role: .assistant, content: "For Tokyo-Kyoto round trip, individual Shinkansen tickets are often cheaper.")
        model.activeSideThread?.messages = [q, a]

        #expect(model.messages.count == 2)

        // Scope switch resets active side thread to avoid leaking across scopes
        model.openSession(.app(bundleId: "com.apple.Notes"), title: "Notes")
        #expect(model.activeSideThread == nil)

        // Return to general session and fold back
        model.openGeneralSession()
        model.messages = [
            AIChatMessage(role: .user, content: "Plan a trip to Japan"),
            AIChatMessage(role: .assistant, content: "Here is a 7-day itinerary for Tokyo and Kyoto.")
        ]
        model.branchSideThread(from: model.messages.last)
        model.activeSideThread?.messages = [q, a]
        model.foldBackSideThread()

        #expect(model.activeSideThread == nil)
        #expect(model.messages.count == 3)
        #expect(model.messages.last?.content.contains("Shinkansen") == true)
    }

    @Test("DockKeyMap shortcuts reference includes chat.sideThread")
    func keysOverlayIncludesSideThread() {
        let bindings = DockKeyMap.allBindings()
        let sideThreadBinding = bindings.first { $0.id == "chat.sideThread" }
        #expect(sideThreadBinding != nil)
        #expect(sideThreadBinding?.surface == .chatAndClipboard)
        #expect(sideThreadBinding?.keys == ["⌥", "S"])
    }
}
