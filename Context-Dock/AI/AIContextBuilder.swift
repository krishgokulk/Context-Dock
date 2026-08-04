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
            prompt += "\n\n" + liveContextBlock(live, query: request.text)
        }
        if request.source == .globalContext || request.includesWorkflowCapabilities {
            prompt += "\n\n" + AppWorkflowToolCatalog.shared.generalChatPromptBlock(
                query: request.text,
                liveBundleID: request.liveContext?.bundleID
            )
        }
        if request.source != .mediaDock {
            let appBundleID = request.source == .contextDock ? request.liveContext?.bundleID : nil
            let memory = MarkdownMemoryStore.shared.contextBlock(
                query: request.text,
                appBundleID: appBundleID
            )
            if !memory.isEmpty { prompt += "\n\n" + memory }
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
            let analyzed = ContextDetector.shared.analyzeFiles(Array(files.prefix(6)))
            var remainingBudget = 12_000
            let documentBlocks = analyzed.compactMap { item -> String? in
                guard remainingBudget > 500,
                    let content = item.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !content.isEmpty
                else { return nil }
                let excerpt = String(content.prefix(remainingBudget))
                remainingBudget -= excerpt.count
                return "### \(item.url.lastPathComponent)\n\(excerpt)"
            }
            if !documentBlocks.isEmpty {
                sections.append(
                    "Token-budgeted document context (MarkItDown when available):\n\n"
                        + documentBlocks.joined(separator: "\n\n"))
            }
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
                return "Behavior: Answer general request. You may reference registered app workflow tools and saved app chat history when relevant. Do not execute actions unless user explicitly requests execution."
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

    private func liveContextBlock(_ context: AIContextSnapshot, query: String) -> String {
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
        if let browser = context.browserContext,
           let markdown = browser.cleanMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !markdown.isEmpty
        {
            lines.append("- Web context app: \(browser.appName ?? context.appName)")
            lines.append("- Web context source: \(browser.source ?? "WebContextEngine")")
            if let capturedAt = browser.capturedAt {
                lines.append("- Web context captured: \(relativeDate(capturedAt))")
            }
            if let quality = browser.qualityScore {
                lines.append("- Web context quality: \(Int((quality * 100).rounded()))%")
            }
            if let words = browser.wordCount { lines.append("- Web context words: \(words)") }
            if let codeBlocks = browser.codeBlockCount {
                lines.append("- Web context code blocks: \(codeBlocks)")
            }
            lines.append("- Web context characters: \(markdown.count)")
            if !browser.headings.isEmpty {
                lines.append("- Page headings:\n\(browser.headings.prefix(30).map { "  - \($0)" }.joined(separator: "\n"))")
            }
            if !browser.links.isEmpty {
                lines.append("- Page links:\n\(browser.links.prefix(20).map { "  - \($0)" }.joined(separator: "\n"))")
            }
            if !browser.images.isEmpty {
                lines.append("- Page images:\n\(browser.images.prefix(10).map { "  - \($0)" }.joined(separator: "\n"))")
            }
            lines.append("Relevant page Markdown:\n\(relevantMarkdown(from: markdown, query: query, limit: 8_000))")
        }
        if !context.connectedBrowserContexts.isEmpty {
            lines.append("Connected running browser contexts:")
            for browser in context.connectedBrowserContexts.prefix(4) {
                guard let markdown = browser.cleanMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !markdown.isEmpty
                else { continue }
                var header = "- \(browser.appName ?? "Browser")"
                if let title = browser.title, !title.isEmpty { header += ": \(title)" }
                header += " | \(browser.url)"
                if let quality = browser.qualityScore {
                    header += " | quality \(Int((quality * 100).rounded()))%"
                }
                lines.append(header)
                if !browser.headings.isEmpty {
                    lines.append("  Headings: \(browser.headings.prefix(8).joined(separator: " | "))")
                }
                lines.append(
                    "  Relevant Markdown:\n\(indent(relevantMarkdown(from: markdown, query: query, limit: 2_200), spaces: 2))"
                )
            }
        }
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

    private func relevantMarkdown(from markdown: String, query: String, limit: Int) -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else { return String(markdown.prefix(limit)) }

        let terms = Set(
            trimmedQuery
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )
        guard !terms.isEmpty else { return String(markdown.prefix(limit)) }

        let sections = splitMarkdownIntoSections(markdown)
        let ranked = sections
            .map { section -> (score: Int, text: String) in
                let lower = section.lowercased()
                let score = terms.reduce(0) { partial, term in
                    partial + lower.components(separatedBy: term).count - 1
                }
                return (score, section)
            }
            .sorted {
                if $0.score == $1.score { return $0.text.count > $1.text.count }
                return $0.score > $1.score
            }

        let selected = ranked.filter { $0.score > 0 }.prefix(4).map(\.text)
        let chosen = selected.isEmpty ? Array(sections.prefix(2)) : Array(selected)
        var output = chosen.joined(separator: "\n\n")
        if output.count < min(limit, 1_500), let first = sections.first, !output.contains(first) {
            output = first + "\n\n" + output
        }
        return String(output.prefix(limit))
    }

    private func splitMarkdownIntoSections(_ markdown: String) -> [String] {
        var sections: [String] = []
        var current: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("#"), !current.isEmpty {
                sections.append(current.joined(separator: "\n"))
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func indent(_ text: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return text.components(separatedBy: .newlines).map { prefix + $0 }.joined(separator: "\n")
    }

    private func relativeDate(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}
