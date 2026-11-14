// ReadingTools.swift
// Context-Dock
//
// The tools that let the model go and look.
//
// DoraX could run a shell command, click a menu and drive an app adapter, and could not read
// the web page whose URL it was holding. Everything the model knew arrived as a snapshot
// assembled before it was asked — fifteen prompt blocks, gathered up front — so when the
// snapshot missed the thing the question was about, the model had no move except to say it
// did not have that. It looked incurious because it was: the app had already done all the
// looking, and left it nothing to look with.
//
// These are deliberately the dullest tools in the registry. Read-only, no approval, no side
// effects, nothing that changes the machine. That is what makes them safe to hand over
// freely, and handing them over freely is the whole point — a model that can check is a model
// that stops guessing.

import AppKit
import Foundation

extension AgentToolRegistry {

    /// Characters returned from one read. Enough for a long article or a source file, small
    /// enough that three reads in a turn do not crowd out the conversation.
    private static let readBudget = 12_000

    func registerReadingTools() {
        register(makeReadPageTool())
        register(makeReadURLTool())
        register(makeReadFileTool())
        register(makeReadSelectionTool())
        // Finding a file is reading too: paths out, nothing opened. See FileSearchTool.swift.
        registerFileSearchTool()
    }

    // MARK: - The page in front of the user

    private func makeReadPageTool() -> AgentTool {
        AgentTool(
            name: "read_page",
            description: "Read the web page the user is looking at right now — its title, "
                + "URL, visible text and links. Call this before answering any question "
                + "about \"this page\", what is on screen in a browser, or what a site says. "
                + "Read-only: it looks, it does not navigate or click.",
            properties: [
                "focus": [
                    "type": "string",
                    "description": "Optional: what you are looking for, so the page is "
                        + "compacted around it rather than truncated from the top.",
                ]
            ],
            required: []
        ) { arguments, context in
            let focus = arguments["focus"] as? String
            let bundleID = await MainActor.run { () -> String in
                if let scoped = AgentToolRegistry.scopedBundleID(for: context.chatScope) {
                    return scoped
                }
                // An unscoped chat asks the frontmost browser. `previousFrontmostApp` rather
                // than the frontmost one: while the dock is open, the frontmost app is DoraX.
                let candidate = AppDelegate.shared?.previousFrontmostApp
                    ?? NSWorkspace.shared.frontmostApplication
                return candidate?.bundleIdentifier ?? ""
            }
            guard await MainActor.run(body: {
                ScopedAppPromptBuilder.isBrowserBundle(bundleID)
            }) else {
                return AgentToolResult(
                    success: false,
                    output: "There is no browser in this conversation's scope, so there is no "
                        + "page to read. Say that plainly rather than guessing what a page "
                        + "might contain.",
                    displayCommand: "read_page")
            }
            let block = await MainActor.run {
                ScopedGroundingBlocks.browserPage(bundleId: bundleID, query: focus)
            }
            return await MainActor.run { AgentToolRegistry.readPageResult(block: block) }
        }
    }

    /// Pure: what `read_page` returns for the page block it read. A page SensitivePageGuard
    /// refused comes back as a plain refusal — outside the untrusted-content fence, so the
    /// model reads the reason as DoraX's and tells the user — never as page content.
    static func readPageResult(block: String) -> AgentToolResult {
        guard !block.isEmpty else {
            return AgentToolResult(
                success: false,
                output: "The page could not be read. DoraX reads pages through its Safari "
                    + "extension or the accessibility API; if neither is available, say "
                    + "the page is unreadable rather than describing it from memory.",
                displayCommand: "read_page")
        }
        if block.contains(ScopedGroundingBlocks.withheldMarker) {
            return AgentToolResult(success: false, output: block, displayCommand: "read_page")
        }
        return AgentToolResult(
            success: true,
            output: UntrustedContent.fenced(block, from: "the current web page"),
            displayCommand: "read_page")
    }

    // MARK: - A page that is not open

