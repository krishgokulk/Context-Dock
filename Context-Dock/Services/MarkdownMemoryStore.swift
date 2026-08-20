import Foundation

struct MarkdownMemoryFileSummary: Identifiable {
    let url: URL
    let relativePath: String
    let factCount: Int
    let freshness: String?
    /// Set for prose files, where a bullet count says nothing about how much is in them.
    var wordCount: Int?

    var id: String { url.path }
}

/// Human-readable durable memory for AI conversations.
///
/// Memory is supporting context only. It never represents live app state and never executes
/// an action. Runtime state stays with context readers; abilities stay with app adapters.
final class MarkdownMemoryStore {
    static let shared = MarkdownMemoryStore()

    private let fileManager = FileManager.default
    private let maxContextCharacters = 8_000

    /// Where the vault lives. Defaults to Application Support, and moves wherever the user
    /// puts it.
    ///
    /// Computed rather than stored: the store is a singleton read from background work as
    /// well as the main actor, and a mutable `root` would be a data race for the sake of
    /// saving a `UserDefaults` read. `UserDefaults` is already the fast path here.
    static let vaultPathKey = "dorax.brain.vaultPath.v1"

    static var defaultRoot: URL {
        ContextDockStore.root.appendingPathComponent("memory", isDirectory: true)
    }

