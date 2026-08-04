import Foundation

struct MarkdownMemoryFileSummary: Identifiable {
    let url: URL
    let relativePath: String
    let factCount: Int
    let freshness: String?

    var id: String { url.path }
}

/// Human-readable durable memory for AI conversations.
///
/// Memory is supporting context only. It never represents live app state and never executes
/// an action. Runtime state stays with context readers; abilities stay with app adapters.
final class MarkdownMemoryStore {
    static let shared = MarkdownMemoryStore()

    private let fileManager = FileManager.default
    private let root: URL
    private let maxContextCharacters = 8_000

    private init() {
        root = ContextDockStore.root.appendingPathComponent("memory", isDirectory: true)
        bootstrapIfNeeded()
    }

    var folderURL: URL { root }

    func fileSummaries() -> [MarkdownMemoryFileSummary] {
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var summaries: [MarkdownMemoryFileSummary] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md",
                  let markdown = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let factCount = markdown.split(separator: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
            }.count
            let freshness: String? = relative.hasPrefix("cache/")
                ? cacheStatus(for: markdown)
                : nil
            summaries.append(
                MarkdownMemoryFileSummary(
                    url: url,
                    relativePath: relative,
                    factCount: factCount,
                    freshness: freshness
                )
            )
        }
        return summaries.sorted { lhs, rhs in
            if lhs.relativePath == "MEMORY.md" { return true }
            if rhs.relativePath == "MEMORY.md" { return false }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    func requestedMemoryURL(from query: String) -> URL? {
        let lower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.contains("open") || lower.contains("show") || lower.contains("reveal") else {
            return nil
        }
        let knownFiles = ["memory.md", "preferences.md", "people.md", "projects.md", "tasks.md"]
        if let filename = knownFiles.first(where: lower.contains) {
            let canonical = filename == "memory.md" ? "MEMORY.md" : filename
            return root.appendingPathComponent(canonical)
        }
        if lower.contains("memory folder") || lower.contains("memory files") {
            return root
        }
        return nil
    }

    func remember(_ rawText: String, appBundleID: String? = nil, appName: String? = nil) -> String? {
        guard let fact = explicitMemoryFact(from: rawText) else { return nil }

        let destination: (url: URL, label: String)
        if let bundleID = appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleID.isEmpty
        {
            let safeBundleID = safeFilename(bundleID)
            destination = (
                root.appendingPathComponent("apps/\(safeBundleID).md"),
                "\(appName?.isEmpty == false ? appName! : bundleID) memory"
            )
        } else {
            let domain = domainFilename(for: fact)
            destination = (root.appendingPathComponent(domain), domain)
        }

        let line = "- \(fact)"
        var content = (try? String(contentsOf: destination.url, encoding: .utf8)) ?? ""
        if content.localizedCaseInsensitiveContains(line) {
            return "Already remembered in \(destination.label): \(fact)"
        }
        if content.isEmpty {
            let title = destination.url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
            content = "# \(title.capitalized)\n\n"
        } else if !content.hasSuffix("\n") {
            content += "\n"
        }
        content += line + "\n"

        do {
            try fileManager.createDirectory(
                at: destination.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: destination.url, atomically: true, encoding: .utf8)
            return "Remembered in \(destination.label): \(fact)"
        } catch {
            return "I couldn’t save that memory: \(error.localizedDescription)"
        }
    }

    func cacheFromCommand(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("cache from "), let colon = trimmed.firstIndex(of: ":") else {
            return nil
        }
        let sourceStart = trimmed.index(trimmed.startIndex, offsetBy: "cache from ".count)
        let source = trimmed[sourceStart..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let fact = trimmed[trimmed.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !fact.isEmpty else { return nil }

        let url = root.appendingPathComponent("cache/\(safeFilename(source.lowercased())).md")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = """
            ---
            kind: cache
            source: \(source)
            last_sync: \(timestamp)
            expires_after: 6h
            ---

            # \(source) Cache

            - \(fact)
            """
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (content + "\n").write(to: url, atomically: true, encoding: .utf8)
            return "Cached from \(source). Fresh for 6 hours: \(fact)"
        } catch {
            return "I couldn’t save that cache: \(error.localizedDescription)"
        }
    }

    func forgetFromCommand(_ query: String, appBundleID: String? = nil) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = [
            "please forget that ", "forget that ", "please forget ", "forget ",
            "delete memory about ", "remove memory about ",
        ]
        guard let prefix = prefixes.first(where: lower.hasPrefix) else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let subject = trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard subject.count >= 2 else { return "Tell me which saved fact to forget." }
        let terms = meaningfulTerms(subject)
        guard !terms.isEmpty else { return "Tell me which saved fact to forget." }

        var files = ["preferences.md", "people.md", "projects.md", "tasks.md"]
            .map { root.appendingPathComponent($0) }
        if let appBundleID, !appBundleID.isEmpty {
            files.insert(root.appendingPathComponent("apps/\(safeFilename(appBundleID)).md"), at: 0)
        }
        let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        let cacheFiles = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "md" } ?? []
        files.append(contentsOf: cacheFiles)

        var matches: [(url: URL, line: String, fact: String, score: Int)] = []
        for file in files {
            guard let markdown = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            where line.hasPrefix("- ") {
                let fact = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let overlap = terms.intersection(meaningfulTerms(fact)).count
                if overlap > 0 {
                    matches.append((file, line, fact, overlap))
                }
            }
        }
        guard !matches.isEmpty else { return "I couldn’t find a saved memory matching “\(subject)”." }
        let bestScore = matches.map(\.score).max() ?? 0
        let best = matches.filter { $0.score == bestScore }
        guard best.count == 1, let match = best.first else {
            let choices = best.prefix(5).map { "- \($0.fact)  _[\($0.url.lastPathComponent)]_" }
            return "I found multiple matching memories and removed nothing. Be more specific:\n"
                + choices.joined(separator: "\n")
        }

        guard var markdown = try? String(contentsOf: match.url, encoding: .utf8) else {
            return "I couldn’t read \(match.url.lastPathComponent)."
        }
        let removal = match.line + "\n"
        if markdown.contains(removal) {
            markdown = markdown.replacingOccurrences(of: removal, with: "")
        } else {
            markdown = markdown.replacingOccurrences(of: match.line, with: "")
        }
        do {
            try markdown.write(to: match.url, atomically: true, encoding: .utf8)
            return "Forgot: \(match.fact)  _[\(match.url.lastPathComponent)]_"
        } catch {
            return "I couldn’t remove that memory: \(error.localizedDescription)"
        }
    }

