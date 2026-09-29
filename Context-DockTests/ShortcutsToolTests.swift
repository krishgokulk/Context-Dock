import Foundation
import Testing

@testable import Context_Dock

/// Records what the injected runner was asked, and answers from a script.
private final class FakeShortcuts: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    private(set) var inputExistedDuringRun: Bool?
    private(set) var inputText: String?
    var names = "Morning\n  Resize Images  \n\nSend Report\n"
    var runOutcome = ShortcutsService.ProcessOutcome(status: 0, stdout: "")

    var runner: ShortcutsService.Runner {
        { [self] arguments, _, _ in
            lock.lock()
            defer { lock.unlock() }
            calls.append(arguments)
            if arguments.first == "list" {
                return .init(status: 0, stdout: names)
            }
            if let flag = arguments.firstIndex(of: "-i"), flag + 1 < arguments.count {
                let path = arguments[flag + 1]
                inputExistedDuringRun = FileManager.default.fileExists(atPath: path)
                inputText = try? String(contentsOfFile: path, encoding: .utf8)
            }
            return runOutcome
        }
    }

    var runCalls: [[String]] { calls.filter { $0.first == "run" } }
}

private func leftoverInputFiles() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        .filter { $0.hasPrefix("dorax-shortcut-") }
}

struct ShortcutsServiceTests {

    @Test func listParsingTrimsAndDropsEmptiesAndRepeats() {
        #expect(ShortcutsService.parseList("Morning\n  Resize Images  \n\n\nSend Report\nMorning\n")
            == ["Morning", "Resize Images", "Send Report"])
        #expect(ShortcutsService.parseList("").isEmpty)
        #expect(ShortcutsService.parseList("\r\nA\r\nB\r\n") == ["A", "B"])
    }

    @Test func listReportCapsTheCount() {
        let many = (1...(ShortcutsService.maxListed + 25)).map { "S\($0)" }
        let report = ShortcutsService.listReport(names: many)
        #expect(report.contains("S\(ShortcutsService.maxListed)"))
        #expect(!report.contains("S\(ShortcutsService.maxListed + 1)\n"))
        #expect(report.contains("25 more not shown"))
        #expect(ShortcutsService.listReport(names: []).contains("no shortcuts"))
    }

    @Test func listFailureIsReported() {
        let dead: ShortcutsService.Runner = { _, _, _ in .init(status: -1, stdout: "", launchFailed: true) }
        #expect(ShortcutsService.allNames(runner: dead) == .failure(.listFailed("the `shortcuts` tool could not be started.")))
        let slow: ShortcutsService.Runner = { _, _, _ in .init(status: 15, stdout: "", timedOut: true) }
        if case .success = ShortcutsService.allNames(runner: slow) { Issue.record("timeout must fail") }
        let bad: ShortcutsService.Runner = { _, _, _ in .init(status: 1, stdout: "", stderr: "nope") }
        #expect(ShortcutsService.allNames(runner: bad) == .failure(.listFailed("nope")))
    }

    @Test func inputFileIsCreatedPassedAndDeleted() {
        let fake = FakeShortcuts()
        fake.runOutcome = .init(status: 0, stdout: "done\n")
        let outcome = ShortcutsService.run(name: "Morning", input: "hello there", runner: fake.runner)
        #expect(outcome.success)
        #expect(fake.inputExistedDuringRun == true)
        #expect(fake.inputText == "hello there")
        #expect(fake.runCalls[0].prefix(2) == ["run", "Morning"])
        #expect(fake.runCalls[0].contains("-i"))
        #expect(leftoverInputFiles().isEmpty)
    }

    @Test func inputFileIsDeletedWhenTheRunFails() {
        let fake = FakeShortcuts()
        fake.runOutcome = .init(status: 1, stdout: "", stderr: "boom")
        let outcome = ShortcutsService.run(name: "Morning", input: "x", runner: fake.runner)
        #expect(!outcome.success)
        #expect(fake.inputExistedDuringRun == true)
        #expect(leftoverInputFiles().isEmpty)
    }

    @Test func noInputMeansNoFlagAndNoFile() {
        let fake = FakeShortcuts()
        _ = ShortcutsService.run(name: "Morning", input: nil, runner: fake.runner)
        #expect(fake.runCalls[0] == ["run", "Morning"])
        #expect(fake.inputExistedDuringRun == nil)
    }

    @Test func nonZeroExitIsAFailedResult() {
        let outcome = ShortcutsService.interpret(
            .init(status: 3, stdout: "partial", stderr: "Error: bad"), name: "X")
        #expect(!outcome.success)
        #expect(outcome.status == 3)
        #expect(outcome.text.contains("exit status 3"))
        #expect(outcome.text.contains("Error: bad"))
    }

    @Test func timeoutIsAFailedResult() {
        let outcome = ShortcutsService.interpret(
            .init(status: 15, stdout: "", timedOut: true), name: "X")
        #expect(!outcome.success)
        #expect(outcome.text.contains("did not finish"))
    }

    @Test func emptyOutputSaysRanNoOutput() {
        let outcome = ShortcutsService.interpret(.init(status: 0, stdout: "  \n"), name: "X")
        #expect(outcome.success)
        #expect(outcome.text.contains("no output"))
    }

    @Test func truncatedOutputIsMarked() {
        let outcome = ShortcutsService.interpret(
            .init(status: 0, stdout: "abc", truncated: true), name: "X")
        #expect(outcome.text.contains("[output truncated]"))
    }

    @Test func drainCapsWhatItKeepsButReadsEverything() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let big = Data(repeating: 0x61, count: 50_000)
        DispatchQueue.global().async {
            writer.write(big)
            try? writer.close()
        }
        let (data, truncated) = ShortcutsService.drain(pipe.fileHandleForReading, maxBytes: 1_000)
        #expect(data.count == 1_000)
        #expect(truncated)
    }
}

