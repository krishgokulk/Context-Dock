import Foundation

/// Chooses the kind of evidence a frontmost-app request is allowed to treat as truth.
/// Models may reason over evidence; they do not get to decide whether stale memory is a
/// substitute for live application state.
enum AgentEvidenceKind: String, Codable {
    case liveState
    case officialReference
    case durableMemory
    case action
    case conversation
}

struct AgentSourceDecision: Equatable {
    let primary: AgentEvidenceKind
    let requiresFreshRead: Bool
    let allowsMemoryEvidence: Bool

    var promptRule: String {
        switch primary {
        case .liveState:
            return """
                SOURCE AUTHORITY: This asks about changing live state. Answer only from a live
                reader included below. Do not use conversation history, model knowledge, or saved
                memory as factual evidence. If the live reader has no answer, say it was not readable.
                """
        case .officialReference:
            return """
                SOURCE AUTHORITY: This is a product/how-to question. Prefer the current official
                reference included below. Clearly distinguish documentation from observed app state.
                """
        case .durableMemory:
            return """
                SOURCE AUTHORITY: This asks for a durable user preference or saved fact. Saved
                Markdown memory is authoritative when it contains a matching explicit fact.
                """
        case .action:
            return """
                SOURCE AUTHORITY: This is an action request. Prefer an installed typed capability;
                use live readers for required inputs and report only observed execution results.
                The current request is the execution authority. A restriction from an earlier
                turn applies only to the app or operation it explicitly named; do not extend a
                Messages draft-only instruction to Reminders, Notes, Calendar, or another app.
                """
        case .conversation:
            return "SOURCE AUTHORITY: Answer conversationally; do not claim unobserved app state."
        }
    }
}

