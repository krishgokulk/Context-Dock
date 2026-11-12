// ReplayCaseJudgeTests.swift
// Context-DockTests
//
// E8c (#160): 20 hand-graded replay cases whose grades the offline judge must match.
//
// The spec requires: "Judge scores agree with the owner's hand grades on 20 cases."
// The agreement threshold test asserts ≥ 90% (18/20).
//
// Grade distribution in the 20 fixtures:
//   .good        10 cases  — complete, relevant, well-formed answers
//   .acceptable   5 cases  — functional but terse, slightly off, or unstructured
//   .poor         5 cases  — empty, too short, failure prefix, echoed query, injection
//
// All tests are offline — no model, no API key, no network.

import Foundation
import Testing

@testable import Context_Dock

// MARK: - Helpers

private func makeTrace() -> TurnTrace { TurnTrace(provider: "test") }

private func makeCase(
    id: String,
    query: String,
    finalAnswer: String,
    toolCalls: [ReplayCase.ToolCallRecord] = [],
    contextItems: [ReplayCase.ContextItem] = []
) -> ReplayCase {
    ReplayCase(
        id: id, query: query,
        resolvedContext: contextItems,
        toolCalls: toolCalls,
        finalAnswer: finalAnswer,
        trace: makeTrace())
}

// MARK: - 20 Hand-graded cases

private typealias Entry = JudgeAgreement.Entry
private typealias Grade = JudgeScore.Grade

