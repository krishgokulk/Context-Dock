import Foundation

enum TaskComplexityRoute: String {
    case direct = "Direct response"
    case bounded = "Bounded tool task"
    case extended = "Extended multi-step task"

    var maxToolIterations: Int {
        switch self {
        // Four, not two. Two bought exactly one tool call and an answer, which is why a
        // question that needed a look — read the page, then answer from it — came back as
        // "I don't have that" instead. Reading is cheap and read-only; the room to look
        // before answering costs a few tokens and buys the difference between an assistant
        // that checks and one that guesses.
        case .direct: return 4
        // Five cut off immediately after the final successful reader in a real browser
        // turn (two failed routes, discovery, summarize attempt, browser.tabs). The answer
        // itself needs a round too, with one spare for recovery from an unavailable source.
        case .bounded: return 7
        case .extended: return 9
        }
    }

    var instruction: String {
        switch self {
        case .direct:
            return "Complexity route: direct. Answer without tools unless live state is strictly required."
        case .bounded:
            return "Complexity route: bounded. Use the minimum tools needed and stop after verification."
        case .extended:
            return "Complexity route: extended. Track dependent steps, reuse receipts, and verify the final state."
        }
    }
}

enum TaskComplexityRouter {
    static func route(_ request: String) -> TaskComplexityRoute {
        let text = request.lowercased()
        let sequenceMarkers = [
            " then ", " after that", " followed by", " before you", " finally ",
            "step by step", "multiple ", "each file", "all files",
        ]
        let actionTerms = [
            "run ", "create ", "delete ", "move ", "rename ", "open ", "send ",
            "update ", "install ", "search ", "read ", "compare ", "verify ",
        ]
        let actionCount = actionTerms.reduce(0) { count, term in
            count + text.components(separatedBy: term).count - 1
        }
        if sequenceMarkers.contains(where: text.contains) || actionCount >= 3 {
            return .extended
        }
        // Live-state questions need one round to choose/read a source and another to answer.
        // A first imperfect lookup can require one more. "What page is open?" previously
        // received the two-round direct budget, used browser.tabs discovery on round two,
        // then hit the limit before it could run the reader or answer.
        let liveStateTerms = [
            "current ", "latest ", "open page", "page is open", "open tab", "active tab",
            "frontmost", "right now", "today", "tomorrow",
        ]
        if actionCount > 0 || liveStateTerms.contains(where: text.contains) {
            return .bounded
        }
        return .direct
    }
}