enum AgentSourceAuthority {
    /// - Parameter scopeBundleId: the app a Context Dock Chat is scoped to, when there is
    ///   one. General Chat spans apps and passes nil; the query is all it has.
    static func decide(query: String, scopeBundleId: String? = nil) -> AgentSourceDecision {
        let q = normalized(query)

        if isExplicitMemoryRequest(q) {
            return AgentSourceDecision(
                primary: .durableMemory, requiresFreshRead: false, allowsMemoryEvidence: true)
        }
        if isReferenceQuestion(q) {
            return AgentSourceDecision(
                primary: .officialReference, requiresFreshRead: false, allowsMemoryEvidence: true)
        }
        if isLiveStateQuestion(q) {
            return AgentSourceDecision(
                primary: .liveState, requiresFreshRead: true, allowsMemoryEvidence: false)
        }
        if let scopeBundleId, ReadOnlyDataDomain(scopeBundleId: scopeBundleId) != nil,
            asksAboutScopedRecords(q)
        {
            return AgentSourceDecision(
                primary: .liveState, requiresFreshRead: true, allowsMemoryEvidence: false)
        }
        if GeneralAIActionResolver.shared.looksExecutable(q) {
            return AgentSourceDecision(
                // A saved preference may help compose an action, but it cannot grant,
                // cancel or narrow one. In General Chat, "Messages: draft only" from an
                // earlier audit was retrieved for a later Reminders create and the model
                // treated that unrelated memory as a global prohibition. The current user
                // request and the approval gate are the authority for execution.
                primary: .action, requiresFreshRead: true, allowsMemoryEvidence: false)
        }
        return AgentSourceDecision(
            primary: .conversation, requiresFreshRead: false, allowsMemoryEvidence: true)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isExplicitMemoryRequest(_ q: String) -> Bool {
        ["remember that", "remember my", "what do you remember", "my preference",
         "do i prefer", "did i prefer", "forget ", "replace memory", "update memory"]
            .contains(where: q.contains)
    }

    private static func isReferenceQuestion(_ q: String) -> Bool {
        let prefixes = ["how do i ", "how can i ", "how does ", "what is ", "explain "]
        let subjects = ["setting", "feature", "shortcut", "support", "documentation",
                        "help", "configure", "configuration", "profile", "rule"]
        return prefixes.contains(where: q.hasPrefix)
            && subjects.contains(where: q.contains)
    }

    /// A question about the frontmost app's records that never named them. `isLiveStateQuestion`
    /// wants a freshness word *and* an object noun; here the scope is the noun, so only the
    /// freshness half has to be present. Asked in Reminders, "what do I need to finish today?"
    /// carries "today" and nothing else, and used to fall through to `.conversation`, where the
    /// model answered from nothing.
    private static func asksAboutScopedRecords(_ q: String) -> Bool {
        // A change is never a read, whatever app is in front. `create a reminder "call mum"
        // today at 5pm` was once answered "You have no open reminders"; the write never ran.
        if GeneralAIActionResolver.shared.requestsChange(q) { return false }
        // A question about the interface carries the same freshness words as a question about
        // the contents. "how do I see what is due today?" wants documentation, not a read.
        let procedurePrefixes = [
            "how do i ", "how can i ", "how to ", "where do i ", "where is ",
            "what happens if ", "can i ",
        ]
        if procedurePrefixes.contains(where: q.hasPrefix) { return false }
        // Two families, both of which name the record set without naming it. When the app in
        // front *is* the records, "how many are there" is as much a read as "what is due".
        // These mirror the read signals ReadOnlyDataRouter already trusts, so the two halves
        // of the decision agree about what counts as a question about someone's own data.
        let agenda = [
            "today", "tomorrow", "tonight", "this week", "due", "overdue", "pending",
            "outstanding", "unread", "upcoming", "latest", "recent", "left to do",
            "remaining", "need to finish", "need to do", "right now", "currently",
        ]
        let readSignals = [
            "how many", "do i have", "any ", "anything", "my ", "show me", "list ",
            "what's on", "whats on",
        ]
        return agenda.contains(where: q.contains) || readSignals.contains(where: q.contains)
    }

    private static func isLiveStateQuestion(_ q: String) -> Bool {
        // Mutable machine state is never a preference. A saved fact such as "I prefer dark
        // mode" may help with an action, but it cannot prove what the Mac is doing now.
        // Keep mutation phrases out: "turn on Wi-Fi" is an action and must continue to the
        // typed capability/approval path below.
        let mutationSignals = [
            "turn on", "turn off", "enable", "disable", "set ", "switch to",
            "change to", "toggle", "increase", "decrease", "mute", "unmute",
        ]
        let isMutation = mutationSignals.contains(where: q.contains)
        let systemStateObjects = [
            "dark mode", "light mode", "appearance", "volume", "sound level",
            "wi-fi", "wifi", "bluetooth", "battery", "focus mode", "do not disturb",
            "now playing", "currently playing", "media playback",
        ]
        let stateQuestionSignals = [
            "status", "current", "currently", "right now", "is ", "are ",
            "what", "which", "how much", "how loud", "active", "connected",
        ]
        if !isMutation,
            systemStateObjects.contains(where: q.contains),
            (stateQuestionSignals.contains(where: q.contains)
                || q.split(separator: " ").count <= 3)
        {
            return true
        }

        let freshness = ["latest", "recent", "current", "right now", "just now", "today",
                         "newest", "last commit", "open ", "unread", "due ", "status"]
        let liveObjects = ["commit", "branch", "change", "workspace", "project", "file",
                           "window", "tab", "page", "website", "site", "url", "email", "mail", "note", "reminder", "inbox",
                           "event", "calendar", "message", "song", "track", "history",
                           "playback", "watched", "played", "viewed"]
        // `create a reminder "call mum" today at 5pm` carries "today" and "reminder" and was
        // classified live state, so the request that had to reach .action — the only kind
        // that carries execution authority and the approval gate — was told to answer from a
        // reader instead. ReadOnlyDataRouter was given this same gate after that request was
        // answered "You have no open reminders"; this half of the decision never got it.
        if freshness.contains(where: q.contains), liveObjects.contains(where: q.contains),
            !GeneralAIActionResolver.shared.requestsChange(q)
        {
            return true
        }
        // These phrases intrinsically name mutable state; requiring an extra word such as
        // "current" made "which branch am I on?" fall through to durable memory.
        let intrinsicLiveState = [
            "which branch", "what branch", "branch am i on", "uncommitted change",
            "working tree", "git status", "files changed", "changes in this project",
            "what page is open", "which page is open", "what page am i on",
            "current page", "active page", "current tab", "active tab",
        ]
        if intrinsicLiveState.contains(where: q.contains) { return true }
        return ["what did i just", "what did i watch", "what have i watched",
                "what did i play", "what have i played", "what am i working on", "what is open",
                "what's open", "whats open"].contains(where: q.contains)
    }
}