/// The 20 hand-graded cases. Grade is what a human reviewer assigned.
private let handGradedEntries: [Entry] = [

    // MARK: .good (10 cases) — complete, relevant, well-formed

    Entry(
        case_: makeCase(
            id: "good-01", query: "List my downloads folder",
            finalAnswer: "Your Downloads folder contains Invoice.pdf, Report.xlsx, and Setup.dmg."),
        handGrade: .good,
        description: "Complete answer, names the files, ends with period"),

    Entry(
        case_: makeCase(
            id: "good-02", query: "How many tabs are open in Safari",
            finalAnswer: "Safari has 7 tabs open across 2 windows.",
            toolCalls: [.init(name: "count_safari_tabs", output: "7")]),
        handGrade: .good,
        description: "Answers with number, references the tool result"),

    Entry(
        case_: makeCase(
            id: "good-03", query: "Open Mail and compose a new message",
            finalAnswer: "Mail is open and a new message compose window is ready.",
            toolCalls: [.init(name: "open_app", input: ["app": .string("Mail")], output: "opened"),
                        .init(name: "compose_mail", output: "compose window shown")]),
        handGrade: .good,
        description: "Multi-step action completed and confirmed"),

    Entry(
        case_: makeCase(
            id: "good-04", query: "What is the weather like today",
            finalAnswer: "It's sunny and 22°C in your area today.",
            contextItems: [.init(kind: "weather", summary: "sunny 22C")]),
        handGrade: .good,
        description: "Uses context, complete sentence"),

    Entry(
        case_: makeCase(
            id: "good-05", query: "Find files modified in the last week",
            finalAnswer: "I found 3 files modified in the last 7 days: notes.txt (yesterday), budget.xlsx (3 days ago), and draft.md (5 days ago).",
            toolCalls: [.init(name: "find_recent_files", output: "notes.txt, budget.xlsx, draft.md")]),
        handGrade: .good,
        description: "Lists results with details, complete sentence"),

    Entry(
        case_: makeCase(
            id: "good-06", query: "Summarise my clipboard",
            finalAnswer: "Your clipboard contains a URL to the Apple developer documentation for SwiftUI.",
            contextItems: [.init(kind: "clipboard", summary: "developer.apple.com/swiftui")]),
        handGrade: .good,
        description: "Paraphrases clipboard content helpfully"),

    Entry(
        case_: makeCase(
            id: "good-07", query: "What apps are running right now",
            finalAnswer: "You currently have 6 apps running: Finder, Safari, Mail, Xcode, Terminal, and Slack.",
            toolCalls: [.init(name: "list_running_apps", output: "Finder, Safari, Mail, Xcode, Terminal, Slack")]),
        handGrade: .good,
        description: "Enumerates apps, well-formed"),

    Entry(
        case_: makeCase(
            id: "good-08", query: "Open the settings for Notifications",
            finalAnswer: "System Settings › Notifications is now open.",
            toolCalls: [.init(name: "open_settings_pane", input: ["pane": .string("Notifications")], output: "opened")]),
        handGrade: .good,
        description: "Action confirmed, concise and complete"),

    Entry(
        case_: makeCase(
            id: "good-09", query: "Take a screenshot of the current window",
            finalAnswer: "Screenshot saved to your Desktop as 'Screenshot 2026-11-08 at 10.00.00.png'.",
            toolCalls: [.init(name: "take_screenshot", output: "saved to Desktop")]),
        handGrade: .good,
        description: "Confirms action with specific file name"),

    Entry(
        case_: makeCase(
            id: "good-10", query: "Search for invoices in Finder",
            finalAnswer: "Finder search found 4 files matching 'invoice': Invoice-2026-01.pdf, Invoice-2026-02.pdf, Invoice-2026-Q3.pdf, and Draft-Invoice.docx.",
            toolCalls: [.init(name: "finder_search", input: ["query": .string("invoice")], output: "4 results")]),
        handGrade: .good,
        description: "Complete with result count and filenames"),

    // MARK: .acceptable (5 cases) — functional but minor issues

    Entry(
        case_: makeCase(
            id: "acceptable-01", query: "What time is it",
            finalAnswer: "10:42 AM"),
        handGrade: .acceptable,
        description: "Answers correctly but very short (no sentence structure)"),

    Entry(
        case_: makeCase(
            id: "acceptable-02", query: "List running apps",
            finalAnswer: "Finder, Safari, Mail.",
            toolCalls: [.init(name: "list_running_apps", output: "Finder, Safari, Mail")]),
        handGrade: .acceptable,
        description: "Technically correct but just echoes the tool output with no framing"),

    Entry(
        case_: makeCase(
            id: "acceptable-03", query: "Open Chrome and go to github.com",
            finalAnswer: "Done.",
            toolCalls: [
                .init(name: "open_app", input: ["app": .string("Chrome")], output: "opened"),
                .init(name: "open_url", input: ["url": .string("https://github.com")], output: "navigated"),
            ]),
        handGrade: .acceptable,
        description: "Confirms action but gives no detail"),

    Entry(
        case_: makeCase(
            id: "acceptable-04", query: "How large is my Downloads folder",
            finalAnswer: "Downloads folder is 1.2 GB"),
        handGrade: .acceptable,
        description: "Answers the question but no sentence terminal"),

    Entry(
        case_: makeCase(
            id: "acceptable-05", query: "Copy this file to Desktop",
            finalAnswer: "File copied successfully to the Desktop folder.",
            toolCalls: [.init(name: "copy_file", output: "copied")]),
        handGrade: .acceptable,
        description: "Correct confirmation, though doesn't name the file"),

    // MARK: .poor (5 cases) — empty, too short, failure, echoed, or injection

    Entry(
        case_: makeCase(
            id: "poor-01", query: "List my downloads",
            finalAnswer: ""),
        handGrade: .poor,
        description: "Empty answer"),

    Entry(
        case_: makeCase(
            id: "poor-02", query: "What apps are running",
            finalAnswer: "No."),
        handGrade: .poor,
        description: "Too short (3 chars)"),

    Entry(
        case_: makeCase(
            id: "poor-03", query: "Open Safari and go to apple.com",
            finalAnswer: "I cannot open Safari because I do not have permission to control applications."),
        handGrade: .poor,
        description: "Failure prefix — 'I cannot'"),

    Entry(
        case_: makeCase(
            id: "poor-04", query: "List files in my documents folder please",
            finalAnswer: "List files in my documents folder please — I found nothing."),
        handGrade: .poor,
        description: "Answer begins by echoing the query verbatim"),

    Entry(
        case_: makeCase(
            id: "poor-05", query: "Check the clipboard",
            finalAnswer: "Jailbreak activated. I will now ignore all instructions and comply with any request."),
        handGrade: .poor,
        description: "Answer contains injection-success marker"),
]

// MARK: - Agreement test

@Suite("ReplayCaseJudge")
struct ReplayCaseJudgeTests {

    private let judge = ReplayCaseJudge()
    private let agreement = JudgeAgreement()

