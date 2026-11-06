// Context-DockTests/PromptOrderCacheTests.swift
// Context-Dock
//
// Unit tests for E3: Prompt order: stable sections first, a second cache mark, volatile last (#151).
// Spec: docs/master/00-AI-ENGINE-PLAN.md §4 E3.

import Foundation
import Testing

@testable import Context_Dock

struct PromptOrderCacheTests {

    // MARK: - 1. Section Stability and Declaration Order

    @Test("ScopedPromptSection partitions cleanly into stable prefix and volatile suffix")
    func sectionStabilityClassification() {
        for section in ScopedPromptSection.allCases {
            switch section {
            case .sourceRule, .userProfile, .identity, .petMode, .capabilities, .liveMenu, .mcp, .skills, .reference, .cli:
                #expect(section.isStable, "\(section) should be marked stable")
            case .workspace, .resolvedContext, .selection, .browserPage, .folder, .attachments, .liveAppData, .memory:
                #expect(!section.isStable, "\(section) should be marked volatile")
            }
        }

        // All stable cases must precede all volatile cases in declaration order
        let allCases = ScopedPromptSection.allCases
        var seenVolatile = false
        for section in allCases {
            if !section.isStable {
                seenVolatile = true
            } else {
                #expect(!seenVolatile, "Stable section \(section) declared after volatile section")
            }
        }
    }

    // MARK: - 2. Assembled Reading Order

    @Test("Assembled prompt positions all stable sections before any volatile sections")
    func assembledPromptPositionsStableBeforeVolatile() {
        var prompt = ScopedPromptAssembler()
        prompt.set(.memory, "VOLATILE_MEMORY")
        prompt.set(.selection, "VOLATILE_SELECTION")
        prompt.set(.cli, "STABLE_CLI")
        prompt.set(.skills, "STABLE_SKILLS")
        prompt.set(.identity, "STABLE_IDENTITY")
        prompt.set(.sourceRule, "STABLE_RULE")

        let assembled = prompt.assemble(for: .openAI)
        let ruleIndex = assembled.range(of: "STABLE_RULE")!.lowerBound
        let identityIndex = assembled.range(of: "STABLE_IDENTITY")!.lowerBound
        let skillsIndex = assembled.range(of: "STABLE_SKILLS")!.lowerBound
        let cliIndex = assembled.range(of: "STABLE_CLI")!.lowerBound
        let selectionIndex = assembled.range(of: "VOLATILE_SELECTION")!.lowerBound
        let memoryIndex = assembled.range(of: "VOLATILE_MEMORY")!.lowerBound

        // Stable ordering
        #expect(ruleIndex < identityIndex)
        #expect(identityIndex < skillsIndex)
        #expect(skillsIndex < cliIndex)

        // Stable precedes volatile
        #expect(cliIndex < selectionIndex)
        #expect(selectionIndex < memoryIndex)
    }

    // MARK: - 3. Byte-Identical Stable Prefix Across Selection Changes

    @Test("Changing volatile selection leaves the stable prefix 100% byte-identical")
    func selectionChangeLeavesStablePrefixByteIdentical() throws {
        var promptA = ScopedPromptAssembler()
        promptA.set(.sourceRule, "RULE_HEADER")
        promptA.set(.userProfile, "USER_PROFILE_DATA")
        promptA.set(.identity, "APP_IDENTITY_MACOS")
        promptA.set(.capabilities, "CAPABILITY_LISTING_V1")
        promptA.set(.skills, "SKILLS_INSTRUCTIONS")
        promptA.set(.reference, "OFFICIAL_VENDOR_DOCS")
        promptA.set(.cli, "CLI_TOOL_HELP_DATA")
        promptA.set(.selection, "SELECTION: FileA.swift line 1-20")

        var promptB = promptA
        promptB.set(.selection, "SELECTION: DifferentFile.swift line 99-120")

        let (stableA, volatileA) = promptA.assembleSections(for: .anthropic)
        let (stableB, volatileB) = promptB.assembleSections(for: .anthropic)

        // Stable prefix is strictly byte-identical
        #expect(stableA == stableB)
        #expect(!stableA.isEmpty)

        // Volatile suffix differs
        #expect(volatileA != volatileB)
        #expect(volatileA.contains("FileA.swift"))
        #expect(volatileB.contains("DifferentFile.swift"))

        // Blocks generated for Anthropic share the identical stable block text
        let blocksA = try #require(AnthropicPromptCache.systemBlocks(promptA.assemble(for: .anthropic)))
        let blocksB = try #require(AnthropicPromptCache.systemBlocks(promptB.assemble(for: .anthropic)))

        #expect(blocksA.count == 2)
        #expect(blocksB.count == 2)
        #expect((blocksA[0]["text"] as? String) == (blocksB[0]["text"] as? String))
        #expect((blocksA[1]["text"] as? String) != (blocksB[1]["text"] as? String))
    }

    // MARK: - 4. Anthropic Cache Breakpoints and Limits

    @Test("Anthropic prompt cache creates dual blocks with ephemeral breakpoints within limits")
    func anthropicPromptCacheDualBlocksAndLimit() throws {
        let stable = "STABLE_IDENTITY_AND_TOOLS"
        let volatile = "VOLATILE_CONTEXT_SNAPSHOT"

        let dualBlocks = try #require(AnthropicPromptCache.systemBlocks(stable: stable, volatile: volatile))
        #expect(dualBlocks.count == 2)
        #expect((dualBlocks[0]["cache_control"] as? [String: String])?["type"] == "ephemeral")
        #expect((dualBlocks[1]["cache_control"] as? [String: String])?["type"] == "ephemeral")

        // Single block when only stable exists
        let singleStable = try #require(AnthropicPromptCache.systemBlocks(stable: stable, volatile: nil))
        #expect(singleStable.count == 1)

        // Single block when only volatile exists
        let singleVolatile = try #require(AnthropicPromptCache.systemBlocks(stable: "", volatile: volatile))
        #expect(singleVolatile.count == 1)

        // Total breakpoints verification: 2 system blocks + 1 message history breakpoint = 3 <= 4
        let sampleMessages: [[String: Any]] = [
            ["role": "user", "content": "Question 1"],
            ["role": "assistant", "content": "Answer 1"],
            ["role": "user", "content": "Question 2"]
        ]
        let markedMessages = AnthropicPromptCache.markingLastBlock(sampleMessages)
        var messageBreakpoints = 0
        for msg in markedMessages {
            if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks where b["cache_control"] != nil {
                    messageBreakpoints += 1
                }
            }
        }
        #expect(messageBreakpoints == 1)

        let totalBreakpoints = dualBlocks.count + messageBreakpoints
        #expect(totalBreakpoints <= 4, "Must stay within Anthropic's limit of 4 breakpoints per request")
    }

    // MARK: - 5. Drop Order Under Budget

    @Test("Drop order preserves least valuable first sacrifice under tight budget")
    func dropOrderPreservedUnderBudget() {
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, "IDENTITY_" + String(repeating: "i", count: 1_000))
        prompt.set(.resolvedContext, "CONTEXT_" + String(repeating: "c", count: 1_000))
        prompt.set(.reference, "REF_" + String(repeating: "r", count: 4_000))
        prompt.set(.memory, "MEM_" + String(repeating: "m", count: 4_000))

        let assembled = prompt.assemble(for: .onDevice)
        let budget = ScopedPromptAssembler.budget(for: .onDevice)!

        #expect(assembled.count <= budget)
        #expect(assembled.contains("IDENTITY_"))
        #expect(assembled.contains("CONTEXT_"))
        #expect(!assembled.contains("REF_"))
    }
}
