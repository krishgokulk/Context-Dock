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
            guard !block.isEmpty else {
                return AgentToolResult(
                    success: false,
                    output: "The page could not be read. DoraX reads pages through its Safari "
                        + "extension or the accessibility API; if neither is available, say "
                        + "the page is unreadable rather than describing it from memory.",
                    displayCommand: "read_page")
            }
            return AgentToolResult(
                success: true,
                output: UntrustedContent.fenced(block, from: "the current web page"),
                displayCommand: "read_page")
        }
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
                + "approval because it only reads.",
            properties: [
                "path": [
                    "type": "string",
                    "description": "Absolute path, or ~ relative to the user's home.",
                ]
            ],
            required: ["path"]
        ) { arguments, context in
            let raw = (arguments["path"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                return AgentToolResult(
                    success: false, output: "read_file needs 'path'.",
                    displayCommand: "read_file")
            }
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL

            // A folder thread is a boundary, not a starting point. Reading outside it is the
            // same trespass whether it happens through a capability or through this.
            if let folder = await MainActor.run(body: { context.chatScope?.folderURL }) {
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
            let reading = await MainActor.run { () -> String? in
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
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