    func replaceFromCommand(_ query: String, appBundleID: String? = nil) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = ["replace memory ", "update memory "]
        guard let prefix = prefixes.first(where: lower.hasPrefix) else { return nil }

        let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let body = String(trimmed[bodyStart...])
        guard let separator = body.range(of: " with ", options: .caseInsensitive) else {
            return "Use: Replace memory OLD with NEW."
        }
        let oldText = body[..<separator.lowerBound]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        let newText = body[separator.upperBound...]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        guard oldText.count >= 2, newText.count >= 2 else {
            return "Use: Replace memory OLD with NEW."
        }

        let files = memoryFactFiles(appBundleID: appBundleID)
        var matches: [(url: URL, line: String, updatedLine: String)] = []
        for file in files {
            guard let markdown = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            where line.hasPrefix("- ") {
                guard let range = line.range(of: oldText, options: .caseInsensitive) else { continue }
                var updated = line
                updated.replaceSubrange(range, with: newText)
                matches.append((file, line, updated))
            }
        }

        guard !matches.isEmpty else {
            return "I couldn’t find a saved memory containing “\(oldText)”."
        }
        guard matches.count == 1, let match = matches.first else {
            let choices = matches.prefix(5).map { "- \(String($0.line.dropFirst(2)))  _[\($0.url.lastPathComponent)]_" }
            return "I found multiple matching memories and changed nothing. Be more specific:\n"
                + choices.joined(separator: "\n")
        }
        guard var markdown = try? String(contentsOf: match.url, encoding: .utf8) else {
            return "I couldn’t read \(match.url.lastPathComponent)."
        }
        markdown = markdown.replacingOccurrences(of: match.line, with: match.updatedLine)
        do {
            try markdown.write(to: match.url, atomically: true, encoding: .utf8)
            return "Updated: \(String(match.updatedLine.dropFirst(2)))  _[\(match.url.lastPathComponent)]_"
        } catch {
            return "I couldn’t update that memory: \(error.localizedDescription)"
        }
    }

    func contextBlock(query: String, appBundleID: String? = nil) -> String {
        let queryTerms = meaningfulTerms(query)
        var candidates: [(url: URL, priority: Int)] = []

        for filename in ["preferences.md", "people.md", "projects.md", "tasks.md"] {
            candidates.append((root.appendingPathComponent(filename), filename == "preferences.md" ? 4 : 1))
        }
        if let bundleID = appBundleID, !bundleID.isEmpty {
            candidates.append((
                root.appendingPathComponent("apps/\(safeFilename(bundleID)).md"),
                8
            ))
        }
        let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        let cacheFiles = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        candidates.append(contentsOf: cacheFiles.filter { $0.pathExtension == "md" }.map { ($0, 0) })

        let ranked = candidates.compactMap { candidate -> (score: Int, text: String)? in
            guard let raw = try? String(contentsOf: candidate.url, encoding: .utf8),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let lower = raw.lowercased()
            let termScore = queryTerms.reduce(0) { score, term in
                score + (lower.contains(term) ? 3 : 0)
            }
            let isAppMemory = candidate.priority >= 8
            let isPreference = candidate.url.lastPathComponent == "preferences.md"
            guard termScore > 0 || isAppMemory || (isPreference && !queryTerms.isEmpty) else {
                return nil
            }
            var text = "### \(candidate.url.lastPathComponent)\n"
            if candidate.url.deletingLastPathComponent().lastPathComponent == "cache" {
                text += cacheFreshnessNotice(for: raw) + "\n"
            }
            text += relevantSections(from: raw, terms: queryTerms, limit: 2_800)
            return (candidate.priority + termScore, text)
        }.sorted { $0.score > $1.score }

        guard !ranked.isEmpty else { return "" }
        var body = ranked.prefix(4).map(\.text).joined(separator: "\n\n")
        body = String(body.prefix(maxContextCharacters))
        return """
            ## Relevant durable memory
            Memory is user-maintained background context, not proof of current app or external state.
            Prefer live context when it conflicts with memory. Cache entries must state their freshness.

            \(body)
            """
    }

    func relevantSourceChips(query: String, appBundleID: String? = nil) -> [String] {
        contextBlock(query: query, appBundleID: appBundleID)
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("### ") else { return nil }
                let source = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                return source.isEmpty ? nil : "Used memory: \(source)"
            }
    }

    /// Answers an explicit memory-recall question without involving an AI provider or tool
    /// router. This prevents app-scoped agents from interpreting `projects.md` as a file they
    /// should open in an editor or shell.
    func recallAnswer(for query: String, appBundleID: String? = nil) -> String? {
        guard isExplicitRecallQuery(query) else { return nil }
        let terms = meaningfulTerms(query).subtracting([
            "remember", "memory", "saved", "know", "about", "prefer", "preference",
        ])
        var files = ["preferences.md", "people.md", "projects.md", "tasks.md"]
            .map { root.appendingPathComponent($0) }
        if let appBundleID, !appBundleID.isEmpty {
            files.insert(
                root.appendingPathComponent("apps/\(safeFilename(appBundleID)).md"),
                at: 0
            )
        }

        let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        let cacheFiles = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "md" } ?? []
        files.append(contentsOf: cacheFiles)

        var facts: [(score: Int, appScoped: Bool, text: String, source: String, freshness: String?)] = []
        for file in files {
            guard let markdown = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let isCache = file.deletingLastPathComponent().lastPathComponent == "cache"
            for line in markdown.split(separator: "\n").map(String.init) where line.hasPrefix("- ") {
                let fact = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let factTerms = meaningfulTerms(fact)
                let overlap = terms.intersection(factTerms).count
                let exactPhraseBonus = terms.contains(where: {
                    fact.lowercased().contains($0 + " ") || fact.lowercased().hasSuffix($0)
                }) ? 1 : 0
                let score = overlap * 3 + exactPhraseBonus
                if terms.isEmpty || score > 0 {
                    facts.append((
                        score,
                        file.deletingLastPathComponent().lastPathComponent == "apps",
                        fact,
                        file.lastPathComponent,
                        isCache ? cacheStatus(for: markdown) : nil
                    ))
                }
            }
        }
        facts.sort {
            if $0.score == $1.score, $0.appScoped != $1.appScoped { return $0.appScoped }
            if $0.score == $1.score { return $0.text < $1.text }
            return $0.score > $1.score
        }

        guard !facts.isEmpty else {
            return "I don’t have a matching saved memory yet. Say “Remember that …” to add one."
        }
        let strongest: [(score: Int, appScoped: Bool, text: String, source: String, freshness: String?)]
        if terms.isEmpty {
            strongest = Array(facts.prefix(8))
        } else {
            let threshold = max(1, (facts.first?.score ?? 1) - 1)
            strongest = Array(facts.filter { $0.score >= threshold }.prefix(8))
        }
        let rows = strongest.map {
            let freshness = $0.freshness.map { " · \($0)" } ?? ""
            return "- \($0.text)  _[\($0.source)\(freshness)]_"
        }
        return "I found \(strongest.count) matching saved memor\(strongest.count == 1 ? "y" : "ies"):\n"
            + rows.joined(separator: "\n")
    }

    private func bootstrapIfNeeded() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? fileManager.createDirectory(
            at: root.appendingPathComponent("apps", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: root.appendingPathComponent("cache", isDirectory: true),
            withIntermediateDirectories: true
        )

        writeStarter(
            named: "MEMORY.md",
            content: """
                # Memory Index

                - preferences.md — durable user preferences and defaults
                - people.md — contacts, relationships, and communication preferences
                - projects.md — active projects, folders, repositories, and goals
                - tasks.md — commitments and next actions
                - apps/ — app-specific memory, keyed by bundle identifier
                - cache/ — timestamped mirrors of external sources; never source of truth
                """
        )
        writeStarter(named: "preferences.md", content: "# Preferences\n")
        writeStarter(named: "people.md", content: "# People\n")
        writeStarter(named: "projects.md", content: "# Projects\n")
        writeStarter(named: "tasks.md", content: "# Tasks\n")
    }

    private func writeStarter(named name: String, content: String) {
        let url = root.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try? (content + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func explicitMemoryFact(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = ["please remember that ", "remember that ", "please remember ", "remember "]
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let fact = trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard fact.count >= 2 else { return nil }
        return fact.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func memoryFactFiles(appBundleID: String?) -> [URL] {
        var files = ["preferences.md", "people.md", "projects.md", "tasks.md"]
            .map { root.appendingPathComponent($0) }
        if let appBundleID, !appBundleID.isEmpty {
            files.insert(root.appendingPathComponent("apps/\(safeFilename(appBundleID)).md"), at: 0)
        }
        let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        let cacheFiles = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "md" } ?? []
        files.append(contentsOf: cacheFiles)
        return files
    }

    private func domainFilename(for fact: String) -> String {
        let lower = fact.lowercased()
        if ["prefer", "preference", "always use", "default", "normally", "usually"].contains(where: lower.contains) {
            return "preferences.md"
        }
        if ["task", "todo", "to-do", "remind", "deadline", "next step"].contains(where: lower.contains) {
            return "tasks.md"
        }
        if ["project", "repository", "repo", "workspace", "client"].contains(where: lower.contains) {
            return "projects.md"
        }
        if ["contact", "manager", "colleague", "wife", "husband", "friend", "prefers"].contains(where: lower.contains) {
            return "people.md"
        }
        return "preferences.md"
    }

    private func isExplicitRecallQuery(_ query: String) -> Bool {
        let lower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("what do you remember")
            || lower.contains("what did you remember")
            || lower.contains("do you remember")
            || lower.contains("show my memory")
            || lower.contains("show saved memory")
            || lower.contains("what is in memory")
            || lower.contains("what's in memory")
            || lower.contains("what are my preferences")
            || lower.contains("what is my preference")
            || lower.contains("which format do i prefer")
            || lower.contains("what format do i prefer")
    }

    private func meaningfulTerms(_ text: String) -> Set<String> {
        let stop: Set<String> = ["about", "again", "could", "does", "from", "have", "please", "show", "that", "their", "there", "these", "this", "what", "when", "where", "which", "with", "would", "your"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 3 && !stop.contains($0) })
    }

    private func relevantSections(from markdown: String, terms: Set<String>, limit: Int) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if terms.isEmpty { return String(markdown.prefix(limit)) }
        let matches = lines.filter { line in
            let lower = line.lowercased()
            return line.hasPrefix("#") || terms.contains(where: lower.contains)
        }
        let result = matches.isEmpty ? markdown : matches.joined(separator: "\n")
        return String(result.prefix(limit))
    }

    private func cacheFreshnessNotice(for markdown: String) -> String {
        let lastSync = frontMatterValue("last_sync", in: markdown) ?? "unknown"
        let expiry = frontMatterValue("expires_after", in: markdown) ?? "unspecified"
        return "Cache freshness: last_sync \(lastSync); expires_after \(expiry). Announce this before analysis."
    }

    private func cacheStatus(for markdown: String) -> String {
        guard let rawSync = frontMatterValue("last_sync", in: markdown),
              let syncDate = ISO8601DateFormatter().date(from: rawSync)
        else { return "Unknown freshness · missing last_sync" }
        let expiryText = frontMatterValue("expires_after", in: markdown) ?? "0h"
        let seconds = expiryInterval(expiryText)
        let isFresh = seconds > 0 && Date().timeIntervalSince(syncDate) <= seconds
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: syncDate, relativeTo: Date())
        return "\(isFresh ? "Fresh" : "Stale") · synced \(relative) · expires \(expiryText)"
    }

    private func expiryInterval(_ value: String) -> TimeInterval {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.count >= 2, let number = Double(lower.dropLast()) else { return 0 }
        switch lower.last {
        case "m": return number * 60
        case "h": return number * 3_600
        case "d": return number * 86_400
        default: return 0
        }
    }

    private func frontMatterValue(_ key: String, in markdown: String) -> String? {
        for line in markdown.prefix(2_000).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func safeFilename(_ value: String) -> String {
        value.components(separatedBy: CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        ).inverted).joined(separator: "_")
    }
}