    var root: URL {
        guard let path = UserDefaults.standard.string(forKey: Self.vaultPathKey), !path.isEmpty
        else { return Self.defaultRoot }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private init() {
        bootstrapIfNeeded()
    }

    /// Moves the vault to a folder the user picked.
    ///
    /// Memory is meant to be theirs — plain markdown they can open, back up, or point
    /// Obsidian at. Buried in Application Support it is technically plain text and
    /// practically invisible, which is not the same promise.
    ///
    /// Files are moved rather than copied, and anything already at the destination is left
    /// alone: someone pointing DoraX at an existing vault means "use this", not "overwrite
    /// it with mine".
    @discardableResult
    func relocate(to destination: URL) -> String? {
        let source = root
        guard source.standardizedFileURL != destination.standardizedFileURL else { return nil }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let contents = (try? fileManager.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            var renamed: [String] = []
            for item in contents {
                let name = item.lastPathComponent
                var target = destination.appendingPathComponent(name)
                if fileManager.fileExists(atPath: target.path) {
                    // Both vaults have this file. Leaving ours behind would strand it in a
                    // folder nothing reads again — the user's facts would appear to have
                    // been deleted by moving house. Keep both, and say which is which.
                    let base = item.deletingPathExtension().lastPathComponent
                    let ext = item.pathExtension
                    let moved = ext.isEmpty
                        ? "\(base) (from previous vault)"
                        : "\(base) (from previous vault).\(ext)"
                    target = destination.appendingPathComponent(moved)
                    guard !fileManager.fileExists(atPath: target.path) else { continue }
                    renamed.append(moved)
                }
                try fileManager.moveItem(at: item, to: target)
            }
            UserDefaults.standard.set(destination.path, forKey: Self.vaultPathKey)
            bootstrapIfNeeded()
            return renamed.isEmpty
                ? nil
                : "Moved. That folder already had \(renamed.count) file\(renamed.count == 1 ? "" : "s") "
                    + "with the same name, so yours were kept alongside them: "
                    + renamed.joined(separator: ", ")
        } catch {
            return "Could not move the vault: \(error.localizedDescription)"
        }
    }

    var folderURL: URL { root }

    /// Where Quick Notes are mirrored, so a captured note is searchable memory rather
    /// than an island in its own JSON file.
    var notesFolderURL: URL { root.appendingPathComponent("notes", isDirectory: true) }

    /// One file per day, built from real task-run receipts.
    var dailyFolderURL: URL { root.appendingPathComponent("daily", isDirectory: true) }

    private var profileURL: URL { root.appendingPathComponent("profile.md") }

    // MARK: - Profile

    func loadProfile() -> BrainProfile {
        guard let markdown = try? String(contentsOf: profileURL, encoding: .utf8) else {
            return .empty
        }
        return BrainProfile.parse(markdown)
    }

    @discardableResult
    func saveProfile(_ profile: BrainProfile) -> Bool {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try profile.markdown.write(to: profileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// The identity block, injected into every turn regardless of what was asked.
    ///
    /// This deliberately skips the ranking the rest of memory goes through. Ranking asks
    /// "does this file match the question", and the profile never does — nobody mentions
    /// their own job title when asking to rename a file, which is exactly the turn where
    /// knowing it would have changed the answer.
    func profileBlock() -> String {
        let profile = loadProfile()
        guard !profile.isEmpty else { return "" }
        let body = profile.markdown
            .replacingOccurrences(of: "# Profile\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        return """
            ## About this user
            Written by the user themselves. Treat it as standing context for every answer, \
            not as something to repeat back to them.

            \(body)
            """
    }

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
            // Notes and profiles are prose, not bullet lists. Counting bullets in them
            // reports 0 for a file that is entirely full of writing, so measure the thing
            // they are actually made of.
            let isProse = relative.hasPrefix("notes/") || relative == "profile.md"
            let wordCount = isProse
                ? markdown.split(whereSeparator: { $0 == " " || $0.isNewline }).count
                : 0
            let freshness: String? = relative.hasPrefix("cache/")
                ? cacheStatus(for: markdown)
                : nil
            summaries.append(
                MarkdownMemoryFileSummary(
                    url: url,
                    relativePath: relative,
                    factCount: factCount,
                    freshness: freshness,
                    wordCount: isProse ? wordCount : nil
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

        // A note the user wrote themselves outranks a cached mirror of somebody else's
        // data, and sits just under an app-specific file.
        candidates.append(contentsOf: markdownFiles(in: notesFolderURL).map { ($0, 3) })
        // Yesterday's work is context; it is not what the user asked about, so it ranks
        // below anything they wrote down on purpose.
        candidates.append(contentsOf: recentDailyFiles(limit: 3).map { ($0, 1) })

        let ranked = candidates.compactMap { candidate -> (score: Int, text: String)? in
            guard let raw = try? String(contentsOf: candidate.url, encoding: .utf8),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let termScore = matchScore(raw, terms: queryTerms)
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
            return (candidate.priority + termScore + recencyBonus(for: candidate.url), text)
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
        let sources = contextBlock(query: query, appBundleID: appBundleID)
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("### ") else { return nil }
                let source = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                return source.isEmpty ? nil : source
            }
        guard !sources.isEmpty else { return [] }

        // One chip, not one per file. Three stacked capsules reading
        // "Used memory: 18e64caa-mapped-it-here-s-what-s-actually-there-measured-.md" sat
        // above every answer — more lines of filename than the answer had of sentence.
        let names = sources.map(Self.memoryLabel(for:))
        guard names.count > 1 else { return ["Read memory · \(names[0])"] }
        var joined = ""
        var shown = 0
        for name in names {
            let next = joined.isEmpty ? name : joined + ", " + name
            if next.count > 48 { break }
            joined = next
            shown += 1
        }
        let suffix = shown < names.count ? "\(joined) +\(names.count - shown)" : joined
        return ["Read \(names.count) memories · \(suffix)"]
    }

    /// A memory file's name as something a person would recognise.
    ///
    /// These are filenames, and they were being shown raw. Four shapes exist on disk and
    /// each needs different handling: a named file (`preferences.md`), a day
    /// (`2026-08-18.md`), an app (`com.microsoft.VSCode.md`), and a captured note, which is
    /// eight hex characters and the first line slugged down to punctuationless kebab-case.
    static func memoryLabel(for filename: String) -> String {
        var stem = filename
        if stem.lowercased().hasSuffix(".md") { stem = String(stem.dropLast(3)) }
        guard !stem.isEmpty else { return filename }

        // A day.
        if stem.count == 10, stem.filter({ $0 == "-" }).count == 2,
            let date = Self.dayFormatter.date(from: stem)
        {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            return Self.shortDayFormatter.string(from: date)
        }

        // An app's own memory, named by bundle id.
        if stem.contains("."), stem.split(separator: ".").count >= 3 {
            return stem.split(separator: ".").last.map(String.init) ?? stem
        }

        // A captured note: strip the hex prefix that keeps names unique, then read the slug
        // back as a sentence. The slug has already lost its apostrophes — "what-s" — so the
        // stranded "s" is put back where it plainly belongs.
        var body = stem
        let parts = stem.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 8,
            parts[0].allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        {
            body = String(parts[1])
        }
        var words = body.replacingOccurrences(of: "-", with: " ")
        words = words.replacingOccurrences(of: " s ", with: "'s ")
        words = words.replacingOccurrences(of: " t ", with: "'t ")
        words = words.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return stem }
        let titled = words.prefix(1).uppercased() + words.dropFirst()
        return titled.count > 34 ? titled.prefix(33).trimmingCharacters(in: .whitespaces) + "…" : titled
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

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

    func bootstrapIfNeeded() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? fileManager.createDirectory(
            at: root.appendingPathComponent("apps", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: root.appendingPathComponent("cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(at: notesFolderURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: dailyFolderURL, withIntermediateDirectories: true)

        writeStarter(
            named: "MEMORY.md",
            content: """
                # Memory Index

                - preferences.md — durable user preferences and defaults
                - people.md — contacts, relationships, and communication preferences
                - projects.md — active projects, folders, repositories, and goals
                - tasks.md — commitments and next actions
                - profile.md — who the user is; standing context for every conversation
                - notes/ — Quick Notes, mirrored as markdown
                - daily/ — what actually ran each day, from task-run receipts
                - apps/ — app-specific memory, keyed by bundle identifier
                - cache/ — timestamped mirrors of external sources; never source of truth
                """
        )
        addMissingIndexEntries()
        writeStarter(named: "preferences.md", content: "# Preferences\n")
        writeStarter(named: "people.md", content: "# People\n")
        writeStarter(named: "projects.md", content: "# Projects\n")
        writeStarter(named: "tasks.md", content: "# Tasks\n")
    }

    /// Teaches an existing index about folders added after it was written.
    ///
    /// `writeStarter` only writes a file that is absent, which is right for content the
    /// user may have edited — but it means every install that predates a new folder keeps
    /// an index that never mentions it. The index is what the model reads to know what
    /// memory contains, so a missing line is a folder that effectively does not exist.
    private func addMissingIndexEntries() {
        let url = root.appendingPathComponent("MEMORY.md")
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let entries = [
            ("profile.md", "- profile.md — who the user is; standing context for every conversation"),
            ("notes/", "- notes/ — Quick Notes, mirrored as markdown"),
            ("daily/", "- daily/ — what actually ran each day, from task-run receipts"),
        ]
        var added = false
        for (marker, line) in entries where !content.contains(marker) {
            if !content.hasSuffix("\n") { content += "\n" }
            content += line + "\n"
            added = true
        }
        guard added else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
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
        files.append(contentsOf: markdownFiles(in: notesFolderURL))
        files.append(contentsOf: recentDailyFiles(limit: 3))
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

    /// Whole sections that matched, best first — not the matching lines on their own.
    ///
    /// Line filtering kept every heading whether or not it had anything under it that
    /// matched, and dropped the line after a hit. So a note came through as a list of
    /// headings with a stray sentence between them, and a fact that ran onto a second line
    /// arrived cut in half. A section is the smallest piece of a markdown file that still
    /// means what it said.
    private func relevantSections(from markdown: String, terms: Set<String>, limit: Int) -> String {
        if terms.isEmpty { return String(markdown.prefix(limit)) }

        let scored = sections(of: markdown)
            .map { (section: $0, score: matchScore($0, terms: terms)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        // Nothing matched section-by-section, but the file as a whole did — a one-line
        // file, or a term in the title. Send its opening rather than nothing.
        guard !scored.isEmpty else { return String(markdown.prefix(limit)) }

        var out: [String] = []
        var used = 0
        for entry in scored {
            let text = entry.section.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if used + text.count > limit {
                // Take a partial section only if nothing has been taken yet, so a large
                // first section cannot shut out the whole file.
                if out.isEmpty { out.append(String(text.prefix(limit))) }
                break
            }
            out.append(text)
            used += text.count
        }
        return out.joined(separator: "\n\n")
    }

    /// Splits on headings, keeping each heading with the body beneath it. Text before the
    /// first heading is its own section, which is what a prose Quick Note is made of.
    private func sections(of markdown: String) -> [String] {
        var sections: [String] = []
        var current: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("#"), !current.isEmpty {
                sections.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections
    }

    /// How well a piece of text answers the query.
    ///
    /// Two things this fixes over a substring test. `contains` matched inside words, so
    /// "art" hit every "start" and "smart" in the folder and pulled in files about
    /// nothing. And a hit was worth the same whether the term appeared once or forty
    /// times, so a passing mention outranked the file the query was actually about.
    /// Repeats are counted with diminishing returns, because the fortieth mention does not
    /// make a file four times more relevant than the tenth.
    private func matchScore(_ text: String, terms: Set<String>) -> Int {
        guard !terms.isEmpty else { return 0 }
        let words = tokenSet(text)
        return terms.reduce(0) { total, term in
            let exact = words[term] ?? 0
            // A stem match ("project" in "projects") counts, but for less than the real
            // word, and only for terms long enough that the prefix means something.
            let stemmed = term.count >= 5
                ? words.reduce(0) { $1.key.hasPrefix(term) && $1.key != term ? $0 + $1.value : $0 }
                : 0
            let hits = min(exact, 4) * 3 + min(stemmed, 2)
            return total + hits
        }
    }

    private func tokenSet(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(token)
            guard word.count >= 3 else { continue }
            counts[word, default: 0] += 1
        }
        return counts
    }

    /// A small thumb on the scale for what was written recently. Deliberately small: it
    /// breaks ties between comparably relevant files, and never promotes a fresh file that
    /// has nothing to do with the question over an old one that answers it.
    private func recencyBonus(for url: URL) -> Int {
        guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return 0 }
        let days = Date().timeIntervalSince(modified) / 86_400
        switch days {
        case ..<2: return 3
        case ..<8: return 2
        case ..<31: return 1
        default: return 0
        }
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

    private func markdownFiles(in directory: URL) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "md" }
    }

    /// Only the last few days. The whole archive would crowd out the answer, and a brief
    /// from three weeks ago is history rather than context.
    private func recentDailyFiles(limit: Int) -> [URL] {
        markdownFiles(in: dailyFolderURL)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { $0 }
    }

    private func safeFilename(_ value: String) -> String {
        value.components(separatedBy: CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        ).inverted).joined(separator: "_")
    }
}
