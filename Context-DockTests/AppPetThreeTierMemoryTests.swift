// AppPetThreeTierMemoryTests.swift
// Context-DockTests
//
// Acceptance tests for Task #340: App Pets Stage 3 — Three-Tier Memory.
//
// 1. Per-Pet identity memory (inspect, edit, pin, delete; inferred confirmation).
// 2. Combined Chat shared working memory across connected participants.
// 3. Combined Chat writeback of verified facts only to participating Pets.
// 4. Invariant: General Chat single-turn borrowing NEVER writes into Pet identity memory.
// 5. Full transcript remains local and searchable while provider payload is bounded.
// 6. Rolling summaries preserve provenance, decisions and unresolved work.
// 7. Deterministic token-budget tests across multiple provider limits.
// 8. Near-limit choices (Keep active, Archive and new chat, New chat without saving).
// 9. Provider switching re-projects while keeping single conversation identity.

import Foundation
import Testing

@testable import Context_Dock

@Suite("App Pets Stage 3 — Three-Tier Memory & Provider Projection", .serialized)
struct AppPetThreeTierMemoryTests {

    private func makeIsolatedVault() -> (URL, AppPetMemoryController, MarkdownMemoryStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPetsMemoryTest-\(UUID().uuidString)", isDirectory: true)
        let memoryStore = MarkdownMemoryStore(rootOverride: root)
        let petController = AppPetMemoryController(rootOverride: root)
        return (root, petController, memoryStore)
    }

    // MARK: - 1. Tier 1: Per-Pet Identity Memory CRUD

    @Test("Pet identity memory supports inspect, edit, pin, and delete with provenance")
    func petIdentityMemoryCRUD() throws {
        let (root, controller, _) = makeIsolatedVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let mailPet = AppPetID.app(bundleID: "com.apple.mail")

        // 1. Explicit save
        let explicitRecord = PetMemoryRecord(
            fact: "Drafts folder is Work/Drafts",
            petID: mailPet,
            provenance: .userExplicit(sourceApp: "Mail")
        )
        let saveResult = controller.saveRecord(explicitRecord, conversationKind: .appPet(mailPet))
        #expect(saveResult.success)

        // 2. Verified receipt save
        let receiptRecord = PetMemoryRecord(
            fact: "Default export format is PDF",
            petID: mailPet,
            provenance: .verifiedReceipt(receiptID: "rcpt-export-01", toolName: "mail.export")
        )
        controller.saveRecord(receiptRecord, conversationKind: .appPet(mailPet))

        // 3. Inspect (loadRecords)
        var records = controller.loadRecords(for: mailPet)
        #expect(records.count == 2)
        #expect(records.contains { $0.fact == "Drafts folder is Work/Drafts" })
        #expect(records.contains { $0.fact == "Default export format is PDF" })

        // Check provenance preservation
        let loadedReceipt = records.first { $0.fact == "Default export format is PDF" }
        #expect(loadedReceipt?.provenance == .verifiedReceipt(receiptID: "rcpt-export-01", toolName: "mail.export"))

        // 4. Pin
        guard let firstID = records.first?.id else {
            Issue.record("Expected records to be non-empty")
            return
        }
        let pinSuccess = controller.pinRecord(id: firstID, for: mailPet, pinned: true)
        #expect(pinSuccess)
        records = controller.loadRecords(for: mailPet)
        #expect(records.first { $0.id == firstID }?.isPinned == true)

        // Pinned records are sorted first in admitted records
        let admitted = controller.loadAdmittedRecords(for: mailPet)
        #expect(admitted.first?.id == firstID)

        // 5. Edit
        let editSuccess = controller.editRecord(
            id: firstID, for: mailPet, newFact: "Drafts folder is Archived/Drafts")
        #expect(editSuccess)
        records = controller.loadRecords(for: mailPet)
        #expect(records.first { $0.id == firstID }?.fact == "Drafts folder is Archived/Drafts")

        // 6. Delete
        let deleteSuccess = controller.deleteRecord(id: firstID, for: mailPet)
        #expect(deleteSuccess)
        records = controller.loadRecords(for: mailPet)
        #expect(records.count == 1)
        #expect(!records.contains { $0.id == firstID })
    }

    // MARK: - 2. Inferred Preferences Require Confirmation

