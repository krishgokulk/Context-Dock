//
//  DailyBrief.swift
//  Context-Dock
//
//  What actually happened today, written from receipts rather than from recollection.
//
//  A summary a model writes about its own session is the least trustworthy thing in the
//  app: it is generated from the same context that produced the work, so a step that
//  silently failed gets summarised as a step that happened. This reads `TaskRunStore`'s
//  files instead — the command that ran, the output it returned, whether it exited well —
//  and states only what is in them. No model is called, which is also why it can run on a
//  timer without costing anything.
//

import Foundation

enum DailyBrief {
    /// Rebuilds today's brief. Safe to call repeatedly — the file is derived, so the last
    /// write of the day is the complete one rather than an append of duplicates.
    @discardableResult
    static func rebuildToday() -> URL? {
        rebuild(for: Date())
    }

    @discardableResult
    static func rebuild(for day: Date) -> URL? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }

        let runs = loadRuns()
            .filter { $0.createdAt >= start && $0.createdAt < end }
            .filter { !isInternal($0.request) }
        guard !runs.isEmpty else { return nil }

        let folder = MarkdownMemoryStore.shared.dailyFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = folder.appendingPathComponent("\(formatter.string(from: start)).md")

        let markdown = render(runs: runs, day: start)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Rendering

    private static func render(runs: [TaskRunStore.Run], day: Date) -> String {
        let heading = DateFormatter()
        heading.dateFormat = "EEEE d MMMM yyyy"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"

        let completed = runs.filter { $0.status == .completed }
        let failed = runs.filter { $0.status == .failed }
        let unfinished = runs.filter { $0.status == .interrupted || $0.status == .running }

        var lines = [
            "# \(heading.string(from: day))",
            "",
            "> Built from task-run receipts. Every line below is something that ran.",
            "",
            "\(runs.count) requests · \(completed.count) completed · "
                + "\(failed.count) failed · \(unfinished.count) left unfinished",
            "",
        ]

        lines.append("## What ran")
        for run in runs.sorted(by: { $0.createdAt < $1.createdAt }) {
            let mark: String
            switch run.status {
            case .completed: mark = "done"
            case .failed: mark = "failed"
            case .interrupted: mark = "interrupted"
            case .running: mark = "unfinished"
            }
            lines.append("- \(clock.string(from: run.createdAt)) — \(oneLine(run.request)) [\(mark)]")
            // The commands are the part worth keeping: they are the spelling that worked
            // on this Mac, which is exactly what a later turn should reuse rather than
            // guess at again.
            let commands = run.receipts.filter { $0.success && !$0.isVerification }
            for receipt in commands.prefix(4) {
                lines.append("    - `\(oneLine(receipt.command))`")
            }
            if commands.count > 4 {
                lines.append("    - … and \(commands.count - 4) more")
            }
        }

        // Failures get their own section because they are the only part of the day worth
        // acting on tomorrow, and buried in a list they read as noise.
        if !failed.isEmpty || !unfinished.isEmpty {
            lines.append("")
            lines.append("## Left open")
            for run in failed + unfinished {
                let reason = run.failure.map { " — \(oneLine($0))" } ?? ""
                lines.append("- \(oneLine(run.request))\(reason)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The assistant re-prompts itself — a verification note, a retry instruction — and
    /// those are tracked as runs like any other. They are not things the user asked for,
    /// and listing them in a record of the day both triples its length and misreports who
    /// wanted what.
    private static func isInternal(_ request: String) -> Bool {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("SYSTEM NOTE")
            || trimmed.hasPrefix("Resume this interrupted task:")
    }

    private static func oneLine(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flattened.prefix(160))
    }

    // MARK: - Source

    /// Reads the same files `TaskRunStore` writes. It keeps its runs private, and this is
    /// a reader — going through the disk means the brief cannot describe a run the store
    /// never durably recorded.
    private static func loadRuns() -> [TaskRunStore.Run] {
        let directory = ContextDockStore.root
            .appendingPathComponent("task-runs", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }

        let decoder = JSONDecoder.taskRun
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TaskRunStore.Run.self, from: data)
            }
    }
}
