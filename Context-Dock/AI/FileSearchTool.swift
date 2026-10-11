// FileSearchTool.swift
// Context-Dock
//
// `find_files`: the model's way to look for a file by name. Read-only, no approval — it lists
// paths, it opens nothing. One tool serves the in-app agent (General Chat and every scoped chat
// that is offered it, Finder first) and the DoraX MCP server, both through `runSearch`, so there
// is one search path. See FileSearchService for the rules.

import Foundation

extension AgentToolRegistry {

    func registerFileSearchTool() {
        register(
            AgentTool(
                name: "find_files",
                description: "Find files on this Mac by name. Uses Spotlight, and when Spotlight "
                    + "is off or finds nothing, scans Desktop, Documents, Downloads and iCloud "
                    + "Drive. Returns full absolute paths, newest first. Use this for \"find my "
                    + "passport pdfs\" or \"where is the tax spreadsheet\" instead of `mdfind` "
                    + "or `find` in a shell. Read-only; matches file names, not contents.",
                properties: [
                    "query": [
                        "type": "string",
                        "description": "Words the file name contains, e.g. \"passport pdf\". "
                            + "Leave out filler such as \"find my\".",
                    ]
                ],
                required: ["query"]
            ) { arguments, context in
                let query = (arguments["query"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else {
                    return AgentToolResult(
                        success: false, output: "find_files needs 'query'.",
                        displayCommand: "find_files")
                }
                // A folder thread is a boundary: search inside it and nowhere else.
                let folder = await MainActor.run { context.chatScope?.folderURL }
                let (success, text) = await AgentToolRegistry.runFileSearch(
                    query: query, folder: folder)
                return AgentToolResult(
                    success: success,
                    output: success ? UntrustedContent.fenced(text, from: "a file search") : text,
                    displayCommand: "find_files(\(query))")
            })
    }

    /// The single entry point for both the in-app tool and the MCP tool.
    ///
    /// `@concurrent`, not `Task.detached`: the walk is blocking file I/O that must stay off the
    /// main actor, but a detached task is cut off from the caller's cancellation, so a
    /// cancelled turn waited out the whole scan. Here the search runs in the caller's own task
    /// and `FileSearchService.scan` sees its cancellation.
    @concurrent
    static func runFileSearch(query: String, folder: URL? = nil) async -> (Bool, String) {
        let options = folder.map { FileSearchService.Options(roots: [$0.path]) }
            ?? FileSearchService.Options()
        let outcome = FileSearchService.search(query: query, options: options)
        return (
            !outcome.paths.isEmpty,
            FileSearchService.report(query: query, outcome: outcome)
        )
    }
}
