import Foundation

/// A question the model asked with options, read back out of its own answer.
///
/// The model already asks well — "update" produced three real choices — but it asks in
/// prose, so answering meant retyping "1" and trusting the next turn to remember what the
/// number stood for. A number is a reference to something the conversation can lose; the
/// option's own words are not.
///
/// Read from the answer rather than required as a protocol: models ask this way already,
/// and a picker that only appears when the model remembers a JSON envelope is a picker the
/// user cannot rely on.
struct ChatClarification: Equatable {
    struct Option: Equatable, Identifiable {
        let index: Int
        let label: String
        var id: Int { index }
    }

    let question: String
    let options: [Option]

    /// What choosing this option says. The option's words, not its number, because the next
    /// turn resolves text and cannot see the list the number belonged to.
    func reply(for option: Option) -> String {
        option.label
    }

    /// The most a row should carry. Past this the option is a paragraph and the picker
    /// becomes the transcript.
    private static let maximumLabelLength = 120
    private static let maximumOptions = 6

    static func parse(_ text: String) -> ChatClarification? {
        let lines = text.components(separatedBy: .newlines)

        var options: [Option] = []
        var firstOptionLine: Int?
        for (number, raw) in lines.enumerated() {
            guard let option = parseOption(raw) else {
                // Options have to be one run. A number appearing again further down belongs
                // to a different list, not to this question.
                if !options.isEmpty, !raw.trimmingCharacters(in: .whitespaces).isEmpty,
                    options.count > 1
                {
                    break
                }
                continue
            }
            if option.index == 1 { firstOptionLine = number }
            guard option.index == options.count + 1 else { continue }
            options.append(option)
            if options.count == maximumOptions { break }
        }

        guard options.count >= 2, let listStart = firstOptionLine else { return nil }

        // The question is the line that asks, not whatever preceded the list: a turn often
        // narrates what it read before getting to the choice.
        let preceding = lines[..<listStart]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let question = preceding.last(where: { $0.hasSuffix("?") }) else { return nil }

        return ChatClarification(question: cleaned(question), options: options)
    }

    /// "1. Label", "1) Label", "- 1. Label". Anything else is prose.
    private static func parseOption(_ raw: String) -> Option? {
        let line = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-• "))
        guard let match = line.range(
            of: #"^(\d{1,2})[.)]\s+"#, options: .regularExpression)
        else { return nil }

        let digits = line[match].prefix { $0.isNumber }
        guard let index = Int(digits), index >= 1 else { return nil }

        let label = cleaned(String(line[match.upperBound...]))
        guard !label.isEmpty else { return nil }
        return Option(index: index, label: label)
    }

    /// Emphasis is the model's formatting, not part of the choice.
    private static func cleaned(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > maximumLabelLength {
            value = String(value.prefix(maximumLabelLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return value
    }
}
