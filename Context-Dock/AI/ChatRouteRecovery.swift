import Foundation

/// Who to ask when the model wrote its tool call as text instead of calling it.
///
/// A protocol-only answer is a call that never ran. The surface refuses to show JSON as an
/// answer and recovers by resolving the request deterministically through `ChatRouteResolver`
/// — but a route belongs to an app, so recovery first has to decide which app to ask.
///
/// That decision used to be `case .app`: only a single-app thread could recover. A combined
/// workspace and a General chat with an app attached both had routes available and no way to
/// reach them, so a resolved Messages call came back as "couldn't carry it out on this
/// surface" while Messages sat one route away.
enum ChatRouteRecovery {
    struct Candidate: Equatable {
        let bundleID: String
        let name: String
    }

    /// Did the user ask for something to be written *to* a person?
    ///
    /// Read from the request rather than the answer. A drafted message should end in a Send
    /// button, and detecting one by pattern-matching generated prose would mean guessing at
    /// our own feature — the wording of an answer varies, the shape of the ask does not.
    ///
    /// "Read the messages from salman" and "how do I send a message with the API" are about
    /// messaging without asking for one, so the verb has to govern and a question word has
    /// to disqualify.
    static func wantsMessageComposition(_ query: String) -> Bool {
        let text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let questionOpeners = ["what", "when", "where", "who", "why", "how", "did", "does", "is", "are", "can"]
        let firstWord = text.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        if questionOpeners.contains(firstWord) { return false }

        // Reading is not writing, however much vocabulary the two share.
        let readingVerbs = ["read ", "show ", "check ", "list ", "summarise ", "summarize ", "find "]
        if readingVerbs.contains(where: text.hasPrefix) { return false }

        let composingVerbs = ["draft", "send", "message", "text", "write", "reply", "compose"]
        guard composingVerbs.contains(where: { text.contains($0) }) else { return false }

        // Something has to be written *to* someone: "write the release notes" is not a
        // message, "write to Ann" is.
        let hasRecipient =
            text.contains(" to ") || text.contains(" imessage ") || text.contains("imessage to")
            || composingVerbs.contains(where: { verb in
                // "message sujith that…", "text mum the address" — verb then a name.
                guard let range = text.range(of: verb + " ") else { return false }
                let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return !rest.isEmpty && !rest.hasPrefix("with ") && !rest.hasPrefix("using ")
            })
        return hasRecipient
    }

    /// The apps whose routes may answer this turn, in the order they should be tried.
    ///
    /// The scope's own app leads — it is what the thread is about — followed by whatever was
    /// attached to the conversation. An app whose bundle id cannot be resolved is skipped
    /// rather than ending the search: one unknown name must not cost the user the app next
    /// to it.
    static func candidateApps(
        scope: GeneralChatScope,
        attachedAppNames: [String],
        scopeAppName: String?,
        bundleID: (String) -> String?
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var seen: Set<String> = []

        func add(bundleID id: String, name: String) {
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            candidates.append(Candidate(bundleID: id, name: name))
        }

        if case .app(let scopeBundleID) = scope {
            add(bundleID: scopeBundleID, name: scopeAppName ?? scopeBundleID)
        }

        for name in attachedAppNames {
            guard let id = bundleID(name) else { continue }
            add(bundleID: id, name: name)
        }

        return candidates
    }
}
