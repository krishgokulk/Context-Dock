//
//  BrainProfile.swift
//  Context-Dock
//
//  Who the user is, written down once so no conversation has to ask again.
//
//  Every other memory file answers "what did the user tell me": it grows a fact at a
//  time, and only when someone says "remember that". A profile is the opposite shape —
//  it is asked for on purpose, it is small, and it is true in every conversation rather
//  than in the ones whose wording happens to match it. That is why it is injected whole
//  instead of being ranked against the question like the rest of memory: identity is not
//  a search hit.
//

import Foundation

struct BrainProfile: Codable, Equatable {
    /// Name and what the user does — the one line that makes an answer sound addressed
    /// to a person instead of to an anonymous prompt.
    var identity: String = ""
    /// What they are trying to achieve this year. Goals decide what "useful" means.
    var goals: String = ""
    /// How they want to be spoken to: length, tone, how much to explain.
    var communication: String = ""
    /// What they are good at, so the assistant stops explaining it, and what they are
    /// not, so it stops assuming it.
    var strengths: String = ""
    /// What they are working on right now.
    var projects: String = ""

    static let empty = BrainProfile()

    var isEmpty: Bool { self == .empty }

    /// The fields in the order they are asked and rendered. Keeping this list in one
    /// place means the file, the editor and the prompt block can never drift apart.
    static let fields: [(heading: String, prompt: String, key: WritableKeyPath<BrainProfile, String>)] = [
        ("Who I am", "Your name, role, and what you actually spend the day doing.", \.identity),
        ("Goals", "What you are trying to achieve this year.", \.goals),
        ("How to talk to me", "Length, tone, how much to explain, what to skip.", \.communication),
        ("Strengths and weaknesses", "What to stop explaining, and what not to assume.", \.strengths),
        ("Current projects", "What you are working on right now.", \.projects),
    ]

    // MARK: Markdown

    /// Rendered as an ordinary markdown document so it is readable, editable and
    /// diffable outside the app — the file is the record, this type is only a view of it.
    var markdown: String {
        var lines = ["# Profile", ""]
        for field in Self.fields {
            let value = self[keyPath: field.key].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            lines.append("## \(field.heading)")
            lines.append(value)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Parses the file back.
    ///
    /// Unrecognised headings are ignored, which also means the editor does not round-trip
    /// them: hand-add a `## Notes to self` section to profile.md and the next save from
    /// Settings drops it. That is the trade for keeping the file a fixed, predictable
    /// shape — the whole thing goes in front of the model every turn, so it cannot be an
    /// open-ended document. Free-form knowledge belongs in the other memory files.
    static func parse(_ markdown: String) -> BrainProfile {
        var profile = BrainProfile()
        var currentKey: WritableKeyPath<BrainProfile, String>?
        var buffer: [String] = []

        func flush() {
            guard let key = currentKey else { return }
            profile[keyPath: key] = buffer
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                flush()
                let heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentKey = fields.first { $0.heading.caseInsensitiveCompare(heading) == .orderedSame }?.key
            } else if line.hasPrefix("# ") {
                continue
            } else if currentKey != nil {
                buffer.append(line)
            }
        }
        flush()
        return profile
    }
}