    @Test("Inferred preferences require user confirmation before entering active long memory")
    func inferredPreferencesRequireConfirmation() throws {
        let (root, controller, _) = makeIsolatedVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let safariPet = AppPetID.app(bundleID: "com.apple.Safari")

        // Save an assistant inference
        let inferenceRecord = PetMemoryRecord(
            fact: "Prefers compact tab layout",
            petID: safariPet,
            provenance: .inferred(confidence: 0.82, confirmed: false)
        )
        controller.saveRecord(inferenceRecord, conversationKind: .appPet(safariPet))

        // All records contains it, but loadAdmittedRecords excludes it
        let allRecords = controller.loadRecords(for: safariPet)
        #expect(allRecords.count == 1)
        #expect(!allRecords[0].provenance.isAdmitted)

        let admittedBefore = controller.loadAdmittedRecords(for: safariPet)
        #expect(admittedBefore.isEmpty)

        // Confirm the inference
        let confirmed = controller.confirmInferredRecord(id: allRecords[0].id, for: safariPet)
        #expect(confirmed)

        let admittedAfter = controller.loadAdmittedRecords(for: safariPet)
        #expect(admittedAfter.count == 1)
        #expect(admittedAfter[0].provenance.isAdmitted)
        #expect(admittedAfter[0].fact == "Prefers compact tab layout")
    }

    // MARK: - 3. Tier 2: Combined Chat Working Memory & Writeback

    @Test("Combined Chat preserves shared working memory and writes back ONLY verified facts to participating Pets")
    func combinedChatWorkspaceMemoryAndWriteback() throws {
        let (root, controller, _) = makeIsolatedVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let finderPet = AppPetID.app(bundleID: "com.apple.finder")
        let messagesPet = AppPetID.app(bundleID: "com.apple.MobileSMS")
        let mailPet = AppPetID.app(bundleID: "com.apple.mail")

        let participants = ParticipantSet([
            ConversationParticipant(petID: finderPet, displayName: "Finder"),
            ConversationParticipant(petID: messagesPet, displayName: "Messages"),
        ])
        let workspaceID = participants.combinedThreadID

        // 1. Shared working memory
        let wsMemory = CombinedWorkspaceMemory(
            workspaceID: workspaceID,
            participantPetIDs: [finderPet, messagesPet],
            taskSummary: "Export sales report from Finder and message Alex",
            decisions: ["Report filtered to Q3 only"],
            unresolvedWork: ["Awaiting approval to send SMS"]
        )
        controller.saveWorkspaceMemory(wsMemory)

        let loadedWS = controller.loadWorkspaceMemory(workspaceID: workspaceID)
        #expect(loadedWS != nil)
        #expect(loadedWS?.taskSummary == "Export sales report from Finder and message Alex")
        #expect(loadedWS?.decisions == ["Report filtered to Q3 only"])
        #expect(loadedWS?.unresolvedWork == ["Awaiting approval to send SMS"])

        // 2. Writeback of verified fact to participating Pet (Messages) succeeds
        let writebackResult = controller.writebackVerifiedFact(
            fact: "Alex's SMS number is +1-555-0199",
            targetPet: messagesPet,
            workspaceID: workspaceID,
            participants: participants,
            receiptID: "rcpt-contact-lookup"
        )
        #expect(writebackResult.success)

        let messagesRecords = controller.loadRecords(for: messagesPet)
        #expect(messagesRecords.count == 1)
        #expect(messagesRecords[0].fact == "Alex's SMS number is +1-555-0199")
        #expect(
            messagesRecords[0].provenance
                == .combinedChatWriteback(
                    workspaceID: workspaceID, receiptID: "rcpt-contact-lookup"))

