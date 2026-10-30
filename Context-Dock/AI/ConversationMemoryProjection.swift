// ConversationMemoryProjection.swift
// Context-Dock
//
// Active provider context projection and conversation memory (#340).
//
// Ref: docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md §6
//
// 1. Full transcript stays local and searchable; provider context is a bounded projection.
// 2. Rolling factual summaries distinguish user statements, observed facts, assistant inferences
//    and verified receipts.
// 3. Provider switching re-projects the same local conversation without creating a second thread.
// 4. Near-limit choices: Keep active, Archive and new chat, New chat without saving.

import Foundation

/// Bounded context limits and token budgets for AI providers (#340).
struct ProviderContextBudget: Equatable, Sendable {
    let maxContextTokens: Int
    let reservedOutputTokens: Int
    let maxPromptBudget: Int
    let nearLimitThreshold: Double

    init(
        maxContextTokens: Int,
        reservedOutputTokens: Int = 1024,
        nearLimitThreshold: Double = 0.80
    ) {
        self.maxContextTokens = maxContextTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.maxPromptBudget = max(32, maxContextTokens - reservedOutputTokens)
        self.nearLimitThreshold = nearLimitThreshold
    }

    func isNearLimit(estimatedTokens: Int) -> Bool {
        Double(estimatedTokens) >= Double(maxPromptBudget) * nearLimitThreshold
    }

    func isExceeded(estimatedTokens: Int) -> Bool {
        estimatedTokens > maxPromptBudget
    }

    /// Canonical token budget presets per provider (#340).
    static func budget(for provider: AIProvider) -> ProviderContextBudget {
        switch provider {
        case .onDevice:
            return ProviderContextBudget(maxContextTokens: 4096, reservedOutputTokens: 512)
        case .ollama:
            return ProviderContextBudget(maxContextTokens: 8192, reservedOutputTokens: 1024)
        case .openAI, .openAICompatible:
            return ProviderContextBudget(maxContextTokens: 128000, reservedOutputTokens: 4096)
        case .anthropic:
            return ProviderContextBudget(maxContextTokens: 200000, reservedOutputTokens: 4096)
        case .googleGemini:
            return ProviderContextBudget(maxContextTokens: 1000000, reservedOutputTokens: 8192)
        case .claudeCode:
            return ProviderContextBudget(maxContextTokens: 160000, reservedOutputTokens: 4096)
        case .chatGPTSubscription:
            return ProviderContextBudget(maxContextTokens: 100000, reservedOutputTokens: 4096)
        case .kimi:
            return ProviderContextBudget(maxContextTokens: 128000, reservedOutputTokens: 4096)
        case .claudeBridge, .chatGPTBridge:
            return ProviderContextBudget(maxContextTokens: 128000, reservedOutputTokens: 4096)
        case .shortcuts:
            return ProviderContextBudget(maxContextTokens: 4096, reservedOutputTokens: 512)
        }
    }

    /// Custom budget constructor for deterministic token-budget testing.
    static func testBudget(maxPromptBudget: Int, nearLimitThreshold: Double = 0.80) -> ProviderContextBudget {
        let reserved = 32
        return ProviderContextBudget(
            maxContextTokens: maxPromptBudget + reserved,
            reservedOutputTokens: reserved,
            nearLimitThreshold: nearLimitThreshold
        )
    }
}

/// Pure, deterministic token estimation for local context bounds (#340).
enum TokenEstimator {
    /// Estimates token count for a text string using deterministic heuristic
    /// (~3.8 characters per token, minimum 1 token per non-empty word).
    static func estimateTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let charEstimate = Int(ceil(Double(trimmed.count) / 3.8))
        let words = trimmed.split { $0.isWhitespace || $0.isPunctuation }.count
        return max(charEstimate, words)
    }

    /// Estimates token count for an AIChatMessage including role overhead.
    static func estimateMessage(_ message: AIChatMessage) -> Int {
        // Base overhead for message framing/role (~4 tokens)
        4 + estimateTokens(message.content)
    }

    /// Estimates token count for an array of messages.
    static func estimateMessages(_ messages: [AIChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateMessage($1) }
    }
}

/// Rolling summary of older conversation turns preserving provenance, decisions and unresolved work (#340).
struct RollingConversationSummary: Codable, Equatable, Sendable {
    var userStatements: [String]
    var observedFacts: [String]
    var decisions: [String]
    var unresolvedWork: [String]
    var coveredMessageCount: Int
    var updatedAt: Date

    init(
        userStatements: [String] = [],
        observedFacts: [String] = [],
        decisions: [String] = [],
        unresolvedWork: [String] = [],
        coveredMessageCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.userStatements = userStatements
        self.observedFacts = observedFacts
        self.decisions = decisions
        self.unresolvedWork = unresolvedWork
        self.coveredMessageCount = coveredMessageCount
        self.updatedAt = updatedAt
    }

    var isEmpty: Bool {
        userStatements.isEmpty && observedFacts.isEmpty && decisions.isEmpty && unresolvedWork.isEmpty
    }

