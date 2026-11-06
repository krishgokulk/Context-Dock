// SideThread.swift
// Context-Dock
//
// Side Thread (branch a sub-conversation) for App Pet, Combined Chat, and General Chat (#333).
//
// A side thread branches a temporary tangent off an active conversation turn without polluting
// the main conversation transcript or Pet durable memory. It operates as a child view of the
// same scope's storage rather than a new surface, preserving scope and grounding.
//
// When finished, the user can explicitly fold back a concise summary into the main thread, or
// discard the tangent entirely.

import Foundation

struct SideThreadState: Identifiable, Equatable {
    let id: UUID
    let parentMessageID: UUID?
    let parentTurnSnippet: String
    let parentScopeKey: String
    var messages: [AIChatMessage]
    var isSending: Bool
    var liveSteps: [String]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        parentMessageID: UUID? = nil,
        parentTurnSnippet: String = "",
        parentScopeKey: String = "general",
        messages: [AIChatMessage] = [],
        isSending: Bool = false,
        liveSteps: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.parentMessageID = parentMessageID
        self.parentTurnSnippet = parentTurnSnippet
        self.parentScopeKey = parentScopeKey
        self.messages = messages
        self.isSending = isSending
        self.liveSteps = liveSteps
        self.createdAt = createdAt
    }

    var isEmpty: Bool {
        messages.isEmpty
    }

    var turnCount: Int {
        messages.count
    }
}

enum SideThreadSummarizer {
    static func extractTurnSnippet(from message: AIChatMessage?, maxLength: Int = 120) -> String {
        guard let message else { return "" }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return "" }
        let firstLine = content.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? content
        let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= maxLength {
            return clean
        }
        return String(clean.prefix(maxLength - 1)) + "…"
    }

    static func generateFoldBackSummary(
        parentSnippet: String,
        messages: [AIChatMessage]
    ) -> String {
        let assistantMessages = messages.filter {
            $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.isError
        }
        let userMessages = messages.filter {
            $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var lines: [String] = []
        let cleanSnippet = parentSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSnippet.isEmpty {
            let truncated = cleanSnippet.count > 60 ? String(cleanSnippet.prefix(57)) + "…" : cleanSnippet
            lines.append("📌 **Side Thread Summary** _(branched from: “\(truncated)”)_")
        } else {
            lines.append("📌 **Side Thread Summary**")
        }
        lines.append("")

        if assistantMessages.isEmpty {
            if let firstQuestion = userMessages.first?.content {
                lines.append("Explored side tangent: \(firstQuestion)")
            } else {
                lines.append("Side conversation concluded with no additional findings.")
            }
        } else {
            for (idx, msg) in assistantMessages.enumerated() {
                let questionContext = idx < userMessages.count ? userMessages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                let cleanContent = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let firstParagraph = cleanContent.components(separatedBy: "\n\n").first ?? cleanContent
                let summaryLine = firstParagraph.components(separatedBy: .newlines).first ?? firstParagraph
                let trimmedLine = summaryLine.trimmingCharacters(in: .whitespacesAndNewlines)

                if let questionContext, !questionContext.isEmpty {
                    lines.append("• **Q:** \(questionContext)")
                    lines.append("  **A:** \(trimmedLine)")
                } else {
                    let bullet = trimmedLine.hasPrefix("•") || trimmedLine.hasPrefix("-") ? trimmedLine : "• \(trimmedLine)"
                    lines.append(bullet)
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