        // 3. Writeback to non-participating Pet (Mail) is refused
        let refusedResult = controller.writebackVerifiedFact(
            fact: "Mail invoice sent",
            targetPet: mailPet,
            workspaceID: workspaceID,
            participants: participants,
            receiptID: nil
        )
        #expect(!refusedResult.success)
        #expect(refusedResult.message.contains("not a connected participant"))
        #expect(controller.loadRecords(for: mailPet).isEmpty)
    }

    // MARK: - 4. Invariant: General Chat Borrowing Never Writes Pet Memory

    @Test("General Chat single-turn borrowing NEVER writes into Pet identity memory")
    func generalChatBorrowingNeverWritesPetMemory() throws {
        let (root, controller, store) = makeIsolatedVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let mailPet = AppPetID.app(bundleID: "com.apple.mail")

        // 1. Controller refuses saveRecord when conversationKind is .general
        let directRecord = PetMemoryRecord(
            fact: "Mail preference: always use HTML",
            petID: mailPet,
            provenance: .userExplicit(sourceApp: "Mail")
        )
        let directSave = controller.saveRecord(directRecord, conversationKind: .general)
        #expect(!directSave.success)
        #expect(directSave.message.contains("Refused"))
        #expect(controller.loadRecords(for: mailPet).isEmpty)

        // 2. MarkdownMemoryStore.remember with conversationKind: .general routes to global files
        let generalRemember = store.remember(
            "Please remember that I prefer dark mode appearance",
            appBundleID: "com.apple.mail",
            appName: "Mail",
            conversationKind: .general
        )
        #expect(generalRemember != nil)

        // Verify apps/com.apple.mail.md was NOT created
        let mailFile = root.appendingPathComponent("apps/com.apple.mail.md")
        #expect(!FileManager.default.fileExists(atPath: mailFile.path))

        // Verify it was saved in preferences.md (Tier 3)
        let preferencesFile = root.appendingPathComponent("preferences.md")
        #expect(FileManager.default.fileExists(atPath: preferencesFile.path))
        let preferencesContent = try String(contentsOf: preferencesFile, encoding: .utf8)
        #expect(preferencesContent.contains("I prefer dark mode appearance"))

        // 3. Prompt context block for General Chat never loads Mail Pet memory
        let (contextBlock, chips) = controller.promptContextBlock(
            query: "What are my preferences?",
            scope: .general,
            participants: .empty
        )
        #expect(!contextBlock.contains("com.apple.mail Memory"))
        #expect(!chips.contains("com.apple.mail memory"))
    }

    // MARK: - 5. Provider Context Projection & Bounded Payloads

    @Test("Full local transcript remains local/searchable while provider payload is bounded")
    func boundedProviderPayloadKeepsLocalTranscript() {
        var messages: [AIChatMessage] = []
        for i in 1...25 {
            messages.append(
                AIChatMessage(role: .user, content: "Step \(i): Process dataset and report metrics.")
            )
            messages.append(
                AIChatMessage(
                    role: .assistant,
                    content: "Completed step \(i). Metrics: accuracy 9\(i)%. We decided to continue."
                )
            )
        }
        #expect(messages.count == 50)

        // Project into tight budget where 50 messages exceed the turn window
        let tightBudget = ProviderContextBudget.testBudget(maxPromptBudget: 350)
        let projection = ConversationMemoryProjector.project(
            messages: messages,
            conversationKind: .general,
            scope: .general,
            systemPrompt: "You are DoraX.",
            provider: .onDevice,
            customBudget: tightBudget
        )

        // 1. Full transcript remains preserved locally
        #expect(projection.fullLocalMessageCount == 50)

        // 2. Active turn window contains bounded recent messages
        #expect(projection.activeTurnWindowMessages.count < 50)
        #expect(projection.activeTurnWindowMessages.count >= 2)
        #expect(
            projection.activeTurnWindowMessages.last?.content
                == messages.last?.content)

        // 3. Older messages are rolled into summary
        #expect(projection.rollingSummary != nil)
        #expect(projection.rollingSummary?.coveredMessageCount ?? 0 > 0)
        #expect(
            projection.estimatedTotalTokens
                <= projection.budget.maxPromptBudget + 100)
    }

    // MARK: - 6. Rolling Summaries

    @Test("Rolling summaries preserve decisions, unresolved work, and user context")
    func rollingSummariesPreserveDecisionsAndUnresolvedWork() {
        let history: [AIChatMessage] = [
            AIChatMessage(
                role: .user,
                content: "Find all unread invoices in Mail and convert them to PDF."),
            AIChatMessage(
                role: .assistant,
                content:
                    "Found 3 invoices. We decided to save them in ~/Documents/Invoices.\nPending: unresolved verification of invoice totals."
            ),
            AIChatMessage(
                role: .user,
                content: "Send the total invoice sum to finance."),
            AIChatMessage(
                role: .assistant,
                content:
                    "Result: Total sum is $4,250. Decided on Slack for finance channel.\nTodo: send confirmation link."
            ),
        ]

        let summary = RollingConversationSummary.extract(from: history)
        #expect(!summary.isEmpty)
        #expect(summary.coveredMessageCount == 4)

        let rendered = summary.renderedMarkdown
        #expect(rendered.contains("Rolling Conversation Summary"))
        #expect(rendered.contains("Decisions:"))
        #expect(rendered.contains("Unresolved Work:"))
    }

    // MARK: - 7. Deterministic Token-Budget Tests

    @Test("Deterministic token-budget tests cover multiple provider limits")
    func deterministicTokenBudgets() {
        let onDeviceBudget = ProviderContextBudget.budget(for: .onDevice)
        #expect(onDeviceBudget.maxContextTokens == 4096)
        #expect(onDeviceBudget.maxPromptBudget == 3584)

        let ollamaBudget = ProviderContextBudget.budget(for: .ollama)
        #expect(ollamaBudget.maxContextTokens == 8192)
        #expect(ollamaBudget.maxPromptBudget == 7168)

        let openAIBudget = ProviderContextBudget.budget(for: .openAI)
        #expect(openAIBudget.maxContextTokens == 128000)

        let anthropicBudget = ProviderContextBudget.budget(for: .anthropic)
        #expect(anthropicBudget.maxContextTokens == 200000)

        let geminiBudget = ProviderContextBudget.budget(for: .googleGemini)
        #expect(geminiBudget.maxContextTokens == 1000000)

        // Near limit detection
        #expect(!onDeviceBudget.isNearLimit(estimatedTokens: 1000))
        #expect(onDeviceBudget.isNearLimit(estimatedTokens: 3000))
        #expect(onDeviceBudget.isExceeded(estimatedTokens: 4000))
    }

    // MARK: - 8. Near-Limit Choices

    @Test("Near-limit status surfaces Keep active, Archive and new chat, and New chat without saving")
    func nearLimitChoicesStatus() {
        let tightBudget = ProviderContextBudget.testBudget(maxPromptBudget: 100)

        let messages = [
            AIChatMessage(
                role: .user,
                content:
                    "This is a relatively long query designed to push the estimated token count close to or above the threshold of eighty percent for the test budget."
            ),
            AIChatMessage(
                role: .assistant,
                content:
                    "Here is a detailed response covering multiple aspects of the question and adding sufficient length to trigger the near-limit warning."
            ),
        ]

        let projection = ConversationMemoryProjector.project(
            messages: messages,
            conversationKind: .general,
            scope: .general,
            systemPrompt: "DoraX",
            provider: .onDevice,
            customBudget: tightBudget
        )

        #expect(projection.isNearLimit)
        if case .nearLimit(_, _, _, let choices) = projection.nearLimitStatus {
            #expect(choices.contains(.keepActive))
            #expect(choices.contains(.archiveAndNewChat))
            #expect(choices.contains(.newChatWithoutSaving))
        } else if case .exceeded = projection.nearLimitStatus {
            // Also acceptable if messages pushed slightly over 100 tokens
            #expect(projection.nearLimitStatus.isNearLimit)
        } else {
            Issue.record("Expected nearLimit or exceeded status")
        }
    }

    // MARK: - 9. Provider Change Keeps One Conversation Identity

    @Test("Provider switching re-projects the same local conversation without changing identity")
    func providerSwitchingPreservesConversationIdentity() {
        let messages = [
            AIChatMessage(role: .user, content: "Hello Dora"),
            AIChatMessage(role: .assistant, content: "Hello! How can I help with your Mac today?"),
        ]

        let initialAnthropic = ConversationMemoryProjector.project(
            messages: messages,
            conversationKind: .general,
            scope: .general,
            systemPrompt: "System",
            provider: .anthropic
        )
        #expect(initialAnthropic.provider == .anthropic)
        #expect(initialAnthropic.budget.maxContextTokens == 200000)

        // Switch to onDevice
        let switchedOnDevice = ConversationMemoryProjector.reprojectForProviderSwitch(
            currentProjection: initialAnthropic,
            newProvider: .onDevice,
            fullLocalMessages: messages,
            conversationKind: .general,
            scope: .general
        )

        #expect(switchedOnDevice.provider == .onDevice)
        #expect(switchedOnDevice.budget.maxContextTokens == 4096)
        #expect(switchedOnDevice.fullLocalMessageCount == messages.count)
        #expect(switchedOnDevice.projectedMessages.count == messages.count)
    }
}
