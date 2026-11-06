// LivePanelDetailModeTests.swift
// Context-DockTests
//
// Tests for Live-panel detail modes (Summary / Normal / Verbose) (Issue #331).

import Foundation
import Testing
import SwiftUI

@testable import Context_Dock

@Suite("Live-Panel Detail Modes (#331)")
@MainActor
struct LivePanelDetailModeTests {

    @Test("Detail mode cases, system images, and descriptions")
    func detailModeProperties() {
        #expect(LivePanelDetailMode.allCases == [.summary, .normal, .verbose])
        #expect(LivePanelDetailMode.summary.rawValue == "Summary")
        #expect(LivePanelDetailMode.normal.rawValue == "Normal")
        #expect(LivePanelDetailMode.verbose.rawValue == "Verbose")

        #expect(!LivePanelDetailMode.summary.systemImage.isEmpty)
        #expect(!LivePanelDetailMode.normal.systemImage.isEmpty)
        #expect(!LivePanelDetailMode.verbose.systemImage.isEmpty)

        #expect(LivePanelDetailMode.summary.helpDescription.contains("Headline"))
        #expect(LivePanelDetailMode.normal.helpDescription.contains("Standard"))
        #expect(LivePanelDetailMode.verbose.helpDescription.contains("Expanded"))
    }

    @Test("Headline extraction cleans markdown headers and prefixes")
    func headlineExtractionMarkdown() {
        let h1 = "# Document exported successfully\nHere are the details."
        #expect(LivePanelDetailMode.headline(from: h1) == "Document exported successfully")

        let h2 = "### 2. Converted PDF to Images\nNext steps follow."
        #expect(LivePanelDetailMode.headline(from: h2) == "2. Converted PDF to Images")

        let bold = "**Result:** All 5 tasks completed on schedule."
        #expect(LivePanelDetailMode.headline(from: bold).contains("Result: All 5 tasks completed"))

        let bullet = "- Export completed without errors."
        #expect(LivePanelDetailMode.headline(from: bullet) == "Export completed without errors.")
    }

    @Test("Headline extraction strips leaked tool calls (per #316)")
    func headlineStripsLeakedToolOutput() {
        let leaked = """
        run_command(command: "ls -la")
        Found 12 matching items in the project directory.
        """
        let extracted = LivePanelDetailMode.headline(from: leaked)
        #expect(!extracted.contains("run_command"))
        #expect(extracted.contains("Found 12 matching items"))
    }

    @Test("Headline truncation handles long outputs gracefully")
    func headlineTruncation() {
        let long = "This is an extremely long response line that goes on and on with multiple descriptive sentences explaining everything that happened during the process of converting various documents into their corresponding final output formats."
        let extracted = LivePanelDetailMode.headline(from: long)
        #expect(extracted.count <= 120)
        #expect(extracted.hasSuffix("…") || extracted.hasSuffix("."))
    }

    @Test("Headline empty content returns fallback")
    func headlineEmptyContentFallback() {
        #expect(LivePanelDetailMode.headline(from: "") == "Response completed")
        #expect(LivePanelDetailMode.headline(from: "   \n\n  ") == "Response completed")
    }

    @Test("Verdict calculation with error")
    func verdictError() {
        let (text, isSuccess, symbol) = LivePanelDetailMode.verdict(
            evaluation: nil, receipts: [], isError: true)
        #expect(text == "Failed")
        #expect(!isSuccess)
        #expect(symbol == "xmark.circle.fill")
    }

    @Test("Verdict calculation with subjective evaluation")
    func verdictSubjectiveEvaluation() {
        let passEval = SubjectiveEvaluation(verdict: .pass, summary: "Looks clean", issues: [])
        let (passText, passSuccess, passSymbol) = LivePanelDetailMode.verdict(
            evaluation: passEval, receipts: [], isError: false)
        #expect(passText == "Review: Passed")
        #expect(passSuccess)
        #expect(passSymbol == "checkmark.shield.fill")

        let revisionEval = SubjectiveEvaluation(verdict: .needsRevision, summary: "Needs rework", issues: ["Missing title"])
        let (revText, revSuccess, revSymbol) = LivePanelDetailMode.verdict(
            evaluation: revisionEval, receipts: [], isError: false)
        #expect(revText == "Review: Needs revision")
        #expect(!revSuccess)
        #expect(revSymbol == "exclamationmark.shield.fill")
    }

    @Test("Verdict calculation with evidence receipts")
    func verdictEvidenceReceipts() {
        let r1 = DoraXActionReceipt(command: "menu.click", output: "ok", success: true)
        let r2 = DoraXActionReceipt(command: "verify.state", output: "exported", success: true, isVerification: true)

        let (allPassText, allPassSuccess, _) = LivePanelDetailMode.verdict(
            evaluation: nil, receipts: [r1, r2], isError: false)
        #expect(allPassText == "Verified (2 receipts)")
        #expect(allPassSuccess)

        let r3Failed = DoraXActionReceipt(command: "save", output: "permission denied", success: false)
        let (failText, failSuccess, failSymbol) = LivePanelDetailMode.verdict(
            evaluation: nil, receipts: [r1, r3Failed], isError: false)
        #expect(failText == "1 of 2 failed")
        #expect(!failSuccess)
        #expect(failSymbol == "xmark.circle.fill")
    }

    @Test("Summary card and mode picker can be instantiated")
    func summaryCardAndModePickerInitialization() {
        var mode = LivePanelDetailMode.summary
        let binding = Binding(get: { mode }, set: { mode = $0 })

        let picker = LivePanelDetailModePicker(mode: binding, compact: true)
        #expect(picker.compact)

        let card = LivePanelSummaryCard(
            headline: "Exported successfully",
            verdictText: "Verified (1 receipt)",
            isSuccess: true,
            verdictSymbol: "checkmark.seal.fill",
            evaluationNote: "All tests green",
            receiptCount: 1,
            detailMode: binding
        )
        #expect(card.headline == "Exported successfully")
        #expect(card.isSuccess)
    }

    @Test("AIChatMessageView initializes with detail modes")
    func messageViewDetailModes() {
        let message = AIChatMessage(
            role: .assistant,
            content: "# Summary Headline\nDetailed content line that should be hidden in summary mode.",
            evidenceReceipts: [
                DoraXActionReceipt(command: "echo test", output: "test", success: true)
            ]
        )

        let viewSummary = AIChatMessageView(message: message, initialDetailMode: .summary)
        #expect(viewSummary.initialDetailMode == .summary)

        let viewNormal = AIChatMessageView(message: message, initialDetailMode: .normal)
        #expect(viewNormal.initialDetailMode == .normal)

        let viewVerbose = AIChatMessageView(message: message, initialDetailMode: .verbose)
        #expect(viewVerbose.initialDetailMode == .verbose)
    }

    @Test("ActivityRows supports initially expanded for verbose mode")
    func activityRowsInitiallyExpanded() {
        let step = ActivityStep(kind: .command, title: "Export file", status: .ok)
        let rowsCollapsed = ActivityRows(steps: [step], isInitiallyExpanded: false)
        #expect(!rowsCollapsed.isInitiallyExpanded)

        let rowsExpanded = ActivityRows(steps: [step], isInitiallyExpanded: true)
        #expect(rowsExpanded.isInitiallyExpanded)
    }
}
