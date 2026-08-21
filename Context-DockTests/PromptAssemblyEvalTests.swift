import Foundation
import Testing

@testable import Context_Dock

// Evals for the shared prompt assembly, the rate card and cancellation reporting.
//
// The assembler is the one place that decides what a small-context model is given up. That
// decision used to live twice — once in the dock, once in the window, with different orders
// and only one budget — and the failure it guards against is silent: the model receives a
// prompt that overruns its window and answers with nothing at all.

struct ScopedPromptAssemblyEvalTests {

    private func filled(_ size: Int) -> String { String(repeating: "x", count: size) }

    @Test func sectionsAreReadInDeclarationOrderRegardlessOfInsertion() {
        // Blocks are set as each reader returns, which is not the order the model should read
        // them in: identity has to come before the evidence it frames.
        var prompt = ScopedPromptAssembler()
        prompt.set(.memory, "MEMORY")
        prompt.set(.identity, "IDENTITY")
        prompt.set(.sourceRule, "RULE")
        let assembled = prompt.assemble(for: .anthropic)
        let rule = assembled.range(of: "RULE")!.lowerBound
        let identity = assembled.range(of: "IDENTITY")!.lowerBound
        let memory = assembled.range(of: "MEMORY")!.lowerBound
        #expect(rule < identity)
        #expect(identity < memory)
    }

    @Test func emptyBlocksLeaveNoGap() {
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, "IDENTITY")
        prompt.set(.memory, "   ")
        prompt.set(.reference, nil)
        #expect(prompt.assemble(for: .anthropic) == "IDENTITY")
    }

    @Test func appendingKeepsBothBlocksInOneSlot() {
        // A combined chat has several apps' identity blocks and they belong together.
        var prompt = ScopedPromptAssembler()
        prompt.append(.identity, "FIRST")
        prompt.append(.identity, "SECOND")
        let assembled = prompt.assemble(for: .anthropic)
        #expect(assembled.contains("FIRST"))
        #expect(assembled.contains("SECOND"))
    }

    @Test func aCloudModelIsNotTrimmed() {
        var prompt = ScopedPromptAssembler()
        for section in ScopedPromptSection.allCases { prompt.set(section, filled(5_000)) }
        let assembled = prompt.assemble(for: .anthropic)
        #expect(assembled.count > 50_000)
    }

    @Test func theOnDeviceModelIsKeptInsideItsWindow() {
        // The full inventory overran Apple's on-device model and it produced no token at all,
        // so the chat sat on an empty bubble until it timed out.
        var prompt = ScopedPromptAssembler()
        for section in ScopedPromptSection.allCases { prompt.set(section, filled(2_000)) }
        let assembled = prompt.assemble(for: .onDevice)
        let budget = ScopedPromptAssembler.budget(for: .onDevice)!
        #expect(assembled.count <= budget)
    }

    @Test func identitySurvivesTrimmingAndReferenceDoesNot() {
        // An answer about the wrong app is worse than a short one; being unable to quote the
        // vendor's documentation is survivable.
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, "IDENTITY-" + filled(1_000))
        prompt.set(.resolvedContext, "CONTEXT-" + filled(1_000))
        prompt.set(.reference, "REFERENCE-" + filled(4_000))
        prompt.set(.memory, "MEMORY-" + filled(4_000))
        let assembled = prompt.assemble(for: .onDevice)
        #expect(assembled.contains("IDENTITY-"))
        #expect(assembled.contains("CONTEXT-"))
        #expect(!assembled.contains("REFERENCE-"))
    }

    @Test func anOversizedEssentialIsShortenedAndSaysSo() {
        // The identity block carries up to fifty menu paths; on the on-device model that
        // alone can fill the window. It cannot be dropped — the model would not know which
        // app it is answering about — so it is shortened, and the shortening is announced.
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, (0..<400).map { "- Menu \($0)" }.joined(separator: "\n"))
        let assembled = prompt.assemble(for: .onDevice)
        #expect(assembled.count <= ScopedPromptAssembler.budget(for: .onDevice)!)
        #expect(assembled.contains("shortened to fit"))
        #expect(assembled.contains("- Menu 0"))
    }

    @Test func aSectionIsDroppedWholeRatherThanCutInHalf() {
        // The model reads a truncated flag as a real one, and a list that stops mid-way as a
        // complete list of fewer things.
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, "IDENTITY")
        prompt.set(.reference, "REFERENCE-START" + filled(9_000) + "REFERENCE-END")
        let assembled = prompt.assemble(for: .onDevice)
        #expect(assembled.contains("REFERENCE-START") == assembled.contains("REFERENCE-END"))
    }

    @Test func selectedLiveEvidenceSurvivesBeforeCapabilityCatalogues() {
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, "IDENTITY-" + filled(1_000))
        prompt.set(.liveAppData, "OBSERVED-HISTORY\n- Real title\n" + filled(1_000))
        prompt.set(.capabilities, "COMMAND-CATALOGUE-" + filled(8_000))

        let assembled = prompt.assemble(for: .onDevice, preserving: [.liveAppData])
        #expect(assembled.contains("OBSERVED-HISTORY"))
        #expect(assembled.contains("Real title"))
        #expect(!assembled.contains("COMMAND-CATALOGUE"))
        #expect(assembled.count <= ScopedPromptAssembler.budget(for: .onDevice)!)
    }
}

