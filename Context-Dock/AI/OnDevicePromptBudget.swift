// OnDevicePromptBudget.swift
// Context-Dock
//
// Proactive token budgeting for the on-device Apple Intelligence model.
//
// The on-device model has a 4,096-token context window shared by system instructions,
// conversation history, and the model's reply. E5a added reactive overflow recovery
// (condense + retry). E5b adds proactive measurement: count tokens before dispatching
// and trim the oldest history turns until the prompt fits, so the error path is never
// hit in normal operation.
//
// Token counting uses a character-based estimate (the same proxy AIContextBudget uses),
// which is accurate enough for budget purposes and costs nothing at dispatch time. The
// counter is injectable via a protocol so unit tests can supply exact counts.

import Foundation

// MARK: - Token counter protocol

protocol OnDeviceTokenCounter: Sendable {
    func count(_ text: String) async -> Int
}

/// Default counter: ~4 characters per English token, matching AIContextBudget's proxy.
struct CharacterTokenCounter: OnDeviceTokenCounter {
    func count(_ text: String) async -> Int { (text.count + 3) / 4 }
}

// MARK: - Budget constants and fitting logic

enum OnDevicePromptBudget {
    /// Total context window for the on-device model.
    static let windowTokens = 4_096
    /// Token headroom reserved for the model's reply — never consumed by prompt content.
    static let replyReserve = 1_000
    /// Maximum tokens that system instructions + history + user message may occupy.
    /// When native multimodal image prompts are attached on macOS 27.0+, callers subtract
    /// `OnDeviceImagePrompt.estimatedTokensPerImage` per image (~130–200 tokens) from this cap.
    static let maxPromptTokens = windowTokens - replyReserve  // 3,096

    /// Returns the history slice that fits within `maxTokens` when combined with
    /// `systemPrompt` and `message`. Drops the oldest turns first until the assembled
    /// text is within budget or history is exhausted.
    ///
    /// Pass `counter` explicitly in tests to supply exact token counts; production callers
    /// use the default `CharacterTokenCounter`.
    static func fittingHistory(
        systemPrompt: String,
        history: [ChatMessage],
        message: String,
        counter: some OnDeviceTokenCounter = CharacterTokenCounter(),
        maxTokens: Int = maxPromptTokens
    ) async -> [ChatMessage] {
        var trimmed = history
        while true {
            let assembled = assembleForCounting(system: systemPrompt, history: trimmed, message: message)
            let n = await counter.count(assembled)
            if n <= maxTokens || trimmed.isEmpty { return trimmed }
            trimmed = Array(trimmed.dropFirst())
        }
    }

    /// Assembles a single string from the same parts `sendToOnDevice` uses, so the
    /// count reflects the actual bytes sent to the session.
    static func assembleForCounting(system: String, history: [ChatMessage], message: String) -> String {
        var parts = [system]
        if !history.isEmpty {
            var block = "## Conversation History\n"
            for msg in history {
                let label = msg.role == .user ? "User" : "Assistant"
                block += "\(label): \(msg.content)\n"
            }
            parts.append(block)
        }
        parts.append(message)
        return parts.joined(separator: "\n\n")
    }
}