@MainActor
struct ShortcutsToolTests {

    @Test func bothToolsAreRegistered() {
        #expect(AgentToolRegistry.shared.tool(named: "list_shortcuts") != nil)
        let run = AgentToolRegistry.shared.tool(named: "run_shortcut")
        #expect(run?.required == ["name"])
    }

    @Test func runningIsHighRiskAndNeedsApproval() {
        #expect(ShortcutsTool.capability().riskLevel.requiresApproval)
        #expect(ApprovalRisk(ShortcutsTool.capability().riskLevel) == .high)
    }

    @Test func listNeedsNoApproval() async {
        let fake = FakeShortcuts()
        let (ok, text) = await AgentToolRegistry.runListShortcuts(runner: fake.runner)
        #expect(ok)
        #expect(text.contains("Resize Images"))
        #expect(fake.runCalls.isEmpty)
    }

    @Test func approvedRunShowsNameAndInputAndReturnsOutput() async {
        let fake = FakeShortcuts()
        fake.runOutcome = .init(status: 0, stdout: "42\n")
        var asked: [AIActionPlan] = []
        let result = await AgentToolRegistry.runRunShortcut(
            name: "Morning", input: "hi", scope: nil, attended: true, runner: fake.runner
        ) { plan, capability in
            asked.append(plan)
            #expect(capability.riskLevel.requiresApproval)
            return true
        }
        #expect(result.success)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("42"))
        #expect(asked.count == 1)
        #expect(asked[0].capability == ShortcutsTool.capabilityID)
        #expect(asked[0].input["shortcut"] == "Morning")
        #expect(asked[0].input["input"] == "hi")
        #expect(leftoverInputFiles().isEmpty)
    }

    @Test func unknownNameIsRefusedBeforeTheSheet() async {
        let fake = FakeShortcuts()
        var asked = false
        let result = await AgentToolRegistry.runRunShortcut(
            name: "morning", input: nil, scope: nil, attended: true, runner: fake.runner
        ) { _, _ in asked = true; return true }
        #expect(!result.success)
        #expect(!asked)
        #expect(fake.runCalls.isEmpty)
        #expect(result.output.contains("no shortcut named"))
    }