@MainActor
struct AgentToolAuthorityEvalTests {
    @Test func factualQuestionsExposeReadersButNotControls() {
        let names = AgentToolRegistry.shared.toolNamesAvailable(
            for: "What did I watch here before?")
        #expect(names.contains("run_mcp_tool"))
        #expect(!names.contains("run_menu_command"))
        #expect(!names.contains("run_adapter_action"))
        #expect(!names.contains("run_command"))
        #expect(!names.contains("window_control"))
        #expect(!names.contains("compose_message"))
    }

    @Test func actionRequestsStillExposeAppControls() {
        let names = AgentToolRegistry.shared.toolNamesAvailable(
            for: "Open the latest item in History")
        #expect(names.contains("run_menu_command"))
        #expect(names.contains("run_adapter_action"))
    }
}

@MainActor
struct ModelRateCardEvalTests {

    @Test func nothingIsShownUntilTheUserSaysWhatTheyPay() {
        // DoraX ships no price table: one is wrong the day a provider changes its pricing
        // page, and someone would choose a cheaper model on a number the app made up.
        let card = AIModelRateCard.shared
        #expect(card.rate(forModel: "a-model-nobody-has-priced") == nil)
    }

    @Test func costIsArithmeticOnTheUsersOwnFigures() {
        let rate = AIModelRate(
            inputPerMillion: 3, outputPerMillion: 15, cachedInputPerMillion: 0.3)
        let cost = rate.cost(
            inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 1_000_000)
        #expect(abs(cost - 18.3) < 0.0001)
    }

    @Test func anUnpricedCacheIsBilledAsInputRatherThanFree() {
        // The conservative reading: it never understates what the user paid.
        let rate = AIModelRate(
            inputPerMillion: 3, outputPerMillion: 15, cachedInputPerMillion: nil)
        let cost = rate.cost(inputTokens: 0, cachedInputTokens: 1_000_000, outputTokens: 0)
        #expect(abs(cost - 3) < 0.0001)
    }

    @Test func aDatedModelIdMatchesTheFamilyRate() {
        // Providers publish "claude-sonnet-4-5" and serve "claude-sonnet-4-5-20250929".
        let card = AIModelRateCard.shared
        card.set(
            AIModelRate(inputPerMillion: 3, outputPerMillion: 15, cachedInputPerMillion: nil),
            forModel: "eval-family-model")
        defer { card.set(nil, forModel: "eval-family-model") }
        #expect(card.rate(forModel: "eval-family-model-20250929") != nil)
    }

    @Test func smallSpendReadsInCentsRatherThanAsFree() {
        // "$0.00" for four cents of usage reads as free.
        #expect(0.04.compactUSD == "4¢")
        #expect(2.5.compactUSD == "$2.50")
    }
}

struct CancellationEvalTests {

    @Test func aCancelledCommandSaysItWasStopped() {
        // Silently returning partial output as though the command finished is how a
        // half-completed move gets summarised as a completed one.
        #expect(CancellableProcessRunner.stoppedNote.contains("Stopped"))
    }

    @Test func aBoxCancelledBeforeAdoptionRefusesToStartTheProcess() {
        // A process launched after Stop is one nothing is left watching.
        let box = CancellableProcessBox()
        box.cancel()
        #expect(box.adopt(Process()) == false)
        #expect(box.wasCancelled)
    }

    @Test func anUncancelledBoxAdoptsItsProcess() {
        let box = CancellableProcessBox()
        #expect(box.adopt(Process()))
        #expect(!box.wasCancelled)
    }
}
