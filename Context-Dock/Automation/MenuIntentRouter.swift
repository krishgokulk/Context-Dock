// MenuIntentRouter.swift
// Context-Dock
//
// Routes natural language → frontmost app's cached menu → click.
// Completely isolated per app — Safari menus never mix with Xcode menus.
//
// Tier 1: Keyword score ≥ threshold → click instantly, zero AI
// Tier 2: Low confidence → on-device AI picks from top candidates (typed output)
// Tier 3: Not a menu action → returns nil, caller falls through to normal AI
//
// Tier 2 answers with a @Generable value rather than prose: the model fills in an index and
// how sure it is, and the app reads fields instead of parsing a sentence. The older picker
// asked for "ONLY a single integer" and threw the answer away whenever the model wrote
// "Item 3" — a correct pick lost to its formatting.
//
// A pick the model is guessing at is dropped rather than offered. Tier 2 is reached only
// because tier 1 already found no confident match, so a shaky guess on top of an already
// weak shortlist is worth less than saying nothing and letting the request fall through to
// a normal AI answer.

import AppKit
import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif


// MARK: - Typed answer

#if canImport(FoundationModels)
/// What the on-device model is allowed to answer with when it disambiguates a menu query.
///
/// Two fields, both read as fields. There is no output format for the model to get wrong,
/// which is the whole point of asking this way.
@available(macOS 26.0, *)
@Generable
struct MenuPick {
    @Guide(
        description:
            "The 1-based number of the menu item that does what the user asked, or 0 if none of them do."
    )
    var index: Int

    @Guide(
        description:
            "How sure you are: 'certain' if the item plainly does what was asked, 'likely' if it probably does, 'unsure' if you are guessing."
    )
    var certainty: String
}
#endif

/// The rule applied to a pick, kept out of the model call so it can be tested without one.
enum MenuPickRule {
    /// Words that mean the model was guessing.
    ///
    /// Matched as a reject list rather than by requiring an approved word: an answer like
    /// "very sure" should still count as a pick, and would be thrown away by a rule that
    /// only accepted three exact spellings.
    static let lowConfidenceWords: Set<String> = [
        "unsure", "uncertain", "guess", "guessing", "low", "none", "no",
    ]

    /// The index into the candidate list to propose, or nil when nothing should be proposed.
    ///
    /// Index 0, an index outside the list, and a guess all collapse to the same answer here:
    /// no menu proposal.
    static func candidateIndex(index: Int, certainty: String, candidateCount: Int) -> Int? {
        guard candidateCount > 0, index >= 1, index <= candidateCount else { return nil }
        let word = certainty.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowConfidenceWords.contains(word) else { return nil }
        return index - 1
    }

    /// What a cloud provider said, read as the same two fields the on-device model fills in.
    ///
    /// The on-device path gets its shape for free from `@Generable`. A cloud provider returns a
    /// `String`, so the fields have to be recovered from it — which is the parsing this change
    /// removes everywhere it can, kept here only because `AIProviderRouter.send(_:)` has no
    /// typed seam to use instead.
    ///
    /// Tolerant on purpose. A model that wraps its JSON in a code fence, or writes a sentence
    /// around it, has still answered; the older picker threw all three away. A bare number is
    /// read as a pick with no stated certainty, which the rule above then treats as any other
    /// unrecognised word: offered, because the user still has to press the pill.
    static func parse(reply: String) -> (index: Int, certainty: String)? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let object = firstJSONObject(in: trimmed),
            let data = object.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(ReplyShape.self, from: data)
        {
            return (decoded.index, decoded.certainty ?? "")
        }

        // No JSON. "none" is a real answer — nothing here fits — and so is a bare number from a
        // model that ignored the format.
        let firstWord =
            trimmed
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .first ?? ""
        guard firstWord.lowercased() != "none",
            let number = Int(firstWord.trimmingCharacters(in: CharacterSet(charactersIn: ".,:")))
        else { return nil }
        return (number, "")
    }

    private struct ReplyShape: Decodable {
        var index: Int
        var certainty: String?
    }

    /// The first `{…}` in a string, brace-balanced, so a fenced or explained answer still
    /// yields its object.
    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
