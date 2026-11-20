// UnifiedIntentClassifier.swift
// Context-Dock
//
// Deterministic (<1ms) query intent classification for the unified Spotlight-Pet surface.
// Categorises every keystroke so the ranker knows what to promote and what to penalise
// without waiting for a model.

import Foundation

public enum QueryIntentArchetype: Sendable, Equatable {
    /// Direct app or menu keyword ("safari", "export", "save").
    case navigational
    /// Exact file path or extension ("resume.pdf", "~/Downloads").
    case explicitFile
    /// Question or instruction ("how to fix...", "draft reply...").
    case conversational
    /// Search operators, comparison, recency ("vs", "latest", "weather").
    case webResearch
}

enum UnifiedIntentClassifier {

    // MARK: - Public

    static func classify(_ query: String) -> QueryIntentArchetype {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .navigational }
        let lower = trimmed.lowercased()

        if isExplicitFile(lower) { return .explicitFile }
        if isWebResearch(lower) { return .webResearch }
        if isConversational(lower) { return .conversational }
        return .navigational
    }

    /// Whether the query is conversational — the ranker uses this to apply the -100
    /// incidental file penalty and promote the Ask AI row.
    static func isConversational(_ query: String) -> Bool {
        let lower = query.lowercased()
        return detectConversational(lower)
    }

    // MARK: - Conversational Detection

    private static let questionPrefixes: [String] = [
        "how ", "why ", "what ", "where ", "who ", "when ", "which ",
        "can i ", "should i ", "is it ", "is there ", "are there ",
        "do i ", "does ", "did ", "will ", "would ", "could ",
    ]

    private static let directiveVerbs: [String] = [
        "explain ", "summarize ", "summarise ", "draft ", "fix ", "debug ",
        "translate ", "compare ", "solve ", "write ", "create ", "help ",
        "describe ", "suggest ", "recommend ", "find out ", "tell me ",
        "show me how", "walk me through",
    ]

    private static func detectConversational(_ lower: String) -> Bool {
        if lower.hasSuffix("?") { return true }
        for prefix in questionPrefixes where lower.hasPrefix(prefix) { return true }
        for verb in directiveVerbs where lower.hasPrefix(verb) { return true }

        // >3 words without a file extension suggests natural language
        let words = lower.split(separator: " ")
        if words.count > 3, !containsFileExtension(lower) { return true }

        return false
    }

    // MARK: - Explicit File Detection

    private static let fileExtensions: Set<String> = [
        ".pdf", ".swift", ".png", ".jpg", ".jpeg", ".gif", ".dmg", ".zip",
        ".json", ".md", ".txt", ".csv", ".xlsx", ".docx", ".pptx", ".html",
        ".py", ".js", ".ts", ".rb", ".go", ".rs", ".c", ".cpp", ".h",
        ".app", ".pkg", ".tar", ".gz", ".mov", ".mp4", ".mp3",
    ]

    private static let pathPrefixes: [String] = [
        "~/", "/users/", "/applications/", "/volumes/", "/tmp/", "/var/",
        "desktop/", "downloads/", "documents/",
    ]

    private static func isExplicitFile(_ lower: String) -> Bool {
        for prefix in pathPrefixes where lower.hasPrefix(prefix) { return true }
        return containsFileExtension(lower)
    }

    private static func containsFileExtension(_ lower: String) -> Bool {
        for ext in fileExtensions {
            if lower.hasSuffix(ext) { return true }
            // "resume.pdf something" still counts
            let marker = ext + " "
            if lower.contains(marker) { return true }
        }
        return false
    }

    // MARK: - Web Research Detection

    private static let webSignals: [String] = [
        " vs ", " versus ", " latest ", " news ", " price ", " weather ",
        " stock ", " review ", " reddit ", " stackoverflow ",
    ]

    private static func isWebResearch(_ lower: String) -> Bool {
        for signal in webSignals {
            if lower.contains(signal) { return true }
            let trimmed = signal.trimmingCharacters(in: .whitespaces)
            if lower.hasPrefix(trimmed + " ") || lower.hasSuffix(" " + trimmed) { return true }
        }
        if lower.hasPrefix("search ") || lower.hasPrefix("google ") { return true }
        return false
    }

    // MARK: - Scoring Adjustments

    /// The penalty applied to raw disk file results when the query is conversational,
    /// suppressing keyword collision noise ("how to fix" matching a "fix.log" file).
    static let conversationalFilePenalty: Double = -100

    /// Boost applied to results belonging to the frontmost application, so that
    /// typing "save" in Word surfaces Word's Save, not a background app's.
    static let frontmostAppBoost: Double = 500

    /// Boost applied to explicit file results when the query names a file.
    static let explicitFileBoost: Double = 50
}