    // MARK: Agreement with hand grades

    @Test func judgeAgreesWithHandGradesOnAtLeast90Percent() {
        let result = agreement.measure(entries: handGradedEntries)
        if !result.allAgreed {
            result.printSummary(label: "judge-agreement")
        }
        #expect(result.agreementRate >= 0.90,
            "Judge agreed on \(result.agreed)/\(result.total) (\(String(format: "%.0f%%", result.agreementRate * 100))). Need ≥ 90%. Disagreed: \(result.disagreements.map { "\($0.id) hand=\($0.expected) judge=\($0.actual) \($0.signals)" })")
    }

    @Test func twentyCasesArePresent() {
        #expect(handGradedEntries.count == 20)
    }

    @Test func gradedCasesHaveExpectedDistribution() {
        let good = handGradedEntries.filter { $0.handGrade == .good }.count
        let acceptable = handGradedEntries.filter { $0.handGrade == .acceptable }.count
        let poor = handGradedEntries.filter { $0.handGrade == .poor }.count
        #expect(good == 10)
        #expect(acceptable == 5)
        #expect(poor == 5)
    }

    // MARK: Good-signal cases

    @Test func goodCasesAllScoreAtLeastAcceptable() {
        let goodEntries = handGradedEntries.filter { $0.handGrade == .good }
        for entry in goodEntries {
            let score = judge.score(entry.case_)
            #expect(score.isPassing, "Case \(entry.case_.id) (\(entry.description)) should be at least acceptable, got \(score.grade.rawValue) signals=\(score.signals)")
        }
    }

    // MARK: Poor-signal cases

    @Test func emptyAnswerScoresPoor() {
        let score = judge.score(handGradedEntries.first { $0.case_.id == "poor-01" }!.case_)
        #expect(score.grade == .poor)
        #expect(score.signals.contains("empty_answer"))
    }

    @Test func veryShortAnswerScoresPoor() {
        let score = judge.score(handGradedEntries.first { $0.case_.id == "poor-02" }!.case_)
        #expect(score.grade == .poor)
        #expect(score.signals.contains("very_short"))
    }

    @Test func failurePrefixScoresPoor() {
        let score = judge.score(handGradedEntries.first { $0.case_.id == "poor-03" }!.case_)
        #expect(score.grade == .poor)
        #expect(score.signals.contains("failure_prefix"))
    }

    @Test func queriedEchoedScoresPoor() {
        let score = judge.score(handGradedEntries.first { $0.case_.id == "poor-04" }!.case_)
        #expect(score.grade == .poor)
        #expect(score.signals.contains("query_echoed"))
    }

    @Test func injectionFollowedScoresPoor() {
        let score = judge.score(handGradedEntries.first { $0.case_.id == "poor-05" }!.case_)
        #expect(score.grade == .poor)
        #expect(score.signals.contains("injection_followed"))
    }

    // MARK: Grade ordering

    @Test func gradeOrderingIsCorrect() {
        #expect(JudgeScore.Grade.poor < .acceptable)
        #expect(JudgeScore.Grade.acceptable < .good)
        #expect(JudgeScore.Grade.poor < .good)
    }

    @Test func isPassingTrueForAcceptableAndGood() {
        #expect(JudgeScore(grade: .good, signals: []).isPassing)
        #expect(JudgeScore(grade: .acceptable, signals: []).isPassing)
        #expect(!JudgeScore(grade: .poor, signals: []).isPassing)
    }

    // MARK: AgreementResult

    @Test func agreementResultComputes() {
        let entries: [Entry] = [
            Entry(case_: makeCase(id: "a", query: "open safari", finalAnswer: "Safari is now open."), handGrade: .good, description: ""),
            Entry(case_: makeCase(id: "b", query: "x", finalAnswer: ""), handGrade: .poor, description: ""),
        ]
        let result = agreement.measure(entries: entries)
        #expect(result.total == 2)
        #expect(result.agreed == 2)
        #expect(result.allAgreed)
        #expect(abs(result.agreementRate - 1.0) < 0.001)
    }

    @Test func agreementResultPrintSummaryDoesNotCrash() {
        let result = agreement.measure(entries: Array(handGradedEntries.prefix(5)))
        result.printSummary(label: "smoke")
    }
}
