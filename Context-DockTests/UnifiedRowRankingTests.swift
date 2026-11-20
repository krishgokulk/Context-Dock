// UnifiedRowRankingTests.swift
// Context-DockTests

import ApplicationServices
import Foundation
import Testing

@testable import Context_Dock

@Suite("Unified row ranking adjustments")
struct UnifiedRowRankingTests {

    // MARK: - Ghost Text

    @Test("Prefix match yields ghost suffix")
    func ghostPrefixMatch() {
        let row = AppChatRow.action(AdapterAction(
            id: "export", name: "Export as PDF", icon: "square.and.arrow.up",
            description: "", triggers: [], type: .menubar))
        let ghost = AppChatRowRanker.ghostText(for: "exp", topRow: row)
        #expect(ghost == "ort as PDF")
    }

    @Test("No prefix match yields nil ghost")
    func ghostNoMatch() {
        let row = AppChatRow.action(AdapterAction(
            id: "save", name: "Save", icon: "square.and.arrow.down",
            description: "", triggers: [], type: .menubar))
        #expect(AppChatRowRanker.ghostText(for: "exp", topRow: row) == nil)
    }

    @Test("Empty query yields nil ghost")
    func ghostEmptyQuery() {
        let row = AppChatRow.action(AdapterAction(
            id: "save", name: "Save", icon: "square.and.arrow.down",
            description: "", triggers: [], type: .menubar))
        #expect(AppChatRowRanker.ghostText(for: "", topRow: row) == nil)
    }

    @Test("Nil row yields nil ghost")
    func ghostNilRow() {
        #expect(AppChatRowRanker.ghostText(for: "exp", topRow: nil) == nil)
    }

    @Test("Exact match yields nil ghost (no suffix left)")
    func ghostExactMatch() {
        let row = AppChatRow.action(AdapterAction(
            id: "save", name: "Save", icon: "square.and.arrow.down",
            description: "", triggers: [], type: .menubar))
        #expect(AppChatRowRanker.ghostText(for: "Save", topRow: row) == nil)
    }

    @Test("Case-insensitive prefix match works")
    func ghostCaseInsensitive() {
        let row = AppChatRow.action(AdapterAction(
            id: "export", name: "Export", icon: "square.and.arrow.up",
            description: "", triggers: [], type: .menubar))
        let ghost = AppChatRowRanker.ghostText(for: "exp", topRow: row)
        #expect(ghost == "ort")
    }

    // MARK: - Conversational Ghost Text

    @Test("Conversational query with no match yields Ask Dora ghost")
    func conversationalGhost() {
        let ghost = AppChatRowRanker.conversationalGhostText(
            for: "how to fix this", intent: .conversational, hasHighConfidenceMatch: false)
        #expect(ghost == " \u{2014} Ask Dora (\u{21B5})")
    }

    @Test("Conversational query with high confidence match yields nil")
    func conversationalHighConfidence() {
        let ghost = AppChatRowRanker.conversationalGhostText(
            for: "how to fix this", intent: .conversational, hasHighConfidenceMatch: true)
        #expect(ghost == nil)
    }

    @Test("Navigational query yields nil conversational ghost")
    func navigationalNoConversationalGhost() {
        let ghost = AppChatRowRanker.conversationalGhostText(
            for: "safari", intent: .navigational, hasHighConfidenceMatch: false)
        #expect(ghost == nil)
    }

    @Test("Web research query with no match yields Ask Dora ghost")
    func webResearchGhost() {
        let ghost = AppChatRowRanker.conversationalGhostText(
            for: "vim vs emacs", intent: .webResearch, hasHighConfidenceMatch: false)
        #expect(ghost != nil)
    }

    @Test("Empty query yields nil conversational ghost")
    func emptyConversationalGhost() {
        let ghost = AppChatRowRanker.conversationalGhostText(
            for: "", intent: .conversational, hasHighConfidenceMatch: false)
        #expect(ghost == nil)
    }

    // MARK: - Unified Adjustments

    @Test("Conversational intent penalises file rows")
    func conversationalFilePenalty() {
        let fileRow = AppChatRow.file(URL(fileURLWithPath: "/tmp/fix.log"))
        let actionRow = AppChatRow.action(AdapterAction(
            id: "fix", name: "Fix Issue", icon: "wrench",
            description: "", triggers: [], type: .menubar))
        let rows = [fileRow, actionRow]
        let adjusted = AppChatRowRanker.applyUnifiedAdjustments(
            to: rows, query: "how to fix", intent: .conversational)
        #expect(adjusted.first?.id == actionRow.id)
    }

    @Test("Explicit file intent boosts file rows")
    func explicitFileBoost() {
        let fileRow = AppChatRow.file(URL(fileURLWithPath: "/tmp/resume.pdf"))
        let actionRow = AppChatRow.action(AdapterAction(
            id: "resume", name: "Resume Task", icon: "play",
            description: "", triggers: [], type: .menubar))
        let rows = [actionRow, fileRow]
        let adjusted = AppChatRowRanker.applyUnifiedAdjustments(
            to: rows, query: "resume.pdf", intent: .explicitFile)
        #expect(adjusted.first?.isFile == true)
    }

    @Test("Navigational intent does not penalise files")
    func navigationalNoPenalty() {
        let fileRow = AppChatRow.file(URL(fileURLWithPath: "/tmp/notes.txt"))
        let rows = [fileRow]
        let adjusted = AppChatRowRanker.applyUnifiedAdjustments(
            to: rows, query: "notes", intent: .navigational)
        #expect(adjusted.first?.isFile == true)
    }

    @Test("Empty rows returns empty")
    func emptyAdjustments() {
        let adjusted = AppChatRowRanker.applyUnifiedAdjustments(
            to: [], query: "test", intent: .navigational)
        #expect(adjusted.isEmpty)
    }

    // MARK: - Frontmost Boost in rank()

    @MainActor
    @Test("Frontmost bundle ID applies boost to commands")
    func frontmostBoostInRank() {
        let item = AXMenuItem(
            title: "Save", path: ["File", "Save"], isEnabled: true,
            element: AXUIElementCreateSystemWide(), children: [])
        let rows = AppChatRowRanker.rank(
            commands: [item], actions: [], query: "save", limit: 5,
            frontmostBundleID: "com.example.app")
        #expect(!rows.isEmpty)
    }
}