    /// Renders the rolling summary into structured Markdown for provider prompt injection.
    var renderedMarkdown: String {
        guard !isEmpty else { return "" }
        var sections: [String] = ["### Rolling Conversation Summary"]

        if !decisions.isEmpty {
            sections.append("**Decisions:**\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !unresolvedWork.isEmpty {
            sections.append("**Unresolved Work:**\n" + unresolvedWork.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !observedFacts.isEmpty {
            sections.append("**Observed Facts:**\n" + observedFacts.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !userStatements.isEmpty {
            sections.append("**User Context:**\n" + userStatements.map { "- \($0)" }.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    /// Extracts a rolling summary from an array of older conversation messages.
    static func extract(from messages: [AIChatMessage]) -> RollingConversationSummary {
        var userStmts: [String] = []
        var obsFacts: [String] = []
        var decs: [String] = []
        var unres: [String] = []

        for msg in messages {
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.role == .user {
                if content.count > 10 && !content.hasPrefix("/") {
                    // Extract core user intent
                    let firstSentence = content.components(separatedBy: CharacterSet(charactersIn: ".?!")).first ?? content
                    userStmts.append(firstSentence.trimmingCharacters(in: .whitespaces))
                }
            } else if msg.role == .assistant {
                // Look for decisions or receipts
                let lines = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                for line in lines {
                    let lower = line.lowercased()
                    if lower.contains("decided") || lower.contains("we will") || lower.contains("chosen") {
                        decs.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "-* ")))
                    } else if lower.contains("todo") || lower.contains("pending") || lower.contains("unresolved") || lower.contains("next step") {
                        unres.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "-* ")))
                    } else if lower.contains("found") || lower.contains("result:") || lower.contains("verified") {
                        obsFacts.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "-* ")))
                    }
                }
            }
        }

        return RollingConversationSummary(
            userStatements: Array(userStmts.suffix(4)),
            observedFacts: Array(obsFacts.suffix(4)),
            decisions: Array(decs.suffix(4)),
            unresolvedWork: Array(unres.suffix(4)),
            coveredMessageCount: messages.count,
            updatedAt: Date()
        )
    }
}

/// Choices offered to the user near provider context limits (#340).
enum NearLimitChoice: String, CaseIterable, Codable, Sendable {
    /// Condense older turns into the rolling summary and continue in the active thread.
    case keepActive = "Keep active"
    /// Archive the current thread to session history and start a new clean chat with memory preserved.
    case archiveAndNewChat = "Archive and new chat"
    /// Start a new clean chat immediately without saving current rolling summary.
    case newChatWithoutSaving = "New chat without saving"
}

/// Near-limit status of a conversation projection (#340).
enum NearLimitStatus: Equatable, Sendable {
    case withinSafeBudget(usedTokens: Int, maxBudget: Int, ratio: Double)
    case nearLimit(usedTokens: Int, maxBudget: Int, ratio: Double, choices: [NearLimitChoice])
    case exceeded(usedTokens: Int, maxBudget: Int, ratio: Double)

    var isNearLimit: Bool {
        switch self {
        case .nearLimit, .exceeded:
            return true
        case .withinSafeBudget:
            return false
        }
    }
}

/// Bounded provider projection of a conversation (#340).
struct ConversationProjection: Equatable, Sendable {
    let provider: AIProvider
    let budget: ProviderContextBudget
    let systemPrompt: String
    let projectedMessages: [AIChatMessage]
    let rollingSummary: RollingConversationSummary?
    let activeTurnWindowMessages: [AIChatMessage]
    let estimatedTotalTokens: Int
    let nearLimitStatus: NearLimitStatus
    let fullLocalMessageCount: Int

    var isNearLimit: Bool {
        nearLimitStatus.isNearLimit
    }
}

