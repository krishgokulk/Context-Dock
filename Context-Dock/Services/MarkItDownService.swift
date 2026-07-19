import Foundation

/// Shared bridge to Microsoft's MarkItDown document-to-Markdown converter.
///
/// The external converter is deliberately optional: DoraX keeps its native PDF/text/OCR
/// fallbacks, while installations with the managed `markitdown` CLI gain structured Office,
/// archive, EPUB, media, and URL conversion everywhere that consumes document context.
enum MarkItDownService {
    struct Conversion: Sendable {
        let markdown: String
        let wasTruncated: Bool
    }

    nonisolated static let supportedExtensions: Set<String> = [
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "xlsm",
        "csv", "html", "htm", "epub", "zip", "json", "xml", "rtf",
        "txt", "md", "markdown", "jpg", "jpeg", "png", "gif", "webp",
        "tif", "tiff", "bmp", "heic", "wav", "mp3", "m4a",
    ]

    /// About 4k model tokens for English prose. Callers with tighter budgets can request less.
    nonisolated static let defaultCharacterBudget = 16_000

    nonisolated static var executableURL: URL? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let fixed = [
            "/opt/homebrew/bin/markitdown",
            "/usr/local/bin/markitdown",
            "\(home)/.local/bin/markitdown",
        ]
        if let path = fixed.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        // pip --user varies by Python minor version.
        let pythonRoot = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Python", isDirectory: true)
        if let versions = try? fm.contentsOfDirectory(
            at: pythonRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let candidate = version.appendingPathComponent("bin/markitdown")
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    nonisolated static var isAvailable: Bool { executableURL != nil }

    nonisolated static func supports(_ url: URL) -> Bool {
        if !url.isFileURL {
            return url.scheme == "http" || url.scheme == "https"
        }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Converts a local file or remote URL and compacts the result to a predictable prompt budget.
    /// MarkItDown is launched directly (never through a shell), so paths and URLs are not executable.
    nonisolated static func convert(
        _ input: URL,
        characterBudget: Int = defaultCharacterBudget,
        query: String? = nil
    ) -> Conversion? {
        guard supports(input), let executableURL else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [input.isFileURL ? input.path : input.absoluteString]

        var environment = ProcessInfo.processInfo.environment
        let paths = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(NSHomeDirectory())/.local/bin",
        ]
        environment["PATH"] = (paths + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout before waiting so large documents cannot fill the pipe and deadlock.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }

        let compacted = compact(raw, for: query, limit: max(1_000, characterBudget))
        return Conversion(markdown: compacted, wasTruncated: compacted.count < raw.count)
    }

    /// Keeps headings and query-relevant sections before applying the hard budget. This preserves
    /// substantially more signal than a blind prefix while avoiding unnecessary prompt tokens.
    nonisolated static func compact(_ markdown: String, for query: String?, limit: Int) -> String {
        guard markdown.count > limit else { return markdown }
        let terms = Set(
            (query ?? "")
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )
        let sections = markdown.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let headings = sections.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let ranked = sections.map { section -> (Int, String) in
            let lower = section.lowercased()
            let relevance = terms.reduce(0) { score, term in
                score + max(0, lower.components(separatedBy: term).count - 1)
            }
            let structureBonus = section.hasPrefix("#") ? 2 : 0
            return (relevance + structureBonus, section)
        }.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1.count > rhs.1.count : lhs.0 > rhs.0
        }

        var chosen: [String] = []
        var used = 0
        for section in (Array(headings.prefix(20)) + ranked.map(\.1)) {
            guard !chosen.contains(section) else { continue }
            let remaining = limit - used
            guard remaining > 80 else { break }
            chosen.append(String(section.prefix(remaining)))
            used += min(section.count, remaining) + 2
        }
        return chosen.joined(separator: "\n\n")
            + "\n\n*(MarkItDown output compacted to fit the AI context budget)*"
    }
}
