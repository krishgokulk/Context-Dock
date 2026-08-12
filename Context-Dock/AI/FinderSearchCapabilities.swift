// FinderSearchCapabilities.swift
// Context-Dock
//
// Looking *inside* the files, and describing a folder as a whole.
//
// The co-worker could already list, read and measure files one at a time. What it could
// not do is the two things people actually ask a folder: "which of these mentions the
// invoice number" and "what even is all this". Both are whole-folder questions, and
// answering them by reading files one call at a time costs a round trip per file and
// usually gives up before it finds anything.
//
// Content search goes through the same MarkItDown converter finder.readFile uses, so a
// PDF or a .docx is searchable rather than opaque. The summary is written to a file
// instead of printed: a folder report is a document, and the panel beside the
// conversation already renders documents.

import AppKit
import Foundation

@MainActor
enum FinderSearchCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerGrep(in: registry)
        registerSummary(in: registry)
    }

    /// Files read per search. A folder of ten thousand PDFs would otherwise convert all of
    /// them to answer one question, and the answer is wanted this minute.
    private static let readBudget = 400
    private static let perFileBudget = 60_000

    // MARK: - Content search

    private static func registerGrep(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.grepFiles",
                title: "Search inside files for text (PDF, Office and plain text) and by name",
                appBundleID: FinderCoworkerCapabilities.finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Text to look for", required: true),
                    .init(
                        name: "path",
                        description: "Folder to search (defaults to this chat's folder or the selection)",
                        required: false),
                    .init(
                        name: "extensions",
                        description: "Comma-separated extensions to restrict to, e.g. pdf,md",
                        required: false),
                ]),
                riskLevel: .low
            ) { request in
                guard let needle = request.input["query"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !needle.isEmpty
                else { throw AICapabilityError.missingInput("query") }

                let scope = FinderCoworkerCapabilities.scopeURLs(
                    from: request, explicitPath: request.input["path"])
                let wanted = Set(
                    (request.input["extensions"] ?? "")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty })

                var candidates = FinderCoworkerCapabilities.files(under: scope.roots)
                if !wanted.isEmpty {
                    candidates = candidates.filter {
                        wanted.contains($0.pathExtension.lowercased())
                    }
                }

                // A name match is a hit in its own right — "find the invoice" is as often
                // about what a file is called as what is in it — and it costs no read.
                let lowered = needle.lowercased()
                var nameHits: [URL] = []
                var contentHits: [(url: URL, line: String)] = []
                var read = 0
                var skipped = 0

                for url in candidates {
                    if url.lastPathComponent.lowercased().contains(lowered) {
                        nameHits.append(url)
                    }
                    guard read < readBudget else {
                        skipped += 1
                        continue
                    }
                    guard let text = readable(url) else { continue }
                    read += 1
                    guard let line = firstMatchingLine(in: text, needle: lowered) else { continue }
                    contentHits.append((url, line))
                }

                guard !nameHits.isEmpty || !contentHits.isEmpty else {
                    return .init(
                        success: true,
                        output:
                            "Nothing in \(scope.describedAs) matches \"\(needle)\" — searched "
                            + "\(candidates.count) file(s), read \(read) of them."
                            + (skipped > 0
                                ? " \(skipped) were left unread at the search limit." : ""))
                }

                var lines: [String] = []
                if !contentHits.isEmpty {
                    lines.append("Found inside \(contentHits.count) file(s):")
                    for hit in contentHits.prefix(20) {
                        lines.append("- \(hit.url.path)")
                        lines.append("    \(hit.line)")
                    }
                    if contentHits.count > 20 {
                        lines.append("…and \(contentHits.count - 20) more.")
                    }
                }
                let namesOnly = nameHits.filter { hit in
                    !contentHits.contains { $0.url == hit }
                }
                if !namesOnly.isEmpty {
                    lines.append("")
                    lines.append("Matched by name only:")
                    lines += namesOnly.prefix(20).map { "- \($0.path)" }
                    if namesOnly.count > 20 {
                        lines.append("…and \(namesOnly.count - 20) more.")
                    }
                }
                if skipped > 0 {
                    lines.append("")
                    lines.append(
                        "\(skipped) file(s) were not read — the search stops at \(readBudget) "
                            + "to stay answerable. Narrow it with extensions or a subfolder.")
                }
                return .init(success: true, output: lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Folder summary

    private static func registerSummary(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.summarizeFolder",
                title: "Describe a whole folder — what is in it, by kind, size and age",
                appBundleID: FinderCoworkerCapabilities.finderBundleID,
                inputSchema: .init(fields: [
                    .init(
                        name: "path",
                        description: "Folder to describe (defaults to this chat's folder)",
                        required: false)
                ]),
                riskLevel: .low
            ) { request in
                let scope = FinderCoworkerCapabilities.scopeURLs(
                    from: request, explicitPath: request.input["path"])
                let all = FinderCoworkerCapabilities.files(under: scope.roots)
                guard !all.isEmpty else {
                    return .init(success: true, output: "\(scope.describedAs) has no files in it.")
                }

                var byKind: [String: (count: Int, bytes: Int64)] = [:]
                var total: Int64 = 0
                var oldest = Date.distantFuture
                var newest = Date.distantPast
                for url in all {
                    let ext = url.pathExtension.isEmpty
                        ? "no extension" : url.pathExtension.lowercased()
                    let bytes = FinderCoworkerCapabilities.size(of: url)
                    var entry = byKind[ext] ?? (0, 0)
                    entry.count += 1
                    entry.bytes += bytes
                    byKind[ext] = entry
                    total += bytes
                    let date = FinderCoworkerCapabilities.modified(url)
                    if date < oldest, date != .distantPast { oldest = date }
                    if date > newest { newest = date }
                }

                let ranked = byKind.sorted { $0.value.bytes > $1.value.bytes }
                let biggest = all
                    .sorted {
                        FinderCoworkerCapabilities.size(of: $0)
                            > FinderCoworkerCapabilities.size(of: $1)
                    }
                    .prefix(10)

                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let dates = DateFormatter()
                dates.dateStyle = .medium

                var lines = [
                    "\(scope.describedAs): \(all.count) file(s), "
                        + "\(formatter.string(fromByteCount: total)) in total.",
                    "",
                    "By kind:",
                ]
                for (ext, entry) in ranked.prefix(10) {
                    lines.append(
                        "- \(ext): \(entry.count) file(s), "
                            + formatter.string(fromByteCount: entry.bytes))
                }
                if ranked.count > 10 {
                    lines.append("- …and \(ranked.count - 10) other kinds")
                }
                lines.append("")
                lines.append("Largest:")
                for url in biggest {
                    lines.append(
                        "- \(url.lastPathComponent) — "
                            + formatter.string(
                                fromByteCount: FinderCoworkerCapabilities.size(of: url)))
                }
                if oldest != .distantFuture {
                    lines.append("")
                    lines.append(
                        "Touched between \(dates.string(from: oldest)) and "
                            + "\(dates.string(from: newest)).")
                }

                // The full breakdown as a document beside the conversation. Only the
                // headline goes in the transcript — a hundred rows of extensions is a
                // report, and a chat is a bad place to read one.
                if let scopeForFile = request.chatScope {
                    let csv = csvReport(ranked: ranked, formatterTotal: total)
                    if let url = ArtifactStore.file(
                        csv, named: ArtifactStore.reportName("folder-breakdown", extension: "csv"),
                        scope: scopeForFile)
                    {
                        lines.append("")
                        lines.append(
                            "Full breakdown saved as \(url.lastPathComponent) — it is in the "
                                + "Artifacts panel beside this conversation.")
                    }
                }

                return .init(success: true, output: lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Helpers

    private static func csvReport(
        ranked: [(key: String, value: (count: Int, bytes: Int64))], formatterTotal: Int64
    ) -> String {
        var rows = ["extension,files,bytes,share_percent"]
        for (ext, entry) in ranked {
            let share = formatterTotal > 0
                ? Int((Double(entry.bytes) / Double(formatterTotal)) * 100) : 0
            rows.append("\(ext),\(entry.count),\(entry.bytes),\(share)")
        }
        return rows.joined(separator: "\n")
    }

    /// The file as text, whatever it started as. Nil for anything that is not text and
    /// cannot be converted — an image has nothing to search.
    private static func readable(_ url: URL) -> String? {
        if MarkItDownService.supports(url),
            let converted = MarkItDownService.convert(url, characterBudget: perFileBudget),
            !converted.markdown.isEmpty
        {
            return converted.markdown
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return String(text.prefix(perFileBudget))
    }

    /// The first line containing the term, trimmed to something quotable. The line is what
    /// makes a search result usable — a list of filenames means opening each one to find
    /// out which was meant.
    private static func firstMatchingLine(in text: String, needle: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.lowercased().contains(needle) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
        }
        return nil
    }
}