/// Projects full local conversations into bounded provider payloads (#340).
enum ConversationMemoryProjector {
    /// Projects a local conversation and its three-tier memory into a bounded provider payload.
    ///
    /// Preserves full local transcripts on disk while fitting prompt content strictly to the selected provider.
    static func project(
        messages: [AIChatMessage],
        conversationKind: ConversationKind,
        scope: GeneralChatScope,
        petMemoryRecords: [PetMemoryRecord] = [],
        workspaceMemory: CombinedWorkspaceMemory? = nil,
        globalMemoryBlock: String = "",
        systemPrompt: String = "",
        provider: AIProvider,
        customBudget: ProviderContextBudget? = nil
    ) -> ConversationProjection {
        let budget = customBudget ?? ProviderContextBudget.budget(for: provider)
        let systemPromptTokens = TokenEstimator.estimateTokens(systemPrompt)

        // 1. Tier Memory Context Assembly
        var memorySections: [String] = []

        // Tier 1: Pinned records take precedence, followed by admitted records
        if conversationKind.loadsAppPetMemory && !petMemoryRecords.isEmpty {
            let admitted = petMemoryRecords.filter(\.provenance.isAdmitted)
            let pinned = admitted.filter(\.isPinned)
            let unpinned = admitted.filter { !$0.isPinned }

            var petLines: [String] = []
            if !pinned.isEmpty {
                petLines.append("Pinned Pet Facts:")
                for p in pinned { petLines.append("- ★ \(p.fact)") }
            }
            if !unpinned.isEmpty {
                petLines.append("Pet Facts:")
                for u in unpinned.prefix(6) { petLines.append("- \(u.fact)") }
            }
            if !petLines.isEmpty {
                memorySections.append(petLines.joined(separator: "\n"))
            }
        }

        // Tier 2: Combined Chat Workspace Memory
        if case .combined = conversationKind, let ws = workspaceMemory {
            var wsLines = ["Combined Workspace Goals:"]
            if !ws.taskSummary.isEmpty { wsLines.append("Task: \(ws.taskSummary)") }
            if !ws.decisions.isEmpty { wsLines.append("Decisions: " + ws.decisions.joined(separator: "; ")) }
            if !ws.unresolvedWork.isEmpty { wsLines.append("Pending: " + ws.unresolvedWork.joined(separator: "; ")) }
            memorySections.append(wsLines.joined(separator: "\n"))
        }

        // Tier 3: Global Context Memory
        if !globalMemoryBlock.isEmpty {
            memorySections.append(globalMemoryBlock)
        }

        let combinedMemoryText = memorySections.joined(separator: "\n\n")
        let memoryTokens = TokenEstimator.estimateTokens(combinedMemoryText)
        let overheadTokens = systemPromptTokens + memoryTokens

        // Available tokens for messages (rolling summary + active turn window)
        let availableForMessages = max(64, budget.maxPromptBudget - overheadTokens)

        // 2. Windowing: Split messages into active turn window and older history
        var activeWindow: [AIChatMessage] = []
        var olderMessages: [AIChatMessage] = []
        var runningWindowTokens = 0

        // Iterate backwards from newest message to fit into active turn window
        for msg in messages.reversed() {
            let msgTokens = TokenEstimator.estimateMessage(msg)
            // Keep at least the latest user query, or what fits within 65% of available space
            let targetWindowBudget = max(128, Int(Double(availableForMessages) * 0.70))
            if activeWindow.isEmpty || (runningWindowTokens + msgTokens <= targetWindowBudget) {
                activeWindow.insert(msg, at: 0)
                runningWindowTokens += msgTokens
            } else {
                olderMessages.insert(msg, at: 0)
            }
        }

        // 3. Rolling Summary for older messages
        var rollingSummary: RollingConversationSummary? = nil
        var summaryTokens = 0
        if !olderMessages.isEmpty {
            let summary = RollingConversationSummary.extract(from: olderMessages)
            rollingSummary = summary
            summaryTokens = TokenEstimator.estimateTokens(summary.renderedMarkdown)
        }

        let totalEstimatedTokens = overheadTokens + runningWindowTokens + summaryTokens
        let ratio = Double(totalEstimatedTokens) / Double(budget.maxPromptBudget)

        let status: NearLimitStatus
        if budget.isExceeded(estimatedTokens: totalEstimatedTokens) {
            status = .exceeded(usedTokens: totalEstimatedTokens, maxBudget: budget.maxPromptBudget, ratio: ratio)
        } else if budget.isNearLimit(estimatedTokens: totalEstimatedTokens) {
            status = .nearLimit(
                usedTokens: totalEstimatedTokens,
                maxBudget: budget.maxPromptBudget,
                ratio: ratio,
                choices: NearLimitChoice.allCases
            )
        } else {
            status = .withinSafeBudget(usedTokens: totalEstimatedTokens, maxBudget: budget.maxPromptBudget, ratio: ratio)
        }

        return ConversationProjection(
            provider: provider,
            budget: budget,
            systemPrompt: systemPrompt,
            projectedMessages: activeWindow,
            rollingSummary: rollingSummary,
            activeTurnWindowMessages: activeWindow,
            estimatedTotalTokens: totalEstimatedTokens,
            nearLimitStatus: status,
            fullLocalMessageCount: messages.count
        )
    }

    /// Re-projects an existing local conversation when the provider changes (#340).
    ///
    /// Preserves single conversation identity while recalculating the bounded payload
    /// for the new provider's budget.
    static func reprojectForProviderSwitch(
        currentProjection: ConversationProjection,
        newProvider: AIProvider,
        fullLocalMessages: [AIChatMessage],
        conversationKind: ConversationKind,
        scope: GeneralChatScope,
        petMemoryRecords: [PetMemoryRecord] = [],
        workspaceMemory: CombinedWorkspaceMemory? = nil,
        globalMemoryBlock: String = ""
    ) -> ConversationProjection {
        project(
            messages: fullLocalMessages,
            conversationKind: conversationKind,
            scope: scope,
            petMemoryRecords: petMemoryRecords,
            workspaceMemory: workspaceMemory,
            globalMemoryBlock: globalMemoryBlock,
            systemPrompt: currentProjection.systemPrompt,
            provider: newProvider
        )
    }
}