    private func makeReadURLTool() -> AgentTool {
        AgentTool(
            name: "read_url",
            description: "Fetch a web page by URL and read it as Markdown. Use when the user "
                + "gives a link, or when a page you already read links somewhere the answer "
                + "needs. Read-only: nothing is opened on screen and no browser is touched.",
            properties: [
                "url": ["type": "string", "description": "The full URL, including https://."],
                "focus": [
                    "type": "string",
                    "description": "Optional: what you are looking for on that page.",
                ],
            ],
            required: ["url"]
        ) { arguments, _ in
            let raw = (arguments["url"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                return AgentToolResult(
                    success: false,
                    output: "read_url needs a full http(s) URL.",
                    displayCommand: "read_url(\(raw))")
            }
            let focus = arguments["focus"] as? String
            let converted = await Task.detached(priority: .userInitiated) {
                MarkItDownService.convert(
                    url, characterBudget: AgentToolRegistry.readBudget, query: focus)
            }.value
            guard let converted, !converted.markdown.isEmpty else {
                return AgentToolResult(
                    success: false,
                    output: "Could not fetch \(url.absoluteString). Report that the page could "
                        + "not be read; do not answer from what you remember about the site.",
                    displayCommand: "read_url(\(url.host ?? raw))")
            }
            return AgentToolResult(
                success: true,
                output: UntrustedContent.fenced(converted.markdown, from: url.absoluteString),
                displayCommand: "read_url(\(url.host ?? raw))")
        }
    }

    // MARK: - A file on disk

    private func makeReadFileTool() -> AgentTool {
        AgentTool(
            name: "read_file",
            description: "Read a file's contents as text — source, Markdown, PDF, Word, "
                + "spreadsheets, anything DoraX can convert. Use this instead of `cat` or a "
                + "shell command: it handles documents a shell cannot, and it needs no "
                + "approval because it only reads. It is also how a file the user attached "
                + "to this message is read — text, PDF, or OCR for images and screenshots: "
                + "call it FIRST whenever the user says \"this\", \"this screenshot\" or "
                + "\"the attached file\", and do not guess the content from the clipboard.",
            properties: [
                "path": [
                    "type": "string",
                    "description": "Absolute path, or ~ relative to the user's home. For an "
                        + "attachment, its path or just its filename; omit when exactly one "
                        + "file is attached.",
                ]
            ],
            required: []
        ) { arguments, context in
            let raw = (arguments["path"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // read_attachment is retired (#413 H6): an attachment is a file, read here.
            let attachment = AgentToolRegistry.attachment(named: raw, in: context.attachments)
            let url: URL
            if let attachment {
                url = attachment.standardizedFileURL
            } else if raw.isEmpty {
                return AgentToolResult(
                    success: false,
                    output: AgentToolRegistry.missingPathFeedback(context),
                    displayCommand: "read_file")
            } else {
                let expanded = (raw as NSString).expandingTildeInPath
                url = URL(fileURLWithPath: expanded).standardizedFileURL
            }

            // A folder thread is a boundary, not a starting point. Reading outside it is the
            // same trespass whether it happens through a capability or through this. A file
            // the user attached by hand is theirs to hand over, wherever it lives.
            if attachment == nil,
                let folder = await MainActor.run(body: { context.chatScope?.folderURL })
            {
                let root = folder.standardizedFileURL.path
                guard url.path == root || url.path.hasPrefix(root + "/") else {
                    return AgentToolResult(
                        success: false,
                        output: "This conversation is scoped to \(folder.lastPathComponent), "
                            + "and \(url.lastPathComponent) is outside it. Ask the user to "
                            + "attach that folder rather than reaching for the path.",
                        displayCommand: "read_file(\(url.lastPathComponent))")
                }
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            else {
                return AgentToolResult(
                    success: false,
                    output: "No file at \(url.path). Do not guess another path — say it is not "
                        + "there, or use find_capability to search for it.",
                    displayCommand: "read_file(\(url.lastPathComponent))")
            }
            if isDirectory.boolValue {
                let listing = await MainActor.run { FolderScopeDigest.promptBlock(for: url) }
                return AgentToolResult(
                    success: true,
                    output: listing.isEmpty ? "The folder is empty." : listing,
                    displayCommand: "read_file(\(url.lastPathComponent)/)")
            }

            // Images are read by OCR — a document converter returns metadata, not the words
            // in a screenshot.
            if AgentToolRegistry.imageExtensions.contains(url.pathExtension.lowercased()),
                let data = try? Data(contentsOf: url)
            {
                let label = url.lastPathComponent
                let outcome = await Task.detached(priority: .userInitiated) {
                    ScreenCaptureService.recognizeTextOutcome(in: data)
                }.value
                // An image with no text is a real answer, not a failure — and saying so
                // stops the model inventing content it cannot see. A recogniser that could
                // not run is not that answer: the summary says which one it was.
                guard !outcome.text.isEmpty else {
                    return AgentToolResult(
                        success: true,
                        output: outcome.summary(label: label) + " If the user is asking "
                            + "about what the image depicts, describe it from the image you "
                            + "were shown rather than from this tool.",
                        displayCommand: "read_file(\(label))")
                }
                return AgentToolResult(
                    success: true,
                    output: UntrustedContent.fenced(
                        String(outcome.text.prefix(AgentToolRegistry.readBudget)), from: label),
                    displayCommand: "read_file(\(label))")
            }

            let text = await Task.detached(priority: .userInitiated) {
                AIAttachmentPreparer.extractedText(from: url)
            }.value
            guard let text, !text.isEmpty else {
                return AgentToolResult(
                    success: false,
                    output: "\(url.lastPathComponent) could not be read as text — it may be a "
                        + "binary or an unsupported format. Say so rather than describing what "
                        + "a file of that name usually contains.",
                    displayCommand: "read_file(\(url.lastPathComponent))")
            }
            return AgentToolResult(
                success: true,
                output: UntrustedContent.fenced(
                    String(text.prefix(AgentToolRegistry.readBudget)), from: url.lastPathComponent),
                displayCommand: "read_file(\(url.lastPathComponent))")
        }
    }

    nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp",
    ]

    /// The attachment `raw` names: by full path, by bare filename, or — with nothing named
    /// and exactly one file attached — that file. Nil means `raw` is an ordinary path.
    nonisolated static func attachment(named raw: String, in attachments: [URL]) -> URL? {
        guard !raw.isEmpty else { return attachments.count == 1 ? attachments[0] : nil }
        let expanded = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL.path
        if let exact = attachments.first(where: { $0.standardizedFileURL.path == expanded }) {
            return exact
        }
        guard !raw.contains("/") else { return nil }
        return attachments.first {
            $0.lastPathComponent.caseInsensitiveCompare(raw) == .orderedSame
        }
    }

    /// What to say when read_file is called with no path and no single attachment to mean.
    nonisolated static func missingPathFeedback(_ context: AgentToolContext) -> String {
        if !context.attachments.isEmpty {
            let paths = context.attachments.map(\.path).joined(separator: "\n")
            return "\(context.attachments.count) files are attached to this message. Call "
                + "read_file again with the path of the one to read:\n\(paths)"
        }
        // "These files" usually means the Finder selection, not an upload. Ending the turn
        // on "nothing is attached" left the model with a flat no while the files the user
        // was pointing at sat one tool call away — so this says what *is* there.
        if case .filesSelected(let selected) = context.userContext, !selected.isEmpty {
            let names = selected.prefix(10).map(\.path).joined(separator: "\n")
            return "Nothing is attached to this message, but the user has "
                + "\(selected.count) item(s) selected in Finder:\n\(names)\n\n"
                + "That is what \"these files\" means. Any image among them has already been "
                + "shown to you — describe it directly. For anything else call read_file "
                + "with one of the paths above."
        }
        return "read_file needs 'path'. Nothing is attached to this message."
    }

    // MARK: - What the user has highlighted

    private func makeReadSelectionTool() -> AgentTool {
        AgentTool(
            name: "read_selection",
            description: "Read what the user currently has selected — highlighted text, or "
                + "the files selected in Finder. Call this when a question says \"this\", "
                + "\"these\" or \"the selected…\" and the selection is not already in front "
                + "of you.",
            properties: [:],
            required: []
        ) { _, _ in
            let (reading, frontBundleID) = await MainActor.run { () -> (String?, String) in
                let context = AXContextReader.shared.current
                var lines: [String] = []
                if let text = context.selectedText?.trimmingCharacters(
                    in: .whitespacesAndNewlines), !text.isEmpty
                {
                    lines.append("SELECTED TEXT in \(context.appName):")
                    lines.append(String(text.prefix(AgentToolRegistry.readBudget)))
                }
                if !context.selectedFilePaths.isEmpty {
                    lines.append(
                        "SELECTED FILES (\(context.selectedFilePaths.count)):")
                    lines += context.selectedFilePaths.prefix(30).map { "- \($0)" }
                }
                return (lines.isEmpty ? nil : lines.joined(separator: "\n"), context.bundleId)
            }
            // Mail's message pane is a WebKit view that may not expose the highlighted text to
            // Accessibility. Mail can still say which message is open, so read that instead of
            // reporting an empty selection while a message is on screen.
            if reading == nil, frontBundleID.lowercased() == "com.apple.mail" {
                let outcome = await MailReader.selected(using: LiveMailSource())
                if outcome.hasMessage {
                    return AgentToolResult(
                        success: true,
                        output: "No highlighted text could be read in Mail; this is the "
                            + "message open in Mail:\n" + outcome.output,
                        displayCommand: "read_selection")
                }
            }
            guard let reading else {
                return AgentToolResult(
                    success: false,
                    output: "Nothing is selected right now. Ask the user what they meant "
                        + "rather than assuming which thing they had in mind.",
                    displayCommand: "read_selection")
            }
            return AgentToolResult(
                success: true,
                output: UntrustedContent.fenced(reading, from: "the user's selection"),
                displayCommand: "read_selection")
        }
    }
}
