// BrowserPageReadEvidence.swift
// Context-Dock
//
// Turns the page snapshot supplied to a model into the same visible evidence users see
// for tools. Page grounding used to be silent prompt injection: the answer knew the page,
// but the workflow showed no read, extraction, source, or receipt.

import Foundation

struct BrowserPageReadEvidence: Equatable {
    let browserName: String
    let source: String
    let title: String
    let url: String
    let textCharacterCount: Int
    let linkCount: Int

    static func parse(
        promptBlock: String, browserName: String, source: String
    ) -> BrowserPageReadEvidence? {
        guard !promptBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        func value(after labels: [String]) -> String {
            for line in promptBlock.components(separatedBy: .newlines) {
                for label in labels where line.hasPrefix(label) {
                    return String(line.dropFirst(label.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return ""
        }

        let title = value(after: ["CURRENT PAGE TITLE:", "Title:"])
        let url = value(after: ["CURRENT PAGE URL:", "URL:"])
        let linkCount = promptBlock.components(separatedBy: .newlines).filter {
            $0.hasPrefix("- [") || ($0.hasPrefix("- ") && $0.contains(" → http"))
        }.count
        let text: String = {
            for marker in ["PAGE MARKDOWN EXCERPT:\n", "PAGE TEXT EXCERPT:\n"] {
                if let range = promptBlock.range(of: marker) {
                    let tail = String(promptBlock[range.upperBound...])
                    return tail.components(separatedBy: "\n\nPAGE LINKS").first ?? tail
                }
            }
            return ""
        }()
        guard !title.isEmpty || !url.isEmpty || !text.isEmpty || linkCount > 0 else {
            return nil
        }
        return BrowserPageReadEvidence(
            browserName: browserName,
            source: source,
            title: title == "(unknown)" ? "" : title,
            url: url == "(unknown)" ? "" : url,
            textCharacterCount: text.trimmingCharacters(in: .whitespacesAndNewlines).count,
            linkCount: linkCount)
    }

    var traceLines: [String] {
        var lines = ["Read current page via \(source)"]
        var fields: [String] = []
        if !title.isEmpty { fields.append("title") }
        if !url.isEmpty { fields.append("URL") }
        if textCharacterCount > 0 { fields.append("\(textCharacterCount) text characters") }
        if linkCount > 0 { fields.append("\(linkCount) links") }
        lines.append("Extracted " + (fields.isEmpty ? "no readable page fields" : fields.joined(separator: ", ")))
        return lines
    }

    var receipt: DoraXActionReceipt {
        var facts: [String] = ["Browser: \(browserName)", "Source: \(source)"]
        if !title.isEmpty { facts.append("Title: \(title)") }
        if !url.isEmpty { facts.append("URL: \(url)") }
        facts.append("Readable text: \(textCharacterCount) characters")
        facts.append("Links: \(linkCount)")
        return DoraXActionReceipt(
            command: "read_browser_page(\(browserName))",
            output: facts.joined(separator: "\n"),
            success: !title.isEmpty || !url.isEmpty || textCharacterCount > 0,
            isVerification: true)
    }
}
