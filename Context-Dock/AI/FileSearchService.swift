// FileSearchService.swift
// Context-Dock
//
// Find files by name when Spotlight cannot be trusted.
//
// The owner's Mac has Spotlight switched off, so `mdfind` prints nothing and "find my passport
// pdfs" in a Finder chat could not find files that were sitting in ~/Documents. This is the one
// file-search path DoraX has: Spotlight first (cheap, whole-disk, content-aware when it is on),
// and when it answers nothing — off, unindexed, or simply no hit — a bounded walk of the places
// people keep their files. Full absolute paths come out, newest first, so the result cards
// (`TurnFileExtractor`) draw them.
//
// Pure apart from two injected seams — the Spotlight runner and the clock — so the rules are
// tested against a temp directory with no dependence on the machine's index.

import Foundation

nonisolated enum FileSearchService {

    struct Options: Sendable {
        /// Absolute directories to search. Default: Desktop, Documents, Downloads, iCloud Drive.
        var roots: [String]
        var maxResults = 25
        /// Directory levels below a root the scan will descend.
        var maxDepth = 6
        /// Entries the scan may look at across all roots.
        var maxVisited = 40_000
        /// Wall-clock budget for the scan, seconds.
        var scanTimeBudget: TimeInterval = 3
        /// Wall-clock budget for one `mdfind`, seconds.
        var spotlightTimeout: TimeInterval = 4
        var homeDirectory = NSHomeDirectory()

        init(roots: [String]? = nil, homeDirectory: String = NSHomeDirectory()) {
            self.homeDirectory = homeDirectory
            self.roots = roots ?? FileSearchService.defaultRoots(homeDirectory: homeDirectory)
        }
    }

    enum Source: String, Sendable {
        case spotlight
        case scan
        case none
    }

    struct Outcome: Sendable {
        var paths: [String]
        var source: Source
        /// The scan stopped on a cap rather than running out of files.
        var truncated: Bool
        var searchedRoots: [String]
    }

    /// Runs Spotlight for name tokens under roots and returns absolute paths. Injected.
    typealias SpotlightRunner = @Sendable (_ tokens: [String], _ roots: [String], _ timeout: TimeInterval) -> [String]

    static func defaultRoots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        ["Desktop", "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { homeDirectory + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Query

    private static let stopWords: Set<String> = [
        "find", "search", "look", "for", "me", "my", "the", "a", "an", "all", "any", "of", "in",
        "on", "to", "file", "files", "document", "documents", "please", "show", "where", "is",
        "are", "locate", "get", "and", "with", "named", "called", "mac", "computer", "folder",
    ]

    /// The words a filename must contain, lowercased, with plurals folded ("pdfs" → "pdf").
    static func tokens(from query: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        var seen = Set<String>()
        var result: [String] = []
        for raw in query.lowercased().components(separatedBy: separators) where !raw.isEmpty {
            guard !stopWords.contains(raw) else { continue }
            let folded = (raw.count > 3 && raw.hasSuffix("s") && !raw.hasSuffix("ss"))
                ? String(raw.dropLast()) : raw
            if seen.insert(folded).inserted { result.append(folded) }
        }
        return result
    }

    /// Case-insensitive: every token appears in the name (extension included).
    static func matches(name: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let lower = name.lowercased()
        return tokens.allSatisfy { lower.contains($0) }
    }

    // MARK: - Search

    static func search(
        query: String,
        options: Options = Options(),
        spotlight: SpotlightRunner = FileSearchService.runSpotlight,
        now: @Sendable () -> Date = { Date() }
    ) -> Outcome {
        let tokens = tokens(from: query)
        let roots = options.roots.map { standardized($0) }
        guard !tokens.isEmpty, !roots.isEmpty else {
            return Outcome(paths: [], source: .none, truncated: false, searchedRoots: roots)
        }

        let hits = spotlight(tokens, roots, options.spotlightTimeout)
            .map { standardized($0) }
            .filter { path in
                isInsideAny(path, roots: roots)
                    && !isExcluded(path, roots: roots, home: options.homeDirectory)
                    && matches(name: (path as NSString).lastPathComponent, tokens: tokens)
                    && FileManager.default.fileExists(atPath: path)
            }
        if !hits.isEmpty {
            return Outcome(
                paths: newestFirst(hits, limit: options.maxResults), source: .spotlight,
                truncated: false, searchedRoots: roots)
        }

        let scanned = scan(tokens: tokens, roots: roots, options: options, now: now)
        return Outcome(
            paths: newestFirst(scanned.paths, limit: options.maxResults),
            source: scanned.paths.isEmpty ? .none : .scan,
            truncated: scanned.truncated, searchedRoots: roots)
    }

    /// Matches per scan before sorting; the sort needs them all, the caller only wants a few.
    private static let scanMatchCeiling = 400

    static func scan(
        tokens: [String], roots: [String], options: Options,
        now: @Sendable () -> Date = { Date() }
    ) -> (paths: [String], truncated: Bool) {
        let started = now()
        var visited = 0
        var truncated = false
        var found: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true })
            else { continue }

            while let item = enumerator.nextObject() as? URL {
                visited += 1
                if visited > options.maxVisited
                    || now().timeIntervalSince(started) > options.scanTimeBudget
                {
                    truncated = true
                    break
                }
                let path = item.standardizedFileURL.path
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let isDirectory = values?.isDirectory ?? false
                let isPackage = values?.isPackage ?? false

                if isDirectory {
                    if enumerator.level >= options.maxDepth
                        || isExcluded(path, roots: roots, home: options.homeDirectory)
                    {
                        enumerator.skipDescendants()
                    }
                    // A package (.pages, .app) is one file to the user; a folder is not a hit.
                    guard isPackage else { continue }
                }
                guard matches(name: item.lastPathComponent, tokens: tokens),
                    seen.insert(path).inserted
                else { continue }
                found.append(path)
                if found.count >= scanMatchCeiling { truncated = true; break }
            }
            if truncated { break }
        }
        return (found, truncated)
    }

    // MARK: - Paths

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isInsideAny(_ path: String, roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Hidden components and ~/Library are never searched — unless the root itself is inside
    /// them, as iCloud Drive is.
    static func isExcluded(_ path: String, roots: [String], home: String) -> Bool {
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") })
        else { return true }
        let relative = String(path.dropFirst(root.count))
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return true }
        let library = standardized(home) + "/Library"
        if path == library || (path.hasPrefix(library + "/") && !root.hasPrefix(library)) {
            return true
        }
        return false
    }

    private static func newestFirst(_ paths: [String], limit: Int) -> [String] {
        let dated = paths.map { path -> (String, Date) in
            let date = (try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (path, date)
        }
        return dated.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit).map(\.0)
    }

    // MARK: - Spotlight

    /// `mdfind` by display name. Stdin is the null device, stderr is discarded, the pipe is
    /// drained before waiting on the process (a full pipe would deadlock it), and a timer
    /// terminates a query that hangs. Empty when Spotlight is off — which is the case the
    /// scan exists for.
    static let runSpotlight: SpotlightRunner = { tokens, roots, timeout in
        let clauses = tokens.map { token -> String in
            let safe = token.replacingOccurrences(of: "\\", with: "")
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\"", with: "")
            return "kMDItemDisplayName == '*\(safe)*'cd"
        }
        guard !clauses.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = roots.flatMap { ["-onlyin", $0] } + [clauses.joined(separator: " && ")]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return [] }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - What the model reads

    /// The tool result: one full path per line, so the answer can quote them and the cards can
    /// draw them.
    static func report(query: String, outcome: Outcome, homeDirectory: String = NSHomeDirectory())
        -> String
    {
        let where_ = outcome.searchedRoots.map {
            $0.hasPrefix(homeDirectory) ? "~" + $0.dropFirst(homeDirectory.count) : $0
        }.joined(separator: ", ")
        guard !outcome.paths.isEmpty else {
            return "No file names matched \"\(query)\" in \(where_). Say that plainly and "
                + "offer to search another folder; do not guess a path."
        }
        let how = outcome.source == .spotlight ? "Spotlight" : "a scan of \(where_)"
        var lines = ["Found \(outcome.paths.count) file(s) for \"\(query)\" via \(how), newest first:"]
        lines += outcome.paths
        if outcome.truncated {
            lines.append("(The scan hit its size or time cap; there may be more.)")
        }
        return lines.joined(separator: "\n")
    }
}
