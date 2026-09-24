// AppleNotesBodyFormatter.swift
// Context-Dock
//
// Turning the text DoraX wrote into the HTML Apple Notes actually stores.
//
// A note of fourteen Safari tabs came out as one unbroken paragraph: "1. DoraX Layer
// Dependencies https://… 2. dtDhruv/ytkew: …". The content was right and the note was
// unreadable, because Notes' `body` property is HTML and every newline in a plain-text body is
// collapsed to a space by the renderer. Nothing warns about it — the script succeeds, the note
// exists, and the formatting is silently gone.
//
// So the text is converted rather than escaped-and-hoped: lines become lines, numbered runs
// become numbered lists, and a bare URL becomes a link, because a note of links whose links
// cannot be clicked is a note of text about links.

import Foundation

enum AppleNotesBodyFormatter {

    /// Plain text as Notes-ready HTML.
    ///
    /// Idempotent for text that is already HTML: a body containing a tag is passed through
    /// untouched, so a caller that has built its own markup is not double-escaped into
    /// visible angle brackets.
    static func html(from text: String) -> String {
        guard !looksLikeHTML(text) else { return text }
        let lines = text.components(separatedBy: .newlines)
        var out: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                out.append("<div><br></div>")
                index += 1
                continue
            }

            // A run of "1. …", "2) …" becomes one ordered list. Notes renumbers its own
            // list, so the original numbers are dropped rather than printed twice.
            if orderedMarker(trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                    let content = orderedMarker(lines[index].trimmingCharacters(in: .whitespaces))
                {
                    items.append("<li>\(inline(content))</li>")
                    index += 1
                }
                out.append("<ol>" + items.joined() + "</ol>")
                continue
            }

            if let content = bulletMarker(trimmed) {
                var items: [String] = ["<li>\(inline(content))</li>"]
                index += 1
                while index < lines.count,
                    let next = bulletMarker(lines[index].trimmingCharacters(in: .whitespaces))
                {
                    items.append("<li>\(inline(next))</li>")
                    index += 1
                }
                out.append("<ul>" + items.joined() + "</ul>")
                continue
            }

            out.append("<div>\(inline(trimmed))</div>")
            index += 1
        }

        return out.joined()
    }

    /// One line's worth: escaped, with bare URLs turned into links.
    private static func inline(_ text: String) -> String {
        linkified(escaped(text))
    }

    static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Bare URLs become anchors. Run *after* escaping, so the `&` inside a query string is
    /// already `&amp;` — which is what an href needs anyway.
    private static func linkified(_ escapedText: String) -> String {
        let pattern = #"https?://[^\s<>"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return escapedText }
        let full = NSRange(escapedText.startIndex..<escapedText.endIndex, in: escapedText)
        var result = ""
        var last = escapedText.startIndex

        for match in regex.matches(in: escapedText, range: full) {
            guard let range = Range(match.range, in: escapedText) else { continue }
            result += escapedText[last..<range.lowerBound]
            var url = String(escapedText[range])
            // Trailing punctuation belongs to the sentence, not to the address.
            var tail = ""
            while let final = url.last, ".,;:)]".contains(final) {
                tail = String(final) + tail
                url.removeLast()
            }
            result += "<a href=\"\(url)\">\(url)</a>\(tail)"
            last = range.upperBound
        }
        result += escapedText[last...]
        return result
    }

    private static func orderedMarker(_ line: String) -> String? {
        guard let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression)
        else { return nil }
        return String(line[range.upperBound...])
    }

    private static func bulletMarker(_ line: String) -> String? {
        guard let range = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range.upperBound...])
    }

    /// Markup the caller built, not prose that happens to mention a tag.
    ///
    /// Merely containing "<div" is not enough: "compare <div> with <span>" is a sentence, and
    /// passing it through unescaped both loses the user's angle brackets and hands Notes
    /// markup nobody wrote. Real markup starts as markup and closes what it opens.
    private static func looksLikeHTML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("<") else { return false }
        return trimmed.contains("</") || trimmed.contains("<br")
    }
}
