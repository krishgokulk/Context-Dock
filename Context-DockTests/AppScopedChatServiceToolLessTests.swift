// AppScopedChatServiceToolLessTests.swift
// Context-DockTests
//
// Todo 7 of docs/superpowers/plans/2026-09-10-agentic-capability-parity.md.
//
// A scoped chat under a tool-less provider — Apple Intelligence, or Claude Code, which
// DoraX deliberately runs with none of its own tools — got exactly one turn: no capability
// catalogue, no way to ask for a second read. A question needing one hop of evidence
// ("what's on my clipboard, and does it look like an email?") failed outright, with the
// model guessing at a permission system that does not exist. General Chat had already
// solved this with a prose "ask, run, re-ask" loop; `runToolLessScopedTurn` gives the scoped
// surface the same one. These cover the two pieces of it that are pure enough to test
// without a live provider — this suite runs with no API key and no network.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Scoped chat, tool-less provider loop")
struct AppScopedChatServiceToolLessTests {

    // MARK: - Which scope the loop searches and executes under

    @Test("An app scope reaches its own capabilities and no other app's")
    func appScopeIsExact() {
        let scope = AppScopedChatService.conversationScope(
            routingBundleId: "com.apple.Safari", appName: "Safari")
        #expect(scope == .contextDock(bundleID: "com.apple.Safari", appName: "Safari"))
    }

    @Test("A scope the router could not resolve to one app still gets a search, not nothing")
    func unresolvedScopeFallsBackToGeneralRatherThanNoCapabilitiesAtAll() {
        // A CLI tool or a bare thread has no bundle id to gate on. Before this loop
        // existed, that meant zero capability access under a tool-less provider — `.general`
        // here is strictly more than that, never a narrowing of anything that worked before.
        #expect(
            AppScopedChatService.conversationScope(routingBundleId: nil, appName: "brew")
                == .general)
        #expect(
            AppScopedChatService.conversationScope(routingBundleId: "", appName: "brew")
                == .general)
    }

    // MARK: - What the model is told after a capability call returns

    @Test("The result is stated as real, not as something to reconsider")
    func theFollowUpAssertsAccessRatherThanAskingAboutIt() {
        let note = AppScopedChatService.toolResultFollowUp(
            originalQuery: "what's on my clipboard?",
            label: "clipboard.read",
            output: "Clipboard contains: a phone number",
            success: true)

        #expect(note.contains("clipboard.read"))
        #expect(note.contains("REAL data"))
        #expect(note.contains("you are connected to it"))
        #expect(note.contains("a phone number"))
        // The user's own words survive into the follow-up, so the model answers the
        // question that was asked rather than drifting onto the tool result as its own
        // topic.
        #expect(note.contains(#""what's on my clipboard?""#))
    }

    @Test("An empty result is an answer, not an invitation to guess")
    func anEmptyResultIsNamedAsSuchNotHidden() {
        let note = AppScopedChatService.toolResultFollowUp(
            originalQuery: "what's on my clipboard?",
            label: "clipboard.read",
            output: "   ",
            success: true)
        #expect(note.contains("no items were returned"))
        #expect(note.contains("not that you lack access"))
    }

    @Test("A failed call is marked failed, not folded into an ordinary result")
    func aFailureIsLabelled() {
        let note = AppScopedChatService.toolResultFollowUp(
            originalQuery: "turn on dark mode",
            label: "system.appearance.set",
            output: "Permission denied",
            success: false)
        #expect(note.contains("FAILED"))
        #expect(note.contains("Permission denied"))
    }

    @Test("A very long result is capped rather than sent whole")
    func longOutputIsTruncated() {
        let huge = String(repeating: "x", count: 20_000)
        let note = AppScopedChatService.toolResultFollowUp(
            originalQuery: "read this file", label: "files.read", output: huge, success: true)
        // 8_000 characters of the payload, plus the surrounding prose — comfortably under
        // sending the whole thing.
        #expect(note.count < 8_500)
    }
}
