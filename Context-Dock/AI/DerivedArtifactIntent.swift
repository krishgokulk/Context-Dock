import Foundation

/// A follow-up that transforms information already present in the conversation and writes
/// a new artifact. It is not an instruction to invoke the scoped app's Save menu.
enum DerivedArtifactIntent {
    static func shouldBypassNativeAppMenu(_ query: String) -> Bool {
        let text = query.lowercased()
        let referencesPriorResult = [
            " them", "those", "these", "the results", "that list", "the list",
            "the output", "above", "previous result", "previous output",
        ].contains(where: text.contains)
        let transforms = [
            "group", "organize", "categorize", "classify", "summarize", "filter",
            "convert", "format", "turn ",
        ].contains(where: text.contains)
        let writesArtifact = ["save", "write", "export", "create"]
            .contains(where: text.contains)
        let namesMarkdown = text.contains("markdown") || text.contains(".md")
        return referencesPriorResult && transforms && writesArtifact && namesMarkdown
    }
}
