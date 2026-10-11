// Context-Dock/Services/Plugins/PluginOutput.swift
//
// A script's stdout, as data the renderer can bind to. Pure. The four formats exist so a
// migrated script keeps working byte-for-byte: `lines` is the "Title | subtitle" shape every
// Global Extension prints, `raw` is a single value, `jsonl` one object per line.

import Foundation

/// A diagnostic is what a failure is reported AS everywhere in this system — the schema, the
/// renderer and now the runtime all speak it — so it is also how a failure is thrown. Without
/// this, decoding would need a second error type that exists only to be converted back into a
/// diagnostic before anyone could show it.
extension PluginDiagnostic: Error {}

enum PluginOutput {
    static func decode(_ stdout: String, format: PluginDataFormat)
        -> Result<PluginValue, PluginDiagnostic>
    {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case .json:
            guard !text.isEmpty else { return .success(.object([:])) }
            guard let data = text.data(using: .utf8),
                let value = try? JSONDecoder().decode(PluginValue.self, from: data)
            else {
                return .failure(PluginDiagnostic(
                    severity: .error, path: "data",
                    message: "the script did not print JSON (format: json)"))
            }
            return .success(value)

        case .jsonl:
            // One bad line never costs the good ones: a list that goes blank because one row
            // is malformed is worse than a list one row short.
            let items = text.split(separator: "\n").compactMap { line -> PluginValue? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(PluginValue.self, from: data)
            }
            return .success(.object(["lines": .array(items)]))

        case .lines:
            let items = text.split(separator: "\n").compactMap { line -> PluginValue? in
                let raw = line.trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { return nil }
                let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let title = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
                let subtitle = parts.count > 1
                    ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                return .object([
                    "title": .string(title),
                    "subtitle": .string(subtitle),
                    "raw": .string(raw),
                ])
            }
            return .success(.object(["lines": .array(items)]))

        case .raw:
            return .success(.object(["value": .string(text)]))
        }
    }
}
