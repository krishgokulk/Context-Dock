import Foundation

struct AIRequestBuilder {
    static func aiChat(
        text: String,
        history: [ChatMessage] = [],
        attachments: [URL] = [],
        liveContext: AIContextSnapshot? = nil,
        includesWorkflowCapabilities: Bool = false
    ) -> AIRequest {
        AIRequest(
            text: text,
            context: attachments.isEmpty ? .none : .filesSelected(attachments),
            history: history,
            attachments: attachments.map(AIAttachment.inferred(from:)),
            mode: .answer,
            source: .aiChat,
            liveContext: liveContext,
            includesWorkflowCapabilities: includesWorkflowCapabilities
        )
    }

    static func globalContext(
        text: String,
        context: UserContext,
        history: [ChatMessage] = [],
        attachments: [URL] = [],
        mode: AIRequestMode = .answer,
        capabilityPrompt: String = ""
    ) -> AIRequest {
        AIRequest(
            text: text,
            context: context,
            history: history,
            attachments: attachments.map(AIAttachment.inferred(from:)),
            mode: mode,
            source: .globalContext,
            liveContext: ContextCollector.shared.snapshot(),
            additionalContextPrompt: capabilityPrompt
        )
    }

    static func contextDock(
        text: String,
        context: UserContext,
        history: [ChatMessage] = [],
        attachments: [URL] = [],
        mode: AIRequestMode = .answer,
        capabilityPrompt: String = ""
    ) -> AIRequest {
        return AIRequest(
            text: text,
            context: context,
            history: history,
            attachments: attachments.map(AIAttachment.inferred(from:)),
            mode: mode,
            source: .contextDock,
            liveContext: ContextCollector.shared.snapshot(),
            additionalContextPrompt: capabilityPrompt
        )
    }

    static func mediaDock(
        text: String,
        media: [URL],
        history: [ChatMessage] = []
    ) -> AIRequest {
        AIRequest(
            text: text,
            context: .filesSelected(media),
            history: history,
            attachments: media.map(AIAttachment.inferred(from:)),
            mode: .answer,
            source: .mediaDock
        )
    }
}
