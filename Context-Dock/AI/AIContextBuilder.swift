import Foundation
import UniformTypeIdentifiers

@MainActor
final class AIContextBuilder {
    static let shared = AIContextBuilder()

    private init() {}

    func build(request: AIRequest) -> String {
        var prompt = build(context: request.context, additionalPrompt: request.additionalContextPrompt)
        prompt += "\n\nRequest source: \(request.source.rawValue)"
        prompt += "\nRequest mode: \(request.mode.rawValue)"
        prompt += "\n" + behaviorRule(for: request)
        if let live = request.liveContext {
            prompt += "\n\n" + liveContextBlock(live)
        }
        if !request.attachments.isEmpty {
            let attachmentSummary = request.attachments.prefix(20).map { attachment in
                "- \(attachment.kind.rawValue): \(metadata(for: attachment.url))"
            }.joined(separator: "\n")
            prompt += "\n\nAttachments:\n\(attachmentSummary)"
        }
        return prompt
    }

    func build(context: UserContext, additionalPrompt: String = "") -> String {
        var sections = [
            "You are Context-Dock's AI assistant. Use the supplied user context accurately and do not invent unavailable state."
        ]

        switch context {
        case .filesSelected(let files):
            sections.append("Selected files:\n\(files.prefix(20).map(\.path).joined(separator: "\n"))")
        case .textSelected(let text):
            sections.append("Selected text:\n\(text)")
        case .url(let url):
            sections.append("Selected URL:\n\(url)")
        case .appFocused(let name, let bundleID):
            sections.append("Frontmost app: \(name) (\(bundleID))")
        case .contactSelected(let contact):
            sections.append("Selected contact:\n\(contact)")
        case .none:
            sections.append("No explicit selection is available.")
        }

        let extra = additionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { sections.append(extra) }
        return sections.joined(separator: "\n\n")
    }

    private func behaviorRule(for request: AIRequest) -> String {
        switch request.source {
        case .globalContext:
            switch request.context {
            case .none:
                return "Behavior: Answer general request. Do not assume selection or app state."
            default:
                return "Behavior: Answer about explicit selected context. Do not execute actions unless user explicitly requests execution."
            }
        case .contextDock:
            return "Behavior: Stay scoped to frontmost app context and registered capabilities. Plan before execution."
        case .mediaDock:
            return "Behavior: Analyze supplied media only. State when provider cannot inspect media contents."
        case .aiChat:
            return "Behavior: Provide direct conversational answer."
        case .extensionSystem:
            return "Behavior: Follow extension task and supplied context only."
        case .workflow:
            return "Behavior: Return precise workflow result or action plan."
        }
    }

    private func metadata(for url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentTypeKey, .nameKey,
        ])
        var parts = [values?.name ?? url.lastPathComponent, url.path]
        if values?.isDirectory == true {
            parts.append("directory")
        } else {
            if let type = values?.contentType?.identifier { parts.append(type) }
            if let size = values?.fileSize {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
        }
        return parts.joined(separator: " | ")
    }

    private func liveContextBlock(_ context: AIContextSnapshot) -> String {
        var lines = ["Shared context snapshot:", "- App: \(context.appName) (\(context.bundleID))"]
        if let title = context.windowTitle, !title.isEmpty { lines.append("- Window: \(title)") }
        if let text = context.selectedText, !text.isEmpty {
            lines.append("- Selected text source: \(context.selectedTextSource ?? context.appName)")
            lines.append("- Selected text characters: \(context.selectedTextCharacterCount)")
            lines.append("- Selected text: \(String(text.prefix(2_000)))")
        }
        if !context.selectedFiles.isEmpty {
            lines.append("- Selected files:\n\(context.selectedFiles.prefix(20).map { "  - \($0)" }.joined(separator: "\n"))")
        }
        if let url = context.browserURL, !url.isEmpty { lines.append("- Browser URL: \(url)") }
        if let title = context.browserTitle, !title.isEmpty { lines.append("- Browser title: \(title)") }
        if let directory = context.currentDirectory, !directory.isEmpty {
            lines.append("- Current directory: \(directory)")
        }
        if !context.menuCapabilities.isEmpty {
            lines.append("- Available menu capabilities:\n\(context.menuCapabilities.prefix(80).map { "  - \($0)" }.joined(separator: "\n"))")
        }
        if !context.registeredCapabilities.isEmpty {
            lines.append("- Registered capabilities:\n\(context.registeredCapabilities.prefix(80).map { "  - \($0)" }.joined(separator: "\n"))")
        }
        return lines.joined(separator: "\n")
    }
}