    @Test func emptyNameAndOversizedInputAreRefused() async {
        let fake = FakeShortcuts()
        var asked = false
        let empty = await AgentToolRegistry.runRunShortcut(
            name: "  ", input: nil, scope: nil, attended: true, runner: fake.runner
        ) { _, _ in asked = true; return true }
        let long = await AgentToolRegistry.runRunShortcut(
            name: "Morning", input: String(repeating: "a", count: ShortcutsService.maxInputCharacters + 1),
            scope: nil, attended: true, runner: fake.runner
        ) { _, _ in asked = true; return true }
        #expect(!empty.success && !long.success)
        #expect(!asked)
        #expect(fake.calls.isEmpty)
    }

    @Test func declinedRunsNothing() async {
        let fake = FakeShortcuts()
        let result = await AgentToolRegistry.runRunShortcut(
            name: "Morning", input: nil, scope: nil, attended: true, runner: fake.runner
        ) { _, _ in false }
        #expect(!result.success)
        #expect(result.deniedByUser)
        #expect(fake.runCalls.isEmpty)
    }

    @Test func failedShortcutIsAFailedStep() async {
        let fake = FakeShortcuts()
        fake.runOutcome = .init(status: 1, stdout: "", stderr: "Error: nope")
        let result = await AgentToolRegistry.runRunShortcut(
            name: "Morning", input: nil, scope: nil, attended: true, runner: fake.runner
        ) { _, _ in true }
        #expect(!result.success)
        #expect(result.exitCode == 1)
    }

    @Test func unattendedMCPCallerIsRefusedWithoutAskingOrRunning() async {
        let fake = FakeShortcuts()
        var asked = false
        let result = await AgentToolRegistry.runRunShortcut(
            name: "Morning", input: nil, scope: nil, attended: false, runner: fake.runner
        ) { _, _ in asked = true; return true }
        #expect(!result.success)
        #expect(!asked)
        #expect(fake.calls.isEmpty)
        #expect(result.output.contains("unattended"))
    }

    @Test func unattendedRunRefusesTheRealApprovalSheet() async {
        let fake = FakeShortcuts()
        let (result, requested) = await AICapabilityApprovalCenter.withUnattendedRun {
            await AgentToolRegistry.runRunShortcut(
                name: "Morning", input: nil, scope: nil, attended: true, runner: fake.runner)
        }
        #expect(!result.success)
        #expect(requested == [ShortcutsTool.capabilityID])
        #expect(fake.runCalls.isEmpty)
    }

    @Test func aPathInTheOutputBecomesACard() async {
        let fake = FakeShortcuts()
        fake.runOutcome = .init(status: 0, stdout: "/Users/me/Documents/Reports/week 12.pdf\n")
        let result = await AgentToolRegistry.runRunShortcut(
            name: "Send Report", input: nil, scope: nil, attended: true, runner: fake.runner
        ) { _, _ in true }
        let cards = TurnFileExtractor.files(
            answer: "", stepOutputs: [result.output], homeDirectory: "/Users/me",
            probe: { $0 == "/Users/me/Documents/Reports/week 12.pdf" ? .file : nil })
        #expect(cards.map(\.path) == ["/Users/me/Documents/Reports/week 12.pdf"])
    }

    @Test func mcpServerListsBothTools() {
        for attended in [true, false] {
            let names = DoraXMCPServer.toolDefinitions(attended: attended).compactMap { $0["name"] as? String }
            #expect(names.contains("dorax_list_shortcuts"))
            #expect(names.contains("dorax_run_shortcut"))
        }
    }

    @Test func scopedChatsGetTheToolsOnlyWhenTheSentenceIsAboutShortcuts() {
        for query in ["run my morning shortcut", "start the automation", "run my backup"] {
            let plan = FrontmostAppTaskPlan.make(
                query: query, bundleId: "com.apple.finder", appName: "Finder")
            #expect(plan.allowedToolNames.contains("run_shortcut"), "\(query)")
            #expect(plan.allowedToolNames.contains("list_shortcuts"), "\(query)")
        }
        let other = FrontmostAppTaskPlan.make(
            query: "what is on this page", bundleId: "com.apple.finder", appName: "Finder")
        #expect(!other.allowedToolNames.contains("run_shortcut"))
    }

    @Test func stepsHaveLabels() {
        #expect(ScopedToolStep.label(for: "run_shortcut") == "Running the shortcut…")
        #expect(ScopedToolStep.label(for: "list_shortcuts") == "Looking at your shortcuts…")
    }
}
