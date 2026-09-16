import Foundation

/// Stops General Chat from treating an incomplete cross-app statement as a live lookup.
///
/// A message such as "currently visited Safari about llbrain.dev, to our project" names
/// context, but not an operation or the app that owns the project. Sending that directly to
/// a provider encouraged it to turn cached tab context into a confident answer. Clarify the
/// missing contract before reading either app.
enum CrossAppGeneralChatClarifier {
    static func questionIfNeeded(
        query: String,
        namedApp: (name: String, bundleId: String)?
    ) -> String? {
        guard let namedApp else { return nil }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        let mentionsLiveAppContext = [
            "current", "currently", "visited", "open page", "open tab", "in safari",
        ].contains(where: text.contains)
        let mentionsSecondWorkspace = [
            "project", "workspace", "repository", "repo", "codebase",
        ].contains(where: text.contains)
        guard mentionsLiveAppContext, mentionsSecondWorkspace else { return nil }

        let questionOrActionPrefixes = [
            "what ", "why ", "how ", "which ", "where ", "is ", "are ", "does ",
            "do ", "did ", "can ", "could ", "would ", "compare ", "summarize ",
            "summarise ", "save ", "add ", "copy ", "send ", "create ", "update ",
            "search ", "find ", "read ", "use ", "check ", "inspect ", "explain ",
        ]
        let hasOperation = text.hasSuffix("?")
            || questionOrActionPrefixes.contains(where: text.hasPrefix)
        guard !hasOperation else { return nil }

        return "I can connect **\(namedApp.name)** with your project, but I need the task first. What should I do with the current page and the project, and which app currently has the project?"
    }
}
