// TurnFileExtractor.swift
// Context-Dock
//
// The files a finished turn talked about, as files.
//
// Finder App Chat found the passport PDFs and said so in prose: the paths were on screen,
// correct, and useless — to open one the user had to select it, copy it and go to Finder.
// Claude and Codex draw the files a turn produced as cards. This reads the paths a turn
// mentioned — in the answer, or in what its steps returned — keeps the ones that are
// really on disk, and hands them to `TurnFileCards` to draw.
//
// Pure apart from the disk probe, which is injected so the rules are tested without files.
// Nothing here goes to the model: the cards are local UI over paths already on screen.

import Foundation

nonisolated enum TurnFileExtractor {

    /// What is at a path, if anything.
    enum Probe: Equatable, Sendable {
        case file
        case directory
    }

    /// More than a dozen cards is a listing, not an answer.
    static let defaultLimit = 12

    /// Disk probes allowed per turn. A step that printed a thousand non-paths must not
    /// cost a thousand `stat`s before the cards settle.
    static let probeBudget = 240

    /// Paths a finished turn mentioned that exist, answer first, deduplicated, at most
    /// `limit`.
    ///
    /// The answer is what the user reads, so its paths lead and may be folders ("it's in
    /// ~/Documents/Taxes"). Step output is a listing the answer drew from — `mdfind`,
    /// `ls`, `find` — so from there only files count; the folder a search ran in is not
    /// a result.
    static func files(
        answer: String,
        stepOutputs: [String],
        limit: Int = defaultLimit,
        homeDirectory: String = NSHomeDirectory(),
        probe: (String) -> Probe? = TurnFileExtractor.diskProbe
    ) -> [URL] {
        var budget = probeBudget
        let counted: (String) -> Probe? = { path in
            guard budget > 0 else { return nil }
            budget -= 1
            return probe(path)
        }
        var seen: Set<String> = []
        var found: [URL] = []

        func take(_ text: String, allowDirectories: Bool) {
            for path in paths(in: text, homeDirectory: homeDirectory, probe: counted) {
                guard found.count < limit else { return }
                guard !seen.contains(path), let kind = counted(path) else { continue }
                if kind == .directory, !allowDirectories { continue }
                seen.insert(path)
                found.append(URL(fileURLWithPath: path, isDirectory: kind == .directory))
            }
        }

        take(answer, allowDirectories: true)
        for output in stepOutputs where found.count < limit {
            take(output, allowDirectories: false)
        }
        return found
    }

    static func diskProbe(_ path: String) -> Probe? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? .directory : .file
    }

    // MARK: - Candidates

    /// Normalised absolute paths written in `text`, in the order they appear, not yet
    /// checked against the disk — except that a bare path with spaces asks the disk where
    /// it ends.
    static func paths(
        in text: String,
        homeDirectory: String = NSHomeDirectory(),
        probe: (String) -> Probe? = TurnFileExtractor.diskProbe
    ) -> [String] {
        var ordered: [(offset: Int, path: String)] = []
        // Spans already read as a path are blanked so the bare scan does not read
        // fragments of them ("/Users/me/My" out of a quoted "/Users/me/My Docs/a.pdf").
        // A blank is one UTF-16 unit per unit, so offsets never move.
        let working = NSMutableString(string: text)

        func blank(_ range: NSRange) {
            working.replaceCharacters(
                in: range, with: String(repeating: " ", count: range.length))
        }

        // file:// links — Markdown links and CLI output use them; the path is
        // percent-encoded.
        for match in fileURLPattern.matches(
            in: working as String, options: [], range: NSRange(location: 0, length: working.length))
        {
            let raw = trimmedTrailing(working.substring(with: match.range))
            if let url = URL(string: raw), url.isFileURL,
                let path = normalised(url.path, homeDirectory: homeDirectory)
            {
                ordered.append((match.range.location, path))
            }
            blank(match.range)
        }

        // Quoted and backticked paths may hold spaces; the delimiters say where they end.
        for pattern in delimitedPatterns {
            for match in pattern.matches(
                in: working as String, options: [], range: NSRange(location: 0, length: working.length))
            {
                let inner = working.substring(with: match.range(at: 1))
                if let path = normalised(trimmedTrailing(inner), homeDirectory: homeDirectory) {
                    ordered.append((match.range.location, path))
                }
                blank(match.range)
            }
        }

        // Bare paths. A space may belong to the name ("passport scan.pdf") or end the
        // path ("… /a.pdf and /b.pdf"); only the disk can tell, so the longest run of
        // words that exists wins, and one word when none does.
        let flat = working as String
        let length = working.length
        var cursor = 0
        while cursor < length,
            let match = bareStartPattern.firstMatch(
                in: flat, options: [.withTransparentBounds],
                range: NSRange(location: cursor, length: length - cursor))
        {
            let start = match.range.location
            var stop = start
            while stop < length, !bareStopUnits.contains(working.character(at: stop)) {
                stop += 1
            }
            let tail = working.substring(with: NSRange(location: start, length: stop - start))
            let words = tail.components(separatedBy: " ")

            var chosen: (path: String, length: Int)?
            var prefixLength = 0
            var candidates: [(raw: String, length: Int)] = []
            for word in words.prefix(8) {
                prefixLength += (candidates.isEmpty ? 0 : 1) + (word as NSString).length
                candidates.append(
                    ((tail as NSString).substring(to: prefixLength), prefixLength))
            }
            for (index, candidate) in candidates.enumerated().reversed() {
                guard let path = normalised(
                    trimmedTrailing(candidate.raw), homeDirectory: homeDirectory)
                else { continue }
                if index == 0 || probe(path) != nil {
                    chosen = (path, candidate.length)
                    break
                }
            }
            if let chosen {
                ordered.append((start, chosen.path))
                cursor = start + max(chosen.length, 1)
            } else {
                cursor = start + max(match.range.length, 1)
            }
        }

        var seen: Set<String> = []
        return ordered
            .sorted { $0.offset < $1.offset }
            .map(\.path)
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Rules

    /// `~/x` → the home folder; `..` and trailing slashes resolved. Nil for anything that
    /// is not an absolute path below the root, and for the root and home themselves —
    /// places, not results.
    static func normalised(_ raw: String, homeDirectory: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("~/") {
            path = homeDirectory + String(path.dropFirst())
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        path = lexical(path)
        guard path != "/", path != lexical(homeDirectory) else { return nil }
        return path
    }

    /// `.`, `..`, doubled and trailing slashes resolved by the text alone.
    /// `standardizingPath` consults the disk for `..` and `/private`, which would make the
    /// same answer draw different cards on different Macs.
    static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Prose punctuation after a path is not part of it: "saved to ~/a.pdf." A closing
    /// bracket goes only when the path did not open it: "(see /x/a.pdf)" loses it,
    /// "/x/file(1).pdf" keeps its own.
    static func trimmedTrailing(_ raw: String) -> String {
        var path = Substring(raw.trimmingCharacters(in: .whitespaces))
        while let last = path.last {
            if trailingPunctuation.contains(last) {
                path = path.dropLast()
            } else if last == ")", count("(", in: path) < count(")", in: path) {
                path = path.dropLast()
            } else if last == "]", count("[", in: path) < count("]", in: path) {
                path = path.dropLast()
            } else {
                break
            }
        }
        return String(path)
    }

    private static func count(_ character: Character, in text: Substring) -> Int {
        text.reduce(0) { $0 + ($1 == character ? 1 : 0) }
    }

    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "*", "_", "'", "\u{2019}", "\u{201D}",
    ]

    // Literal patterns: a typo fails every test in TurnFileExtractorTests, not a user.
    private static let fileURLPattern = try! NSRegularExpression(
        pattern: #"file://[^\s<>"'`)\]]+"#)

    /// A path inside backticks, straight or curly double quotes, or single quotes. The
    /// inner text must start like a path, so "it's" never opens a span.
    private static let delimitedPatterns: [NSRegularExpression] = [
        #"`(~?/[^`\n]+)`"#,
        #""(~?/[^"\n]+)""#,
        "\u{201C}(~?/[^\u{201D}\\n]+)\u{201D}",
        #"(?<![\w])'(~?/[^'\n]+)'"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Where a bare path starts: `/` or `~/` not glued to a word, a URL or another path
    /// ("https://x.com/Users" and "a/b" are not paths here), followed by a name.
    private static let bareStartPattern = try! NSRegularExpression(
        pattern: #"(?<![\w.:/~\-])~?/[\w.~\-]"#)

    /// Characters that end a bare path however the words fall: line breaks, tabs,
    /// backticks, quotes, angle brackets, pipes (a Markdown table cell).
    private static let bareStopUnits: Set<unichar> = Set(
        "\n\r\t`\"<>|\u{201C}\u{201D}".utf16)
}
