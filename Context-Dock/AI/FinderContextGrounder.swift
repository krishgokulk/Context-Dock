// FinderContextGrounder.swift
// Context-Dock
//
// Cascading 4-tier autonomous context grounder for Finder Pet and General Chat (#384).
// Resolves live filesystem context with or without an open frontmost Finder window,
// ensuring accurate answers across both tool-enabled and tool-free AI providers.

import Foundation
import os

struct FinderGroundedFile: Equatable, Sendable {
    let name: String
    let path: String
    let sizeBytes: Int64
    let formattedSize: String
    let modificationDate: Date
    let isDirectory: Bool

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }
}

enum FinderTargetSource: String, Sendable {
    case selection = "selection"
    case queryNamedFolder = "query-named folder"
    case openWindow = "open Finder window"
    case windowlessRoots = "default user roots"
}

struct FinderGroundingOutcome: Equatable, Sendable {
    let targetPath: String
    let targetSource: FinderTargetSource
    let matchingFiles: [FinderGroundedFile]
    let recentFiles: [FinderGroundedFile]
    let totalItemsCount: Int

    var summary: String {
        "target=\(targetPath) source=\(targetSource.rawValue) matches=\(matchingFiles.count) recent=\(recentFiles.count)"
    }
}

enum FinderContextGrounder {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "FinderContextGrounder")

    private static let stopWords: Set<String> = [
        "a", "about", "all", "an", "and", "any", "are", "as", "at", "be",
        "can", "check", "could", "did", "do", "does", "document", "documents",
        "download", "downloads", "file", "files", "find", "for", "from",
        "get", "give", "have", "here", "how", "i", "in", "is", "it",
        "item", "items", "latest", "me", "my", "new", "of", "on", "open",
        "our", "please", "read", "recent", "search", "show", "some", "tell",
        "that", "the", "there", "this", "to", "view", "what", "where",
        "which", "with", "would", "you"
    ]

    /// Whether a query asks about local files, directories, or mentions standard macOS folders.
    static func wantsFileGrounding(_ query: String) -> Bool {
        let text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        // Mentioning any folder target
        if text.contains("download") || text.contains("document")
            || text.contains("desktop") || text.contains("picture")
            || text.contains("photo") || text.contains("movie")
            || text.contains("music") || text.contains("folder")
            || text.contains("directory") || text.contains("~/")
        {
            return true
        }

        // Mentioning file inquiries or extensions
        let fileTerms = [
            "file", "files", "document", "documents", "pdf", "png", "jpg",
            "jpeg", "csv", "json", "txt", "docx", "zip", "sharecode",
            "tax", "invoice", "receipt", "resume", "cv", "code", "script"
        ]
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.contains(where: { fileTerms.contains($0) })
    }

    /// Extracts a named directory from the query (e.g. "downloads" -> ~/Downloads).
    static func extractNamedFolder(from query: String) -> URL? {
        let lower = query.lowercased()
        let fm = FileManager.default

        if lower.contains("download") {
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        if lower.contains("document") {
            return fm.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        if lower.contains("desktop") {
            return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        if lower.contains("picture") || lower.contains("photo") {
            return fm.urls(for: .picturesDirectory, in: .userDomainMask).first
        }
        if lower.contains("movie") || lower.contains("video") {
            return fm.urls(for: .moviesDirectory, in: .userDomainMask).first
        }
        if lower.contains("music") {
            return fm.urls(for: .musicDirectory, in: .userDomainMask).first
        }

        // Explicit ~/path matching
        if let range = query.range(of: "~/[a-zA-Z0-9_.-]+", options: .regularExpression) {
            let path = String(query[range]).replacingOccurrences(of: "~", with: NSHomeDirectory())
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }

        // Check if query names an arbitrary existing user folder
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) }
        for token in tokens {
            if let folder = FinderCoworkerCapabilities.namedFolder(token) {
                return folder
            }
        }

        return nil
    }

    /// Extracts search keywords from the user's prompt (excluding common conversational stopwords).
    static func extractQueryKeywords(from query: String) -> [String] {
        let cleaned = query.lowercased()
            .replacingOccurrences(of: "gov.uk", with: "gov uk")
            .replacingOccurrences(of: "right-to-work", with: "right to work")
        let rawTokens = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && !stopWords.contains($0) }

        var result: [String] = []
        for token in rawTokens {
            result.append(token)
            // Handle common typo variations e.g. "empolyment" -> stem "employ"
            if token.hasPrefix("empoly") || token.hasPrefix("employ") {
                result.append("employ")
            }
            if token == "sharecode" || token == "share-code" {
                result.append("share")
                result.append("code")
            }
        }
        return Array(Set(result))
    }

    /// Resolves Finder filesystem context through the 4-tier cascading hierarchy.
    static func resolveFinderContext(
        query: String? = nil,
        finderSelection: [String] = []
    ) -> FinderGroundingOutcome {
        let fm = FileManager.default

        // Tier 1: User explicitly highlighted files in Finder
        let existingSelection = finderSelection.filter { fm.fileExists(atPath: $0) }
        if !existingSelection.isEmpty {
            let files = existingSelection.compactMap { makeGroundedFile(at: URL(fileURLWithPath: $0)) }
            let parentDir = URL(fileURLWithPath: existingSelection[0]).deletingLastPathComponent().path
            return FinderGroundingOutcome(
                targetPath: parentDir,
                targetSource: .selection,
                matchingFiles: files,
                recentFiles: files,
                totalItemsCount: files.count
            )
        }

        // Tier 2: Query explicitly mentions a folder (e.g. "downloads", "documents")
        if let query, let namedURL = extractNamedFolder(from: query) {
            let files = filesInDirectory(namedURL)
            let keywords = extractQueryKeywords(from: query)
            let matches = matchFiles(in: files, keywords: keywords, rawQuery: query)
            return FinderGroundingOutcome(
                targetPath: namedURL.path,
                targetSource: .queryNamedFolder,
                matchingFiles: matches,
                recentFiles: files,
                totalItemsCount: files.count
            )
        }

        // Tier 3: Open Finder window target (if any Finder window is currently open)
        if let frontDir = ContextDetector.shared.getCurrentFinderDirectory(), !frontDir.isEmpty {
            let url = URL(fileURLWithPath: frontDir)
            let files = filesInDirectory(url)
            let keywords = query.map(extractQueryKeywords) ?? []
            let matches = matchFiles(in: files, keywords: keywords, rawQuery: query ?? "")
            return FinderGroundingOutcome(
                targetPath: frontDir,
                targetSource: .openWindow,
                matchingFiles: matches,
                recentFiles: files,
                totalItemsCount: files.count
            )
        }

        // Tier 4: Windowless / closed Finder fallback to standard user roots
        let defaultRoots: [URL] = [
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            fm.urls(for: .desktopDirectory, in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }

        var allRecent: [FinderGroundedFile] = []
        for root in defaultRoots {
            allRecent.append(contentsOf: filesInDirectory(root, limit: 15))
        }
        allRecent.sort { $0.modificationDate > $1.modificationDate }

        let keywords = query.map(extractQueryKeywords) ?? []
        let matches = matchFiles(in: allRecent, keywords: keywords, rawQuery: query ?? "")
        let rootNames = defaultRoots.map { $0.lastPathComponent }.joined(separator: ", ")

        return FinderGroundingOutcome(
            targetPath: "~/(\(rootNames))",
            targetSource: .windowlessRoots,
            matchingFiles: matches,
            recentFiles: Array(allRecent.prefix(20)),
            totalItemsCount: allRecent.count
        )
    }

    /// Enumerates non-hidden files in `directory` sorted by modification date descending.
    static func filesInDirectory(_ directory: URL, limit: Int = 40) -> [FinderGroundedFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .nameKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey
        ]
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else {
            return []
        }

        var results: [FinderGroundedFile] = []
        for item in items {
            guard let grounded = makeGroundedFile(at: item) else { continue }
            results.append(grounded)
        }
        results.sort { $0.modificationDate > $1.modificationDate }
        return Array(results.prefix(limit))
    }

    /// Matches files against query keywords and phrases.
    static func matchFiles(
        in files: [FinderGroundedFile],
        keywords: [String],
        rawQuery: String
    ) -> [FinderGroundedFile] {
        guard !keywords.isEmpty else { return [] }
        var scored: [(file: FinderGroundedFile, score: Int)] = []

        let cleanQuery = rawQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        for file in files {
            let lowerName = file.name.lowercased()
            var score = 0

            // Direct substring match with entire query fragment
            if !cleanQuery.isEmpty && lowerName.contains(cleanQuery) {
                score += 10
            }

            for keyword in keywords {
                if lowerName.contains(keyword) {
                    score += 3
                } else if keyword.count >= 4 && lowerName.contains(keyword.prefix(4)) {
                    score += 1
                }
            }

            if score > 0 {
                scored.append((file, score))
            }
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.file.modificationDate > $1.file.modificationDate
        }

        return scored.map(\.file)
    }

    /// Formats a single file into a grounded metadata object.
    private static func makeGroundedFile(at url: URL) -> FinderGroundedFile? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }

        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return nil }
        let size = Int64(values.fileSize ?? 0)
        let date = values.contentModificationDate ?? Date.distantPast
        let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)

        return FinderGroundedFile(
            name: name,
            path: url.path,
            sizeBytes: size,
            formattedSize: formattedSize,
            modificationDate: date,
            isDirectory: isDir.boolValue
        )
    }

    /// Formats a clean, factual markdown prompt block for model consumption.
    static func promptBlock(for outcome: FinderGroundingOutcome) -> String {
        var lines: [String] = [
            "### Live Finder Filesystem Context (read just now)",
            "- Target Directory: \(outcome.targetPath) (\(outcome.targetSource.rawValue))"
        ]

        if !outcome.matchingFiles.isEmpty {
            lines.append("- Verified Matches for your question:")
            for match in outcome.matchingFiles.prefix(5) {
                let kind = match.isDirectory ? "folder" : match.formattedSize
                lines.append("  • \(match.name) (\(kind), modified \(match.formattedDate), path: \(match.path))")
            }
        }

        if !outcome.recentFiles.isEmpty {
            let names = outcome.recentFiles.prefix(10).map(\.name).joined(separator: ", ")
            lines.append("- Recent items in target directory (\(outcome.recentFiles.count) total): \(names)")
        }

        return lines.joined(separator: "\n")
    }
}
