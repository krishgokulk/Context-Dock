import Foundation

enum TaskComplexityRoute: String {
    case direct = "Direct response"
    case bounded = "Bounded tool task"
    case extended = "Extended multi-step task"

    var maxToolIterations: Int {
        switch self {
        case .direct: return 2
        case .bounded: return 5
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
        if actionCount > 0 || text.contains("current ") || text.contains("latest ") {
            return .bounded
        }
        return .direct
    }
}
