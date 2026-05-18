// OnDeviceStructuredStubs.swift
// Context-Doc
//
// generateMailIntent: keyword-based mail query classifier.
// Replaces the removed @Generable structured output approach with a deterministic
// parser that works on every macOS version without Apple Intelligence.

#if canImport(FoundationModels)
import Foundation

@available(macOS 26.0, *)
struct GeneratedMailIntent {
    var mode: String        // "search" | "question" | "none"
    var searchQuery: String // the cleaned query to search Mail with
    var tokenKind: String   // "subject" | "from" | "to" | "attachment" | "date" | "generic"
}

@available(macOS 26.0, *)
func generateMailIntent(
    from query: String,
    dateTimeContext: String
) async throws -> GeneratedMailIntent? {
    let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return nil }

    // ── Question patterns → not a search, let AI answer ──────────────────────
    let questionPrefixes = ["what", "how", "why", "explain", "tell me", "summarize",
                            "who sent", "who is", "can you", "do i", "should i"]
    if q.hasSuffix("?") || questionPrefixes.contains(where: { q.hasPrefix($0) }) {
        return GeneratedMailIntent(mode: "question", searchQuery: "", tokenKind: "none")
    }

    // ── Token kind detection ──────────────────────────────────────────────────
    var tokenKind = "generic"
    var cleanedQuery = q

    // Subject
    let subjectPhrases = ["subject:", "subject ", "titled ", "with subject", "about "]
    for phrase in subjectPhrases {
        if q.contains(phrase) {
            tokenKind = "subject"
            cleanedQuery = q.replacingOccurrences(of: phrase, with: "").trimmingCharacters(in: .whitespaces)
            break
        }
    }

    // From / sender
    let fromPhrases = ["from:", "from ", "sent by ", "emails from ", "mail from "]
    if tokenKind == "generic" {
        for phrase in fromPhrases {
            if q.contains(phrase) {
                tokenKind = "from"
                cleanedQuery = q.replacingOccurrences(of: phrase, with: "").trimmingCharacters(in: .whitespaces)
                break
            }
        }
    }

    // To / recipient
    let toPhrases = ["to:", "to ", "sent to ", "emails to "]
    if tokenKind == "generic" {
        for phrase in toPhrases {
            if q.hasPrefix(phrase) {
                tokenKind = "to"
                cleanedQuery = q.replacingOccurrences(of: phrase, with: "").trimmingCharacters(in: .whitespaces)
                break
            }
        }
    }

    // Attachment
    if tokenKind == "generic" && (q.contains("attach") || q.contains("pdf") || q.contains("file") || q.contains("document")) {
        tokenKind = "attachment"
    }

    // Date
    let datePhrases = ["yesterday", "today", "last week", "this week", "last month",
                       "monday", "tuesday", "wednesday", "thursday", "friday", "january",
                       "february", "march", "april", "may", "june", "july", "august",
                       "september", "october", "november", "december"]
    if tokenKind == "generic" {
        for phrase in datePhrases {
            if q.contains(phrase) {
                tokenKind = "date"
                cleanedQuery = q
                break
            }
        }
    }

    // ── Strip filler words from the search query ──────────────────────────────
    let filler = ["show me", "find", "search for", "search", "look for", "get",
                  "emails", "email", "mails", "mail", "messages", "inbox"]
    var result = cleanedQuery
    for word in filler {
        result = result.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
    }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !result.isEmpty else {
        return GeneratedMailIntent(mode: "none", searchQuery: "", tokenKind: "none")
    }

    return GeneratedMailIntent(mode: "search", searchQuery: result, tokenKind: tokenKind)
}
#endif
