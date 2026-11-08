// ReplayCaseSanitizer.swift
// Context-Dock
//
// Strips personal data from replay cases before they reach disk.
//
// ## Stripped fields (documented per requirement)
//
// | Pattern                                            | Replacement  |
// |----------------------------------------------------|--------------|
// | Home directory prefix in any string                | <home>/      |
// | /Users/<name> path component                       | <home>       |
// | Email address (RFC-5321 local@domain)              | <email>      |
// | Authorization header values (Bearer/Basic/Token …) | <token>      |
// | Hex strings ≥ 40 chars (SHA-1/SHA-256, auth tokens)| <token>      |
// | sk-… / xoxb-… / ghp_… style API key prefixes      | <token>      |
//
// What is NOT stripped:
// - UUIDs (kept — they are case IDs and receipt IDs, not secrets)
// - Short alphanumeric strings (avoid false positives)
// - Numeric values in tool inputs (file sizes, timestamps, etc.)
//
// The sanitizer is value-typed and stateless. Tests pass a custom homeDirectory to avoid
// depending on the test host's real username.

import Foundation

struct ReplayCaseSanitizer: Sendable {

    private let homePrefix: String

    init(homeDirectory: String = NSHomeDirectory()) {
        self.homePrefix = homeDirectory
    }

    // MARK: - Public

    func sanitize(_ case_: ReplayCase) -> ReplayCase {
        var out = case_
        out.query = sanitize(out.query)
        out.resolvedContext = out.resolvedContext.map { item in
            ReplayCase.ContextItem(kind: item.kind, summary: sanitize(item.summary))
        }
        out.toolCalls = out.toolCalls.map { call in
            ReplayCase.ToolCallRecord(
                name: call.name,
                input: call.input.mapValues { $0.mapStrings(sanitize) },
                output: sanitize(call.output),
                durationSeconds: call.durationSeconds)
        }
        out.finalAnswer = sanitize(out.finalAnswer)
        // scope is a bundle ID — no personal data, keep as-is
        // receiptIDs are UUIDs — not personal, keep as-is
        // trace.promptSections are char counts — no personal data
        return out
    }

    func sanitize(_ text: String) -> String {
        var result = text
        result = stripHomePaths(result)
        result = stripEmails(result)
        result = stripAuthHeaders(result)
        result = stripAPIKeyPrefixes(result)
        result = stripLongHex(result)
        return result
    }

    // MARK: - Private passes

    private func stripHomePaths(_ text: String) -> String {
        var out = text
        // Exact home directory match first
        if !homePrefix.isEmpty {
            out = out.replacingOccurrences(of: homePrefix, with: "<home>")
        }
        // Generic /Users/<name> pattern for any other username
        if let re = try? NSRegularExpression(pattern: #"/Users/[^/\s"'<>\\]+"#) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "<home>")
        }
        return out
    }

    private func stripEmails(_ text: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "<email>")
    }

    private func stripAuthHeaders(_ text: String) -> String {
        // "Bearer <value>", "Basic <value>", "Token <value>", "Authorization: <value>"
        guard let re = try? NSRegularExpression(
            pattern: #"(?i)(?:Bearer|Basic|Token)\s+[A-Za-z0-9+/=_\-\.]{8,}"#)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "<token>")
    }

    private func stripAPIKeyPrefixes(_ text: String) -> String {
        // Common API key prefixes: sk-, sk_live_, sk_test_, xoxb-, xoxp-, ghp_, ghs_, glpat-
        guard let re = try? NSRegularExpression(
            pattern: #"(?:sk[-_](?:live_|test_|proj[-_])?|xox[boprs]-|ghp_|ghs_|glpat-)[A-Za-z0-9_\-]{8,}"#)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "<token>")
    }

    private func stripLongHex(_ text: String) -> String {
        // Hex strings ≥ 40 characters that are not surrounded by word characters
        // (to avoid matching things like UUIDs which we want to keep)
        guard let re = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9\-])[0-9a-fA-F]{40,}(?![A-Za-z0-9\-])"#)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "<token>")
    }
}
